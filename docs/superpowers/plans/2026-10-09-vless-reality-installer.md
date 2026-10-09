# VLESS REALITY Vision 一键安装器 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 创建并发布一个公开 GitHub 仓库，提供可在支持的 Linux VPS 上全自动安装 VLESS + REALITY + Vision 的单文件 Bash 安装器。

**Architecture:** `install.sh` 保持单文件交付，内部按预检、备份、Xray 安装、凭据/配置生成、443 切换、本机端到端验证和回滚拆分为可单测函数。测试通过 source 脚本并注入命令替身来验证状态转换，真实安装入口仅在脚本被直接执行时调用。GitHub Actions 执行语法、ShellCheck、静态安全和行为测试。

**Tech Stack:** Bash 4+、systemd、curl、OpenSSL、Xray-core、XTLS/Xray-install、ShellCheck、GitHub Actions、GitHub CLI

**Spec:** `docs/superpowers/specs/2026-10-09-vless-reality-installer-design.md`

## Global Constraints

- 公开仓库固定为 `oceanliam/vless-reality-installer`，默认分支为 `main`。
- 服务固定为 VLESS + REALITY + `xtls-rprx-vision`，入站端口 `443`，Target/SNI 为 `www.bing.com:443` / `www.bing.com`。
- 支持 systemd 上的 x86_64/arm64 Debian、Ubuntu、CentOS、Rocky Linux、AlmaLinux 和 Oracle Linux。
- 仅使用 XTLS 官方 `Xray-install`；下载到临时目录后执行，不使用嵌套 `curl | bash`。
- 每次执行都生成新 UUID、X25519 密钥对和 Short ID，并创建 UTC 时间戳备份。
- 可追溯的 systemd 443 占用服务可自动停止和禁用；未知非 systemd 进程必须中止安装，不强制 kill。
- 不修改 SSH、22 端口、防火墙或云安全组，不上传任何服务器凭据。
- 现有 VPS 不得用于托管、执行、测试或发布本安装器。
- README、提交信息及项目协作文档使用中文。

## Review Focus

- 非 root、非 systemd、不支持的系统或 CPU：应在任何包安装或服务变更前失败，由 Task 2 的预检测试覆盖。
- GitHub/DNS/Bing TLS 1.3/公网 IPv4 检测超时：应在停止 443 原服务前失败，由 Task 2 的网络预检测试覆盖。
- 443 由无法映射到 systemd 的进程占用：应报告 PID/进程名并且不 kill，由 Task 3 的端口占用测试覆盖。
- 停止原 443 服务后 Xray 启动、监听或代理验收失败：应恢复配置及原服务状态，由 Task 5 的事务回滚测试覆盖。
- 重复执行：应创建新备份并更换凭据，旧分享链接失效，由 Task 4/5 的重入测试覆盖。

---

### Task 1: 建立仓库骨架与可测试的单文件入口

**Files:**
- Create: `vless-reality-installer/install.sh`
- Create: `vless-reality-installer/tests/test-installer.sh`
- Create: `vless-reality-installer/tests/run.sh`
- Copy: `docs/superpowers/specs/2026-10-09-vless-reality-installer-design.md` -> `vless-reality-installer/docs/superpowers/specs/2026-10-09-vless-reality-installer-design.md`
- Copy: `docs/superpowers/plans/2026-10-09-vless-reality-installer.md` -> `vless-reality-installer/docs/superpowers/plans/2026-10-09-vless-reality-installer.md`

**Interfaces:**
- Consumes: 已确认的设计文档。
- Produces: 可 source 的 `install.sh`；常量 `XRAY_PORT=443`、`REALITY_HOST=www.bing.com`、`REALITY_DEST=www.bing.com:443`、`CLIENT_OUTPUT=/root/VLESS-REALITY-Vision.txt`；`main()` 仅在直接执行时运行。

- [ ] **Step 1: 初始化本地 Git 仓库和 `main` 分支**

Run: `mkdir -p vless-reality-installer && git -C vless-reality-installer init -b main`
Expected: `git -C vless-reality-installer branch --show-current` 输出 `main`。

- [ ] **Step 2: 编写失败的入口测试**

在 `tests/test-installer.sh` 中添加 `test_constants_are_fixed` 和 `test_source_does_not_run_main`，断言三个固定配置值，并断言 source 后没有执行系统变更命令。`tests/run.sh` 负责运行行为测试。

