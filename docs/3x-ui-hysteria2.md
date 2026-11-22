# 3x-ui 双栈 Hysteria2 迁移手册

适用场景：一台双栈 Linux VPS 运行 3x-ui 和 Xray，Windows 用 Clash Verge Rev，Android 用 Clash Meta for Android。新机器、新云账号或更换域名都可按本手册从零重建。面板密码、Hysteria2 密码、私钥和订阅链接应通过私密渠道保管。

本手册适用于可接收公网流量的双栈 Linux 云服务器。部署时选同时支持 Hysteria2 和 Clash 高级模板的 3x-ui 稳定版，记录 3x-ui、Xray 和 Mihomo 版本，再按第 9 节校验。

> 建议顺序：新机网络 → 安全组和防火墙 → DNS → TLS 证书 → 3x-ui → 两个入站和一个客户端 → Xray 出站分流 → Clash 订阅模板 → 电脑及手机验收 → 切换。新旧服务器并行时优先给新机使用一对新域名，便于对照和回退。

## 1. 要迁移的结构与分流行为

| 层 | 当前做法 | 迁移要点 |
| --- | --- | --- |
| 订阅下载 | 两个 HTTPS 域名，均使用 TCP 2096 | 从同一个客户端生成的 Clash 订阅里获得两条节点，下载链接的地址族与节点选择分别设置 |
| 客户端到 VPS | Hysteria2 over QUIC，UDP 49606 | 两个独立监听，一个绑定服务器本地 IPv4，一个绑定服务器公网 IPv6 |
| 节点身份验证 | IP 字面量拨号，SNI 使用各自的证书域名 | DNS 地址、入站共享地址、SNI、证书 SAN 都要分别核对 |
| 用户凭据 | 一个客户端关联两个入站 | 生成一个新的 Hysteria2 密码和订阅标识，在 3x-ui 中私密保存 |
| 客户端可见代理组 | `连接方式`，选 `IPv6` 或 `IPv4` | 这里选择的是设备到 VPS 的 UDP 外层地址族 |
| VPS 到互联网 | Xray 对字面量公网 IPv6 使用 IPv6 出站，剩余流量经 IPv4 出站 | 例如在纯 IPv4 外网连接 IPv4 节点，仍可以访问通过代理转交的 IPv6 字面量目标 |

| 模式 | 普通公网 IPv4 | 国内公网 IPv6 | 国外公网 IPv6 | 局域网、门户与面板 |
| --- | --- | --- | --- | --- |
| Windows / Android TUN + 规则 | 走选中的 Hysteria2 节点 | 进入 Mihomo 后按 CN GeoIP 通过本地 IPv6 接口直出 | 走选中的 Hysteria2 节点 | 局域网、校园门户、两个管理面板有前置直连例外 |
| Windows / Android 系统代理 + 规则 | 国内直连，国外代理 | 国内直连 | 国外代理 | 学校域名、VPS 父域名、局域网与私有域名直连 |
| 全局模式 | 依客户端全局组 | 依客户端全局组 | 依客户端全局组 | 会跳过上述规则，日常使用统一选「规则」 |

- 国内 IPv6 当前用的是 **Mihomo 收到流量后直出**。验收时可以同时看到操作系统把初始目标路由给 TUN、Mihomo 命中 `直连 / IPv6-DIRECT`，以及物理网卡使用学校原生 IPv6 访问目标。这套方案不需要维护国内 IPv6 CIDR 白名单，电脑和手机可以用同一份订阅。
- 订阅中两个 `route-exclude-address` 专门用于 Hysteria2 外层端点。它们是操作系统路由层的精确例外，和国内 IPv6 的应用层规则是两件事。整段 `::/0` 会让国外 IPv6 同时绕开 TUN。
- TUN 的「公网 IPv4 都代理」适用于进入 Mihomo 且未命中前置例外的流量。面板、校园门户、局域网、学校 DNS、IPv4 节点自身的 QUIC 外层连接可能使用物理网 IPv4。若校园网络只剩 IPv6，启动后应选择 IPv6 节点，IPv4 直连的例外也可能不可达。
- 系统代理只接管遵守代理设置的应用。QQ 等程序可能自己创建 TCP 或 UDP 连接，应通过 Mihomo 连接页或本地网络观察确认。
- 域名代理请求与字面量 IP 请求的服务器出站可能不同。本方案的 Xray 规则按目标形态分流，送到 Xray 的域名通常会由 IPv4 出站解析和连接。如果要验证 VPS IPv6 出站，测试使用字面量 IPv6。

## 2. 改域名、改 IP 前填写迁移表

文中 `NEW_…` 都要替换。IPv6 入站的 `listen` 和 YAML 字面量使用裸 IPv6，只有 URL、curl `--resolve` 和 IPv6 DNS 的主机部分在需要时加方括号。

