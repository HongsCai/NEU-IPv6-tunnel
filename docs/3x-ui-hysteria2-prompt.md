# 3x-ui 双栈 Hysteria2 部署 Prompt

把本文完整交给一个能使用你本机终端、通过 SSH 操作服务器的 AI。下文可单独使用，已内嵌 Xray 路由与 Clash 订阅模板。也可附上同目录的《3x-ui 双栈 Hysteria2 迁移手册》供 AI 查阅。

---

## 角色与任务

你负责在我管理的 Linux VPS 上安装或迁移 3x-ui，部署双栈 Hysteria2，并让 Windows 和 Android 共用一份 Mihomo 订阅。按下列顺序向我收集信息。信息齐备后，如果你有本机终端与 SSH 能力，就执行部署、检查结果并处理可恢复的失败。缺权限时具体指出需要谁配置哪个项目，同时完成可以独立执行的步骤。

这是一套云厂商通用方案。默认保留本 Prompt 中的端口、TLS 验证和分流规则。发现旧服务或端口冲突时，先说明影响，再由我决定如何处置旧服务。默认不改我的本机网络设置、不改旧服务器，也不切换线上 DNS。需要变更这些项目时，先说明具体操作并取得授权。已有线上服务的重启时间由我指定。部署全新的 3x-ui 时，按流程执行必要的服务启动和重载。

## 第一轮：只问我怎么从本机连接服务器

先用中文问我：

> 你希望我怎么从这台电脑连到服务器？已有 SSH 别名的话，发我别名（例如 `ssh new-vps`）。否则请给 SSH 主机/IP、用户名、端口，以及是否需要跳板机。你可以先用本机 SSH Agent 或已配置好的密钥登录。另请告诉我这是空白新机、从旧机迁移，还是有现有服务要保留。

不要在第一轮追问域名。不要索要私钥内容、SSH 密码、云 API Token 或节点密码。首次出现无法核对的 SSH 主机指纹时，让我从云控制台或其他可信渠道核对，再继续。保留主机指纹校验。

收到回复后用已授权的连接方式执行只读预检：确认 SSH、sudo、系统和 CPU 架构，读 IPv4/IPv6 网卡地址、路由和端口占用，判断是否已有 3x-ui、独立 Hysteria2、反向代理或正在使用的数据库。摘要只显示必要的诊断数据，跳过含凭据的配置。仅凭服务器能出站上网无法判断公网入站可达。

## 第二轮：再问我域名和公网入口

列出已经通过预检确认的信息。只问尚未确认的项目，能从网卡、DNS 或已有配置可靠查到的值就引用检测结果，请我核对有歧义的项。

1. **域名**：使用哪两个用于 VPS 的域名，分别回答 IPv4 域名和 IPv6 域名。如果我只提供一个父域，请提出 `vpn4.`、`vpn6.` 两个子域名。问我 DNS 记录是否已配置，是否已有授权让你操作 DNS。
2. **公网地址**：公网 IPv4 和公网 IPv6 是什么。IPv4 是直接绑在网卡上，还是由云平台映射到网卡的本地 IPv4。用云平台分配值和 DNS 记录交叉核对。IPv4 的公网入口和出站地址可能不同。
3. **证书**：复用已有覆盖两个域名的证书，还是新签发。新签发时问我 ACME 联系邮箱和是否可以用 TCP 80 做 HTTP-01。无法放行 80 时，改用经我授权的 DNS-01 流程。
4. **管理来源和权限**：我希望从哪些 IPv4、IPv6 来源访问面板和 SSH，云防火墙、端口转发由谁设置。已有明确的管理范围时沿用，先确保能保留 SSH 管理通道。若只能由我从云控制台操作，给我准确规则并确认状态。
5. **校园网**：确认是否保留东北大学校园网配置。其他学校由我给出域名后缀、认证门户域名及 IP 和校内 DNS。没有校园网需求时，按模板后的说明删除对应配置。

仅在迁移或覆盖旧安装时追问旧订阅是否要保留、是否另建并行服务器以及什么时候切换。信息齐备后发一份不含凭据的部署摘要，说明执行目标、端口和备份位置，然后继续已授权的部署。遇到改变已有服务、账号、数据库、生产 DNS 或公网管理范围的决定时暂停相关步骤。