- [ ] **Step 3: 运行测试确认因缺少脚本而失败**

Run: `cd vless-reality-installer && bash tests/run.sh`
Expected: FAIL，提示找不到 `install.sh` 或固定常量。

- [ ] **Step 4: 实现最小入口骨架**

在 `install.sh` 定义固定常量、`log()`、`die()` 和空的 `main()`；使用 `[[ "${BASH_SOURCE[0]}" == "$0" ]]` 守卫直接执行入口。复制 spec 和 plan 到新仓库。

- [ ] **Step 5: 验证入口测试通过**

Run: `cd vless-reality-installer && bash -n install.sh && bash tests/run.sh`
Expected: PASS，且 source 脚本时不产生系统变更。

- [ ] **Step 6: 提交骨架**

```bash
git -C vless-reality-installer add install.sh tests docs
git -C vless-reality-installer commit -m "chore: 初始化安装器仓库"
```

### Task 2: 实现平台与网络预检

**Files:**
- Modify: `vless-reality-installer/install.sh`
- Modify: `vless-reality-installer/tests/test-installer.sh`

**Interfaces:**
- Consumes: Task 1 的常量、`log()` 和 `die()`。
- Produces: `require_root() -> 0|nonzero`、`detect_platform() -> sets OS_FAMILY, PKG_MANAGER, ARCH`、`install_dependencies()`、`detect_public_ipv4() -> stdout IPv4`、`check_reality_target()`、`preflight()`。

- [ ] **Step 1: 添加预检失败测试**

添加 `test_non_root_stops_before_mutation`、`test_rejects_non_systemd`、`test_rejects_unsupported_os`、`test_maps_supported_architectures`，命令替身记录调用，断言失败时未调用包管理器或 `systemctl`。

- [ ] **Step 2: 运行定向测试确认失败**

Run: `cd vless-reality-installer && bash tests/test-installer.sh preflight_platform`
Expected: FAIL，预检函数未定义。

- [ ] **Step 3: 实现本地环境预检**

读取 `/etc/os-release`，映射 `apt-get`/`dnf`/`yum`，将 `x86_64|amd64` 映射为 `64`、`aarch64|arm64` 映射为 `arm64-v8a`；确认 PID 1/systemd 可用。任何变更前先完成 root/系统/架构检查。

- [ ] **Step 4: 添加网络预检失败测试**

添加 `test_github_failure_precedes_port_switch`、`test_bing_must_support_tls13`、`test_public_ipv4_rejects_invalid_output`；断言 curl/openssl 超时或非 IPv4 输出时未调用任何停服务函数。

- [ ] **Step 5: 实现依赖安装与有超时的网络检查**

`install_dependencies()` 仅安装 `curl unzip openssl ca-certificates` 和各系统对应的 `iproute2|iproute`。GitHub 和 IPv4 检测使用至少两个有超时的 HTTPS 端点顺序回退；Bing 使用 `openssl s_client -tls1_3 -servername www.bing.com` 检查。

- [ ] **Step 6: 验证预检测试**

Run: `cd vless-reality-installer && bash tests/run.sh`
Expected: 所有预检测试 PASS。

- [ ] **Step 7: 提交预检实现**

```bash
git -C vless-reality-installer add install.sh tests/test-installer.sh
git -C vless-reality-installer commit -m "feat: 增加平台与网络预检"
```

### Task 3: 实现备份与 443 占用服务管理

**Files:**
- Modify: `vless-reality-installer/install.sh`
- Modify: `vless-reality-installer/tests/test-installer.sh`

**Interfaces:**
- Consumes: Task 2 的平台信息和预检。
- Produces: `create_backup_dir() -> sets BACKUP_DIR`、`backup_existing_state()`、`get_port_443_pids() -> stdout PID list`、`systemd_unit_for_pid(pid) -> stdout unit`、`capture_service_state(unit)`、`quiesce_port_443()`、`restore_service_states()`。

- [ ] **Step 1: 添加备份与重入失败测试**

添加 `test_backup_uses_unique_utc_directory`、`test_backup_copies_only_declared_paths`、`test_previous_client_file_is_preserved`，断言两次运行使用不同目录，并且不复制日志、缓存或站点数据。

- [ ] **Step 2: 实现时间戳备份和服务状态清单**

备份 spec 声明的配置路径、已存在的 `/usr/local/bin/xray`、systemd unit/override、Web 服务主配置和客户端信息；在 `$BACKUP_DIR/service-states.tsv` 保存 `unit<TAB>active<TAB>enabled`。

