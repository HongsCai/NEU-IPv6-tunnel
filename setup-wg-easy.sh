#!/usr/bin/env bash
# =============================================================================
# setup-wg-easy.sh —— 在云服务器上一键部署 wg-easy (v15)
#
# 目标架构:
#   客户端 --(IPv6 / UDP 自定义端口)--> 服务器 --(IPv4 出口)--> Internet
#   隧道内部只走 IPv4;Web 面板只监听 127.0.0.1,通过 SSH 端口转发访问。
#
# 选项 (也可用同名环境变量传入,见下方默认值):
#   --host <域名或IP>   客户端连接的地址 (IPv6 字面量无需加方括号)
#   --port <UDP端口>    WireGuard 对外端口 (默认: 52116;必须与你在云安全组放行的端口一致)
#   --user <用户名>     面板管理员用户名 (默认: admin)
#   --password <密码>   面板管理员密码 (默认: 123456789123;建议部署后立即修改,
#                       也不建议用命令行传,会留在历史记录里)
#   --dns <DNS>         下发给客户端的 DNS (默认: 1.1.1.1)
#   --ipv4-cidr <网段>  隧道 IPv4 网段 (默认: 10.8.0.0/24)
#   --allowed-ips <列表> 客户端默认 AllowedIPs,逗号分隔,不要带空格 (默认: 0.0.0.0/1,128.0.0.0/1)
#   --harden-ssh        禁用 SSH 密码登录 (需要当前登录用户已配置公钥)
#                       (默认不改;IPv6 入站 UDP 测试不通时再用)
#   --reinstall         检测到已有部署时不再询问,直接删除并重装 (非交互环境必须加)
#   -h, --help          显示本帮助
# =============================================================================
set -euo pipefail

# ----------------------------- 可调参数 --------------------------------------
INSTALL_DIR="/etc/docker/containers/wg-easy"
COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
IMAGE="ghcr.io/wg-easy/wg-easy:15"
WEB_PORT=51821

WG_HOST="${WG_HOST:-}"
WG_PORT="${WG_PORT:-52116}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASS="${ADMIN_PASS:-123456789123}"
WG_DNS="${WG_DNS:-1.1.1.1}"
WG_IPV4_CIDR="${WG_IPV4_CIDR:-10.8.0.0/24}"
WG_IPV6_CIDR="${WG_IPV6_CIDR:-fd42:42:42::/64}"   # wg-easy 要求与 IPv4 网段成对设置
WG_ALLOWED_IPS="${WG_ALLOWED_IPS:-0.0.0.0/1,128.0.0.0/1}"     # 只接管 IPv4,不含 ::/0
DO_HARDEN_SSH=0
FORCE_REINSTALL=0
CRED_FILE="/root/wg-easy-credentials.txt"

# ----------------------------- 工具函数 --------------------------------------
log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
用法 (root 身份运行):
  bash setup-wg-easy.sh --host vpn.example.com --port 52116
  bash setup-wg-easy.sh            # 自动探测 IPv6,端口 52116

选项 (也可用同名环境变量传入):
  --host <域名或IP>   客户端连接的地址 (IPv6 字面量无需加方括号)
  --port <UDP端口>    WireGuard 对外端口 (默认 52116,需与云安全组一致)
  --user <用户名>     面板管理员用户名 (默认 admin)
  --password <密码>   面板管理员密码 (默认 123456789123,部署后请尽快修改)
  --dns <DNS>         下发给客户端的 DNS (默认 1.1.1.1)
  --ipv4-cidr <网段>  隧道 IPv4 网段 (默认 10.8.0.0/24)
  --allowed-ips <列表> 客户端默认 AllowedIPs,逗号分隔 (默认 0.0.0.0/1,128.0.0.0/1)
  --harden-ssh        禁用 SSH 密码登录 (需要已配置公钥)
  --reinstall         已有部署时不询问,直接删除并重装 (会清空所有客户端)
  -h, --help          显示本帮助
EOF
}

# ----------------------------- 参数解析 --------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)       WG_HOST="${2:?--host 缺少参数值}"; shift 2 ;;
    --port)       WG_PORT="${2:?--port 缺少参数值}"; shift 2 ;;
    --user)       ADMIN_USER="${2:?--user 缺少参数值}"; shift 2 ;;
    --password)   ADMIN_PASS="${2:?--password 缺少参数值}"; shift 2 ;;
    --dns)        WG_DNS="${2:?--dns 缺少参数值}"; shift 2 ;;
    --ipv4-cidr)  WG_IPV4_CIDR="${2:?--ipv4-cidr 缺少参数值}"; shift 2 ;;
	--allowed-ips) WG_ALLOWED_IPS="${2:?--allowed-ips 缺少参数值}"; shift 2 ;;
    --harden-ssh) DO_HARDEN_SSH=1; shift ;;
    --reinstall)  FORCE_REINSTALL=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) die "未知参数: $1 (用 --help 查看用法)" ;;
  esac
