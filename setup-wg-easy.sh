#!/usr/bin/env bash
# =============================================================================
# setup-wg-easy.sh —— 在全新的 Debian/Ubuntu 云服务器上一键部署 wg-easy (v15)
#
# 目标架构:
#   客户端 --(IPv6 / UDP 自定义端口)--> 服务器 --(IPv4 出口)--> Internet
#   隧道内部只走 IPv4;Web 面板只监听 127.0.0.1,通过 SSH 端口转发访问。
#
# 用法 (root 身份运行,例如先 sudo -i):
#   bash setup-wg-easy.sh --host vpn.example.com --port 52116
#   bash setup-wg-easy.sh            # 不带参数:自动探测 IPv6,端口用 52116
#
# 选项 (也可用同名环境变量传入,见下方默认值):
#   --host  <域名或IP>    客户端连接的地址 (IPv6 字面量无需加方括号)
#   --port  <UDP端口>     WireGuard 对外端口 (默认: 52116;必须与你在云安全组放行的端口一致)
#   --user  <用户名>      面板管理员用户名 (默认: admin)
#   --password <密码>     面板管理员密码 (默认: 随机生成;建议不要用命令行传,会留在历史记录里)
#   --dns <DNS>           下发给客户端的 DNS (默认: 1.1.1.1)
#   --ipv4-cidr <网段>    隧道 IPv4 网段 (默认: 10.8.0.0/24)
#   --harden-ssh          禁用 SSH 密码登录 (需要当前登录用户已配置公钥)
#                         (默认不改;IPv6 入站 UDP 测试不通时再用)
#   -h, --help            显示本帮助
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
ADMIN_PASS="${ADMIN_PASS:-}"
WG_DNS="${WG_DNS:-1.1.1.1}"
WG_IPV4_CIDR="${WG_IPV4_CIDR:-10.8.0.0/24}"
WG_IPV6_CIDR="${WG_IPV6_CIDR:-fd42:42:42::/64}"   # wg-easy 要求与 IPv4 网段成对设置
WG_ALLOWED_IPS="${WG_ALLOWED_IPS:-0.0.0.0/0}"     # 只接管 IPv4,不含 ::/0
DO_HARDEN_SSH=0

# ----------------------------- 工具函数 --------------------------------------
log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,/^# =====.*$/p' "$0" | sed -n '2,30p' | sed 's/^# \{0,1\}//'; }

# ----------------------------- 参数解析 --------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)       WG_HOST="${2:?--host 缺少参数值}"; shift 2 ;;
    --port)       WG_PORT="${2:?--port 缺少参数值}"; shift 2 ;;
    --user)       ADMIN_USER="${2:?--user 缺少参数值}"; shift 2 ;;
    --password)   ADMIN_PASS="${2:?--password 缺少参数值}"; shift 2 ;;
    --dns)        WG_DNS="${2:?--dns 缺少参数值}"; shift 2 ;;
    --ipv4-cidr)  WG_IPV4_CIDR="${2:?--ipv4-cidr 缺少参数值}"; shift 2 ;;
    --harden-ssh) DO_HARDEN_SSH=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *)            die "未知参数: $1 (用 --help 查看用法)" ;;
  esac
done

# ----------------------------- 前置检查 --------------------------------------
[[ $EUID -eq 0 ]] || die "请以 root 运行 (例如先执行 sudo -i)"
command -v apt-get >/dev/null 2>&1 || die "目前只支持 Debian/Ubuntu (需要 apt-get)"

if [[ -f "$COMPOSE_FILE" ]]; then
  die "检测到已有部署: $COMPOSE_FILE。为避免覆盖现有数据,脚本只用于全新安装。"
fi
if command -v docker >/dev/null 2>&1 && docker ps -a --format '{{.Names}}' | grep -qx 'wg-easy'; then
  die "已存在名为 wg-easy 的容器,请先处理后再运行。"
fi

# 端口:默认 52116,可用 --port 修改 (云安全组由你自己配置,脚本不再随机选端口)
[[ "$WG_PORT" =~ ^[0-9]+$ ]] && (( WG_PORT >= 1 && WG_PORT <= 65535 )) || die "端口不合法: $WG_PORT"
(( WG_PORT != WEB_PORT )) || die "WireGuard 端口不能与面板端口 ${WEB_PORT} 相同"
log "将使用 UDP ${WG_PORT};请确认云安全组已放行该端口 (IPv4 与 IPv6 规则要分别添加)"