- [ ] **Step 3: 添加 443 占用者分类失败测试**

添加 `test_known_systemd_owner_is_stopped_and_disabled`、`test_multiple_systemd_owners_are_recorded`、`test_unknown_owner_aborts_without_kill`、`test_ssh_unit_is_never_stopped`，断言未知进程时仅输出 PID/命令名。

- [ ] **Step 4: 实现端口进程到 systemd unit 的安全映射**

使用 `ss -H -ltnp 'sport = :443'` 取 PID，使用 `/proc/<pid>/cgroup` 解析 `.service` unit，并用 `systemctl show` 验证。拒绝 `ssh.service`/`sshd.service`、空 unit、非 `.service` 单元和无法验证的映射。

- [ ] **Step 5: 实现状态记录、停止、禁用与恢复**

`quiesce_port_443()` 必须先完成所有占用者分类，然后才可变更服务；任一占用者未知则零变更退出。`restore_service_states()` 精确恢复 active/enabled 组合。

- [ ] **Step 6: 验证备份和端口测试**

Run: `cd vless-reality-installer && bash tests/run.sh`
Expected: 备份、多占用者、未知进程和 SSH 保护测试全部 PASS。

- [ ] **Step 7: 提交备份与端口管理**

```bash
git -C vless-reality-installer add install.sh tests/test-installer.sh
git -C vless-reality-installer commit -m "feat: 增加备份和 443 服务切换"
```

### Task 4: 准备 Xray 并生成待切换的服务端配置

**Files:**
- Modify: `vless-reality-installer/install.sh`
- Modify: `vless-reality-installer/tests/test-installer.sh`

**Interfaces:**
- Consumes: Task 1 的固定配置和 Task 3 的备份目录。
- Produces: `run_official_xray_installer()`、`ensure_xray_binary()`、`generate_credentials() -> sets UUID, PRIVATE_KEY, PUBLIC_KEY, SHORT_ID`、`render_staged_server_config()`、`validate_staged_server_config()`。

- [ ] **Step 1: 添加官方安装器来源测试**

添加 `test_downloads_official_installer_to_mktemp`、`test_does_not_pipe_curl_to_shell`、`test_existing_xray_is_not_restarted_before_switch`、`test_fresh_install_does_not_touch_other_443_service`，断言 URL 来自 `XTLS/Xray-install`、下载文件后再执行，且已存在 Xray 时本阶段不运行会停止/重启它的官方安装器。

- [ ] **Step 2: 实现官方 Xray 安装流程**

`run_official_xray_installer()` 用 `mktemp -d` 和 trap 清理，下载官方 `install-release.sh`后调用 `bash <local-file> install --without-geodata`。`ensure_xray_binary()` 分两路：如已有可用 Xray，只检查 `uuid`/`x25519`/配置校验能力，将升级延后到 443 切换事务内；如未安装，才运行官方安装器，然后立即停止/禁用无入站的新 Xray，不变更其他 443 服务。

- [ ] **Step 3: 添加凭据生成和重入测试**

添加 `test_credentials_have_expected_shapes`、`test_two_runs_rotate_all_credentials`、`test_private_key_never_appears_in_git_files`，断言 UUID 合法、Short ID 为 16 个小写十六进制字符，两次输出均不同。

- [ ] **Step 4: 实现凭据解析和 Xray JSON 生成**

从 `xray uuid` 和 `xray x25519` 解析凭据，严格校验结果后写入 `$BACKUP_DIR/staged-config.json`，不覆盖当前生产配置；配置必须包含 `port: 443`、`protocol: vless`、`flow: xtls-rprx-vision`、`network: raw`、`security: reality`、`target: www.bing.com:443` 和 `serverNames: [www.bing.com]`。

- [ ] **Step 5: 实现动态文件组与配置预校验**

在任何 443 切换前对 staged JSON 运行 `xray run -test -config ...`。正式配置的动态组归属和 `0640` 安装放到 Task 5 的事务内，避免预校验阶段改写生产文件。

- [ ] **Step 6: 验证 Xray 安装与配置测试**

Run: `cd vless-reality-installer && bash tests/run.sh`
Expected: 官方来源、凭据轮换、JSON 固定值、权限与校验顺序测试全部 PASS。

- [ ] **Step 7: 提交 Xray 安装与配置生成**