## 固定部署参数

| 项目 | 值 |
| --- | --- |
| Hysteria2 两个入站 | `49606/UDP`，IPv4 与 IPv6 可分别从公网确认 |
| 3x-ui 管理面板 | HTTPS `15087/TCP`，由我指定的管理来源访问 |
| Clash 订阅服务 | HTTPS `2096/TCP`，供需要的地址族访问 |
| SSH | 以现有 SSH 端口为准，默认 `22/TCP` |
| HTTP-01 | 仅采用该验证方式时，签发与续期需要从公网访问 `80/TCP` |
| 客户端本地代理 | `127.0.0.1:7897`，保留本地监听 |
| Hysteria2 认证 | 一个客户端关联两个入站，认证密码随机生成。使用 TLS、各自 SNI、ALPN `h3` 并校验证书 |
| 节点命名 | `VPS Hysteria2 IPv4` 和 `VPS Hysteria2 IPv6`，与订阅模板的筛选前缀一致 |
| 管理路径 | 在目标服务器生成 `/随机十六进制字符串/`，两个域名共用，路径与订阅路径独立 |

### 替换变量

| 变量 | 实际来源 |
| --- | --- |
| `NEW_IPV4_FQDN`、`NEW_IPV6_FQDN` | 我提供并确认的 IPv4、IPv6 域名。前者只设 A，后者只设 AAAA |
| `NEW_NODE_DOMAIN_SUFFIX` | 两个域名共用且由我控制的父域。无法使用共同父域时，DNS 策略按两个完整域名配置，父域直连改成两个 `DOMAIN` 规则 |
| `NEW_PUBLIC_IPV4` | 供客户端拨号的公网 IPv4，与 A 记录一致 |
| `NEW_BIND_IPV4` | Linux 网卡实际接收入站的 IPv4。公网直绑时和公网 IPv4 相同，云 NAT 时通常为私网 IPv4 |
| `NEW_GLOBAL_IPV6` | Linux 网卡上可接收公网流量的 IPv6，与 AAAA 记录一致 |
| `V4_INBOUND_TAG`、`V6_INBOUND_TAG` | 两个入站保存后，从 Xray 实际生成的运行配置读出 |
| `NEW_HYSTERIA_PASSWORD` | 由 3x-ui 保存并导出。占位符只用于说明或离线校验 |

## 执行顺序

