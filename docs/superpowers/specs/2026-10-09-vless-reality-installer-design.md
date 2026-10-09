# VLESS REALITY Vision 一键安装器设计

## 1. 目标

创建一个公开 GitHub 仓库 `oceanliam/vless-reality-installer`，提供单文件、全自动的 Bash 安装器。用户在新 VPS 上以 root 身份执行一条命令，即可部署：

- VLESS
- TCP/RAW
- REALITY
- XTLS Vision (`xtls-rprx-vision`)
- TCP 443
- REALITY target/SNI: `www.bing.com`

安装器自动生成 UUID、X25519 REALITY 密钥对和 Short ID，最后输出客户端参数及 `vless://` 分享链接。

## 2. 托管和发布

- 公开仓库：`https://github.com/oceanliam/vless-reality-installer`
- 安装脚本：仓库根目录的 `install.sh`
- 文档：`README.md`
- 许可证：`LICENSE`
- 自动检查：`.github/workflows/check.yml`
- 用户从 GitHub Raw 地址下载执行，当前 VPS 不托管脚本。

预期一键命令：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/oceanliam/vless-reality-installer/main/install.sh)
```

GitHub `main` 分支保持可直接使用。README 同时给出“先下载检查、再执行”的更安全方式。

## 3. 支持范围

支持使用 systemd 的 x86_64 或 arm64 Linux：

- Debian
- Ubuntu
- CentOS
- Rocky Linux
- AlmaLinux
- Oracle Linux

支持 `apt`、`dnf` 或 `yum`。非 systemd 系统、不支持的 CPU 架构、非 root 执行将在修改系统前终止。

## 4. 固定默认配置

| 项目 | 值 |
|---|---|
| 入站端口 | `443` |
| 协议 | `vless` |
| 传输 | `raw`（客户端链接使用 `type=tcp`） |
| 安全 | `reality` |
| Flow | `xtls-rprx-vision` |
| Target | `www.bing.com:443` |
| Server Name / SNI | `www.bing.com` |
| Fingerprint | `chrome` |
| SpiderX | `/` |

无需用户准备域名或 TLS 证书。分享链接默认使用自动检测的 VPS 公网 IPv4。

## 5. 安装流程

### 5.1 预检查

1. 确认 root、systemd、操作系统和 CPU 架构。
2. 确认 DNS 和 GitHub 可访问。
3. 检查 `www.bing.com:443` 可连接且支持 TLS 1.3。
4. 安装最小依赖：`curl`、`unzip`、`openssl`、`ca-certificates`、`iproute`。
5. 检测 443 端口占用者。

### 5.2 备份

每次运行创建带 UTC 时间戳的备份目录：

```text
/root/vless-reality-installer-backups/YYYYmmddTHHMMSSZ/
```

备份存在的：

- `/usr/local/etc/xray`
- `/usr/local/bin/xray`（如已存在）
- `/etc/xray`
- `/etc/v2ray`
- 相关 systemd 单元和 override
- Nginx、Caddy、Apache 的主配置与站点配置
- 上一版 `/root/VLESS-REALITY-Vision.txt`
- 443 端口原服务状态

不复制大型日志、缓存或网站数据目录。

### 5.3 安装 Xray

- 仅使用 XTLS 官方 `Xray-install` 脚本安装或升级 Xray-core。
- 下载脚本保存到临时目录后再执行，不使用不可审查的嵌套 `curl | bash`。
- 官方安装器负责 Xray 发布包的 SHA-256 校验。
- 全新安装在端口切换前准备 Xray 二进制；已存在 Xray 时，将官方升级延后到端口切换事务内，并使用 `--no-update-service` 保留原 systemd 服务定义。

### 5.4 生成配置

- UUID：`xray uuid`
- REALITY X25519 密钥对：`xray x25519`
- Short ID：`openssl rand -hex 8`
- 服务端配置：`/usr/local/etc/xray/config.json`
- 配置文件权限：`root:<Xray 服务账户的实际组> 0640`；组名从 systemd 服务账户动态确定，兼容 Debian 系常见的 `nogroup` 与 RHEL 系常见的 `nobody`
- 客户端信息：`/root/VLESS-REALITY-Vision.txt`，权限 `root:root 0600`

配置写入后必须先执行：

```bash
xray run -test -config /usr/local/etc/xray/config.json
```

语法校验成功后才进入端口切换。

### 5.5 443 端口冲突处理

脚本自动识别并停止由 systemd 管理的 443 占用服务，包括 Nginx、Caddy、Apache、V2Ray、旧 Xray 或其他可追溯的 systemd 单元，并记录原先的 active/enabled 状态。

为避免误杀业务：

- 可识别的 systemd 服务：自动停止和禁用。
- 无法追溯到 systemd 单元的未知进程：不强制 `kill`，安装中止并输出 PID/进程名。
- 不停止 SSH，不修改 22 端口。

### 5.6 启动和验收

1. 启用并重启 `xray.service`。
2. 检查 `systemctl is-active xray` 和 `systemctl is-enabled xray`。
3. 确认 443 由 Xray 监听。
4. 临时启动一个本地 Xray SOCKS 客户端，使用刚生成的 REALITY/Vision 参数经 `127.0.0.1:443` 连接生产入站，避免依赖云厂商的公网 IP 回环能力。
5. 通过该 SOCKS 代理访问 HTTPS 检测端点，确认代理链路成功且公网出口 IP 与服务器自动检测的公网 IPv4 一致。
6. 删除临时测试配置和进程。

## 6. 失败回滚

脚本在端口切换后设置失败捕获。如果 Xray 配置校验、启动、监听或代理验收失败：

1. 停止新 Xray。
2. 恢复运行前的 Xray 可执行文件、Xray/V2Ray 配置及相关 systemd 定义。
3. 按记录恢复原 443 服务的 enabled/active 状态。
4. 保留备份和错误日志路径。
5. 以非零状态码退出。

预检查或安装依赖阶段失败时，因尚未停止原服务，不需要回滚。

## 7. 重复运行

- 每次运行都创建新备份。
- 每次运行都重新生成 UUID、REALITY 密钥和 Short ID。
- 旧分享链接在重新运行后失效，README 中明确说明。
- 旧配置不被删除，可从时间戳备份恢复。

## 8. 安全边界

- 不关闭或修改 firewalld、ufw、iptables/nftables。
- 不修改云厂商安全组；如 443 未放行，给出明确提示。
- 不安装 BBR、内核、面板、Nginx 或网站环境。
- 不上传 UUID、私钥、Short ID 或服务器信息到 GitHub。
- 终端仅在安装成功时显示凭据；完整信息保存为 root-only 文件。
- 当前已配置的 VPS 不用于托管、测试或发布此脚本。

## 9. 仓库结构

```text
vless-reality-installer/
├── .github/
│   └── workflows/
│       └── check.yml
├── tests/
│   └── static-check.sh
├── install.sh
├── README.md
└── LICENSE
```

## 10. 自动检查

GitHub Actions 在 push 和 pull request 时执行：

- `bash -n install.sh`
- ShellCheck
- `tests/static-check.sh`

静态检查至少验证：

- 不存在硬编码 UUID、私钥或 Short ID。
- 不包含关闭 SSH/防火墙的命令。
- 安装失败有非零退出码。
- 配置校验发生在停止原 443 服务之前。
- 临时文件使用 `mktemp -d` 并通过 trap 清理。

## 11. 验收标准

1. 在至少一个 Debian/Ubuntu 系和一个 RHEL 兼容系上通过静态/容器测试。
2. 全新 VPS 上单命令安装后 Xray 为 active/enabled，443 由 Xray 监听。
3. 有 Nginx/Caddy/Apache 占用 443 时，脚本可备份并安全切换。
4. 人为制造 Xray 启动失败时，原 443 服务自动恢复。
5. REALITY/Vision 端到端测试通过，检测到的出口 IP 与 VPS 公网 IP 一致。
6. 服务器生成 root-only 的客户端信息文件，分享链接可导入常见 VLESS/REALITY 客户端。
7. GitHub Actions 全部通过，README 的 Raw 安装命令可用。