```bash
git -C vless-reality-installer add install.sh tests/test-installer.sh
git -C vless-reality-installer commit -m "feat: 安装 Xray 并生成 REALITY 配置"
```

### Task 5: 实现交易式激活、端到端验收和回滚

**Files:**
- Modify: `vless-reality-installer/install.sh`
- Modify: `vless-reality-installer/tests/test-installer.sh`

**Interfaces:**
- Consumes: Task 2 `preflight()`、Task 3 备份/服务状态函数、Task 4 的 Xray 准备与 staged 配置。
- Produces: `install_staged_server_config()`、`upgrade_existing_xray()`、`activate_xray()`、`verify_listener()`、`run_end_to_end_test()`、`build_share_uri() -> stdout URI`、`write_client_output()`、`rollback()`、完整 `main()`。

- [ ] **Step 1: 添加事务顺序与回滚失败测试**

添加 `test_switch_happens_after_config_validation`、`test_existing_xray_upgrade_occurs_after_quiesce`、`test_start_failure_restores_config_and_services`、`test_listener_failure_rolls_back`、`test_proxy_failure_rolls_back`，对命令记录断言顺序，并断言原 active/enabled 状态完全恢复。

- [ ] **Step 2: 实现交易标志和统一回滚**

仅在调用 `quiesce_port_443()` 前设置“即将切换”状态；从此刻起任何 ERR/INT/TERM 触发 `rollback()`。回滚停止新 Xray，恢复备份的 Xray 可执行文件、配置、systemd unit/override 和原服务状态，保留日志并非零退出。

- [ ] **Step 3: 添加本地 REALITY/Vision 验收失败测试**

添加 `test_e2e_client_uses_loopback_and_generated_credentials`、`test_e2e_requires_matching_exit_ipv4`、`test_e2e_temp_files_are_cleaned`，断言临时客户端连接 `127.0.0.1:443`、SNI 为 Bing、flow 为 Vision，且经 SOCKS 检测的 IPv4 与预检结果一致。

- [ ] **Step 4: 实现 Xray 启动、监听和本地代理验收**

`install_staged_server_config()` 根据 `xray.service` 账户的实际主组以 `0640` 原子安装配置；已存在 Xray 时，`upgrade_existing_xray()` 在旧 443 占用服务全部停止且新配置就位后调用官方安装器的 `install --without-geodata --no-update-service`。`activate_xray()` 执行 enable/restart 并检查 active/enabled；`verify_listener()` 用 `ss` 确认 Xray PID 监听 443；`run_end_to_end_test()` 在 `mktemp -d` 中写临时 SOCKS 客户端配置，用本机回环连接生产入站，通过 SOCKS 请求有超时的 IPv4 检测端点，最后清理子进程和临时文件。

- [ ] **Step 5: 添加客户端文件和分享链接测试**

添加 `test_share_uri_contains_all_generated_values`、`test_client_output_is_mode_0600`、`test_client_output_written_only_after_success`，断言 URI 包含 `type=tcp&security=reality&fp=chrome&sni=www.bing.com&sid=<SHORT_ID>&spx=%2F&flow=xtls-rprx-vision`。

- [ ] **Step 6: 实现成功输出与完整编排**

`write_client_output()` 在全部验收通过后以原子替换写入 `/root/VLESS-REALITY-Vision.txt`并设为 `0600`；`main()` 严格按预检 -> 备份 -> 安装 -> 生成/校验 -> 切换 -> 启动/验收 -> 输出的顺序组合。

- [ ] **Step 7: 验证完整行为测试**

Run: `cd vless-reality-installer && bash tests/run.sh`
Expected: 启动/监听/代理三类失败都通过回滚测试，成功流程仅在最后写出凭据。

- [ ] **Step 8: 提交完整安装交易**

```bash
git -C vless-reality-installer add install.sh tests/test-installer.sh
git -C vless-reality-installer commit -m "feat: 完成安装验收与失败回滚"
```

### Task 6: 加入静态安全检查、CI 和用户文档

**Files:**
- Create: `vless-reality-installer/tests/static-check.sh`
- Create: `vless-reality-installer/.github/workflows/check.yml`
- Create: `vless-reality-installer/README.md`
- Create: `vless-reality-installer/LICENSE`
- Modify: `vless-reality-installer/tests/run.sh`

**Interfaces:**
- Consumes: Task 5 的完整 `install.sh` 和行为测试。
- Produces: 本地/CI 统一检查入口 `bash tests/run.sh`；GitHub Raw 安装与审查后执行说明。

