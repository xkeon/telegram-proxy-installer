# Telegram MTProto Proxy Installer (EE + DD)

[English](#english) | [中文](#chinese) | [한국어](#korean) | [日本語](#japanese)

One-click interactive installer for Telegram MTProto proxy on Ubuntu 26.04 LTS.

- EE (FakeTLS): `nineseconds/mtg`
- DD (padding): `telegrammessenger/proxy`
- Entry script: `install.sh`

<a id="english"></a>
## English

### Features
- Deploy mode: `EE only` / `DD only` / `EE+DD`
- Fronting domain: presets + manual input
- Port: presets + manual input, conflict detection
- Multi-IP bind support
- `systemd` managed services
- Healthcheck / self-heal / self-update
- Upgrade / migrate / rollback / rotate-secret (advanced)

### Terminal UI
The menu groups services, updates, and recovery, and shows EE/DD service states and ports. In a supported terminal, use Up/Down and Enter, or type a number and press Enter; `r` refreshes status and `q` / Esc goes back or exits. Mode selectors include a Back option. With an existing deployment, the menu initially selects Healthcheck.

Piped input, `TERM=dumb`, and very small terminals use a numbered text menu. Set `NO_COLOR` to disable colors while keeping navigation, for example `sudo env NO_COLOR=1 bash install.sh`. The header shows systemd service state; run Healthcheck for container and port diagnosis.

### Management and automation

The menu now includes settings, connection links/QR, backup history, service controls, resource status, scheduled checks, and language selection. The wizard keeps current values on Enter; use `:back`, `:cancel`, or `:presets` for domain/port suggestions. Review and edit the summary before applying. Language and backup retention are saved in `/etc/telegram-proxy/preferences.env`.

`configure` changes domains, ports and bindings without package installation. Repeating `install` preserves existing secrets; `--reinstall` explicitly generates new ones. Changing the EE FakeTLS domain rotates its embedded secret, so clients need new links. Links are masked by default; `--show-secret` reveals them and `--qr` renders a complete QR locally with qrencode.

```bash
bash install.sh install --config examples/proxy.conf --dry-run --lang en
sudo bash install.sh install --config /path/to/proxy.conf --non-interactive --yes
sudo bash install.sh configure --mode dd --port 8443 --non-interactive --yes
sudo bash install.sh status --mode all --json
sudo bash install.sh links --mode all --show-secret
sudo bash install.sh links --mode ee --qr
sudo bash install.sh service --mode ee --action stop
sudo bash install.sh service --mode ee --action start
sudo bash install.sh service --mode all --action logs --lines 50
sudo bash install.sh backups
sudo bash install.sh backups --keep 20 --prune --yes
sudo bash install.sh monitor --mode all --action enable --interval 5 --max-retries 3 --cooldown 300 --yes
sudo bash install.sh monitor --action disable --yes
sudo bash install.sh regional-diagnose --mode all --public-ipv4 203.0.113.5 --report /root/proxy-report.txt
sudo bash install.sh language --lang en
```

Replace example domains/IPs with your VPS settings. Config files contain literal, unquoted `KEY=value` entries, are never executed, and explicit flags override the file. Use `--secret-file` with a file of mode 600 or 400 when rotating secrets. Mutating commands support `--dry-run` to inspect the requested changes without installing packages, creating locks or modifying services. Applying changes requires root; reading installed private configuration also normally needs sudo. `status` and `healthcheck` accept `--json`. Health exit codes: 0 healthy, 1 unhealthy, 2 absent/unmanaged; `--mode all` skips absent modes when another mode is healthy.

Installation, settings, rotation, migration, upgrades and uninstall save snapshots before changing proxy files. Failures attempt recovery and return nonzero even when recovery succeeds. Snapshots record stopped/paused state; incomplete backups are excluded from history and retention. The history shows timestamp, action, scope, ports and digests. Retention applies to complete new snapshots; old-format and partial directories remain for manual inspection. Uninstall keeps backups, packages and existing firewall rules. Self-update refuses a dirty Git checkout. Migration preserves the detected secrets and leaves original containers stopped under the displayed names; remove those after testing clients.

Scheduled checks are opt-in and use a copied runner under `/etc/telegram-proxy/runner`, a systemd timer, bounded retries and cooldown. A successful check resets the retry counter; `service start/restart` clears it manually. `service stop` pauses automatic repair. The timer never upgrades images. Status shows bindings, image/version, start time and Docker CPU/memory/network metrics. New containers rotate Docker logs at 10 MB × 3.

NAT/public IP checks are separate from local bindings; set `PUBLIC_IPV4/PUBLIC_IPV6` when needed. DNS comparisons normalize IPv6; diagnostic TLS checks verify the certificate and hostname. Reports and recent logs redact known configured secrets. The local health check does not prove Telegram connectivity or regional access; verify with a client. Firewall defaults to `keep`, BBR to `no`. Enabling UFW preserves detected SSH ports. Docker published ports may bypass UFW; use a cloud firewall or Docker-aware forwarding rules for access restrictions. Installation failure can leave newly installed packages and pulled images; proxy files, added firewall rules and BBR settings are the recovery scope.

### Requirements
- Ubuntu 26.04 LTS
- Root privilege
- Domain A records point to your VPS (`DNS only`, no CDN proxy)

### Quick Start

Copy the entire block into your VPS terminal. It installs Git first, downloads or updates the project, then opens the working management menu using its full path. A download or update failure stops execution.

```bash
(
  set -e
  sudo apt-get update
  sudo apt-get install -y git ca-certificates
  proxy_repo="$HOME/telegram-proxy-installer"
  if [ -d "$proxy_repo/.git" ]; then
    git -C "$proxy_repo" pull --ff-only
  else
    git clone https://github.com/xkeon/telegram-proxy-installer.git "$proxy_repo"
  fi
  sudo bash "$proxy_repo/install.sh" --lang en
)
```

### Connect to Your VPS by IP
1. Find the public IPv4 address of your VPS in your cloud provider panel.
2. Open a local terminal and connect over SSH:
```bash
ssh root@<your_vps_ip>
```
3. If your server uses another default user, replace `root` with that user name, for example:
```bash
ssh ubuntu@<your_vps_ip>
```
4. If this is your first connection, type `yes` when SSH asks whether to continue.
5. If your VPS requires an SSH key file, use:
```bash
ssh -i ~/.ssh/<your_key_file> root@<your_vps_ip>
```

### Common Operations
- `sudo bash install.sh`: open interactive menu (install/manage).
- `healthcheck --mode all`: check EE/DD service, container, and port health.
- `self-heal --mode all`: restart unhealthy services automatically.
- `self-update`: update script repo to latest version.
- `uninstall --mode all`: remove managed services and related config.

```bash
sudo bash install.sh healthcheck --mode all
sudo bash install.sh self-heal --mode all
sudo bash install.sh self-update
sudo bash install.sh uninstall --mode all
```

<details>
<summary>Advanced Operations</summary>

Upgrade pulls all selected images before changing configuration. If a restart or health check fails, it attempts to restore the backup and restart the previous services. A failed upgrade still returns a nonzero status after successful recovery. Rollback restarts services and only reports success after its health check passes.

```bash
# upgrade image digest(s)
sudo bash install.sh upgrade --mode ee --mtg-image auto
sudo bash install.sh upgrade --mode dd --dd-image auto
sudo bash install.sh upgrade --mode ee --mtg-image 'nineseconds/mtg@sha256:<digest>'
sudo bash install.sh upgrade --mode dd --dd-image 'telegrammessenger/proxy@sha256:<digest>'

# migrate legacy running containers into script-managed services (auto-detect config)
sudo bash install.sh migrate --mode all

# rollback (latest backup by default)
sudo bash install.sh rollback --mode all
sudo bash install.sh rollback --mode ee --backup-id '<backup-id>'

# manual secret rotation
sudo bash install.sh rotate-secret --mode ee --secret '<new_ee_secret_hex>'
sudo bash install.sh rotate-secret --mode dd --secret 'dd<32hex>'  # or just 32hex
```

</details>

<details>
<summary>Advanced: Pinned Digests</summary>

The script requires digest-style image references (`name@sha256:...`).

Current defaults:
- `MTG_IMAGE="nineseconds/mtg@sha256:c082586a19886e4822f92aa8c1949a771df3519053d64b1b5505a9a280a3929d"`
- `DD_IMAGE="telegrammessenger/proxy@sha256:73210d43c8f8e4c888ba4e30d6daf7742528e9134252a1cd538caabf5e24a597"`

Optional override:
```bash
export MTG_IMAGE='nineseconds/mtg@sha256:<64-hex-digest>'
export DD_IMAGE='telegrammessenger/proxy@sha256:<64-hex-digest>'
sudo -E bash install.sh
```

Fetch digest in a networked environment:
```bash
docker pull nineseconds/mtg:2
docker pull telegrammessenger/proxy:latest
docker image inspect nineseconds/mtg:2 --format '{{index .RepoDigests 0}}'
docker image inspect telegrammessenger/proxy:latest --format '{{index .RepoDigests 0}}'
```

</details>

<a id="chinese"></a>
## 中文

### 功能
- 部署模式：`仅 EE` / `仅 DD` / `EE+DD`
- Fronting 域名：预设 + 手动输入
- 端口：预设 + 手动输入，冲突检测
- 支持多 IP 绑定
- `systemd` 托管服务
- 健康检查 / 自愈 / 脚本自更新
- 升级 / 迁移 / 回滚 / 轮换密钥（高级）

### 终端界面
菜单按服务、更新和恢复分组，并显示 EE/DD 服务状态与端口。在支持的终端中，用方向键和回车选择，或输入编号后回车；`r` 刷新状态，`q` / Esc 返回或退出。操作模式选择支持返回。已有部署时，首页默认选中健康检查。

通过管道输入、使用 `TERM=dumb` 或窗口过小时，自动使用编号文本菜单。设置 `NO_COLOR` 可关闭颜色并保留导航，例如 `sudo env NO_COLOR=1 bash install.sh`。首页显示 systemd 服务状态；容器和端口诊断请使用健康检查。

### 管理与自动化

菜单已加入修改配置、连接链接与二维码、备份历史、服务操作、资源状态、定时检查和语言切换。向导中回车保留当前值，`:back` 返回，`:cancel` 取消，`:presets` 选择常用域名或端口；执行前可以在汇总页修改。语言与备份保留数量保存到 `/etc/telegram-proxy/preferences.env`。

`configure` 可以修改域名、端口和绑定地址，无需重新安装软件。再次 `install` 默认保留已有密钥，`--reinstall` 才重新生成。更换 EE 的 FakeTLS 域名会轮换嵌入域名的密钥，需要给客户端更新链接。连接链接默认隐藏密钥，`--show-secret` 显示完整链接，`--qr` 使用 qrencode 在本机生成完整二维码。

```bash
bash install.sh install --config examples/proxy.conf --dry-run --lang zh
sudo bash install.sh install --config /path/to/proxy.conf --non-interactive --yes
sudo bash install.sh configure --mode dd --port 8443 --non-interactive --yes
sudo bash install.sh status --mode all --json
sudo bash install.sh links --mode all --show-secret
sudo bash install.sh links --mode ee --qr
sudo bash install.sh service --mode ee --action stop
sudo bash install.sh service --mode ee --action start
sudo bash install.sh service --mode all --action logs --lines 50
sudo bash install.sh backups
sudo bash install.sh backups --keep 20 --prune --yes
sudo bash install.sh monitor --mode all --action enable --interval 5 --max-retries 3 --cooldown 300 --yes
sudo bash install.sh monitor --action disable --yes
sudo bash install.sh regional-diagnose --mode all --public-ipv4 203.0.113.5 --report /root/proxy-report.txt
sudo bash install.sh language --lang zh
```

请将示例域名、IP 替换为 VPS 的实际配置。配置文件采用不带引号的 `KEY=value`，只读取数据，不执行文件；命令行参数优先。轮换密钥可用 `--secret-file` 读取权限为 600 或 400 的文件。变更命令支持 `--dry-run`，用于核对即将执行的配置变更，不安装软件、不创建锁、不修改服务。实际变更需要 root，读取已有的私密配置通常也需要 sudo。`status`、`healthcheck` 支持 `--json`；健康检查退出码为 0 正常、1 异常、2 未安装或未托管，`--mode all` 在已有健康模式时跳过缺失模式。

安装、配置、轮换、迁移、升级与卸载都会在修改代理文件前保存快照；失败时尝试恢复，恢复成功也保留失败退出码。备份记录停止/暂停状态，不完整备份不进入历史与保留数量计算。历史列出时间、操作、模式、端口和镜像摘要；自动清理只处理完整的新格式快照，旧格式与不完整目录留给人工检查。卸载保留备份、软件包与已有防火墙规则。自更新会拒绝覆盖有本地变更的 Git 仓库。迁移保留检测到的密钥，并保留以提示名称命名、已停止的旧容器，客户端验证后可自行清理。

定时检查需要主动开启，通过 `/etc/telegram-proxy/runner` 中的脚本副本和 systemd timer 执行，并限制重试次数与冷却时间。健康检查成功会清空次数；手动启动/重启也可重置。手动停止会暂停自动修复；定时任务不升级镜像。状态页显示绑定地址、镜像/版本、本次启动时间和 Docker CPU/内存/网络信息。新建容器日志按 10 MB × 3 轮转。

NAT 公网地址与本机绑定分别检查，可填写 `PUBLIC_IPV4/PUBLIC_IPV6`；IPv6 DNS 对比会规范化地址，诊断中的 TLS 检查会验证证书与域名。报告和最近日志隐藏已知配置密钥。本机健康检查不能证明 Telegram 实际连接或地区可用性，需要客户端验证。防火墙默认 `keep`，BBR 默认 `no`；主动启用 UFW 时保留检测到的 SSH 端口。Docker 发布端口可能绕过 UFW，访问限制应使用云防火墙或适配 Docker 的转发规则。安装失败可能留下已安装的软件包与已拉取镜像；恢复范围包括代理文件、新增防火墙规则与 BBR 设置。

### 前置条件
- Ubuntu 26.04 LTS
- root 权限
- 域名 A 记录已解析到 VPS（`DNS only`，不要 CDN 代理）

### 快速开始

完整复制以下命令到 VPS 终端。先安装 Git，再下载或更新项目，最后通过完整路径打开实际的管理菜单；下载或更新失败时会立即停止。

```bash
(
  set -e
  sudo apt-get update
  sudo apt-get install -y git ca-certificates
  proxy_repo="$HOME/telegram-proxy-installer"
  if [ -d "$proxy_repo/.git" ]; then
    git -C "$proxy_repo" pull --ff-only
  else
    git clone https://github.com/xkeon/telegram-proxy-installer.git "$proxy_repo"
  fi
  sudo bash "$proxy_repo/install.sh" --lang zh
)
```

### 通过 IP 地址连接 VPS
1. 在云服务商控制台找到 VPS 的公网 IPv4 地址。
2. 在本地终端执行 SSH 连接：
```bash
ssh root@<你的VPS_IP>
```
3. 如果服务器默认用户不是 `root`，把它替换成实际用户名，例如：
```bash
ssh ubuntu@<你的VPS_IP>
```
4. 首次连接时，SSH 会询问是否继续，输入 `yes` 即可。
5. 如果你的 VPS 需要指定私钥文件，使用：
```bash
ssh -i ~/.ssh/<你的私钥文件> root@<你的VPS_IP>
```

### 常用命令
- `sudo bash install.sh`：进入交互式主菜单（安装/管理）。
- `healthcheck --mode all`：检查 EE/DD 的服务、容器和端口状态。
- `self-heal --mode all`：自动重启异常服务。
- `self-update`：更新脚本仓库到最新版。
- `uninstall --mode all`：卸载脚本托管的服务与配置。

```bash
sudo bash install.sh healthcheck --mode all
sudo bash install.sh self-heal --mode all
sudo bash install.sh self-update
sudo bash install.sh uninstall --mode all
```

<details>
<summary>高级命令</summary>

升级会先拉取所有选定镜像，再修改配置。重启或健康检查失败时，会尝试恢复备份并重启原服务；即使恢复成功，失败的升级仍返回非零状态。回滚会重启服务，并在健康检查通过后才报告成功。

```bash
# 升级镜像 digest
sudo bash install.sh upgrade --mode ee --mtg-image auto
sudo bash install.sh upgrade --mode dd --dd-image auto
sudo bash install.sh upgrade --mode ee --mtg-image 'nineseconds/mtg@sha256:<digest>'
sudo bash install.sh upgrade --mode dd --dd-image 'telegrammessenger/proxy@sha256:<digest>'

# 迁移旧版正在运行的容器到脚本托管（自动识别配置）
sudo bash install.sh migrate --mode all

# 回滚（默认最新备份）
sudo bash install.sh rollback --mode all
sudo bash install.sh rollback --mode ee --backup-id '<backup-id>'

# 手动轮换 secret
sudo bash install.sh rotate-secret --mode ee --secret '<new_ee_secret_hex>'
sudo bash install.sh rotate-secret --mode dd --secret 'dd<32hex>'  # 或仅 32hex
```

</details>

<details>
<summary>高级：固定 Digest</summary>

脚本要求镜像使用 digest 形式（`name@sha256:...`）。

当前默认值：
- `MTG_IMAGE="nineseconds/mtg@sha256:c082586a19886e4822f92aa8c1949a771df3519053d64b1b5505a9a280a3929d"`
- `DD_IMAGE="telegrammessenger/proxy@sha256:73210d43c8f8e4c888ba4e30d6daf7742528e9134252a1cd538caabf5e24a597"`

可选覆盖：
```bash
export MTG_IMAGE='nineseconds/mtg@sha256:<64位十六进制digest>'
export DD_IMAGE='telegrammessenger/proxy@sha256:<64位十六进制digest>'
sudo -E bash install.sh
```

联网环境下查询 digest：
```bash
docker pull nineseconds/mtg:2
docker pull telegrammessenger/proxy:latest
docker image inspect nineseconds/mtg:2 --format '{{index .RepoDigests 0}}'
docker image inspect telegrammessenger/proxy:latest --format '{{index .RepoDigests 0}}'
```

</details>

<a id="korean"></a>
## 한국어

### 기능
- 배포 모드: `EE만` / `DD만` / `EE+DD`
- Fronting 도메인: 프리셋 + 수동 입력
- 포트: 프리셋 + 수동 입력, 충돌 감지
- 멀티 IP 바인드 지원
- `systemd` 서비스 관리
- 상태 점검 / 자동 복구 / 스크립트 업데이트
- 업그레이드 / 마이그레이션 / 롤백 / 시크릿 교체 (고급)

### 터미널 UI
메뉴는 서비스, 업데이트, 복구 작업을 그룹으로 표시하고 EE/DD 서비스 상태와 포트를 보여 줍니다. 지원되는 터미널에서는 방향키와 Enter 또는 번호와 Enter를 사용합니다. `r`은 상태 새로 고침, `q` / Esc는 뒤로 또는 종료입니다. 모드 선택에서 뒤로 돌아갈 수 있으며, 기존 배포가 있으면 상태 점검이 기본 선택됩니다.

파이프 입력, `TERM=dumb`, 아주 작은 창에서는 번호 메뉴를 사용합니다. `sudo env NO_COLOR=1 bash install.sh`로 색상을 끄고 탐색은 유지할 수 있습니다. 헤더는 systemd 서비스 상태이며, 컨테이너와 포트 진단은 상태 점검을 사용하세요.

### 관리 및 자동화

메뉴에서 설정, 링크/로컬 QR, 백업 기록, 서비스 제어, 리소스, 예약 점검 및 언어를 선택할 수 있습니다. 마법사는 Enter로 현재 값을 유지하며 `:back`, `:cancel`, `:presets`를 지원합니다. 적용 전 요약을 수정할 수 있고 언어/백업 보관 개수는 저장됩니다.

`configure`는 패키지를 다시 설치하지 않고 설정을 바꿉니다. 반복 설치는 기존 시크릿을 유지하고 `--reinstall`은 새 시크릿을 생성합니다. EE FakeTLS 도메인 변경 시 링크도 바뀝니다. 링크는 기본적으로 숨기며 `--show-secret` 또는 `--qr`로 표시합니다.

```bash
bash install.sh install --config examples/proxy.conf --dry-run --lang ko
sudo bash install.sh configure --mode dd --port 8443 --non-interactive --yes
sudo bash install.sh status --json
sudo bash install.sh links --mode ee --qr
sudo bash install.sh service --mode dd --action restart
sudo bash install.sh backups --keep 20 --prune --yes
sudo bash install.sh monitor --action enable --interval 5 --max-retries 3 --cooldown 300 --yes
sudo bash install.sh language --lang ko
```

예제 도메인/IP를 실제 VPS 값으로 바꾸세요. 설정 파일은 인용 부호 없는 `KEY=value` 데이터이며 실행하지 않습니다. 명령행 옵션이 우선합니다. 변경 명령의 `--dry-run`은 파일, 패키지 및 서비스를 바꾸지 않습니다. 시크릿 교체에는 권한 600/400인 `--secret-file`을 사용할 수 있습니다. 적용과 비공개 설정 읽기는 보통 root/sudo가 필요합니다. 상태/건강 점검은 `--json`을 지원합니다. 건강 종료 코드: 0 정상, 1 실패, 2 미관리; `all`은 다른 정상 모드가 있으면 없는 모드를 건너뜁니다.

변경 전 백업하고 실패 시 복구를 시도하며 실패 코드는 유지합니다. 백업은 정지 상태도 복원하고 불완전한 스냅샷은 목록/정리에서 제외합니다. 제거 시 백업/패키지/기존 방화벽 규칙은 유지합니다. 업데이트는 로컬 Git 변경이 있으면 중단합니다. 마이그레이션은 기존 시크릿과 정지한 원본 컨테이너를 보존합니다. 예약 점검은 선택 사항이며 재시도/대기 시간을 제한하고 수동 정지를 존중합니다. 상태는 이미지/버전/바인딩/시작 시간/CPU/메모리/네트워크를 표시합니다.

NAT 공개 IP와 로컬 바인딩을 분리하고 IPv6 DNS를 정규화합니다. TLS 인증서/호스트 이름을 확인하며 보고서/최근 로그의 설정 시크릿을 숨깁니다. 클라이언트 연결은 별도로 테스트하세요. UFW 기본값은 `keep`, BBR은 `no`입니다. Docker 게시 포트는 UFW를 우회할 수 있으므로 클라우드 방화벽 또는 Docker 대응 전달 규칙을 사용하세요. 설치 실패 시 패키지/이미지는 남을 수 있으며 프록시 파일, 추가 방화벽 규칙 및 BBR 설정을 복구합니다.

### 요구사항
- Ubuntu 26.04 LTS
- root 권한
- 도메인 A 레코드가 VPS를 가리켜야 함 (`DNS only`, CDN 프록시 금지)

### 빠른 시작

VPS 터미널에 전체 블록을 복사하세요. Git 설치 후 프로젝트를 다운로드하거나 업데이트하고 전체 경로로 관리 메뉴를 엽니다. 다운로드/업데이트 실패 시 중단합니다.

```bash
(
  set -e
  sudo apt-get update
  sudo apt-get install -y git ca-certificates
  proxy_repo="$HOME/telegram-proxy-installer"
  if [ -d "$proxy_repo/.git" ]; then
    git -C "$proxy_repo" pull --ff-only
  else
    git clone https://github.com/xkeon/telegram-proxy-installer.git "$proxy_repo"
  fi
  sudo bash "$proxy_repo/install.sh" --lang ko
)
```

### IP 주소로 VPS 접속하기
1. 클라우드 제공업체 콘솔에서 VPS의 공인 IPv4 주소를 확인합니다.
2. 로컬 터미널에서 SSH로 접속합니다:
```bash
ssh root@<your_vps_ip>
```
3. 기본 사용자가 `root`가 아니라면 실제 사용자명으로 바꿉니다. 예:
```bash
ssh ubuntu@<your_vps_ip>
```
4. 처음 접속하는 경우 SSH 확인 메시지가 나오면 `yes`를 입력합니다.
5. SSH 키 파일을 지정해야 한다면 다음과 같이 접속합니다:
```bash
ssh -i ~/.ssh/<your_key_file> root@<your_vps_ip>
```

### 기본 명령
- `sudo bash install.sh`: 대화형 메인 메뉴를 열어 설치/관리를 진행합니다.
- `healthcheck --mode all`: EE/DD 서비스, 컨테이너, 포트 상태를 점검합니다.
- `self-heal --mode all`: 비정상 서비스를 자동 재시작합니다.
- `self-update`: 스크립트 저장소를 최신 상태로 갱신합니다.
- `uninstall --mode all`: 스크립트 관리 서비스와 설정을 제거합니다.

```bash
sudo bash install.sh healthcheck --mode all
sudo bash install.sh self-heal --mode all
sudo bash install.sh self-update
sudo bash install.sh uninstall --mode all
```

<details>
<summary>고급 명령</summary>

업그레이드는 선택한 이미지를 모두 가져온 후 설정을 변경합니다. 재시작이나 상태 확인이 실패하면 백업을 복원하고 이전 서비스를 재시작합니다. 복구에 성공해도 실패한 업그레이드는 0이 아닌 상태를 반환합니다. 롤백은 서비스를 재시작하고 상태 확인을 통과한 후에만 성공을 보고합니다.

```bash
# 이미지 digest 업그레이드
sudo bash install.sh upgrade --mode ee --mtg-image auto
sudo bash install.sh upgrade --mode dd --dd-image auto
sudo bash install.sh upgrade --mode ee --mtg-image 'nineseconds/mtg@sha256:<digest>'
sudo bash install.sh upgrade --mode dd --dd-image 'telegrammessenger/proxy@sha256:<digest>'

# 레거시 실행 컨테이너를 스크립트 관리로 마이그레이션 (설정 자동 감지)
sudo bash install.sh migrate --mode all

# 롤백 (기본: 최신 백업)
sudo bash install.sh rollback --mode all
sudo bash install.sh rollback --mode ee --backup-id '<backup-id>'

# 시크릿 수동 교체
sudo bash install.sh rotate-secret --mode ee --secret '<new_ee_secret_hex>'
sudo bash install.sh rotate-secret --mode dd --secret 'dd<32hex>'  # 또는 32hex
```

</details>

<details>
<summary>고급: 고정 Digest</summary>

스크립트는 digest 형식(`name@sha256:...`) 이미지만 허용합니다.

현재 기본값:
- `MTG_IMAGE="nineseconds/mtg@sha256:c082586a19886e4822f92aa8c1949a771df3519053d64b1b5505a9a280a3929d"`
- `DD_IMAGE="telegrammessenger/proxy@sha256:73210d43c8f8e4c888ba4e30d6daf7742528e9134252a1cd538caabf5e24a597"`

선택적으로 덮어쓰기:
```bash
export MTG_IMAGE='nineseconds/mtg@sha256:<64-hex-digest>'
export DD_IMAGE='telegrammessenger/proxy@sha256:<64-hex-digest>'
sudo -E bash install.sh
```

네트워크 환경에서 digest 조회:
```bash
docker pull nineseconds/mtg:2
docker pull telegrammessenger/proxy:latest
docker image inspect nineseconds/mtg:2 --format '{{index .RepoDigests 0}}'
docker image inspect telegrammessenger/proxy:latest --format '{{index .RepoDigests 0}}'
```

</details>

<a id="japanese"></a>
## 日本語

### 機能
- デプロイモード: `EEのみ` / `DDのみ` / `EE+DD`
- fronting ドメイン: プリセット + 手動入力
- ポート: プリセット + 手動入力、競合検出
- マルチIPバインド対応
- `systemd` サービス管理
- ヘルスチェック / 自動復旧 / スクリプト自己更新
- アップグレード / 移行 / ロールバック / シークレット更新（上級）

### ターミナル UI
メニューはサービス、更新、復元に分類され、EE/DD のサービス状態とポートを表示します。対応端末では方向キーと Enter、または番号と Enter で選択します。`r` で状態を更新し、`q` / Esc で戻るか終了します。モード選択から戻ることができ、既存の構成がある場合はヘルスチェックが初期選択になります。

パイプ入力、`TERM=dumb`、非常に小さいウィンドウでは番号メニューになります。`sudo env NO_COLOR=1 bash install.sh` で色を無効にして操作を続けられます。ヘッダーは systemd サービスの状態です。コンテナとポートの診断にはヘルスチェックを使用してください。

### 管理と自動化

メニューから設定、リンク/ローカル QR、バックアップ履歴、サービス操作、リソース、定期点検、言語を選択できます。ウィザードは Enter で現在値を保持し、`:back`、`:cancel`、`:presets` に対応します。適用前の要約を編集でき、言語とバックアップ保持数を保存します。

`configure` はパッケージを再インストールせず設定を変更します。再度のインストールは既存シークレットを保持し、`--reinstall` で新規生成します。EE FakeTLS ドメイン変更時にはリンクも変わります。リンクは通常非表示、`--show-secret` または `--qr` で表示します。

```bash
bash install.sh install --config examples/proxy.conf --dry-run --lang ja
sudo bash install.sh configure --mode dd --port 8443 --non-interactive --yes
sudo bash install.sh status --json
sudo bash install.sh links --mode ee --qr
sudo bash install.sh service --mode dd --action restart
sudo bash install.sh backups --keep 20 --prune --yes
sudo bash install.sh monitor --action enable --interval 5 --max-retries 3 --cooldown 300 --yes
sudo bash install.sh language --lang ja
```

例のドメイン/IP は VPS の実際の値へ変更してください。設定ファイルは引用符なしの `KEY=value` データとして読み、実行しません。コマンド引数を優先します。変更コマンドの `--dry-run` はファイル、パッケージ、サービスを変更しません。鍵の変更には権限 600/400 の `--secret-file` を使えます。適用や非公開設定の読み取りには通常 root/sudo が必要です。状態/ヘルスチェックは `--json` 対応です。終了コードは 0 正常、1 異常、2 未管理で、`all` は別モードが正常なら存在しないモードを除外します。

変更前にバックアップし、失敗時には復元を試み、失敗の終了コードを維持します。停止状態も復元し、不完全なスナップショットは履歴/整理から除外します。削除してもバックアップ、パッケージ、既存ファイアウォール規則は保持します。自動更新は Git のローカル変更があれば中止します。移行は既存キーと停止した旧コンテナを保持します。定期点検は任意で、再試行/待機時間を制限し、手動停止を尊重します。状態にはイメージ/バージョン/バインド/起動時刻/CPU/メモリ/ネットワークを表示します。

NAT の公開 IP とローカルバインドを区別し、IPv6 DNS を正規化します。TLS 証明書/ホスト名を検証し、レポート/最近のログで設定済みキーを伏せます。クライアント接続は別途確認してください。UFW は `keep`、BBR は `no` が初期値です。Docker の公開ポートは UFW を迂回する場合があるため、クラウドのファイアウォールや Docker 対応の転送規則を使ってください。失敗時もパッケージ/イメージは残る場合があり、プロキシファイル、追加規則、BBR 設定を復元します。

### 前提条件
- Ubuntu 26.04 LTS
- root 権限
- ドメインAレコードがVPSを向いていること（`DNS only`、CDNプロキシ禁止）

### クイックスタート

VPS の端末にブロック全体をコピーしてください。Git をインストールし、取得または更新後にフルパスで管理メニューを開きます。取得や更新に失敗した場合は停止します。

```bash
(
  set -e
  sudo apt-get update
  sudo apt-get install -y git ca-certificates
  proxy_repo="$HOME/telegram-proxy-installer"
  if [ -d "$proxy_repo/.git" ]; then
    git -C "$proxy_repo" pull --ff-only
  else
    git clone https://github.com/xkeon/telegram-proxy-installer.git "$proxy_repo"
  fi
  sudo bash "$proxy_repo/install.sh" --lang ja
)
```

### IPアドレスでVPSに接続する
1. クラウド事業者の管理画面で VPS のグローバル IPv4 アドレスを確認します。
2. ローカル端末から SSH で接続します。
```bash
ssh root@<your_vps_ip>
```
3. 既定ユーザーが `root` でない場合は実際のユーザー名に置き換えます。例:
```bash
ssh ubuntu@<your_vps_ip>
```
4. 初回接続時に SSH の確認が表示されたら `yes` を入力します。
5. 秘密鍵ファイルの指定が必要な場合:
```bash
ssh -i ~/.ssh/<your_key_file> root@<your_vps_ip>
```

### 基本コマンド
- `sudo bash install.sh`: 対話式メインメニューを開き、導入/管理を行います。
- `healthcheck --mode all`: EE/DD のサービス・コンテナ・ポート状態を確認します。
- `self-heal --mode all`: 異常なサービスを自動で再起動します。
- `self-update`: スクリプトリポジトリを最新版に更新します。
- `uninstall --mode all`: スクリプト管理のサービスと設定を削除します。

```bash
sudo bash install.sh healthcheck --mode all
sudo bash install.sh self-heal --mode all
sudo bash install.sh self-update
sudo bash install.sh uninstall --mode all
```

<details>
<summary>上級コマンド</summary>

更新は選択したイメージをすべて取得してから設定を変更します。再起動や状態確認に失敗した場合、バックアップの復元と以前のサービスの再起動を試みます。復旧に成功しても、失敗した更新は非ゼロの終了状態を返します。ロールバックはサービスを再起動し、状態確認に成功した後にのみ完了を報告します。

```bash
# イメージ digest 更新
sudo bash install.sh upgrade --mode ee --mtg-image auto
sudo bash install.sh upgrade --mode dd --dd-image auto
sudo bash install.sh upgrade --mode ee --mtg-image 'nineseconds/mtg@sha256:<digest>'
sudo bash install.sh upgrade --mode dd --dd-image 'telegrammessenger/proxy@sha256:<digest>'

# 稼働中の旧コンテナを script 管理に移行（設定を自動検出）
sudo bash install.sh migrate --mode all

# ロールバック（既定: 最新バックアップ）
sudo bash install.sh rollback --mode all
sudo bash install.sh rollback --mode ee --backup-id '<backup-id>'

# secret 手動ローテーション
sudo bash install.sh rotate-secret --mode ee --secret '<new_ee_secret_hex>'
sudo bash install.sh rotate-secret --mode dd --secret 'dd<32hex>'  # または 32hex
```

</details>

<details>
<summary>上級：固定 Digest</summary>

スクリプトは digest 形式（`name@sha256:...`）を必須とします。

現在の既定値:
- `MTG_IMAGE="nineseconds/mtg@sha256:c082586a19886e4822f92aa8c1949a771df3519053d64b1b5505a9a280a3929d"`
- `DD_IMAGE="telegrammessenger/proxy@sha256:73210d43c8f8e4c888ba4e30d6daf7742528e9134252a1cd538caabf5e24a597"`

必要に応じて上書き:
```bash
export MTG_IMAGE='nineseconds/mtg@sha256:<64-hex-digest>'
export DD_IMAGE='telegrammessenger/proxy@sha256:<64-hex-digest>'
sudo -E bash install.sh
```

ネットワーク接続環境での digest 取得:
```bash
docker pull nineseconds/mtg:2
docker pull telegrammessenger/proxy:latest
docker image inspect nineseconds/mtg:2 --format '{{index .RepoDigests 0}}'
docker image inspect telegrammessenger/proxy:latest --format '{{index .RepoDigests 0}}'
```

</details>

## Development / 开发与验证

Run these checks from the repository root with Bash, ShellCheck 0.10.0, shfmt 3.8.0, and Python 3:

在仓库根目录运行以下检查，需要 Bash、ShellCheck 0.10.0、shfmt 3.8.0 和 Python 3：

```bash
bash -n install.sh
shellcheck -x -a install.sh
shfmt -d -i 2 -ci -bn install.sh lib/*.sh
python3 -B -m unittest discover -s tests -v
```

Regression tests use temporary configuration files, mock host mutations and exercise real pseudo-terminals. They cover installation/configuration/rotation/migration recovery, backup retention, CLI validation, redacted reports, NAT, bounded watchdog behavior and terminal navigation. Run in the Ubuntu 26.04 development image with root, qrencode and /usr/bin/docker to also execute the real systemd parser, offline QR and private preference checks; these three checks are explicitly skipped on hosts lacking those capabilities. Real proxy deployment still requires a VPS meeting the requirements above.

回归测试使用临时配置、模拟主机变更并通过真实伪终端验证交互，覆盖安装/配置/轮换/迁移失败恢复、备份清理、命令参数、报告隐藏密钥、NAT、自愈限制和终端导航。在带 root、qrencode 与 /usr/bin/docker 的 Ubuntu 26.04 开发镜像中，还会执行真实 systemd 解析、离线二维码和私密偏好文件检查；缺少这些条件的主机会明确跳过这三项。实际代理部署仍需符合上述要求的 VPS。