done

WG_ALLOWED_IPS="${WG_ALLOWED_IPS// /}"

# ----------------------------- 前置检查 --------------------------------------
[[ $EUID -eq 0 ]] || die "请以 root 运行 (例如先执行 sudo -i)"
command -v apt-get >/dev/null 2>&1 || die "目前只支持 Debian/Ubuntu (需要 apt-get)"

# ----------------------------- 已有部署检测 ----------------------------------
has_existing() {
  [[ -f "$COMPOSE_FILE" ]] && return 0
  command -v docker >/dev/null 2>&1 || return 1
  docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx 'wg-easy' && return 0
  docker volume ls -q 2>/dev/null | grep -qx 'wg-easy_etc_wireguard' && return 0
  return 1
}

remove_existing() {
  log "删除旧的 wg-easy 部署"
  if command -v docker >/dev/null 2>&1; then
    if [[ -f "$COMPOSE_FILE" ]]; then
      ( cd "$INSTALL_DIR" && docker compose down -v --remove-orphans ) || warn "docker compose down 失败,继续强制清理"
    fi
    # compose 文件丢失或 down 不彻底时的兜底清理
    docker rm -f wg-easy >/dev/null 2>&1 || true
    docker volume rm -f wg-easy_etc_wireguard >/dev/null 2>&1 || true
    docker network rm wg-easy_wg >/dev/null 2>&1 || true
  fi
  rm -rf "$INSTALL_DIR"
  rm -f "$CRED_FILE"
}

if has_existing; then
  warn "检测到已有 wg-easy 部署 (${INSTALL_DIR} / 容器 wg-easy / 数据卷 etc_wireguard)。"
  warn "重装会删除容器、数据卷和配置文件,面板里所有客户端与密钥都会丢失,且无法恢复!"
  if (( FORCE_REINSTALL )); then
    ans="y"
  else
    printf '\033[1;33m[?]\033[0m 是否删除旧部署并重装? [y/N] ' >&2
    # 经 curl | bash 运行时 stdin 是管道,必须从 /dev/tty 读取
    if ! read -r ans 2>/dev/null </dev/tty; then
      echo >&2
      die "当前是非交互环境,无法询问。确认要重装请加 --reinstall (bash -s -- --reinstall)"
    fi
  fi
  case "$ans" in
    y|Y|yes|YES|Yes) remove_existing ;;
    *) die "已取消,未做任何改动。" ;;
  esac
fi

# 端口:默认 52116,可用 --port 修改 (云安全组由你自己配置,脚本不再随机选端口)
[[ "$WG_PORT" =~ ^[0-9]+$ ]] && (( WG_PORT >= 1 && WG_PORT <= 65535 )) || die "端口不合法: $WG_PORT"
(( WG_PORT != WEB_PORT )) || die "WireGuard 端口不能与面板端口 ${WEB_PORT} 相同"
log "将使用 UDP ${WG_PORT};请确认云安全组已放行该端口 (需放行 IPv6)"