- [ ] **Step 1: 编写会先失败的静态安全检查**

`tests/static-check.sh` 检查：无硬编码 UUID/私钥/Short ID；无停止 SSH、关闭防火墙或强制 kill 命令；无 `curl ... | bash`；存在 `mktemp -d`/trap；配置校验文本位于停服务调用之前。先以一个临时不安全 fixture 证明每条规则能失败。

- [ ] **Step 2: 将静态检查纳入统一测试入口**

Run: `cd vless-reality-installer && bash tests/run.sh`
Expected: 安全 fixture 测试被检出，真实 `install.sh` 全部 PASS。

- [ ] **Step 3: 创建 GitHub Actions**

`check.yml` 在 push 和 pull_request 上运行 `bash -n install.sh`、ShellCheck 及 `bash tests/run.sh`；行为测试矩阵至少包含 `ubuntu:24.04` 和 `rockylinux:9`，每个容器只 source 脚本并运行命令替身测试，不执行真实 `main()`。权限设为 `contents: read`，不使用 secrets，不 SSH 到任何 VPS。

- [ ] **Step 4: 编写中文 README 和 MIT License**

README 包含支持系统、固定参数、风险警告、安全的“先下载检查再执行”方式、Raw 一键命令、凭据文件路径、重跑会轮换凭据、备份/回滚、不修改防火墙/安全组和客户端导入方法。

- [ ] **Step 5: 执行全部本地检查**

Run: `cd vless-reality-installer && bash -n install.sh && shellcheck install.sh tests/*.sh && bash tests/run.sh`
Expected: 所有命令退出码为 0；如本机未安装 ShellCheck，先用 Homebrew 安装后重跑。

- [ ] **Step 6: 提交文档和 CI**

```bash
git -C vless-reality-installer add .github tests README.md LICENSE
git -C vless-reality-installer commit -m "docs: 增加安装说明与自动检查"
```

### Task 7: 创建公开 GitHub 仓库并验证发布物

**Files:**
- Verify only: `vless-reality-installer/*`

**Interfaces:**
- Consumes: Task 6 中本地通过的完整仓库。
- Produces: 公开仓库 `https://github.com/oceanliam/vless-reality-installer`、通过的 Actions 运行和可读取的 Raw `install.sh`。

- [ ] **Step 1: 发布前检查身份、秘密和工作树**

Run: `gh auth status && git -C vless-reality-installer status --short && git -C vless-reality-installer diff --check && cd vless-reality-installer && bash tests/static-check.sh`
Expected: GitHub 账户为 `oceanliam`，工作树干净，静态安全检查通过。另做一次本地“凭据重合检查”：从现有客户端信息文件读取敏感值并仅返回通过/失败，不在命令、日志或终端中打印敏感值；任何重合都必须在发布前移除。

- [ ] **Step 2: 核对跨发行版 CI 配置**

Run: `cd vless-reality-installer && rg -n 'ubuntu:24.04|rockylinux:9|tests/run.sh' .github/workflows/check.yml`
Expected: 两类发行版容器和统一行为测试入口都存在；真实跨发行版执行由推送后的 GitHub Actions 完成。

- [ ] **Step 3: 创建并推送公开仓库**

Run: `gh repo create oceanliam/vless-reality-installer --public --source=vless-reality-installer --remote=origin --push`
Expected: 仓库可公开访问，`main` 已推送。

- [ ] **Step 4: 等待并验证 GitHub Actions**

Run: `cd vless-reality-installer && gh run list --limit 1 && gh run watch "$(gh run list --limit 1 --json databaseId --jq '.[0].databaseId')" --exit-status`
Expected: `check` workflow conclusion 为 `success`。

- [ ] **Step 5: 验证 GitHub Raw 内容而不执行**

Run: `curl -fsSL https://raw.githubusercontent.com/oceanliam/vless-reality-installer/main/install.sh | bash -n`
Expected: 退出码 0；只进行语法检查，不执行脚本。

- [ ] **Step 6: 最终发布核对**

Run: `gh repo view oceanliam/vless-reality-installer --json nameWithOwner,visibility,defaultBranchRef,url`
Expected: `nameWithOwner` 为 `oceanliam/vless-reality-installer`、`visibility` 为 `PUBLIC`、默认分支为 `main`。最终向用户提供仓库链接、Raw 安装命令、Actions 状态，并明确说明当前 VPS 没有被修改。
