# VLESS REALITY Vision 一键安装器

用于在新 VPS 上自动部署 Xray，固定配置为：

- VLESS + TCP/RAW
- REALITY + XTLS Vision (`xtls-rprx-vision`)
- TCP `443`
- Target/SNI: `www.bing.com:443` / `www.bing.com`

脚本自动生成 UUID、X25519 REALITY 密钥对和 Short ID，最后输出客户端参数及 `vless://` 分享链接。不需要域名和 TLS 证书。

## 支持范围

- Debian、Ubuntu
- CentOS、Rocky Linux、AlmaLinux、Oracle Linux
- systemd
- x86_64 或 arm64
- root 身份

## 重要警告

脚本会停止并禁用正在监听 TCP 443、且能明确映射到 systemd 的服务，例如 Nginx、Caddy、Apache、V2Ray 或旧 Xray。

- 运行前请确认该 VPS 的 443 业务可以被替换。
- 如 443 由无法识别的非 systemd 进程占用，脚本会中止，不强制结束进程。
- 脚本不修改 SSH、22 端口、firewalld、ufw、iptables/nftables 或云安全组。
- 请自行在防火墙和云安全组中放行入站 TCP 443。

## 建议：先下载检查

以 root 身份运行：

```bash
curl -fsSLo /tmp/vless-reality-install.sh https://raw.githubusercontent.com/oceanliam/vless-reality-installer/main/install.sh
less /tmp/vless-reality-install.sh
bash /tmp/vless-reality-install.sh
```

## 一键安装

已审查脚本后，可以 root 身份执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/oceanliam/vless-reality-installer/main/install.sh)
```

## 安装流程

1. 检查 root、systemd、Linux 发行版、CPU 架构和网络。
2. 检查 `www.bing.com:443` 的 TLS 1.3 可用性。
3. 创建 UTC 时间戳备份。
4. 通过 [XTLS/Xray-install](https://github.com/XTLS/Xray-install) 安装或升级 Xray-core。
5. 生成全新凭据和 REALITY/Vision 配置，在切换 443 前先校验配置。
6. 备份并停止原 443 systemd 服务，启动 Xray。
7. 在本机通过 REALITY/Vision 和 SOCKS 做端到端验收。
8. 验收成功后才写出客户端信息。

## 客户端信息

安装成功后，完整参数保存在：

```text
/root/VLESS-REALITY-Vision.txt
```

文件权限为 `0600`，仅 root 可读。可将其中的 `vless://` 链接导入支持 VLESS + REALITY + Vision 的客户端。

| 项目 | 值 |
|---|---|
| 端口 | `443` |
| 传输 | `tcp` / `raw` |
| 安全 | `reality` |
| Flow | `xtls-rprx-vision` |
| SNI | `www.bing.com` |
| Fingerprint | `chrome` |
| SpiderX | `/` |

## 重复运行

每次重新运行都会创建新备份，并生成新 UUID、REALITY 密钥和 Short ID。旧客户端分享链接会立即失效，请及时更新客户端。

## 备份与回滚

备份保存在：

```text
/root/vless-reality-installer-backups/YYYYmmddTHHMMSSZ/
```

如在切换 443 后发生 Xray 升级、启动、监听或代理验收失败，脚本会自动恢复原 Xray 程序、配置、systemd 定义和原 443 服务状态。备份不会自动删除。

## 自动检查

GitHub Actions 执行 Bash 语法、ShellCheck、静态安全、行为测试，以及 Ubuntu 24.04 和 Rocky Linux 9 容器兼容性检查。测试不会连接或修改任何 VPS。

## License

[MIT](LICENSE)