1. **核对云配置和端口。** 检查云防火墙、Linux 防火墙的 IPv4 和 IPv6 规则。使用显式 NAT 端口转发时，把需要的 TCP/UDP 端口转发到本机相同端口。面板和 SSH 用我指定的来源。保留必要的 ICMPv6，尤其是路径 MTU 所需消息。保留旧服务监听，出现冲突出具诊断。
2. **备份。** 发现现有安装时，记录版本、证书路径、旧端口、面板基础路径及服务状态。默认 SQLite 使用一致性在线备份（面板导出或 SQLite Backup API），以 `PRAGMA quick_check` 校验。备份保存在服务器受限目录。现有 Xray 及订阅配置按实际使用的权限和路径备份。
3. **安装 3x-ui 和证书。** 空白机从 3x-ui 官方发行版安装指定稳定版本，先确认该版本可用。已有安装优先复用，升级另行确认。两个 DNS 记录分别指向公网 IPv4 和 IPv6，使用仅 DNS 解析。用一张证书覆盖两个域名，以 Certbot 为例检查 SAN、有效期、证书链、续期定时任务，并配置成功续期后重新加载服务。面板、订阅和两个入站使用正确的证书链和私钥路径。 [3x-ui 官方安装](https://github.com/MHSanaei/3x-ui#quick-start) · [官方发行版](https://github.com/MHSanaei/3x-ui/releases) · [Certbot](https://eff-certbot.readthedocs.io/en/stable/using.html)
4. **配置面板和订阅。** 启用 `15087/TCP` 管理 HTTPS 和随机 `webBasePath`，使两个域名的新路径都能访问。可用 `openssl rand -hex 18` 生成路径中间的字符串。检查旧根路径返回 404。开启 `2096/TCP` 的 HTTPS Clash 订阅及全局路由模板。根据实际导出的结果确认该版本能合并完整配置。 [3x-ui 面板设置](https://docs.sanaei.dev/docs/config/panel/)
5. **配置 Hysteria2。** 创建两个版本 2 的独立 UDP 入站，分别精确监听 `NEW_BIND_IPV4:49606` 和 `[NEW_GLOBAL_IPV6]:49606`。IPv4 共享地址用公网 IPv4，IPv6 用网卡实际公网 IPv6，订阅节点建议输出 IP 字面量和各自 SNI。同一个客户端关联两条入站，关闭混淆，拥塞控制用核心默认值，不填写估算带宽。优先用所装版本支持的面板、CLI 或 API，任一接口不可用时先核对版本归属，避免直接猜数据库结构。
6. **配置路由。** 合并下方 Xray 出站和路由规则，保留面板已有的内部 API 路由。把订阅 YAML 原样作为结构模板，替换变量后粘贴到 3x-ui 的 Clash 全局路由规则。`proxies` 由面板生成。用兼容核心做静态校验，保存并重载所需服务，下载实际订阅校验输出完整。
7. **复查凭据与失败处理。** 密码、私钥、完整订阅链接和随机管理路径仅通过我同意的私人方式交付，例如写入本机受限文件。回报中只列存放位置。发生失败时保留“执行到哪一步”和具体错误。在有旧状态时，先将本次失败项恢复到备份并验证，避免用重装覆盖旧服务。

## Xray 出站与路由模板

按 `tag` 合并这些出站。保留默认出站顺序和面板生成的内部对象。Xray 需支持 `finalRules`，上线前对生成的运行配置执行核心配置测试。

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

路由使用 `AsIs`。面板内部 API 规则优先保留，以下四条放在其后、更宽泛的规则之前。用新机实际入站 tag 替换占位符。

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

## 3x-ui Clash 订阅模板

替换变量后，把这一整段粘贴到 Clash 全局路由规则。预填的是东北大学校园网配置。如我选择其他学校，替换 `neu.edu.cn`、`ipgw.neu.edu.cn`、门户 IPv4 和两台校内 DNS。如我选择无需校园网，删除 `dns.nameserver-policy` 的 `+.neu.edu.cn` 整段，以及 `rules` 中的门户 `DOMAIN`、门户 `IP-CIDR`、校园 `DOMAIN-SUFFIX`。

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

订阅导出后应有以下两条节点。仅用于验收或离线测试，不要把这个 `proxies` 块再粘贴到全局路由模板中。

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

## 验收与交付

按下列项目区分 **实测通过、未验证、需我操作**。HTTP/TCP 端口测试无法替代真实的 Hysteria2 UDP 拨号。

- **VPS**：查双栈出站、两个 UDP 49606 监听、面板和订阅端口。用不同地址族分别验证新面板路径、TLS SAN、旧根路径、实际订阅输出，核对两个地址、SNI、证书校验、代理组筛选和配置字段。记录 IPv4 出站检测结果，和公网入站字段分别核对。
- **Windows 与 Android**：在已有授权、设备可用时执行客户端验证。先分别试用两条节点，再启用 TUN 的规则模式。目标是普通公网 IPv4 走代理、国内 IPv6 进入 TUN 后由 Mihomo 直连、国外 IPv6 走代理，门户和管理面板按前置例外访问。检查 Hysteria2 外层 UDP 走设备物理网卡。订阅带两个端点排除，如果客户端覆写为空，先检查运行态与实际连通性，确需改本机设置时再说明。国内 IPv6 使用前置 Mihomo 规则，无需国内 IPv6 CIDR 排除列表。
- **系统代理模式**：关闭 TUN，验证受系统代理接管的应用。国内 IPv4、IPv6 直连，国外走代理。浏览器、命令行可用显式代理加连接日志对照。
- **DNS 和回环**：确认 `redir-host` 支持 A 和 AAAA，对照已部署的国内 DNS 策略以及通过节点的国外 DoH。测试时区分 DNS 服务器使用的地址族与返回记录类型。检查外层连接没有进隧道循环。
- **结尾反馈**：列出已完成项目、实测结果、仍待操作项、如何在两种客户端切换节点，以及备份与回滚位置。保留旧订阅，等我验收新机后再做正式切换。不能访问我的客户端设备时，给出下一步的具体测试方式，并标注该部分未验收。

现在从第一轮 SSH 连接方式开始。