VPS 示例域名和公网 IP 使用预留的文档值，部署前填入自己的域名和服务器地址。校园网条目预填东北大学的配置。 [示例域名](https://www.rfc-editor.org/rfc/rfc2606.html) · [IPv4 文档地址](https://www.rfc-editor.org/rfc/rfc5737.html) · [IPv6 文档地址](https://www.rfc-editor.org/rfc/rfc3849.html)

| 变量 | 示例 | 新机如何填、在哪里改 |
| --- | --- | --- |
| `NEW_IPV4_FQDN` | `vpn4.vpn.example.com` | 新单栈 IPv4 域名，修改 A 记录、IPv4 TLS SNI、证书 SAN、订阅链接、面板直连规则 |
| `NEW_IPV6_FQDN` | `vpn6.vpn.example.com` | 新单栈 IPv6 域名，修改 AAAA 记录、IPv6 TLS SNI、证书 SAN、订阅链接、面板直连规则 |
| `NEW_NODE_DOMAIN_SUFFIX` | `vpn.example.com` | 自己控制且覆盖两个节点域名的父域，修改订阅 DNS 策略和 `DOMAIN-SUFFIX` |
| `NEW_PUBLIC_IPV4` | `198.51.100.10` | 客户端访问的公网 IPv4，修改 A、IPv4 对外共享地址、订阅节点、面板规则和 `/32` 端点排除 |
| `NEW_BIND_IPV4` | 公网直绑示例 `198.51.100.10`，NAT 映射示例 `10.0.1.10` | Linux 网卡上实际接收入站流量的 IPv4，填入 IPv4 入站 `listen` |
| `NEW_GLOBAL_IPV6` | `2001:db8:100::10` | 新机网卡的公网 IPv6，修改 AAAA、IPv6 入站 `listen`、订阅节点、面板规则和 `/128` 端点排除 |
| `NEW_CERT_NAME` | `vps-dualstack` | Certbot 证书名，同时更新面板、订阅、两个入站以及续期钩子的证书路径 |
| `NEW_PANEL_PATH` | `/随机字符串/` | 新机重新生成，按第 4.4 节设置。复制完整 URL 时保留前后斜杠。分流规则按目标和端口匹配 |
| `NEW_CLASH_PATH` / `NEW_SUB_ID` | 由 3x-ui 生成 | HTTPS 订阅路径和新客户端的订阅标识，使用面板实际生成的私有 URL |
| `V4_INBOUND_TAG` / `V6_INBOUND_TAG` | 由 3x-ui 生成 | 读取新机运行配置中的实际标签，用于 Xray 路由 |
| 订阅节点名称前缀 | `VPS Hysteria2 IPv4` / `VPS Hysteria2 IPv6` | 同步填写入站备注和 YAML 的两个 `filter` |
| 校园域名后缀 | `neu.edu.cn` | 东北大学校园网可保留。换学校时同步修改 DNS 策略和系统代理直连规则 |
| 校园认证门户 | `ipgw.neu.edu.cn` | 换学校时修改门户的 `DOMAIN` 直连规则 |
| 校园门户 IPv4 | `202.118.1.87/32` | 门户地址变化时更新 `IP-CIDR`，保留 `/32` |
| 校内 IPv4 DNS | `202.118.1.29`、`202.118.1.53` | 校园网内使用。换学校时填校内 DNS，只有一个时删去另外一条上游 |

如两个新域名没有合适的共同父域，把 DNS 中 `+.NEW_NODE_DOMAIN_SUFFIX` 拆成两个 `+.NEW_IPV4_FQDN`、`+.NEW_IPV6_FQDN`，规则中的父域直连也拆成两个对应的 `DOMAIN`。避免使用整个托管商域名或公共后缀。

## 3. 创建 VPS、设置防火墙和域名

### 3.1 云服务器网络与地址核对

1. 选支持公网 IPv4 入站、原生公网 IPv6 入站以及双栈出站的 Linux VPS。确认云平台允许 UDP 49606 并能将公网 IPv6 路由到服务器。在云控制台分配地址后，核对 Linux 网卡实际持有的全球单播 IPv6，并把它写入 AAAA 和 IPv6 入站。只提供出站的网络不能用于对应地址族的入站。
2. 对照云控制台和 `ip -br address` 判断 IPv4 是公网直绑还是通过云平台 NAT 映射。按下表填写监听地址、对外地址和端口映射。选长期稳定的公网地址，避免重建主机后旧订阅仍指向原地址。
3. 先确认 SSH 可达，再装面板。远程变更防火墙时保留原 SSH 会话，另开一个会话验证。检查系统版本、网卡地址和两族出站路由。

| IPv4 接入方式 | 3x-ui IPv4 入站监听 `NEW_BIND_IPV4` | DNS A、订阅与对外地址 `NEW_PUBLIC_IPV4` | 云平台要检查的项目 |
| --- | --- | --- | --- |
| 公网 IPv4 直接配置在网卡 | 网卡上的公网 IPv4 | 同一个公网 IPv4 | 云防火墙和主机防火墙允许所需端口 |
| 公网 IPv4 通过 NAT 映射到私网网卡 | 接收流量的私网 IPv4 | 云平台分配的公网 IPv4 | 一对一地址映射应包含相应入站协议。若用显式端口转发，把第 3.2 节实际使用的 TCP 和 UDP 端口原号转发到服务器 |

~~~bash
cat /etc/os-release
uname -m
ip -br address
ip -4 route
ip -6 route
ip -4 route get 1.1.1.1
ip -6 route get 2606:4700:4700::1111
~~~

### 3.2 入站端口清单

| 端口 / 协议 | 新机应放行的来源 | 作用 |
| --- | --- | --- |
| **49606/UDP** | IPv4 和 IPv6 客户端范围。经常换网络时分别为 `0.0.0.0/0` 和 `::/0` | Hysteria2 两个入站使用同一端口。能访问 TCP 49606 不能证明 QUIC 可用 |
| **2096/TCP** | 需要下载订阅的 IPv4 和 IPv6 客户端范围 | HTTPS Clash 订阅。必须支持校外 IPv4-only 网络时，保留 IPv4 |
| **15087/TCP** | 管理设备的实际公网 IPv4、IPv6 或管理网段，按需放行 | 3x-ui HTTPS 管理面板。校园原生 IPv6 访问也要在允许范围内 |
| **22/TCP** | 实际 SSH 管理来源，按需放行两族 | SSH |
| **80/TCP** | HTTP-01 期间签发域名关联的 IPv4、IPv6 公网 | Certbot HTTP-01 签发和续期。改用可自动续期的 DNS-01 时可省去 |
| **ICMPv6** | 根据网络策略允许必要的类型 | IPv6 路径 MTU 发现应保留 Packet Too Big 等必要消息 |

- 本方案需要的公网端口见上表。已有 WireGuard、TCP 代理或其他 HTTPS 服务时，按这些服务自己的需求管理对应规则。
- `7897` 只在客户端回环地址上使用，Xray 的内部 API 同样保留在回环接口。不要把它们开放到公网。
- 在云控制台的防火墙或安全组中，分别检查 IPv4、IPv6 入站，并允许所需的 DNS、TCP 和 UDP 出站。有状态防火墙会跟踪已允许连接的回包。如果另有无状态的网络访问规则，也要检查返回方向和临时端口。服务器的 UFW、firewalld 或 nftables 同样要允许实际使用的端口。先查看已生效的防火墙，再在原有规则体系里修改。

例如已经启用 UFW 的系统，先按实际管理来源放行 SSH 和面板，再开放公共服务。以下命令中管理地址和是否开放 `80/TCP` 按上表调整。云平台防火墙及 NAT 规则单独配置。

~~~bash
sudo ufw status verbose
sudo ufw allow from ADMIN_IPV4_CIDR to any port 22 proto tcp
sudo ufw allow from ADMIN_IPV6_CIDR to any port 22 proto tcp
sudo ufw allow from ADMIN_IPV4_CIDR to any port 15087 proto tcp
sudo ufw allow from ADMIN_IPV6_CIDR to any port 15087 proto tcp
sudo ufw allow 49606/udp
sudo ufw allow 2096/tcp
# 仅在使用 HTTP-01 时
sudo ufw allow 80/tcp
~~~

若使用 firewalld，在活动区域用相应的 `firewall-cmd` 端口或来源限制规则配置后重新加载。检查 UFW 是否开启 IPv6 支持，也检查实例有多张网卡时规则绑定到了正确的活动区域。

### 3.3 DNS

1. `NEW_IPV4_FQDN` 只设 A，指向 `NEW_PUBLIC_IPV4`。
2. `NEW_IPV6_FQDN` 只设 AAAA，指向 `NEW_GLOBAL_IPV6`。
3. 使用 Cloudflare 等 DNS 服务时，对这两个域名选仅 DNS。普通 HTTP 代理无法转发 Hysteria2 的 UDP 49606，也不应依赖其支持两个自定义 HTTPS 端口。
4. 从 VPS 和独立网络分别查询下列记录。多出来的、仍指向旧机的记录会造成订阅或签证书时偶发失败。

~~~bash
dig +short A NEW_IPV4_FQDN
dig +short AAAA NEW_IPV4_FQDN
dig +short A NEW_IPV6_FQDN
dig +short AAAA NEW_IPV6_FQDN
~~~

## 4. 安装 3x-ui 与证书

### 4.1 从官方仓库安装

在新服务器运行下面的命令。将 `VER` 换成官方 Releases 中实际存在的稳定标签。系统和架构以官方支持表为准。Ubuntu/Debian 示例包为 `curl`、`ca-certificates`、`certbot`、`jq`、`dnsutils`、`sqlite3`。其他系统按相应发行版安装 Certbot 和工具。 [3x-ui 官方安装与版本参数](https://github.com/MHSanaei/3x-ui#quick-start) · [官方 Releases](https://github.com/MHSanaei/3x-ui/releases)

~~~bash
VER='v3.11.0'  # 到 Releases 核对稳定版本后替换
curl --fail --silent --show-error --location \
  https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh \
  -o ./3x-ui-install.sh
less ./3x-ui-install.sh
sudo bash ./3x-ui-install.sh "$VER"
sudo systemctl status x-ui --no-pager
~~~

安装后把随机生成的账号、密码和访问路径保存到密码管理器。若初始面板是 HTTP，通过 SSH 转发到本地再登录设置 HTTPS。在 TCP 15087 的安全组规则就绪之前，可以一直通过 SSH 管理。

~~~bash
# 将 INSTALL_PORT 换成安装程序给出的临时面板端口
ssh -N -L 127.0.0.1:18087:127.0.0.1:INSTALL_PORT SSH_USER@NEW_SERVER
~~~

### 4.2 用一张证书覆盖两个域名

先保证两个域名在各自地址族可从公网访问 TCP 80，且该端口由 Certbot standalone 临时占用。用下面的示例签发，填写联系邮箱。80 无法开放时按 DNS 服务商的官方 Certbot DNS 插件流程签发和续期。 [Certbot 官方用法和续期](https://eff-certbot.readthedocs.io/en/stable/using.html)

~~~bash
FQDN4='NEW_IPV4_FQDN'
FQDN6='NEW_IPV6_FQDN'
CERT_NAME='NEW_CERT_NAME'
EMAIL='ADMIN_EMAIL'
sudo certbot certonly --standalone --preferred-challenges http \
  --cert-name "$CERT_NAME" --email "$EMAIL" --agree-tos \
  -d "$FQDN4" -d "$FQDN6"

sudo openssl x509 -in "/etc/letsencrypt/live/$CERT_NAME/fullchain.pem" \
  -noout -dates -ext subjectAltName
~~~

面板和 Hysteria2 一律使用 `fullchain.pem` 作证书、`privkey.pem` 作私钥。两条路径如下。保持私钥文件的严格权限，按服务实际运行用户授予最小访问权限。

~~~text
/etc/letsencrypt/live/NEW_CERT_NAME/fullchain.pem
/etc/letsencrypt/live/NEW_CERT_NAME/privkey.pem
~~~

确认系统有 Certbot 续期定时任务。需要时放置一个只匹配本证书的 deploy hook，让证书成功续期后 Xray 与面板重新加载。重启会短暂中断连接。

~~~bash
sudo install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
sudo tee /etc/letsencrypt/renewal-hooks/deploy/30-x-ui >/dev/null <<'EOF'
#!/bin/sh
set -eu
[ "${RENEWED_LINEAGE:-}" = /etc/letsencrypt/live/NEW_CERT_NAME ] || exit 0
exec systemctl restart x-ui
EOF
sudo chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/30-x-ui
sudo certbot renew --dry-run
systemctl list-timers --all | grep -i certbot
~~~

把钩子里的 `NEW_CERT_NAME` 换成实际名称。`--dry-run` 用于检查 ACME 续期流程，部署钩子通常不会随默认 dry-run 运行。检查现有钩子后再添加，避免同一张证书触发两次服务重启。

### 4.3 面板和订阅监听

在 3x-ui 面板设置中配置下列项目，保存并按界面提示重载。字段所在页与版本有关，优先找「面板设置」「订阅设置」「Clash」「全局路由规则」。

| 项目 | 值 |
| --- | --- |
| 面板 HTTPS | TCP `15087`，证书与私钥用第 4.2 节路径 |
| 面板监听 | 允许两族访问的监听。留空或双栈通配需用 `ss` 和两族 HTTPS 实测，避免设成仅回环或单族 |
| 面板路径 | 设置形如 `/随机字符串/` 的长随机路径，按第 4.4 节保存并验证 |
| 订阅服务 | 开启。HTTPS TCP `2096`，证书和私钥与面板相同 |
| Clash 订阅及全局路由 | 开启 Clash 格式和全局路由规则。确认 YAML 已应用到生成的 Clash 订阅 |
| 订阅路径 | 使用 3x-ui 私密生成的路径，复制客户端详情中的 **Clash** 订阅地址 |
| 域名配置 | 如界面有「订阅域名」或「输出 URL」字段，确认它只影响显示还是限制访问。分别用两个域名实测同一路径 |

~~~text
面板 v4   https://NEW_IPV4_FQDN:15087/NEW_PANEL_PATH/
面板 v6   https://NEW_IPV6_FQDN:15087/NEW_PANEL_PATH/
订阅 v4   https://NEW_IPV4_FQDN:2096/NEW_CLASH_PATH/NEW_SUB_ID
订阅 v6   https://NEW_IPV6_FQDN:2096/NEW_CLASH_PATH/NEW_SUB_ID
~~~

路径格式以面板实际生成的链接为准。复制路径时注意开头和结尾的斜杠。普通订阅、Clash 订阅和单节点 `hysteria2://` 分享链接用途不同。整个订阅 URL 与节点密码按凭据保管。

### 4.4 设置随机面板路径（IPv4 和 IPv6 共用）

`webBasePath` 是 `15087/TCP` 管理面板的基础路径。IPv4 和 IPv6 域名共用这个设置。新机独立生成路径，将两条完整登录 URL 存入密码管理器。路径降低被直接扫描发现的概率，登录仍由账号、密码和面板的访问控制保护。 [3x-ui 面板设置](https://docs.sanaei.dev/docs/config/panel/)

1. 先保持 SSH 会话可用，并按第 10.2 节备份数据库。在管理面板打开「面板设置」，找到「面板访问路径 / Web Base Path」，填入 `/随机字符串/`。可以用下面的命令在可信终端生成 36 位随机十六进制字符串，前后都带斜杠。
2. 保存并按提示重启面板。从新 URL 重新打开面板并登录。IPv4 是 `https://NEW_IPV4_FQDN:15087/NEW_PANEL_PATH/`，IPv6 是 `https://NEW_IPV6_FQDN:15087/NEW_PANEL_PATH/`。把 `NEW_PANEL_PATH` 换成路径中间的字符串，避免重复斜杠。
3. 两个域名的新地址应显示登录页，旧根路径应返回 HTTP 404。再刷新原有两族 Clash 订阅，核对 `2096/TCP` 上原订阅路径可用、节点和规则一致，并验证 `49606/UDP` 代理连接。Mihomo 的面板直连规则只看域名/IP 和端口，无需随路径修改。

SSH 也可以完成同一设置。以下命令适用于官方脚本安装的 3x-ui，使用之前先确认实际二进制路径。执行前记录原路径，供回滚使用。服务重启期间面板和代理连接可能短暂中断。

~~~bash
PANEL_PATH="/$(openssl rand -hex 18)/"
sudo /usr/local/x-ui/x-ui setting -webBasePath "$PANEL_PATH"
sudo systemctl restart x-ui
printf 'New panel base path: %s\n' "$PANEL_PATH"
~~~

如果新路径无法登录，从保留的 SSH 会话把 `OLD_PANEL_PATH` 换成变更前的路径并执行下面的命令。只有原来在根目录时才回滚到 `/`。从两族域名复核恢复后的入口。

~~~bash
sudo /usr/local/x-ui/x-ui setting -webBasePath 'OLD_PANEL_PATH'
sudo systemctl restart x-ui
~~~

若忘记当前路径，可以在私密 SSH 会话运行 `sudo /usr/local/x-ui/x-ui setting -show`，查找 `webBasePath`。不要把实际路径或订阅令牌放进公开的迁移文档、命令截图或日志。

## 5. 在 3x-ui 创建 IPv4 和 IPv6 Hysteria2 入站

创建 **两个入站**，然后将同一个客户端关联到它们。先在空状态配好证书和订阅，再创建入站可以减少排查变量。

| 字段 | IPv6 入站 | IPv4 入站 |
| --- | --- | --- |
| 备注 / 名称前缀 | `VPS Hysteria2 IPv6` | `VPS Hysteria2 IPv4` |
| 协议 | Hysteria，版本 `2`。若界面直接显示 Hysteria2 则选此项 | 同左 |
| 监听地址 | `NEW_GLOBAL_IPV6` | `NEW_BIND_IPV4` |
| 端口 | `49606` | `49606` |
| 传输 | Hysteria2 / QUIC UDP | 同左 |
| TLS | 启用。证书与私钥用第 4.2 节路径 | 同左 |
| TLS serverName / 客户端 SNI | `NEW_IPV6_FQDN` | `NEW_IPV4_FQDN` |
| ALPN | `h3` | `h3` |
| 证书验证 | 启用验证，客户端 `skip-cert-verify: false` 或字段省略 | 同左 |
| 分享地址 | 使用监听地址或自定义公网 IPv6。导出为裸 IPv6 字面量 | 共享地址选「自定义」，填公网 IPv4 `NEW_PUBLIC_IPV4` 和 `49606` |
| 外部代理地址（面板有此字段时） | 默认监听即可 | `dest=NEW_PUBLIC_IPV4`、`port=49606`、`forceTls=same` |
| 混淆 / Brutal | 不启用混淆，不填写虚构的上下行带宽，保持核心默认拥塞控制 | 同左 |

创建一个客户端，例如 `dualstack-client`。用密码管理器生成高熵密码并填入 Hysteria2 认证字段，生成新订阅 ID。将该客户端关联到两个入站，确认两个入站和客户端均启用。不同版本的客户端关联入口可能在「客户端」管理页或入站详情。若无法跨入站关联，检查所用版本是否支持一个客户端关联多个入站。

**IPv4 地址检查。** 「监听地址」填 `ip -br address` 中实际接收流量的 IPv4，「分享/自定义地址」填公网 IPv4。公网直绑时两项使用同一个地址，经 NAT 映射时分别使用本地 IPv4 和公网 IPv4。如果订阅节点出现 `10.0.1.10` 一类私网地址，修正分享地址后重新下载订阅。

~~~bash
sudo systemctl is-active x-ui
sudo ss -H -lunp 'sport = :49606'
sudo ss -H -ltnp '( sport = :15087 or sport = :2096 )'
sudo journalctl -u x-ui -n 50 --no-pager
~~~

UDP 检查应看到两个明确的地址，一个是 `NEW_BIND_IPV4:49606`，一个是 `[NEW_GLOBAL_IPV6]:49606`。同一端口的通配监听可能会和另一族冲突。日志中看到 `address already in use` 时，先确认分别绑定了实际网卡地址，并排查是否还有旧的独立 Hysteria2 服务。

## 6. 配置 Xray 服务端出站和路由

在 3x-ui 的 **Xray 配置 / 基础模板 / 路由** 编辑，保存后由面板生成运行配置。`/usr/local/x-ui/bin/config.json` 通常是生成结果，适合查看，不要把直接编辑这个文件作为迁移手段。Clash 订阅里的规则是客户端规则，和本节是独立的两层。 [Xray 路由](https://xtls.github.io/config/routing.html) · [Xray Freedom](https://xtls.github.io/config/outbounds/freedom.html) · [Xray sockopt](https://xtls.github.io/config/transports/sockopt.html)

先从两个现有入站读取新机的实际 tag，避免导出整个包含认证信息的文件。下面路径若与安装位置不同，从 `systemctl cat x-ui` 与面板日志确定。

~~~bash
CFG=/usr/local/x-ui/bin/config.json
sudo jq -r '.inbounds[] | select(.port == 49606) |
  [.tag,.listen,.port,.protocol] | @tsv' "$CFG"
sudo jq -r '.outbounds[] | [.tag,.protocol] | @tsv' "$CFG"
~~~

### 6.1 出站对象

合并下列对象到 `outbounds`，同名 tag 修改原对象。保留 `direct` 或你所用的普通出站在已有默认位置，也保留面板生成的内部对象。`finalRules` 要求 Xray 版本支持，上线前用核心测试。

~~~json
[
  {
    "tag": "direct",
    "protocol": "freedom",
    "settings": {
      "finalRules": [
        { "action": "block", "ip": ["geoip:private"] },
        { "action": "allow" }
      ]
    }
  },
  {
    "tag": "direct-ipv4",
    "protocol": "freedom",
    "settings": {
      "finalRules": [
        { "action": "block", "ip": ["geoip:private"] },
        { "action": "allow" }
      ]
    },
    "streamSettings": {
      "sockopt": { "domainStrategy": "ForceIPv4" }
    }
  },
  {
    "tag": "blocked",
    "protocol": "blackhole",
    "settings": {}
  }
]
~~~

### 6.2 顺序与精确规则

路由的 `domainStrategy` 设 `AsIs`。面板已有的内部 API 路由优先保留，以下四条排在其后、其他宽泛规则之前。将两个 `INBOUND_TAG` 替换成实际值。同一条路由中的 `type`、`inboundTag` 和目标条件示例如下。

~~~json
{
  "domainStrategy": "AsIs",
  "rules": [
    { "type": "field", "ip": ["geoip:private"], "outboundTag": "blocked" },
    { "type": "field", "protocol": ["bittorrent"], "outboundTag": "blocked" },
    {
      "type": "field",
      "inboundTag": ["V6_INBOUND_TAG", "V4_INBOUND_TAG"],
      "ip": ["2000::/3"],
      "outboundTag": "direct"
    },
    {
      "type": "field",
      "inboundTag": ["V6_INBOUND_TAG", "V4_INBOUND_TAG"],
      "network": "tcp,udp",
      "outboundTag": "direct-ipv4"
    }
  ]
}
~~~

合并时保留原模板的内部 API 规则。规则先拦截私网和已识别的 BitTorrent，再给字面量全球单播 IPv6 走普通出站。其他 TCP/UDP 走 `direct-ipv4`。服务器出口要同时有可用的 IPv4 和 IPv6 默认路由。测试后核对 `x-ui` 日志。BitTorrent 规则的命中依赖核心能够识别相应协议。

~~~bash
cd /usr/local/x-ui/bin
ls -1 xray*
# 把 XRAY_BINARY 换成实际二进制名。保持在安装目录运行，以便找到 geodata 文件。
sudo ./XRAY_BINARY run -test -config ./config.json
~~~

## 7. 粘贴完整的 3x-ui Clash 订阅模板

按第 2 节替换 `NEW_…`。如果不需要校园网直连，按第 7.1 节删除校园配置。把处理好的 **整个 YAML** 粘贴到 3x-ui「订阅设置 → Clash → 全局路由规则」并保存。使用 UTF-8。`proxies` 节点和密码由面板动态生成。如面板说明只提及代理组、规则提供者和规则，仍需以实际下载的 YAML 确认它保留了 `dns`、`tun` 和 `proxy-providers`。下载缺少这些字段时使用支持完整 YAML 合并的面板版本，或在客户端用配置覆写补齐，再按第 9 节验收。

~~~yaml
mixed-port: 7897
allow-lan: false
bind-address: "127.0.0.1"
mode: rule
log-level: info
ipv6: true
geodata-mode: true

profile:
  store-selected: true

dns:
  enable: true
  ipv6: true
  enhanced-mode: redir-host
  default-nameserver:
    - "2400:3200::1"
  proxy-server-nameserver:
    - "udp://[2400:3200::1]:53#DIRECT"
  nameserver-policy:
    "geosite:cn,private":
      - "udp://[2400:3200::1]:53#DIRECT"
      - "https://223.5.5.5/dns-query#连接方式"
    "+.neu.edu.cn":
      - "udp://[2400:3200::1]:53#DIRECT"
      - "udp://202.118.1.29:53#DIRECT"
      - "udp://202.118.1.53:53#DIRECT"
    "+.NEW_NODE_DOMAIN_SUFFIX":
      - "udp://[2400:3200::1]:53#DIRECT"
      - "https://223.5.5.5/dns-query#连接方式"
  nameserver:
    - "https://1.1.1.1/dns-query#连接方式"
    - "https://8.8.8.8/dns-query#连接方式"

tun:
  enable: false
  stack: mips
  device: Mihomo
  auto-route: true
  auto-detect-interface: true
  strict-route: true
  dns-mode: hijack
  dns-hijack:
    - "any:53"
    - "tcp://any:53"
  mtu: 1500
  route-exclude-address:
    - "NEW_PUBLIC_IPV4/32"
    - "NEW_GLOBAL_IPV6/128"

proxy-providers:
  本地IPv6:
    type: inline
    payload:
      - name: IPv6-DIRECT
        type: direct
        ip-version: ipv6
        udp: true

proxy-groups:
  - name: 连接方式
    type: select
    proxies:
      - IPv6
      - IPv4
  - name: IPv6
    type: select
    hidden: true
    include-all-proxies: true
    filter: "^VPS Hysteria2 IPv6"
  - name: IPv4
    type: select
    hidden: true
    include-all-proxies: true
    filter: "^VPS Hysteria2 IPv4"
  - name: 直连
    type: select
    hidden: true
    use:
      - 本地IPv6

rules:
  - "GEOIP,LAN,DIRECT,no-resolve"
  - "IP-CIDR6,fc00::/7,DIRECT,no-resolve"
  - "IP-CIDR6,fe80::/10,DIRECT,no-resolve"
  - "IP-CIDR6,ff00::/8,DIRECT,no-resolve"
  - "IP-CIDR6,::1/128,DIRECT,no-resolve"
  - "DOMAIN,ipgw.neu.edu.cn,DIRECT"
  - "IP-CIDR,202.118.1.87/32,DIRECT,no-resolve"
  - "AND,((IN-TYPE,TUN),(IP-CIDR6,2000::/3,no-resolve),(GEOIP,CN,no-resolve)),直连"
  - "AND,((DST-PORT,15087),(OR,((DOMAIN,NEW_IPV6_FQDN),(IP-CIDR6,NEW_GLOBAL_IPV6/128,no-resolve)))),直连"
  - "AND,((DST-PORT,15087),(OR,((DOMAIN,NEW_IPV4_FQDN),(IP-CIDR,NEW_PUBLIC_IPV4/32,no-resolve)))),DIRECT"
  - "IN-TYPE,TUN,连接方式"
  - "DOMAIN-SUFFIX,neu.edu.cn,DIRECT"
  - "DOMAIN-SUFFIX,NEW_NODE_DOMAIN_SUFFIX,DIRECT"
  - "GEOSITE,private,DIRECT"
  - "GEOSITE,cn,DIRECT"
  - "GEOIP,CN,DIRECT"
  - "MATCH,连接方式"
~~~

### 7.1 规则顺序与校园例外

- 局域网地址和校园认证门户先直连，保留未登录校园网时访问登录页的路径。模板中的门户和校内 DNS 供东北大学校园网使用。换学校时替换域名、门户 IPv4 和校内 DNS。没有校园网需求时可删除四处配置，分别是 `dns.nameserver-policy` 下整段 `+.neu.edu.cn`、`rules` 下的门户 `DOMAIN`、门户 `IP-CIDR` 和学校 `DOMAIN-SUFFIX`。
- `IN-TYPE,TUN` 限定了 TUN 规则的入口。已知真实目标地址为公网 IPv6、同时被 GeoIP 识别为中国大陆时才用 IPv6 直出。使用 `redir-host` 可保留真实地址。`no-resolve` 避免 TUN 规则因为额外查 DNS、取错候选地址而误把 IPv4 流量送去 IPv6 直连。GeoIP 数据把无法识别或尚未更新的地址交给后续代理兜底。
- 管理面板规则匹配「目标主机域名或 IP + 端口 15087」，在 TUN 兜底之前。IPv6 使用 IPv6-only 直连出站，IPv4 使用普通 DIRECT。面板端口改动时，两条 `DST-PORT` 都改。该规则不覆盖订阅 TCP 2096 与 SSH TCP 22。
- `IN-TYPE,TUN,连接方式` 命中以后，后面的学校域名、父域名、GeoSite、GeoIP 和 MATCH 处理非 TUN 流量。因此即使是国内域名，TUN 流量若目标是公网 IPv4，也按 TUN 规则交给代理，校园门户、面板等例外优先。系统代理下会优先使用 GeoSite 再用 GeoIP。
- GeoSite 和 GeoIP 需要能加载兼容的数据库。迁移初次无网时可以用已安装客户端的 geodata，或先用可访问网络让核心完成下载。 [Mihomo 路由规则](https://wiki.metacubex.one/config/rules/) · [Mihomo TUN](https://wiki.metacubex.one/config/inbound/tun/) · [Mihomo Hysteria2](https://wiki.metacubex.one/config/proxies/hysteria2/)

### 7.2 DNS 工作方式

| 请求 | 当前上游 | 出口 |
| --- | --- | --- |
| 国内、私有域名及 VPS 父域名 | 阿里 IPv6 UDP DNS 与经隧道的阿里 IPv4 DoH | 前者本地 IPv6 直连，后者经选中的 Hysteria2 节点。多个上游由 Mihomo 调度，不依赖固定的主备顺序 |
| 东北大学校园域名 | 阿里 IPv6 UDP DNS，外加校内 IPv4 DNS `202.118.1.29`、`202.118.1.53` | 均直连。校内 DNS 是本模板有意保留的 IPv4 DNS 直连例外 |
| 其他域名 | Cloudflare `1.1.1.1` 和 Google `8.8.8.8` DoH | 随 `连接方式` 经 VPS |
| 节点 DNS 引导 | IPv6 阿里 DNS | 两节点以 IP 拨号，TLS 单独用 SNI，正常情况下节点建连不需要 DNS |

上游自身用 IPv4 还是 IPv6，与它返回 A 或 AAAA 无关。`ipv6: true` 和 `dns.ipv6: true` 同时保留两类记录。外出只有 IPv4 连通时，节点组选 IPv4，国内 DoH 可以经 IPv4 隧道工作；校园 DNS 不可达时学校内网域名或门户的访问仍受物理网络限制。

系统 DNS 的 UDP/TCP 53 劫持受实际 TUN 设置影响。浏览器安全 DNS、Android 私人 DNS、应用自身的 DoH/DoT 都可能绕过 Mihomo 的 DNS 策略。做验收时先关闭这些应用级 DNS 覆盖，再单独开启观察。 [Mihomo DNS 配置](https://wiki.metacubex.one/config/dns/)

### 7.3 面板生成的节点应长什么样

这一段只用于核对订阅，**不要粘到第 7 节模板**。`NEW_HYSTERIA_PASSWORD` 由面板从客户端认证信息自动生成。部分版本省略默认值为 false 的 `skip-cert-verify`，实际连接时以校验证书通过为准。

~~~yaml
proxies:
  - name: "VPS Hysteria2 IPv6"
    type: hysteria2
    server: "NEW_GLOBAL_IPV6"
    port: 49606
    password: "NEW_HYSTERIA_PASSWORD"
    sni: "NEW_IPV6_FQDN"
    alpn: [h3]
    skip-cert-verify: false
  - name: "VPS Hysteria2 IPv4"
    type: hysteria2
    server: "NEW_PUBLIC_IPV4"
    port: 49606
    password: "NEW_HYSTERIA_PASSWORD"
    sni: "NEW_IPV4_FQDN"
    alpn: [h3]
    skip-cert-verify: false
~~~

## 8. 让 Windows 和 Android 使用同一份订阅

### 8.1 Windows：Clash Verge Rev

1. 第一次导入或更新订阅时先临时关闭「TUN」和「系统代理」，减少下载被旧规则截获的情况。按当前网络选可达的 v4 或 v6 **订阅下载域名**。导入后检查两条节点和值，不从 URL 猜节点地址族。
2. 打开订阅界面选择新配置，出站模式设「规则」。在「代理组 → 连接方式」选择 IPv6（校园原生 IPv6）或 IPv4（IPv4-only 网络）。客户端会记住上一次选择，换网或换机后手动核对。
3. TUN 用法：启用 Clash Verge 的服务模式/管理员权限后打开「TUN」，并关闭系统代理，防止遵守代理设置的应用先接入本地混合端口导致其 `IN-TYPE` 变成 HTTP/SOCKS。核对核心显示 TUN 已开启与真实 IP DNS 生效。
4. 系统代理用法：关 TUN，开「系统代理」，维持规则模式。浏览器应进入 `127.0.0.1:7897`。手工设置代理的程序可以用同一端口。两种模式互斥时，连接日志最容易核对。
5. 如果以前配置过全局扩展、脚本覆写或客户端 DNS 设置，检查它们有没有把 `redir-host` 改回 `fake-ip`，覆盖规则，或把 TUN 端点排除清空。「订阅预览」与「核心运行配置」分别检查。删除旧覆写前先备份。

Windows 客户端的 GUI 设置可能覆盖订阅中的 `route-exclude-address`、`strict-route` 或 DNS 劫持列表。对照订阅预览和核心运行配置，确认最终采用的值。

- 若实际外层 UDP 已从物理网卡正常发出，可以先保留客户端现状。若路由回环、Hysteria2 不通或订阅在 TUN 下下载失败，先把 `NEW_PUBLIC_IPV4/32` 和 `NEW_GLOBAL_IPV6/128` 补进 Clash Verge 的「TUN → 排除自定义网段」，再重启 TUN 并实测。这个排除对该 IP 的所有端口生效。
- 如果需要订阅和 SSH 也总是走物理网卡，这两个端点排除就很有用。IPv6 不通的物理网无法通过例外项接通 IPv6，换用 IPv4 域名或换网络。原生 IPv4 不通时同理。
- `strict-route` 及 DNS 劫持以实际需要为准，调试时一次只改一项。模板使用 `strict-route: true` 和 UDP/TCP 53 劫持。切换后重新测试学校门户和 IPv4-only 环境。
- `stack: mips` 通过了 Mihomo 1.19.33 的配置校验。如客户端的设置界面只提供 `mixed`，改动后用核心解析测试和 TUN 实测确认。

### 8.2 Android：Clash Meta for Android

1. 在可直达订阅端口的网络下载，若报 `EOF`，先停 VPN、用手机浏览器检查该域名/端口能否建立 HTTPS，再检查手机的 IPv4/IPv6。纯 IPv4 网络用 v4 下载域名。
2. 导入 Clash 订阅并选为当前配置。选择「规则」，在「连接方式」选可以直达的地址族。
3. 点「启动」，接受 Android VPN 授权。VPN 图标出现后，检查应用的 VPN/TUN 设置里「路由系统流量」和「允许 IPv6」已打开，参与测试的应用未被绕过。检查系统的「始终开启 VPN」「屏蔽未使用 VPN 的连接」是否符合预期。
4. 验收 TUN 时如果应用自身有「系统代理」开关，将其关闭。日志里的 `127.0.0.1` 说明该连接从本机回环交给代理，下一跳仍须从日志的 `DIRECT`、`直连` 或 `连接方式` 判断。
5. Android 由应用通过 VpnService 安装系统路由。不要假定 Windows 可用的 YAML 路由排除会被同样应用。国内 IPv6 使用第 7 节共同的 Mihomo 规则直出，优先用手机的连接日志和实际出口验证。若启用系统代理，只有支持代理的应用受系统代理规则约束。 [Clash Meta for Android](https://github.com/MetaCubeX/ClashMetaForAndroid) · [Android VpnService](https://developer.android.com/reference/android/net/VpnService.Builder)

## 9. 迁移验收

按顺序做，先确认新机本身有效，再验证客户端规则。带密码、订阅 URL 的响应、日志和截图只在本地保存。

### 9.1 网络、端口、TLS、订阅

在一台独立的双栈设备上用实际域名替换占位符。管理端口测试来源须在允许范围内。

~~~powershell
Resolve-DnsName NEW_IPV4_FQDN -Type A
Resolve-DnsName NEW_IPV6_FQDN -Type AAAA
Test-NetConnection NEW_IPV4_FQDN -Port 15087
Test-NetConnection NEW_IPV6_FQDN -Port 15087
Test-NetConnection NEW_IPV4_FQDN -Port 2096
Test-NetConnection NEW_IPV6_FQDN -Port 2096
curl.exe -4 --noproxy "*" -sS -o NUL -w "%{http_code}" --max-time 10 "https://NEW_IPV4_FQDN:15087/NEW_PANEL_PATH/"
curl.exe -6 --noproxy "*" -sS -o NUL -w "%{http_code}" --max-time 10 "https://NEW_IPV6_FQDN:15087/NEW_PANEL_PATH/"
~~~

用实际随机路径替换 `NEW_PANEL_PATH`。预期得到面板登录页 HTTPS 200，或可信证书下重定向到登录页。再用同样的域名和端口访问根路径 `/`，确认返回 404。`Test-NetConnection -Port` 只测试 TCP。Hysteria2 必须实际拨号成功才算通过，UDP 检查可以在 VPS 上用下面的命令辅助判断。

~~~bash
sudo tcpdump -ni any -c 24 'udp port 49606'
~~~

切换 `连接方式` 后触发一个代理请求。两个地址族分别测试，应看到对应的 QUIC UDP 双向流量。IPv4 数据包到达服务器时，目标地址应与 `NEW_BIND_IPV4` 一致，经云平台 NAT 映射时通常为本地私网 IPv4。若只有入站无回包或完全收不到包，检查云防火墙、主机防火墙、端口映射、监听和客户端出口。若有双向数据但无法连通，检查证书、SNI、客户端密码和核心日志。

通过面板私密生成的 Clash 订阅分别用两个域名拉取，检查实际下发的 YAML：

- 恰有需要的两条 `type: hysteria2` 节点。`server` 是公网字面量，`sni` 与对应证书域名相同，端口 49606、ALPN 为 h3，证书验证开启。
- 只有一个主要可见的 `连接方式` 代理组，两个子组分别能按前缀匹配到相应节点。
- `dns.enhanced-mode` 为 `redir-host`，`tun.route-exclude-address` 仅有两个新端点，`rules` 同时包含两个 TCP 15087 的前置例外。
- 若更新后导出不给新规则，先核对保存的是 Clash 全局规则并使用正确的订阅路径；按面板提示重载服务后再次下载。服务器导出正确、本机少规则时，更新已选中的配置并排查客户端全局扩展。
- Windows 可用核心做静态检查。订阅文件放在私人目录，`-d` 指向包含 GeoIP/GeoSite 文件的验证目录。此操作不启动 TUN。

~~~powershell
& "C:\Program Files\Clash Verge\verge-mihomo.exe" -v
& "C:\Program Files\Clash Verge\verge-mihomo.exe" -t -d "C:\PRIVATE_MIHOMO_TEST_DIR" -f "C:\PRIVATE_MIHOMO_TEST_DIR\subscription.yaml"
~~~

### 9.2 Windows：操作系统路由与物理网卡

以下命令在 TUN 关闭和开启时各跑一次。对国内 IPv6 测试地址，先选已知使用国内公网 IPv6 的服务并验证它在当前 GeoIP 数据中命中 CN。若 Clash Verge 装在电脑上的实际目录不同，以上一节的路径为准。

~~~powershell
Get-NetAdapter | Format-Table Name,Status,ifIndex
Get-NetIPConfiguration
Find-NetRoute -RemoteIPAddress "NEW_GLOBAL_IPV6"
Find-NetRoute -RemoteIPAddress "NEW_PUBLIC_IPV4"
Find-NetRoute -RemoteIPAddress "2606:4700:4700::1111"
Find-NetRoute -RemoteIPAddress "TEST_CN_IPV6"
Get-NetRoute -AddressFamily IPv6 |
    Where-Object DestinationPrefix -in "::/0","NEW_GLOBAL_IPV6/128" |
    Format-Table DestinationPrefix,InterfaceAlias,NextHop,RouteMetric
~~~

| 检查项 | TUN + 规则 | 系统代理 + 规则 |
| --- | --- | --- |
| 普通国内 IPv4 | 规则 `IN-TYPE,TUN`，VPS 出站 | GeoSite/GEOIP CN，物理网络直连 |
| 国外 IPv4 | 规则 `IN-TYPE,TUN`，VPS 出站 | `MATCH` 或对应代理规则，VPS 出站 |
| 国内公网 IPv6 | 可先进入 TUN，日志命中 CN IPv6 的 `直连`，物理网卡使用本地全球 IPv6 | GeoSite/GEOIP CN，经本地网络直连 |
| 国外公网 IPv6 | 进入 TUN，使用代理；对字面量目标从 VPS IPv6 出站 | 显式代理请求命中代理，字面量从 VPS IPv6 出站 |
| VPS 的 QUIC 外层 | 抓包应看到到所选节点 `UDP 49606` 的包从物理网卡发出 | 同左 |
| 面板例外 | 分别命中各自直连规则，或在端点排除生效时由物理网直接连接 | 仍命中各自面板直连规则 |
| QQ、校园门户 | QQ 依据实际目标分流，门户按前置规则直连 | QQ 若使用系统代理则看规则，其他连接用本机网络；门户直连 |

建议用 Windows 的 Wireshark 或 pktmon 同时查看物理网卡和 TUN，按目标 IP 与端口比对。查看国内直连时应能在物理网卡上看到目标连接，源地址为本机地址。看国外代理时应看到到 VPS 的 UDP 外层，物理网卡上不应同时出现同一请求到外国目标的明文外层连接。只看 `Find-NetRoute` 无法证明核心产生的外层 socket 走了哪块网卡。

### 9.3 实际浏览、DNS、回归和故障演练

TUN 使用绕开系统代理的命令，系统代理模式使用显式代理命令。以下两种命令分别在对应模式使用。先从 VPS 自身运行 `curl -4 https://api.ipify.org` 记录公网出站地址，客户端代理测试结果应与这个地址一致。若云平台分别配置了公网入口和出站 NAT，出站地址可能与订阅节点的入口 IPv4 不同。用 ChatGPT 网页再验证浏览器的实际连接和 Mihomo 命中。

~~~powershell
# TUN 开启，系统代理关闭
curl.exe --noproxy "*" --max-time 10 https://api.ipify.org
curl.exe --noproxy "*" --max-time 10 "https://[2606:4700:4700::1111]/cdn-cgi/trace"

# TUN 关闭，显式使用 Mihomo HTTP 代理
curl.exe --proxy http://127.0.0.1:7897 --max-time 10 https://api.ipify.org
curl.exe --proxy http://127.0.0.1:7897 --max-time 10 "https://[2606:4700:4700::1111]/cdn-cgi/trace"

# 对一个确认同时有 A / AAAA 的公开服务检查 DNS
Resolve-DnsName one.one.one.one -Type A
Resolve-DnsName one.one.one.one -Type AAAA
~~~

IPv6 trace 如可用，比较响应的 `ip=` 与新机出站 IPv6。若该测试目标变更或拒绝 IP HTTPS，用具备有效证书且会返回源地址的自有目标替换。保持 TLS 校验开启。使用固定 IP 验证时，若需要保留证书域名，优先在 TUN 测试中用 `curl --resolve` 把域名映射到实际目标。系统代理模式下 HTTP CONNECT 可能把域名交给代理解析，核对连接日志以确认用于实测的目标地址。

进一步检查：

- A/AAAA 两个查询都有记录。使用已知国内与国外域名分别观察 Mihomo DNS 日志或物理网抓包。公网未加密 DNS 只应看见预期的直连解析器。若设备不允许访问物理 IPv4，校园 IPv4 DNS 例外不可达属预期；验证 IPv4 节点时，国内备用 DoH 和默认国外 DoH 都能随 Hysteria2 成功。
- 在校园纯 IPv6、校外 IPv4-only、普通双栈三种网络中验收。测 IPv4-only 客户端时选 IPv4 节点，公网 IPv6 目标通过 VPS 测试。设备本地没有 IPv6 时，要求原生 IPv6 直出的国内目标可能失败。
- 停掉一条测试节点的入站或临时选用一个不可达的测试节点，清掉旧连接后重复代理请求。原先应代理的 TUN 请求应失败，国内 IPv6 及明确直连例外仍可用。用物理网抓包确认原本应代理的目标没有意外直连。测试后恢复入站。关闭 TUN、关闭系统代理、或应用不遵循系统代理时，系统代理路径不再提供这种约束。
- 登录测试除了浏览器外还要确认 QQ 登录、校园认证门户、IPv4 和 IPv6 面板，以及两族订阅刷新。不要根据一个测速 URL 或全局模式可用就判定规则模式可用。

## 10. 切换、备份与回滚

### 10.1 建议迁移顺序

1. **旧机先备份。** 保留旧 3x-ui 版本、SQLite 备份、私密证书路径与续期配置、域名区域记录、当前安全组规则、客户端的配置备份。数据库含管理凭据、节点密码、订阅链接，备份放在仅管理员可读的位置。
2. 用新域名在新机从零重建。重新签发证书、生成新节点密码和订阅 ID。旧数据库用于参考与回滚。直接恢复整库会一并带回旧监听 IP、证书路径、标签、路由和账号，跨服务器时优先按本手册重建。
3. 新旧机并行时，给电脑和手机导入新配置并保留旧配置。完整验收两个节点、两种模式、不同网络环境。
4. 如果复用旧域名，提前调整 DNS TTL，等原 TTL 到期再切。HTTP-01 验证必须能到实际签发主机；并行期间可先用新域名，或用 DNS-01 给旧域名取得新机证书。切换时同步修改 A、AAAA、节点字面量、SNI、面板规则、两条端点排除和订阅域名。节点用 IP 拨号，**仅改 DNS 无法让已缓存节点自动改 IP**。客户端必须刷新并确认新配置已激活。
5. 旧机保留到新机稳定且可回滚。退役时撤销旧订阅凭据，清理旧防火墙、证书续期任务和已无用途的 DNS 记录。释放公网 IP 或销毁实例前确认已完成回滚窗口。

### 10.2 SQLite 一致性备份

当前方案使用 3x-ui 默认 SQLite，数据库通常在 `/etc/x-ui/x-ui.db`。优先用面板提供的数据库导出，或使用下列 SQLite 在线备份。对于 PostgreSQL，改用数据库原生备份流程。

~~~bash
sudo bash -c '
set -eu
umask 077
dir=/root/x-ui-backups
mkdir -p "$dir"
chmod 0700 "$dir"
backup="$dir/x-ui-$(date -u +%Y%m%dT%H%M%SZ).db"
sqlite3 /etc/x-ui/x-ui.db ".timeout 5000" ".backup $backup"
test "$(sqlite3 -readonly "$backup" "PRAGMA quick_check")" = ok
printf "%s\n" "$backup"
'
~~~

证书与私钥使用独立的受限备份策略，注意 Certbot `live/` 目录是指向 `archive/` 的符号链接，还要保留配套的续期设置。不要把私钥、数据库、订阅 YAML 上传到普通共享网盘或 Git。

### 10.3 按故障范围回滚

- **客户端出问题**：切回旧订阅和旧节点选择，恢复其 TUN/系统代理开关。若新配置覆盖了本地扩展，用备份恢复。检查当前配置与实际运行配置。
- **只有模板出问题**：在面板粘回迁移前保存的 YAML，按需要重载，再拉取订阅验证。替换模板不应影响已保存的节点凭据。
- **Xray 出站或入站出问题**：在面板恢复此项的旧版本，校验 Xray 配置，再检查两个 UDP 监听和实际连接。
- **整个服务回滚**：先另做一份当前状态备份，再使用兼容版本的 3x-ui 在**同一台原机器**恢复之前的 SQLite 快照。停止服务后用 sqlite3 `.restore` 恢复，避免直接把一份数据库文件覆盖在正在写入的数据库上。恢复后先做完整性检查，再启动。

~~~bash
sudo systemctl stop x-ui
# 这一行使用之前保存的、已经校验的绝对路径
sudo sqlite3 /etc/x-ui/x-ui.db ".restore /root/x-ui-backups/OLD_SNAPSHOT.db"
sudo sqlite3 -readonly /etc/x-ui/x-ui.db "PRAGMA quick_check"
sudo systemctl start x-ui
sudo systemctl is-active x-ui
~~~

- **DNS 切换出问题**：恢复旧 A、AAAA、订阅链接和旧客户端配置，等待 TTL 生效。恢复前核实旧服务器仍可监听且证书仍有效。

## 11. 常见故障速查

| 症状 | 第一检查项 |
| --- | --- |
| 规则模式不通，全局模式可用 | 实际核心是否仍是旧规则，顶层 `IN-TYPE,TUN` 以前的直连规则是否过宽，Geo 数据是否缺失。不要靠全局模式掩盖路由错误 |
| TUN 下国内站点打出 `DIRECT i/o timeout` | 看目标是 IPv4 还是 IPv6、是否命中对应的 TUN/非 TUN 分支，当前出口地址族是否可用。系统代理与 TUN 同开会影响应用入口 |
| 订阅显示 `EOF` 或 TLS 错误 | 先关 TUN 和系统代理按可达地址族重试，检查 A/AAAA、2096/TCP、证书 SAN、客户端 Clash 订阅路径。15087 可开不代表 2096 可开 |
| v6 面板正常、v6 订阅失败 | 两条面板例外只匹配 15087，2096 单独测试。核对客户端是否覆盖端点排除，尝试关闭 TUN 拉取 |
| v4 节点导出成私网地址 | 修改 IPv4 入站的分享地址为公网 IPv4，同时保留私网绑定。确认生成后的 `server` |
| 允许 TCP 49606 但节点连接超时 | 放行的是 UDP 49606 才有效，且新服务器应同时在正确的两个地址上监听 |
| HTTPS 正常但 Hysteria2 认证失败 | 核对 SNI、证书链、ALPN h3、两个入站关联的同一认证凭据，以及实际选择的组 |
| 手机日志显示 `127.0.0.1` | 看该条连接命中的规则和最终去向。回环地址不会单独占用校园出口，随后产生的直连流量可能占用 |
| 订阅里有 `redir-host`，客户端却仍显示 `fake-ip` | 客户端全局 DNS 覆写、配置扩展脚本或旧缓存优先级更高。查看运行配置，再删除或调整冲突项 |
| 国内 IPv6 仍走代理 | 核对进程入口是否为 TUN、目标是否实际 IPv6、数据是否判断为 CN、`no-resolve` 是否已有目的 IP，以及是否选了规则模式 |
| 面板 IPv4 被规则强制直连后打不开 | 当前校园 IPv4 可能无法直达公网面板。用原生 IPv6 面板或换到有 IPv4 的管理网络。服务器端先核对 15087 的监听、安全组与 TLS |
| 移机后仍连旧 VPS | 节点 `server` 是字面量 IP，刷新实际使用的订阅。还要核对保留的连接、出站组选择和本机端点排除 |