# 账号密码
[[ "$ADMIN_USER" =~ ^[A-Za-z0-9._-]{3,32}$ ]] || die "用户名只允许字母数字和 . _ - (3-32 位)"
# 密码会写进 compose 的双引号字符串,这两个字符会破坏 YAML
[[ "$ADMIN_PASS" != *\"* && "$ADMIN_PASS" != *\\* ]] || die '密码不能包含双引号 " 或反斜杠 \'
if (( ${#ADMIN_PASS} < 12 )) \
   || ! [[ "$ADMIN_PASS" =~ [A-Z] && "$ADMIN_PASS" =~ [a-z] && "$ADMIN_PASS" =~ [0-9] && "$ADMIN_PASS" =~ [^A-Za-z0-9] ]]; then
  warn "密码强度可能不满足 wg-easy v15 的要求 (≥12 位,含大小写、数字、特殊字符)。"
  warn "如果不满足,INIT_* 可能不生效,部署后会看到\"初始化向导\",按提示手动设置即可。"
fi
# compose 里 $ 会被当成变量插值,需要写成 $$
COMPOSE_PASS="${ADMIN_PASS//\$/\$\$}"

# ----------------------------- 1. 基础工具 -----------------------------------
log "安装基础工具 (不做系统升级,需要的话请自行 apt full-upgrade 后重启再运行本脚本)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl ca-certificates iproute2

# 探测 Host (优先 IPv6;排除临时地址、已弃用地址和 ULA)
detect_ipv6() {
  local ip
  ip="$(curl -6 -fsS --max-time 5 https://api64.ipify.org 2>/dev/null || true)"
  if [[ "$ip" == *:* ]]; then echo "$ip"; return; fi
  ip -6 addr show scope global -deprecated 2>/dev/null \
    | awk '/inet6/ && !/temporary/ {print $2}' | cut -d/ -f1 \
    | grep -viE '^f[cd]' | head -n1 || true
}

if [[ -z "$WG_HOST" ]]; then
  WG_HOST="$(detect_ipv6)"
  [[ -n "$WG_HOST" ]] || die "没能探测到公网 IPv6,请用 --host 指定域名或地址"
  log "自动探测到 Host: $WG_HOST"
fi

# IPv6 字面量在 Endpoint 中必须带方括号
HOST_FOR_INIT="$WG_HOST"
if [[ "$WG_HOST" == *:* && "$WG_HOST" != \[* ]]; then
  HOST_FOR_INIT="[${WG_HOST}]"
fi
# SSH 命令里的地址:IPv6 不加方括号,直接用探测到的 Host
SSH_HOST="${WG_HOST#[}"; SSH_HOST="${SSH_HOST%]}"

# 端口占用检查 (放在安装之后,确保 ss 可用)
if ss -H -uln "sport = :${WG_PORT}" | grep -q .; then
  die "UDP ${WG_PORT} 已被占用 (如果是旧的 wg-quick@wg0,请先 systemctl disable --now wg-quick@wg0)"
fi
if ss -H -tln "sport = :${WEB_PORT}" | grep -q .; then
  die "TCP ${WEB_PORT} 已被占用"
fi

# ----------------------------- 2. Docker -------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  log "安装 Docker (官方脚本 get.docker.com)"
  curl -fsSL https://get.docker.com | sh
fi
docker compose version >/dev/null 2>&1 || die "缺少 docker compose 插件,请参考 Docker 官方文档安装"
systemctl enable --now docker

# ----------------------------- 3. 生成 compose -------------------------------
# mode=init : 带 INIT_* 变量,首次启动时自动完成初始化
# mode=plain: 不含账号密码,初始化完成后用它重建容器
write_compose() {
  local mode="$1" init_block=""
  if [[ "$mode" == "init" ]]; then
    init_block="$(cat <<EOF
      - "INIT_ENABLED=true"
      - "INIT_USERNAME=${ADMIN_USER}"
      - "INIT_PASSWORD=${COMPOSE_PASS}"
      - "INIT_HOST=${HOST_FOR_INIT}"
      - "INIT_PORT=${WG_PORT}"
      - "INIT_DNS=${WG_DNS}"
      - "INIT_IPV4_CIDR=${WG_IPV4_CIDR}"
      - "INIT_IPV6_CIDR=${WG_IPV6_CIDR}"
      - "INIT_ALLOWED_IPS=${WG_ALLOWED_IPS}"
EOF
)"
  fi

  cat > "$COMPOSE_FILE" <<EOF
# 由 setup-wg-easy.sh 生成,结构参照 wg-easy 官方 compose
volumes:
  etc_wireguard:

services:
  wg-easy:
    image: ${IMAGE}
    container_name: wg-easy
    environment:
      - "INSECURE=true"
      - "DISABLE_IPV6=true"
${init_block}
    volumes:
      - etc_wireguard:/etc/wireguard
      - /lib/modules:/lib/modules:ro
    ports:
      - "${WG_PORT}:${WG_PORT}/udp"
      - "127.0.0.1:${WEB_PORT}:${WEB_PORT}/tcp"
    restart: unless-stopped
    networks:
      wg:
        ipv4_address: 10.42.42.42
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.src_valid_mark=1

networks:
  wg:
    driver: bridge
    enable_ipv6: false
    ipam:
      driver: default
      config:
        - subnet: 10.42.42.0/24
EOF
  chmod 600 "$COMPOSE_FILE"
}

wait_web() {
  local i code
  for i in $(seq 1 60); do
    code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${WEB_PORT}/" || true)"
    if [[ "$code" != "000" ]]; then return 0; fi
    sleep 2
  done
  return 1
}

log "部署 wg-easy (UDP ${WG_PORT}, 面板 127.0.0.1:${WEB_PORT})"
mkdir -p "$INSTALL_DIR"
write_compose init
( cd "$INSTALL_DIR" && docker compose up -d )

log "等待面板启动"
wait_web || { docker logs --tail 50 wg-easy || true; die "面板 120 秒内没有响应,请检查上面的日志"; }
sleep 5

# 初始化完成后,去掉 compose 里的明文账号密码并重建容器 (数据卷保留)
log "初始化完成,移除 compose 中的明文密码并重建容器"
write_compose plain
( cd "$INSTALL_DIR" && docker compose up -d --force-recreate )
wait_web || warn "重建后面板暂时没有响应,请稍后用 docker logs wg-easy 查看"

# ----------------------------- 4. 可选:SSH 加固 ------------------------------
if (( DO_HARDEN_SSH )); then
  login_user="${SUDO_USER:-root}"
  login_home="$(getent passwd "$login_user" | cut -d: -f6)"
  if [[ ! -s "${login_home}/.ssh/authorized_keys" ]]; then
    warn "${login_user} 没有 authorized_keys,跳过 SSH 加固,避免把自己锁在外面"
  elif ! grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config; then
    warn "sshd_config 没有 Include sshd_config.d,跳过 SSH 加固,请手动修改"
  else
    log "禁用 SSH 密码登录"
    root_login="prohibit-password"
    [[ "$login_user" != "root" ]] && root_login="no"
    # 文件名用 00- 开头:sshd 取第一个匹配的值,必须排在 50-cloud-init.conf 之前才生效
    cat > /etc/ssh/sshd_config.d/00-hardening.conf <<EOF
PasswordAuthentication no
PermitRootLogin ${root_login}
EOF
    if sshd -t; then
      systemctl restart ssh 2>/dev/null || systemctl restart sshd
      warn "请不要关闭当前窗口,另开终端确认密钥登录正常后再退出"
    else
      rm -f /etc/ssh/sshd_config.d/00-hardening.conf
      warn "sshd 配置校验失败,已回滚"
    fi
  fi
fi

# ----------------------------- 5. 结果与自检 ---------------------------------
( umask 077
  cat > "$CRED_FILE" <<EOF
面板地址 : http://127.0.0.1:${WEB_PORT}  (需先建立 SSH 端口转发)
用户名   : ${ADMIN_USER}
密码     : ${ADMIN_PASS}
Host     : ${HOST_FOR_INIT}
UDP 端口 : ${WG_PORT}
EOF
)
chmod 600 "$CRED_FILE"

echo
log "自检"
# 取所有 TCP 监听地址,只要存在非 127.0.0.1 的就告警
web_listen="$(ss -H -tln "sport = :${WEB_PORT}" | awk '{print $4}')"
if [[ -z "$web_listen" ]]; then
  warn "没有发现面板端口 ${WEB_PORT} 的监听,请用 docker logs wg-easy 检查"
elif grep -qv '^127\.0\.0\.1:' <<<"$web_listen"; then
  warn "面板端口似乎监听在非回环地址,请检查 compose 的 ports 配置!"
else
  echo "  面板端口仅监听 127.0.0.1 ✓"
fi
echo "  UDP ${WG_PORT} 监听情况:"
ss -uln "sport = :${WG_PORT}" | sed 's/^/    /'
if ss -H -uln "sport = :${WG_PORT}" | grep -q '\[::\]:'; then
  echo "  UDP ${WG_PORT} 已监听 IPv6 ✓"
else
  warn "UDP ${WG_PORT} 未发现 IPv6 监听,请检查 Docker 端口发布配置。"
fi

cat <<EOF

==================== 部署完成 ====================
管理员账号已保存到 ${CRED_FILE} (权限 600),查看后请自行妥善保管或删除。

  用户名 : ${ADMIN_USER}
  密码   : ${ADMIN_PASS}

下一步:
1. 安全组放行 UDP ${WG_PORT} (需放行 IPv6)。
2. 先输入 exit 退出当前的 SSH 连接,然后重新连接,并加上端口转发 -L ${WEB_PORT}:127.0.0.1:${WEB_PORT}:
     ssh -i <私钥路径> ${SUDO_USER:-root}@${SSH_HOST} -L ${WEB_PORT}:127.0.0.1:${WEB_PORT}
   - <私钥路径> 是与服务器 authorized_keys 中公钥对应的私钥文件;
     如果是用密码登录的,去掉 "-i <私钥路径>" 即可
   - 登录后请保持这个 SSH 窗口不要关闭,关闭后转发就会断开
   然后浏览器打开 http://127.0.0.1:${WEB_PORT}
3. 如果打开后看到的是"初始化向导"而不是登录页,说明 INIT_* 没有生效
   (已有用户反馈过),按向导手动填写:
     Host=${HOST_FOR_INIT}  Port=${WG_PORT}
   完成后在管理设置里把默认 AllowedIPs 改为 ${WG_ALLOWED_IPS}。
4. 面板里点 New Client 添加设备;客户端连上后验证:
     curl -4 ifconfig.me        # 应显示服务器 IPv4
     docker exec wg-easy wg show

升级: cd ${INSTALL_DIR} && docker compose pull && docker compose up -d
备份: 升级前在面板里下载备份;所有 peer 与私钥都在 etc_wireguard 数据卷里
=================================================
EOF