# 账号密码
[[ "$ADMIN_USER" =~ ^[A-Za-z0-9._-]{3,32}$ ]] || die "用户名只允许字母数字和 . _ - (3-32 位)"
if [[ -z "$ADMIN_PASS" ]]; then
  ADMIN_PASS="admin"
fi

# 探测 Host (优先 IPv6)
detect_ipv6() {
  local ip
  ip="$(curl -6 -fsS --max-time 5 https://api64.ipify.org 2>/dev/null || true)"
  if [[ "$ip" == *:* ]]; then echo "$ip"; return; fi
  ip -6 addr show scope global 2>/dev/null | awk '/inet6/{print $2}' | cut -d/ -f1 | head -n1 || true
}
if [[ -z "$WG_HOST" ]]; then
  apt-get update -y >/dev/null
  apt-get install -y curl ca-certificates iproute2 >/dev/null
  WG_HOST="$(detect_ipv6)"
  [[ -n "$WG_HOST" ]] || die "没能探测到公网 IPv6,请用 --host 指定域名或地址"
  log "自动探测到 Host: $WG_HOST"
fi
# IPv6 字面量在 Endpoint 中必须带方括号
HOST_FOR_INIT="$WG_HOST"
if [[ "$WG_HOST" == *:* && "$WG_HOST" != \[* ]]; then
  HOST_FOR_INIT="[${WG_HOST}]"
fi

# ----------------------------- 1. 系统更新 -----------------------------------
log "安装基础工具 (不做系统升级,需要的话请自行 apt full-upgrade 后重启再运行本脚本)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl ca-certificates iproute2

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
      - "INIT_PASSWORD=${ADMIN_PASS}"
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
CRED_FILE="/root/wg-easy-credentials.txt"
umask 077
cat > "$CRED_FILE" <<EOF
面板地址 : http://127.0.0.1:${WEB_PORT}  (需先建立 SSH 端口转发)
用户名   : ${ADMIN_USER}
密码     : ${ADMIN_PASS}
Host     : ${HOST_FOR_INIT}
UDP 端口 : ${WG_PORT}
EOF
chmod 600 "$CRED_FILE"

echo
log "自检"
if ss -H -tln "sport = :${WEB_PORT}" | awk '{print $4}' | grep -qv '^127\.0\.0\.1:'; then
  warn "面板端口似乎监听在非回环地址,请检查 compose 的 ports 配置!"
else
  echo "  面板端口仅监听 127.0.0.1  ✓"
fi
echo "  UDP ${WG_PORT} 监听情况:"
ss -uln "sport = :${WG_PORT}" | sed 's/^/    /'
if ss -H -uln "sport = :${WG_PORT}" | grep -q '\[::\]:'; then
  echo "  UDP ${WG_PORT} 已监听 IPv6  ✓"
else
  warn "UDP ${WG_PORT} 未发现 IPv6 监听，请检查 Docker 端口发布配置。"
fi

cat <<EOF

==================== 部署完成 ====================
管理员账号已保存到 ${CRED_FILE} (权限 600),查看后请自行妥善保管或删除。

  用户名 : ${ADMIN_USER}
  密码   : ${ADMIN_PASS}

下一步:
  1. 云厂商安全组放行 UDP ${WG_PORT},IPv4 与 IPv6 要分别添加。
  2. 在你自己的电脑上建立 SSH 端口转发 (IPv6 地址不要加方括号):
       ssh -L ${WEB_PORT}:127.0.0.1:${WEB_PORT} ${SUDO_USER:-root}@<服务器地址>
     然后浏览器打开 http://127.0.0.1:${WEB_PORT}
  3. 如果打开后看到的是"初始化向导"而不是登录页,说明 INIT_* 没有生效
     (已有用户反馈过),按向导手动填写:
       Host=${HOST_FOR_INIT}  Port=${WG_PORT}
     完成后在管理设置里把默认 AllowedIPs 改为 ${WG_ALLOWED_IPS}。
  4. 面板里点 New Client 添加设备;客户端连上后验证:
       curl -4 ifconfig.me    # 应显示服务器 IPv4
       docker exec wg-easy wg show

升级:  cd ${INSTALL_DIR} && docker compose pull && docker compose up -d
备份:  升级前在面板里下载备份;所有 peer 与私钥都在 etc_wireguard 数据卷里
=================================================
EOF
