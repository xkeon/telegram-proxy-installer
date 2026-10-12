#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Telegram MTProto proxy one-click (interactive, i18n)
# - Ubuntu 26.04 LTS
# - EE (FakeTLS) via mtg
# - DD (padding) via telegrammessenger/proxy
# - User chooses ports, domains, language
# ============================================================

# Pinned image references for reproducible deployment.
# You can override them with environment variables, for example:
#   MTG_IMAGE='nineseconds/mtg@sha256:<digest>' DD_IMAGE='telegrammessenger/proxy@sha256:<digest>' sudo -E bash install.sh
MTG_IMAGE="${MTG_IMAGE:-nineseconds/mtg@sha256:c082586a19886e4822f92aa8c1949a771df3519053d64b1b5505a9a280a3929d}"
DD_IMAGE="${DD_IMAGE:-telegrammessenger/proxy@sha256:73210d43c8f8e4c888ba4e30d6daf7742528e9134252a1cd538caabf5e24a597}"
DEPLOY_EE=0
DEPLOY_DD=0
CONFIG_DIR="/etc/telegram-proxy"
SYSTEMD_UNIT_DIR="/etc/systemd/system"
MTG_CONFIG_DIR="/opt/mtg"
EE_ENV_FILE="${CONFIG_DIR}/ee.env"
DD_ENV_FILE="${CONFIG_DIR}/dd.env"
EE_SERVICE_NAME="telegram-proxy-ee.service"
DD_SERVICE_NAME="telegram-proxy-dd.service"
EE_CONTAINER_NAME="mtg-ee"
DD_CONTAINER_NAME="mtproto-dd"
BACKUP_DIR="/var/backups/telegram-proxy"
LOCK_FILE="/var/lock/telegram-proxy-install.lock"
LAST_BACKUP_PATH=""
TARGET_UBUNTU_VERSION="26.04"
OS_RELEASE_FILE="/etc/os-release"

# ---------- i18n ----------
UI_LANG="en"

select_language() {
  local language_choice=""
  ui_select language_choice ui_language language 1 \
    1:ui_english 2:ui_chinese 3:ui_korean 4:ui_japanese 0:menu_exit || return 1
  case "$language_choice" in
    1) UI_LANG="en" ;;
    2) UI_LANG="zh" ;;
    3) UI_LANG="ko" ;;
    4) UI_LANG="ja" ;;
    0) return 1 ;;
  esac
  save_preferences
}

t() {
  local key="$1"
  if extra_translation "$key"; then return 0; fi
  case "$UI_LANG" in
    en)
      case "$key" in
        title) echo "Telegram proxy installer (EE+DD) — interactive" ;;
        need_dns) echo "Before you start: make sure your domains have A-records pointing to this VPS (DNS only, no CDN proxy)." ;;
        step_update) echo "Step: Updating system & installing basic tools (curl, openssl, ufw, dnsutils...)." ;;
        step_docker) echo "Step: Installing and enabling Docker (to run proxy services in containers)." ;;
        step_bbr_q) echo "Step: Optional network tuning (BBR + fq). This improves TCP throughput/latency on many links." ;;
        step_firewall) echo "Step: Configuring firewall (UFW) safely (allow SSH and chosen ports before enable)." ;;
        step_pull) echo "Step: Pulling Docker images for mtg (EE) and MTProxy (DD)." ;;
        step_front_test) echo "Step: Testing TLS handshake to your chosen fronting domain (FakeTLS needs a real HTTPS site)." ;;
        step_gen_ee) echo "Step: Generating EE (FakeTLS) secret and writing mtg config." ;;
        step_run_ee) echo "Step: Starting mtg (EE) on your chosen port." ;;
        step_gen_dd) echo "Step: Generating DD secret (padding mode)." ;;
        step_run_dd) echo "Step: Starting MTProxy (DD) on your chosen port." ;;
        step_dns_check) echo "Step: Checking entry domains DNS resolution." ;;
        step_summary) echo "Done. Below are the settings and one-click import links." ;;
        ask_mode) echo "Choose deployment mode:" ;;
        mode_ee_only) echo "EE only (FakeTLS via mtg)" ;;
        mode_dd_only) echo "DD only (padding via MTProxy)" ;;
        mode_both) echo "EE + DD (recommended dual-line)" ;;
        ask_ee_domain) echo "Enter entry domain for EE (example: ee.example.com): " ;;
        ask_dd_domain) echo "Enter entry domain for DD (example: dd.example.com): " ;;
        ask_front_domain) echo "Enter fronting domain for EE (default: www.cloudflare.com): " ;;
        ask_fronting_mode) echo "Choose fronting domain input mode:" ;;
        ask_ee_port) echo "Choose port for EE (recommended: 443). Enter a number: " ;;
        ask_dd_port) echo "Choose port for DD (recommended: 8443). Enter a number: " ;;
        ask_port_menu) echo "Choose a port option:" ;;
        opt_manual_input) echo "Manual input" ;;
        opt_recommended) echo "recommended" ;;
        ask_enable_bbr) echo "Enable BBR+fq (recommended) [Y/n]: " ;;
        ask_strict_ufw) echo "Enable strict UFW rules bound to selected IP(s) [y/N]: " ;;
        ask_continue_anyway) echo "Continue anyway? [y/N]: " ;;
        err_port_num) echo "Port must be a number between 1 and 65535." ;;
        err_port_conflict) echo "EE port and DD port cannot be the same on a single IP. Choose different ports." ;;
        err_port_in_use) echo "Port is already in use on this server. Choose another one." ;;
        warn_443_busy) echo "Selected port is already in use." ;;
        note_port_holders) echo "Current listeners on this port:" ;;
        ask_cleanup_proxy_443) echo "Try to stop old proxy containers and re-check this port? [y/N]: " ;;
        note_cleanup_done) echo "Cleanup attempted. Re-checking the selected port..." ;;
        warn_cleanup_unavailable) echo "Docker not found, cannot auto-clean old proxy containers." ;;
        warn_443_still_busy) echo "Selected port is still occupied after cleanup attempt." ;;
        err_empty) echo "This value cannot be empty." ;;
        err_choice_invalid) echo "Invalid choice. Please enter one of the listed numbers." ;;
        err_mode_invalid) echo "Invalid mode. Choose 1, 2, or 3." ;;
        err_domain_invalid) echo "Invalid domain format. Example: sub.example.com" ;;
        warn_dns_unresolved) echo "Warning: domain has no A record yet." ;;
        warn_dns_mismatch) echo "Warning: domain A records do not include this server IPv4." ;;
        warn_bbr_unsupported) echo "Warning: kernel does not advertise BBR support. Skipping BBR tuning." ;;
        warn_bbr_apply_fail) echo "Warning: failed to apply sysctl settings. Continuing without BBR changes." ;;
        tls_ok) echo "TLS handshake OK." ;;
        tls_fail) echo "TLS handshake FAILED or timed out. FakeTLS may be unstable with this fronting domain." ;;
        tls_abort) echo "Aborted because TLS check failed and user did not confirm continuation." ;;
        warn_front_fallback) echo "No fronting candidate passed TLS check. Falling back to the first candidate:" ;;
        note_secret) echo "Do NOT share secrets publicly. Anyone with the secret can use your proxy." ;;
        note_no_cdn) echo "Important: DNS should be 'DNS only' (no CDN proxy). MTProto is not standard HTTPS." ;;
        err_image_ref_invalid) echo "Image reference must be digest format: name@sha256:64hex. Please set MTG_IMAGE/DD_IMAGE." ;;
        menu_title) echo "Main Menu" ;;
        ui_language) echo "Language / 语言 / 언어 / 言語" ;;
        ui_english) echo "English" ;;
        ui_chinese) echo "中文" ;;
        ui_korean) echo "한국어" ;;
        ui_japanese) echo "日本語" ;;
        ui_group_services) echo "SERVICES & DIAGNOSTICS" ;;
        ui_group_changes) echo "UPDATES & RECOVERY" ;;
        ui_group_more) echo "MORE" ;;
        ui_running) echo "Running" ;;
        ui_stopped) echo "Not running" ;;
        ui_unmanaged) echo "Not managed" ;;
        ui_unknown) echo "Status unavailable" ;;
        ui_back) echo "Back" ;;
        ui_prompt) echo "Choose a number" ;;
        ui_keys) echo "Up/Down | Enter | number + Enter" ;;
        ui_shortcuts) echo "r refresh | q/Esc back/exit" ;;
        ui_service_note) echo "Service state; use healthcheck for full diagnosis" ;;
        menu_install) echo "Install proxy" ;;
        menu_healthcheck) echo "Healthcheck" ;;
        menu_self_heal) echo "Repair services" ;;
        menu_upgrade) echo "Upgrade proxy images" ;;
        menu_self_update) echo "Update installer" ;;
        menu_rotate_secret) echo "Rotate secret" ;;
        menu_region_diag) echo "Network / region diagnosis" ;;
        menu_uninstall) echo "Uninstall proxy" ;;
        menu_help) echo "Help" ;;
        menu_exit) echo "Exit" ;;
        menu_press_enter) echo "Press Enter to return to menu..." ;;
        ask_oper_mode) echo "Select mode:" ;;
        ask_rotate_mode) echo "Select rotate mode:" ;;
        ask_new_mtg_image) echo "Enter new MTG image digest (blank=keep current, auto=latest digest): " ;;
        ask_new_dd_image) echo "Enter new DD image digest (blank=keep current, auto=latest digest): " ;;
        note_upgrade_scope) echo "This upgrades image digests and restarts services only; domains, ports, and secrets stay unchanged." ;;
        ask_new_secret_ee) echo "Enter new EE secret (blank=auto-generate): " ;;
        ask_new_secret_dd) echo "Enter new DD secret (blank=auto-generate): " ;;
        ask_front_for_auto_secret) echo "Enter front-domain for EE auto secret (blank=keep current): " ;;
        ask_bind_ip_mode) echo "Choose bind IP:" ;;
        opt_all_interfaces) echo "all interfaces, recommended" ;;
        opt_primary_ipv4) echo "primary IPv4" ;;
        opt_primary_ipv6) echo "primary IPv6" ;;
        opt_disabled) echo "disabled" ;;
        opt_unavailable) echo "unavailable" ;;
        ask_bind_ipv4) echo "Enter bind IPv4 (or 0.0.0.0): " ;;
        ask_bind_ipv6_mode) echo "Choose bind IPv6:" ;;
        ask_bind_ipv6) echo "Enter bind IPv6 (or ::): " ;;
        err_primary_ipv4_unavailable) echo "Primary IPv4 unavailable." ;;
        err_primary_ipv6_unavailable) echo "Primary IPv6 unavailable." ;;
        err_ipv4_invalid) echo "Invalid IPv4 format." ;;
        err_ipv6_invalid) echo "Invalid IPv6 format." ;;
        err_bind_ip_not_found) echo "IP not found on this host." ;;
        step_self_update) echo "Step: Updating script repository (git pull --ff-only)." ;;
        err_self_update_not_git) echo "Self-update requires a git clone directory containing .git." ;;
        note_self_update_done) echo "Self-update completed." ;;
        note_self_update_rerun) echo "Run the installer again to apply new logic:" ;;
        menu_migrate) echo "Migrate legacy proxy" ;;
        menu_rollback) echo "Restore backup" ;;
        step_migrate) echo "Step: Migrating legacy running containers into script-managed systemd services." ;;
        step_backup) echo "Step: Creating backup before change." ;;
        step_rollback) echo "Step: Rolling back from backup." ;;
        step_region_diag) echo "Step: Running heuristic regional blocking diagnosis." ;;
        ask_backup_id) echo "Enter backup ID (blank = latest): " ;;
        note_backup_saved) echo "Backup saved:" ;;
        note_backup_latest) echo "Using latest backup:" ;;
        note_backup_none) echo "No backups found." ;;
        note_rollback_done) echo "Rollback completed." ;;
        err_backup_not_found) echo "Backup ID not found." ;;
        err_lock_busy) echo "Another install.sh process is running. Try again later." ;;
        err_lock_unavailable) echo "flock is unavailable; cannot enforce single-run lock." ;;
        err_migrate_no_legacy) echo "No legacy proxy containers found to migrate." ;;
        err_legacy_container_missing) echo "Required legacy container is missing." ;;
        note_migrate_done) echo "Migration completed and services are now managed by systemd." ;;
        ask_existing_ee_secret) echo "Enter existing EE secret (ee...hex): " ;;
        err_ee_secret_required) echo "EE secret is required for migration." ;;
        warn_image_not_digest) echo "Current image is not digest-pinned. Falling back to default pinned digest." ;;
        note_using_digest) echo "Using digest image:" ;;
        note_recent_logs) echo "Recent container logs:" ;;
        warn_service_restarts) echo "Service restart count is high:" ;;
        warn_container_restarts) echo "Container restart count is high:" ;;
        err_port_binding_mismatch) echo "Container port binding does not match configured bind IP/port." ;;
        err_unknown_arg) echo "Unknown argument:" ;;
        err_unknown_cmd) echo "Unknown command:" ;;
        err_rotate_mode_required) echo "rotate-secret requires --mode ee|dd" ;;
        err_mode_value_invalid) echo "Invalid mode value:" ;;
        err_not_installed_ee) echo "EE is not installed." ;;
        err_not_installed_dd) echo "DD is not installed." ;;
        err_invalid_mtg_image) echo "Invalid MTG image digest:" ;;
        err_invalid_dd_image) echo "Invalid DD image digest:" ;;
        err_upgrade_failed) echo "Upgrade failed; restoring the previous configuration." ;;
        err_upgrade_rollback_failed) echo "Automatic recovery failed. Restore this backup manually:" ;;
        err_invalid_ee_secret) echo "Invalid EE secret format (expected ee... hex)." ;;
        err_invalid_dd_secret) echo "Invalid DD secret format." ;;
        err_migrate_port_missing) echo "Cannot detect host port binding from legacy container." ;;
        note_legacy_detected) echo "legacy deployment detected: container is running, but env is missing" ;;
        note_legacy_migrate) echo "run migrate/install to bring this instance under script management" ;;
        ask_new_ee_secret_cli) echo "Enter new EE secret (hex). Leave empty to auto-generate: " ;;
        ask_new_dd_secret_cli) echo "Enter new DD secret (32-hex or dd+32-hex, blank=auto-generate): " ;;
        note_attempt_restart_ee) echo "[ee] attempting restart..." ;;
        note_attempt_restart_dd) echo "[dd] attempting restart..." ;;
        hc_not_installed) echo "not installed (env missing)" ;;
        hc_service_not_active) echo "service not active" ;;
        hc_container_not_running) echo "container not running" ;;
        hc_port_not_listening) echo "port not listening" ;;
        hc_image_mismatch) echo "image mismatch" ;;
        hc_healthy) echo "healthy" ;;
        critical_need_systemctl) echo "Critical: systemctl is required." ;;
        critical_need_apt) echo "Critical: apt-get is required." ;;
        preflight_warnings) echo "Preflight warnings:" ;;
        aborted_by_user) echo "Aborted by user." ;;
        note_a_records) echo "A records" ;;
        note_aaaa_records) echo "AAAA records" ;;
        note_server_ip) echo "Server IP" ;;
        note_server_ipv6) echo "Server IPv6" ;;
        label_running) echo "running" ;;
        label_configured) echo "configured" ;;
        label_expected) echo "expected" ;;
        label_actual) echo "actual" ;;
        label_log) echo "log" ;;
        label_secret) echo "Secret" ;;
        label_import_link) echo "Import link" ;;
        note_rotate_done) echo "Secret rotation applied and service restarted." ;;
        summary_images) echo "Images" ;;
        summary_mtg) echo "MTG" ;;
        summary_dd) echo "DD" ;;
        summary_ee_link) echo "EE (FakeTLS)" ;;
        summary_dd_link) echo "DD (padding)" ;;
        usage_title) echo "Usage:" ;;
        usage_notes) echo "Notes:" ;;
        usage_no_args) echo "No arguments: open interactive menu." ;;
        usage_self_update) echo "self-update pulls latest script repository (fast-forward only)." ;;
        usage_migrate) echo "migrate imports legacy running containers into env+systemd management." ;;
        usage_rollback) echo "rollback restores config and units from latest/specified backup." ;;
        usage_install) echo "install command starts interactive install flow." ;;
        usage_rotate_dd) echo "rotate-secret for DD accepts 32-hex or dd+32-hex." ;;
        usage_region_diag) echo "regional-diagnose runs a local heuristic check; exact country confirmation still needs external probes." ;;
        warn_ee_domain_fallback) echo "EE domain not detected. Using server IP:" ;;
        warn_dd_domain_fallback) echo "DD domain not detected. Using server IP:" ;;
        warn_front_domain_fallback) echo "Fronting domain not detected. Using default:" ;;
        err_ee_secret_autodetect_fail) echo "Cannot auto-detect EE secret from legacy config/container." ;;
        warn_dns_aaaa_unresolved) echo "Warning: domain has no AAAA record yet." ;;
        warn_dns_aaaa_mismatch) echo "Warning: domain AAAA records do not include this server IPv6." ;;
        diag_scope_note) echo "This is a local heuristic only. It can suggest likely DNS/fronting/IP-port issues, but it cannot prove which countries are blocking you." ;;
        diag_no_managed_service) echo "No script-managed EE/DD service is installed yet." ;;
        diag_server_ip) echo "Detected server IPv4" ;;
        diag_entry_domain) echo "Entry domain" ;;
        diag_front_domain) echo "Fronting domain" ;;
        diag_bind) echo "Bind target" ;;
        diag_public_dns) echo "Public DNS resolver view" ;;
        diag_literal_ipv4) echo "Entry target is a literal IPv4. Skipping A-record checks." ;;
        diag_resolver_match) echo "includes server IPv4:" ;;
        diag_resolver_missing) echo "has no A record." ;;
        diag_resolver_mismatch) echo "does not include server IPv4:" ;;
        diag_front_tls_ok) echo "Fronting TLS handshake succeeded from this VPS." ;;
        diag_front_tls_fail) echo "Fronting TLS handshake failed from this VPS." ;;
        diag_local_issue_first) echo "Local service/config issues were detected first. Fix those before drawing regional blocking conclusions." ;;
        diag_likely_dns_issue) echo "DNS/domain inconsistency was detected. This looks more like a domain/propagation issue than a country-specific block." ;;
        diag_likely_ee_front_issue) echo "EE fronting checks failed locally. EE front-domain or EE secret/front pairing is more suspicious than regional blocking." ;;
        diag_likely_region_block) echo "No obvious local service or DNS issue was found. If failures happen only in some countries, IP/port/protocol blocking is more likely." ;;
        diag_country_probe_needed) echo "Exact country or ISP confirmation still requires external probes or user-side tests from those networks." ;;
        diag_tool_missing) echo "Required tool is missing" ;;
      esac
      ;;
    zh)
      case "$key" in
        title) echo "Telegram 代理一键部署（EE+DD）— 交互式" ;;
        need_dns) echo "开始前提示：请确保域名 A 记录已指向本 VPS（DNS only/灰云，不要走 CDN 代理）。" ;;
        step_update) echo "步骤：更新系统并安装基础工具（curl、openssl、ufw、dnsutils 等）。" ;;
        step_docker) echo "步骤：安装并启用 Docker（用容器方式运行代理服务，隔离且易维护）。" ;;
        step_bbr_q) echo "步骤：可选网络优化（BBR + fq）。常见情况下可提升 TCP 吞吐与稳定性。" ;;
        step_firewall) echo "步骤：安全配置防火墙（UFW）：先放行 SSH 和代理端口，再启用。" ;;
        step_pull) echo "步骤：拉取 Docker 镜像（mtg 用于 EE，MTProxy 用于 DD）。" ;;
        step_front_test) echo "步骤：测试 fronting 域名的 TLS 握手（FakeTLS 需要一个真正可用的 HTTPS 站点）。" ;;
        step_gen_ee) echo "步骤：生成 EE（FakeTLS）密钥并写入 mtg 配置。" ;;
        step_run_ee) echo "步骤：启动 mtg（EE）并监听你选择的端口。" ;;
        step_gen_dd) echo "步骤：生成 DD（padding）密钥（用于兜底线路）。" ;;
        step_run_dd) echo "步骤：启动 MTProxy（DD）并监听你选择的端口。" ;;
        step_dns_check) echo "步骤：检查入口域名 DNS 解析情况。" ;;
        step_summary) echo "完成。下面输出配置与一键导入链接。" ;;
        ask_mode) echo "请选择部署模式：" ;;
        mode_ee_only) echo "仅 EE（FakeTLS / mtg）" ;;
        mode_dd_only) echo "仅 DD（padding / MTProxy）" ;;
        mode_both) echo "EE + DD（双线路，推荐）" ;;
        ask_ee_domain) echo "请输入 EE 入口域名（例如：ee.example.com）： " ;;
        ask_dd_domain) echo "请输入 DD 入口域名（例如：dd.example.com）： " ;;
        ask_front_domain) echo "请输入 EE 的 fronting 域名（默认：www.cloudflare.com）： " ;;
        ask_fronting_mode) echo "请选择 fronting 域名输入方式：" ;;
        ask_ee_port) echo "请选择 EE 端口（推荐 443）。请输入端口号： " ;;
        ask_dd_port) echo "请选择 DD 端口（推荐 8443）。请输入端口号： " ;;
        ask_port_menu) echo "请选择端口选项：" ;;
        opt_manual_input) echo "手动输入" ;;
        opt_recommended) echo "推荐" ;;
        ask_enable_bbr) echo "是否启用 BBR+fq（推荐）[Y/n]： " ;;
        ask_strict_ufw) echo "是否启用严格 UFW 规则（按所选 IP 放行）[y/N]： " ;;
        ask_continue_anyway) echo "是否仍继续？[y/N]： " ;;
        err_port_num) echo "端口必须是 1~65535 的数字。" ;;
        err_port_conflict) echo "同一台机器的同一个 IP 上，EE 和 DD 不能使用同一个端口。请选不同端口。" ;;
        err_port_in_use) echo "该端口在本机已被占用。请换一个端口。" ;;
        warn_443_busy) echo "所选端口已被占用。" ;;
        note_port_holders) echo "当前占用该端口的监听项：" ;;
        ask_cleanup_proxy_443) echo "是否尝试停止旧代理容器并重新检测该端口？[y/N]： " ;;
        note_cleanup_done) echo "已尝试清理，正在重新检测所选端口..." ;;
        warn_cleanup_unavailable) echo "未检测到 Docker，无法自动清理旧代理容器。" ;;
        warn_443_still_busy) echo "清理后该端口仍被占用。" ;;
        err_empty) echo "该项不能为空。" ;;
        err_choice_invalid) echo "选项无效，请输入列表中的数字。" ;;
        err_mode_invalid) echo "模式输入无效，请输入 1、2 或 3。" ;;
        err_domain_invalid) echo "域名格式不合法，例如：sub.example.com" ;;
        warn_dns_unresolved) echo "警告：该域名当前没有 A 记录。" ;;
        warn_dns_mismatch) echo "警告：该域名的 A 记录未包含本机 IPv4。" ;;
        warn_bbr_unsupported) echo "警告：当前内核未显示支持 BBR，跳过 BBR 配置。" ;;
        warn_bbr_apply_fail) echo "警告：sysctl 配置应用失败，将继续但不保证 BBR 生效。" ;;
        tls_ok) echo "TLS 握手正常。" ;;
        tls_fail) echo "TLS 握手失败或超时。FakeTLS 可能不稳定，建议更换 fronting 域名。" ;;
        tls_abort) echo "由于 TLS 检测失败且未确认继续，脚本已中止。" ;;
        warn_front_fallback) echo "所有候选 fronting 域名 TLS 检测都失败，将回退到第一个候选：" ;;
        note_secret) echo "不要公开分享 secret。任何拿到 secret 的人都能使用你的代理。" ;;
        note_no_cdn) echo "重要：DNS 必须是 DNS only/灰云（不要 CDN 代理）。MTProto 不是标准 HTTPS。" ;;
        err_image_ref_invalid) echo "镜像引用必须是 digest 格式：name@sha256:64位十六进制。请设置 MTG_IMAGE/DD_IMAGE。" ;;
        menu_title) echo "主菜单" ;;
        ui_language) echo "Language / 语言 / 언어 / 言語" ;;
        ui_english) echo "English" ;;
        ui_chinese) echo "中文" ;;
        ui_korean) echo "한국어" ;;
        ui_japanese) echo "日本語" ;;
        ui_group_services) echo "服务与诊断" ;;
        ui_group_changes) echo "更新与恢复" ;;
        ui_group_more) echo "其他操作" ;;
        ui_running) echo "运行中" ;;
        ui_stopped) echo "未运行" ;;
        ui_unmanaged) echo "未托管" ;;
        ui_unknown) echo "状态不可用" ;;
        ui_back) echo "返回" ;;
        ui_prompt) echo "输入编号" ;;
        ui_keys) echo "↑/↓ 选择 · 回车确认 · 编号+回车" ;;
        ui_shortcuts) echo "r 刷新 · q / Esc 返回或退出" ;;
        ui_service_note) echo "此处显示服务状态；完整诊断请用健康检查" ;;
        menu_install) echo "安装" ;;
        menu_healthcheck) echo "健康检查" ;;
        menu_self_heal) echo "自愈" ;;
        menu_upgrade) echo "升级镜像（EE/DD）" ;;
        menu_self_update) echo "脚本自更新" ;;
        menu_rotate_secret) echo "轮换密钥" ;;
        menu_region_diag) echo "网络与地区诊断" ;;
        menu_uninstall) echo "卸载" ;;
        menu_help) echo "帮助" ;;
        menu_exit) echo "退出" ;;
        menu_press_enter) echo "按回车返回菜单..." ;;
        ask_oper_mode) echo "请选择模式：" ;;
        ask_rotate_mode) echo "请选择轮换模式：" ;;
        ask_new_mtg_image) echo "请输入新的 MTG 镜像 digest（留空=保持当前，auto=自动检测最新 digest）： " ;;
        ask_new_dd_image) echo "请输入新的 DD 镜像 digest（留空=保持当前，auto=自动检测最新 digest）： " ;;
        note_upgrade_scope) echo "此操作仅升级镜像 digest 并重启服务，不会修改域名、端口、密钥。" ;;
        ask_new_secret_ee) echo "请输入新的 EE secret（留空=自动生成）： " ;;
        ask_new_secret_dd) echo "请输入新的 DD secret（留空=自动生成）： " ;;
        ask_front_for_auto_secret) echo "请输入 EE 自动生成 secret 的 front-domain（留空=保持当前）： " ;;
        ask_bind_ip_mode) echo "请选择绑定 IP：" ;;
        opt_all_interfaces) echo "全部网卡，推荐" ;;
        opt_primary_ipv4) echo "主 IPv4" ;;
        opt_primary_ipv6) echo "主 IPv6" ;;
        opt_disabled) echo "禁用" ;;
        opt_unavailable) echo "不可用" ;;
        ask_bind_ipv4) echo "请输入绑定 IPv4（或 0.0.0.0）： " ;;
        ask_bind_ipv6_mode) echo "请选择绑定 IPv6：" ;;
        ask_bind_ipv6) echo "请输入绑定 IPv6（或 ::）： " ;;
        err_primary_ipv4_unavailable) echo "主 IPv4 不可用。" ;;
        err_primary_ipv6_unavailable) echo "主 IPv6 不可用。" ;;
        err_ipv4_invalid) echo "IPv4 格式无效。" ;;
        err_ipv6_invalid) echo "IPv6 格式无效。" ;;
        err_bind_ip_not_found) echo "该 IP 不在本机网卡上。" ;;
        step_self_update) echo "步骤：更新脚本仓库（git pull --ff-only）。" ;;
        err_self_update_not_git) echo "脚本自更新需要在包含 .git 的仓库目录中执行。" ;;
        note_self_update_done) echo "脚本自更新完成。" ;;
        note_self_update_rerun) echo "请重新执行安装脚本以应用新逻辑：" ;;
        menu_migrate) echo "迁移旧部署" ;;
        menu_rollback) echo "回滚" ;;
        step_migrate) echo "步骤：将正在运行的旧容器迁移为脚本托管的 systemd 服务。" ;;
        step_backup) echo "步骤：变更前创建备份。" ;;
        step_rollback) echo "步骤：从备份执行回滚。" ;;
        step_region_diag) echo "步骤：执行地区封锁启发式诊断。" ;;
        ask_backup_id) echo "请输入备份 ID（留空=最新）： " ;;
        note_backup_saved) echo "备份已保存：" ;;
        note_backup_latest) echo "使用最新备份：" ;;
        note_backup_none) echo "未找到备份。" ;;
        note_rollback_done) echo "回滚完成。" ;;
        err_backup_not_found) echo "未找到该备份 ID。" ;;
        err_lock_busy) echo "已有另一个 install.sh 正在运行，请稍后重试。" ;;
        err_lock_unavailable) echo "系统缺少 flock，无法启用单实例运行锁。" ;;
        err_migrate_no_legacy) echo "未发现可迁移的旧代理容器。" ;;
        err_legacy_container_missing) echo "缺少需要迁移的旧容器。" ;;
        note_migrate_done) echo "迁移完成，服务已纳入 systemd 托管。" ;;
        ask_existing_ee_secret) echo "请输入现有 EE secret（ee...hex）： " ;;
        err_ee_secret_required) echo "迁移需要 EE secret，不能为空。" ;;
        warn_image_not_digest) echo "当前镜像不是 digest 固定形式，将回退到脚本默认 digest。" ;;
        note_using_digest) echo "使用镜像 digest：" ;;
        note_recent_logs) echo "最近容器日志：" ;;
        warn_service_restarts) echo "服务重启次数偏高：" ;;
        warn_container_restarts) echo "容器重启次数偏高：" ;;
        err_port_binding_mismatch) echo "容器端口绑定与配置的绑定 IP/端口不一致。" ;;
        err_unknown_arg) echo "未知参数：" ;;
        err_unknown_cmd) echo "未知命令：" ;;
        err_rotate_mode_required) echo "rotate-secret 必须指定 --mode ee|dd" ;;
        err_mode_value_invalid) echo "模式值无效：" ;;
        err_not_installed_ee) echo "EE 尚未安装。" ;;
        err_not_installed_dd) echo "DD 尚未安装。" ;;
        err_invalid_mtg_image) echo "MTG 镜像 digest 无效：" ;;
        err_invalid_dd_image) echo "DD 镜像 digest 无效：" ;;
        err_upgrade_failed) echo "升级失败，正在恢复之前的配置。" ;;
        err_upgrade_rollback_failed) echo "自动恢复失败，请手动恢复此备份：" ;;
        err_invalid_ee_secret) echo "EE secret 格式无效（应为 ee... 十六进制）。" ;;
        err_invalid_dd_secret) echo "DD secret 格式无效。" ;;
        err_migrate_port_missing) echo "无法从旧容器识别主机端口绑定。" ;;
        note_legacy_detected) echo "发现旧部署：容器在运行，但 env 文件缺失" ;;
        note_legacy_migrate) echo "请运行 migrate/install 将该实例纳入脚本托管" ;;
        ask_new_ee_secret_cli) echo "请输入新的 EE secret（hex，留空=自动生成）： " ;;
        ask_new_dd_secret_cli) echo "请输入新的 DD secret（32hex 或 dd+32hex，留空=自动生成）： " ;;
        note_attempt_restart_ee) echo "[ee] 正在尝试重启..." ;;
        note_attempt_restart_dd) echo "[dd] 正在尝试重启..." ;;
        hc_not_installed) echo "未安装（缺少 env 文件）" ;;
        hc_service_not_active) echo "服务未运行" ;;
        hc_container_not_running) echo "容器未运行" ;;
        hc_port_not_listening) echo "端口未监听" ;;
        hc_image_mismatch) echo "镜像不匹配" ;;
        hc_healthy) echo "健康" ;;
        critical_need_systemctl) echo "关键错误：需要 systemctl。" ;;
        critical_need_apt) echo "关键错误：需要 apt-get。" ;;
        preflight_warnings) echo "前置检查警告：" ;;
        aborted_by_user) echo "用户已中止。" ;;
        note_a_records) echo "A 记录" ;;
        note_aaaa_records) echo "AAAA 记录" ;;
        note_server_ip) echo "本机 IP" ;;
        note_server_ipv6) echo "本机 IPv6" ;;
        label_running) echo "运行中" ;;
        label_configured) echo "配置值" ;;
        label_expected) echo "期望" ;;
        label_actual) echo "实际" ;;
        label_log) echo "日志" ;;
        label_secret) echo "密钥" ;;
        label_import_link) echo "导入链接" ;;
        note_rotate_done) echo "密钥轮换已生效，服务已重启。" ;;
        summary_images) echo "镜像" ;;
        summary_mtg) echo "MTG" ;;
        summary_dd) echo "DD" ;;
        summary_ee_link) echo "EE (FakeTLS)" ;;
        summary_dd_link) echo "DD (padding)" ;;
        usage_title) echo "用法：" ;;
        usage_notes) echo "说明：" ;;
        usage_no_args) echo "不带参数：进入交互式主菜单。" ;;
        usage_self_update) echo "self-update：快速前进方式更新脚本仓库。" ;;
        usage_migrate) echo "migrate：将旧版运行容器纳入 env+systemd 托管。" ;;
        usage_rollback) echo "rollback：从最新或指定备份恢复配置与 unit。" ;;
        usage_install) echo "install 命令：直接进入交互式安装流程。" ;;
        usage_rotate_dd) echo "DD 的 rotate-secret 支持 32hex 或 dd+32hex。" ;;
        usage_region_diag) echo "regional-diagnose：执行本地启发式诊断；若要精确确认国家/运营商，仍需外部探针。" ;;
        warn_ee_domain_fallback) echo "未检测到 EE 域名，改用服务器 IP：" ;;
        warn_dd_domain_fallback) echo "未检测到 DD 域名，改用服务器 IP：" ;;
        warn_front_domain_fallback) echo "未检测到 fronting 域名，改用默认值：" ;;
        err_ee_secret_autodetect_fail) echo "无法从旧配置/容器自动识别 EE secret。" ;;
        warn_dns_aaaa_unresolved) echo "警告：该域名当前没有 AAAA 记录。" ;;
        warn_dns_aaaa_mismatch) echo "警告：该域名的 AAAA 记录未包含本机 IPv6。" ;;
        diag_scope_note) echo "这只是本地启发式诊断。它可以提示更像是 DNS/fronting/IP/端口问题，但不能证明到底是哪些国家在屏蔽你。" ;;
        diag_no_managed_service) echo "当前还没有脚本托管的 EE/DD 服务。" ;;
        diag_server_ip) echo "检测到的服务器 IPv4" ;;
        diag_entry_domain) echo "入口域名" ;;
        diag_front_domain) echo "Fronting 域名" ;;
        diag_bind) echo "绑定目标" ;;
        diag_public_dns) echo "公共 DNS 解析视角" ;;
        diag_literal_ipv4) echo "入口目标是裸 IPv4，跳过 A 记录检查。" ;;
        diag_resolver_match) echo "包含本机 IPv4：" ;;
        diag_resolver_missing) echo "没有 A 记录。" ;;
        diag_resolver_mismatch) echo "未包含本机 IPv4：" ;;
        diag_front_tls_ok) echo "从本 VPS 到 fronting 域名的 TLS 握手正常。" ;;
        diag_front_tls_fail) echo "从本 VPS 到 fronting 域名的 TLS 握手失败。" ;;
        diag_local_issue_first) echo "首先检测到了本地服务/配置问题。应先修复这些问题，再讨论地区性屏蔽。" ;;
        diag_likely_dns_issue) echo "检测到了 DNS/域名不一致，更像是域名解析或传播问题，而不是国家级屏蔽。" ;;
        diag_likely_ee_front_issue) echo "EE 的 fronting 检查在本地失败。相比地区性屏蔽，更应优先怀疑 front-domain 或 EE secret/front 配对。" ;;
        diag_likely_region_block) echo "未发现明显的本地服务或 DNS 问题。如果只有部分国家失败，更像是 IP/端口/协议层面的地区性拦截。" ;;
        diag_country_probe_needed) echo "若要精确确认到国家或运营商，仍然需要外部探针或当地用户侧测试。" ;;
        diag_tool_missing) echo "缺少所需工具" ;;
      esac
      ;;
    ko)
      case "$key" in
        title) echo "Telegram 프록시 설치(EE+DD) — 대화형" ;;
        need_dns) echo "시작 전: 도메인 A 레코드가 이 VPS를 가리키는지 확인하세요(DNS only, CDN 프록시 사용 금지)." ;;
        step_update) echo "단계: 시스템 업데이트 및 기본 도구 설치(curl, openssl, ufw, dnsutils...)." ;;
        step_docker) echo "단계: Docker 설치 및 활성화(컨테이너로 프록시 실행)." ;;
        step_bbr_q) echo "단계: (선택) 네트워크 튜닝(BBR + fq)." ;;
        step_firewall) echo "단계: 안전한 방화벽(UFW) 설정(먼저 SSH/프록시 포트 허용 후 활성화)." ;;
        step_pull) echo "단계: Docker 이미지 다운로드(mtg=EE, MTProxy=DD)." ;;
        step_front_test) echo "단계: 프론팅 도메인의 TLS 핸드셰이크 테스트." ;;
        step_gen_ee) echo "단계: EE(FakeTLS) 시크릿 생성 및 mtg 설정 작성." ;;
        step_run_ee) echo "단계: mtg(EE) 실행." ;;
        step_gen_dd) echo "단계: DD(padding) 시크릿 생성." ;;
        step_run_dd) echo "단계: MTProxy(DD) 실행." ;;
        step_dns_check) echo "단계: 접속 도메인 DNS 확인." ;;
        step_summary) echo "완료. 아래에 설정과 가져오기 링크를 출력합니다." ;;
        ask_mode) echo "배포 모드를 선택하세요:" ;;
        mode_ee_only) echo "EE만 (FakeTLS / mtg)" ;;
        mode_dd_only) echo "DD만 (padding / MTProxy)" ;;
        mode_both) echo "EE + DD (이중 라인, 권장)" ;;
        ask_ee_domain) echo "EE 접속 도메인 입력(예: ee.example.com): " ;;
        ask_dd_domain) echo "DD 접속 도메인 입력(예: dd.example.com): " ;;
        ask_front_domain) echo "EE 프론팅 도메인 입력(기본: www.cloudflare.com): " ;;
        ask_fronting_mode) echo "프론팅 도메인 입력 방식을 선택하세요:" ;;
        ask_ee_port) echo "EE 포트 선택(권장: 443). 포트 번호 입력: " ;;
        ask_dd_port) echo "DD 포트 선택(권장: 8443). 포트 번호 입력: " ;;
        ask_port_menu) echo "포트 옵션을 선택하세요:" ;;
        opt_manual_input) echo "수동 입력" ;;
        opt_recommended) echo "권장" ;;
        ask_enable_bbr) echo "BBR+fq 활성화(권장) [Y/n]: " ;;
        ask_strict_ufw) echo "선택한 IP에만 적용되는 엄격한 UFW 규칙을 사용할까요? [y/N]: " ;;
        ask_continue_anyway) echo "계속 진행할까요? [y/N]: " ;;
        err_port_num) echo "포트는 1~65535 사이의 숫자여야 합니다." ;;
        err_port_conflict) echo "같은 IP에서 EE와 DD는 동일 포트를 사용할 수 없습니다." ;;
        err_port_in_use) echo "해당 포트가 이미 사용 중입니다." ;;
        warn_443_busy) echo "선택한 포트가 이미 사용 중입니다." ;;
        note_port_holders) echo "현재 이 포트를 점유 중인 리스너:" ;;
        ask_cleanup_proxy_443) echo "기존 프록시 컨테이너를 중지하고 이 포트를 다시 확인할까요? [y/N]: " ;;
        note_cleanup_done) echo "정리 시도 완료. 선택한 포트를 다시 확인합니다..." ;;
        warn_cleanup_unavailable) echo "Docker가 없어 기존 프록시 컨테이너 자동 정리를 할 수 없습니다." ;;
        warn_443_still_busy) echo "정리 후에도 선택한 포트가 여전히 점유 중입니다." ;;
        err_empty) echo "빈 값은 허용되지 않습니다." ;;
        err_choice_invalid) echo "선택이 잘못되었습니다. 목록의 번호를 입력하세요." ;;
        err_mode_invalid) echo "모드 입력이 잘못되었습니다. 1, 2, 3 중에서 선택하세요." ;;
        err_domain_invalid) echo "도메인 형식이 올바르지 않습니다. 예: sub.example.com" ;;
        warn_dns_unresolved) echo "경고: 도메인에 A 레코드가 없습니다." ;;
        warn_dns_mismatch) echo "경고: 도메인 A 레코드에 서버 IPv4가 없습니다." ;;
        warn_bbr_unsupported) echo "경고: 커널에서 BBR 지원이 확인되지 않아 건너뜁니다." ;;
        warn_bbr_apply_fail) echo "경고: sysctl 적용 실패. BBR 없이 계속 진행합니다." ;;
        tls_ok) echo "TLS 핸드셰이크 OK." ;;
        tls_fail) echo "TLS 핸드셰이크 실패/타임아웃." ;;
        tls_abort) echo "TLS 검사 실패 후 계속 확인이 없어 중단합니다." ;;
        warn_front_fallback) echo "모든 프론팅 후보의 TLS 검사에 실패했습니다. 첫 번째 후보로 진행합니다:" ;;
        note_secret) echo "시크릿을 공개 공유하지 마세요." ;;
        note_no_cdn) echo "중요: DNS only(프록시/CDN 금지)." ;;
        err_image_ref_invalid) echo "이미지 참조는 digest 형식(name@sha256:64hex)이어야 합니다. MTG_IMAGE/DD_IMAGE를 설정하세요." ;;
        menu_title) echo "메인 메뉴" ;;
        ui_language) echo "Language / 语言 / 언어 / 言語" ;;
        ui_english) echo "English" ;;
        ui_chinese) echo "中文" ;;
        ui_korean) echo "한국어" ;;
        ui_japanese) echo "日本語" ;;
        ui_group_services) echo "서비스 및 진단" ;;
        ui_group_changes) echo "업데이트 및 복구" ;;
        ui_group_more) echo "기타" ;;
        ui_running) echo "실행 중" ;;
        ui_stopped) echo "중지됨" ;;
        ui_unmanaged) echo "관리되지 않음" ;;
        ui_unknown) echo "상태 확인 불가" ;;
        ui_back) echo "뒤로" ;;
        ui_prompt) echo "번호 선택" ;;
        ui_keys) echo "↑/↓ 선택 · Enter 확인 · 번호 + Enter" ;;
        ui_shortcuts) echo "r 새로 고침 · q / Esc 뒤로 또는 종료" ;;
        ui_service_note) echo "서비스 상태입니다. 전체 진단은 상태 점검을 사용하세요" ;;
        menu_install) echo "설치" ;;
        menu_healthcheck) echo "상태 점검" ;;
        menu_self_heal) echo "자동 복구" ;;
        menu_upgrade) echo "이미지 업그레이드(EE/DD)" ;;
        menu_self_update) echo "스크립트 자체 업데이트" ;;
        menu_rotate_secret) echo "시크릿 교체" ;;
        menu_region_diag) echo "네트워크 / 지역 진단" ;;
        menu_uninstall) echo "제거" ;;
        menu_help) echo "도움말" ;;
        menu_exit) echo "종료" ;;
        menu_press_enter) echo "엔터를 눌러 메뉴로 돌아가기..." ;;
        ask_oper_mode) echo "모드를 선택하세요:" ;;
        ask_rotate_mode) echo "시크릿 교체 모드를 선택하세요:" ;;
        ask_new_mtg_image) echo "새 MTG 이미지 digest 입력 (빈값=현재 유지, auto=최신 digest 자동 감지): " ;;
        ask_new_dd_image) echo "새 DD 이미지 digest 입력 (빈값=현재 유지, auto=최신 digest 자동 감지): " ;;
        note_upgrade_scope) echo "이 작업은 이미지 digest 업데이트와 서비스 재시작만 수행하며, 도메인/포트/시크릿은 변경하지 않습니다." ;;
        ask_new_secret_ee) echo "새 EE 시크릿 입력 (빈값=자동 생성): " ;;
        ask_new_secret_dd) echo "새 DD 시크릿 입력 (빈값=자동 생성): " ;;
        ask_front_for_auto_secret) echo "EE 자동 시크릿용 front-domain 입력 (빈값=현재 유지): " ;;
        ask_bind_ip_mode) echo "바인드 IP를 선택하세요:" ;;
        opt_all_interfaces) echo "모든 인터페이스, 권장" ;;
        opt_primary_ipv4) echo "기본 IPv4" ;;
        opt_primary_ipv6) echo "기본 IPv6" ;;
        opt_disabled) echo "사용 안 함" ;;
        opt_unavailable) echo "사용 불가" ;;
        ask_bind_ipv4) echo "바인드 IPv4 입력(또는 0.0.0.0): " ;;
        ask_bind_ipv6_mode) echo "바인드 IPv6를 선택하세요:" ;;
        ask_bind_ipv6) echo "바인드 IPv6 입력(또는 ::): " ;;
        err_primary_ipv4_unavailable) echo "기본 IPv4를 사용할 수 없습니다." ;;
        err_primary_ipv6_unavailable) echo "기본 IPv6를 사용할 수 없습니다." ;;
        err_ipv4_invalid) echo "IPv4 형식이 올바르지 않습니다." ;;
        err_ipv6_invalid) echo "IPv6 형식이 올바르지 않습니다." ;;
        err_bind_ip_not_found) echo "이 호스트에서 해당 IP를 찾을 수 없습니다." ;;
        step_self_update) echo "단계: 스크립트 저장소 업데이트(git pull --ff-only)." ;;
        err_self_update_not_git) echo "self-update는 .git 이 있는 git clone 디렉터리에서만 가능합니다." ;;
        note_self_update_done) echo "스크립트 자체 업데이트가 완료되었습니다." ;;
        note_self_update_rerun) echo "새 로직 적용을 위해 설치 스크립트를 다시 실행하세요:" ;;
        menu_migrate) echo "레거시 마이그레이션" ;;
        menu_rollback) echo "롤백" ;;
        step_migrate) echo "단계: 실행 중인 레거시 컨테이너를 systemd 관리 서비스로 마이그레이션." ;;
        step_backup) echo "단계: 변경 전 백업 생성." ;;
        step_rollback) echo "단계: 백업에서 롤백 수행." ;;
        step_region_diag) echo "단계: 지역 차단 휴리스틱 진단 실행." ;;
        ask_backup_id) echo "백업 ID 입력 (빈값=최신): " ;;
        note_backup_saved) echo "백업 저장됨:" ;;
        note_backup_latest) echo "최신 백업 사용:" ;;
        note_backup_none) echo "백업이 없습니다." ;;
        note_rollback_done) echo "롤백 완료." ;;
        err_backup_not_found) echo "해당 백업 ID를 찾을 수 없습니다." ;;
        err_lock_busy) echo "다른 install.sh 프로세스가 실행 중입니다. 잠시 후 다시 시도하세요." ;;
        err_lock_unavailable) echo "flock 명령이 없어 단일 실행 잠금을 적용할 수 없습니다." ;;
        err_migrate_no_legacy) echo "마이그레이션할 레거시 프록시 컨테이너가 없습니다." ;;
        err_legacy_container_missing) echo "필수 레거시 컨테이너가 없습니다." ;;
        note_migrate_done) echo "마이그레이션 완료. 서비스가 systemd 관리로 전환되었습니다." ;;
        ask_existing_ee_secret) echo "기존 EE 시크릿 입력 (ee...hex): " ;;
        err_ee_secret_required) echo "마이그레이션에는 EE 시크릿이 필요합니다." ;;
        warn_image_not_digest) echo "현재 이미지는 digest 고정이 아닙니다. 기본 고정 digest로 대체합니다." ;;
        note_using_digest) echo "사용할 digest 이미지:" ;;
        note_recent_logs) echo "최근 컨테이너 로그:" ;;
        warn_service_restarts) echo "서비스 재시작 횟수가 높습니다:" ;;
        warn_container_restarts) echo "컨테이너 재시작 횟수가 높습니다:" ;;
        err_port_binding_mismatch) echo "컨테이너 포트 바인딩이 설정된 IP/포트와 다릅니다." ;;
        err_unknown_arg) echo "알 수 없는 인자:" ;;
        err_unknown_cmd) echo "알 수 없는 명령:" ;;
        err_rotate_mode_required) echo "rotate-secret는 --mode ee|dd가 필요합니다." ;;
        err_mode_value_invalid) echo "잘못된 모드 값:" ;;
        err_not_installed_ee) echo "EE가 설치되어 있지 않습니다." ;;
        err_not_installed_dd) echo "DD가 설치되어 있지 않습니다." ;;
        err_invalid_mtg_image) echo "잘못된 MTG 이미지 digest:" ;;
        err_invalid_dd_image) echo "잘못된 DD 이미지 digest:" ;;
        err_upgrade_failed) echo "업그레이드 실패. 이전 설정을 복원합니다." ;;
        err_upgrade_rollback_failed) echo "자동 복구 실패. 이 백업을 수동으로 복원하세요:" ;;
        err_invalid_ee_secret) echo "EE 시크릿 형식이 잘못되었습니다(ee... hex)." ;;
        err_invalid_dd_secret) echo "DD 시크릿 형식이 잘못되었습니다." ;;
        err_migrate_port_missing) echo "레거시 컨테이너에서 호스트 포트 바인딩을 감지할 수 없습니다." ;;
        note_legacy_detected) echo "레거시 배포 감지: 컨테이너는 실행 중이지만 env 파일이 없습니다" ;;
        note_legacy_migrate) echo "migrate/install로 이 인스턴스를 스크립트 관리로 전환하세요" ;;
        ask_new_ee_secret_cli) echo "새 EE 시크릿 입력(hex, 빈값=자동 생성): " ;;
        ask_new_dd_secret_cli) echo "새 DD 시크릿 입력(32hex 또는 dd+32hex, 빈값=자동 생성): " ;;
        note_attempt_restart_ee) echo "[ee] 재시작 시도 중..." ;;
        note_attempt_restart_dd) echo "[dd] 재시작 시도 중..." ;;
        hc_not_installed) echo "설치되지 않음(env 파일 없음)" ;;
        hc_service_not_active) echo "서비스 비활성" ;;
        hc_container_not_running) echo "컨테이너 미실행" ;;
        hc_port_not_listening) echo "포트 미청취" ;;
        hc_image_mismatch) echo "이미지 불일치" ;;
        hc_healthy) echo "정상" ;;
        critical_need_systemctl) echo "치명적 오류: systemctl 이 필요합니다." ;;
        critical_need_apt) echo "치명적 오류: apt-get 이 필요합니다." ;;
        preflight_warnings) echo "사전 점검 경고:" ;;
        aborted_by_user) echo "사용자에 의해 중단되었습니다." ;;
        note_a_records) echo "A 레코드" ;;
        note_aaaa_records) echo "AAAA 레코드" ;;
        note_server_ip) echo "서버 IP" ;;
        note_server_ipv6) echo "서버 IPv6" ;;
        label_running) echo "실행값" ;;
        label_configured) echo "설정값" ;;
        label_expected) echo "기대값" ;;
        label_actual) echo "실제값" ;;
        label_log) echo "로그" ;;
        label_secret) echo "시크릿" ;;
        label_import_link) echo "가져오기 링크" ;;
        note_rotate_done) echo "시크릿 교체가 적용되었고 서비스가 재시작되었습니다." ;;
        summary_images) echo "이미지" ;;
        summary_mtg) echo "MTG" ;;
        summary_dd) echo "DD" ;;
        summary_ee_link) echo "EE (FakeTLS)" ;;
        summary_dd_link) echo "DD (padding)" ;;
        usage_title) echo "사용법:" ;;
        usage_notes) echo "참고:" ;;
        usage_no_args) echo "인자 없이 실행: 대화형 메뉴를 엽니다." ;;
        usage_self_update) echo "self-update: 스크립트 저장소를 fast-forward로 업데이트합니다." ;;
        usage_migrate) echo "migrate: 레거시 실행 컨테이너를 env+systemd 관리로 전환합니다." ;;
        usage_rollback) echo "rollback: 최신/지정 백업에서 설정과 unit을 복원합니다." ;;
        usage_install) echo "install 명령: 대화형 설치 흐름을 바로 시작합니다." ;;
        usage_rotate_dd) echo "DD rotate-secret는 32-hex 또는 dd+32-hex를 지원합니다." ;;
        usage_region_diag) echo "regional-diagnose는 로컬 휴리스틱 점검을 수행합니다. 정확한 국가/ISP 확인에는 외부 프로브가 필요합니다." ;;
        warn_ee_domain_fallback) echo "EE 도메인을 감지하지 못해 서버 IP를 사용합니다:" ;;
        warn_dd_domain_fallback) echo "DD 도메인을 감지하지 못해 서버 IP를 사용합니다:" ;;
        warn_front_domain_fallback) echo "프론팅 도메인을 감지하지 못해 기본값을 사용합니다:" ;;
        err_ee_secret_autodetect_fail) echo "레거시 설정/컨테이너에서 EE 시크릿 자동 감지에 실패했습니다." ;;
        warn_dns_aaaa_unresolved) echo "경고: 도메인에 AAAA 레코드가 없습니다." ;;
        warn_dns_aaaa_mismatch) echo "경고: 도메인 AAAA 레코드에 서버 IPv6가 없습니다." ;;
        diag_scope_note) echo "이 기능은 로컬 휴리스틱일 뿐입니다. DNS/fronting/IP/포트 문제를 추정할 수는 있지만, 어느 국가가 차단했는지 증명할 수는 없습니다." ;;
        diag_no_managed_service) echo "아직 스크립트가 관리하는 EE/DD 서비스가 없습니다." ;;
        diag_server_ip) echo "감지된 서버 IPv4" ;;
        diag_entry_domain) echo "접속 도메인" ;;
        diag_front_domain) echo "프론팅 도메인" ;;
        diag_bind) echo "바인드 대상" ;;
        diag_public_dns) echo "공용 DNS 해석 결과" ;;
        diag_literal_ipv4) echo "접속 대상이 순수 IPv4입니다. A 레코드 검사를 건너뜁니다." ;;
        diag_resolver_match) echo "서버 IPv4를 포함함:" ;;
        diag_resolver_missing) echo "A 레코드가 없습니다." ;;
        diag_resolver_mismatch) echo "서버 IPv4를 포함하지 않음:" ;;
        diag_front_tls_ok) echo "이 VPS에서 프론팅 도메인 TLS 핸드셰이크가 성공했습니다." ;;
        diag_front_tls_fail) echo "이 VPS에서 프론팅 도메인 TLS 핸드셰이크가 실패했습니다." ;;
        diag_local_issue_first) echo "먼저 로컬 서비스/설정 문제가 감지되었습니다. 지역 차단 결론을 내리기 전에 이를 먼저 수정해야 합니다." ;;
        diag_likely_dns_issue) echo "DNS/도메인 불일치가 감지되었습니다. 국가 차단보다는 도메인 해석/전파 문제일 가능성이 더 큽니다." ;;
        diag_likely_ee_front_issue) echo "EE 프론팅 검사가 로컬에서 실패했습니다. 지역 차단보다는 front-domain 또는 EE secret/front 조합을 먼저 의심해야 합니다." ;;
        diag_likely_region_block) echo "명확한 로컬 서비스 또는 DNS 문제는 보이지 않았습니다. 일부 국가에서만 실패한다면 IP/포트/프로토콜 차단 가능성이 더 큽니다." ;;
        diag_country_probe_needed) echo "정확한 국가나 ISP 확인을 위해서는 외부 프로브 또는 해당 네트워크의 사용자 테스트가 필요합니다." ;;
        diag_tool_missing) echo "필수 도구가 없습니다" ;;
      esac
      ;;
    ja)
      case "$key" in
        title) echo "Telegram プロキシ導入（EE+DD）— 対話式" ;;
        need_dns) echo "開始前：ドメインのAレコードがこのVPSを指していることを確認してください（DNS only、CDNプロキシ禁止）。" ;;
        step_update) echo "手順：システム更新と基本ツール導入（curl、openssl、ufw、dnsutils等）。" ;;
        step_docker) echo "手順：Dockerのインストールと有効化。" ;;
        step_bbr_q) echo "手順：（任意）ネットワーク調整（BBR + fq）。" ;;
        step_firewall) echo "手順：安全なUFW設定（先にSSH/プロキシポート許可、その後有効化）。" ;;
        step_pull) echo "手順：Dockerイメージ取得（mtg=EE、MTProxy=DD）。" ;;
        step_front_test) echo "手順：frontingドメインのTLSハンドシェイク確認。" ;;
        step_gen_ee) echo "手順：EE（FakeTLS）シークレット生成とmtg設定作成。" ;;
        step_run_ee) echo "手順：mtg（EE）起動。" ;;
        step_gen_dd) echo "手順：DD（padding）シークレット生成。" ;;
        step_run_dd) echo "手順：MTProxy（DD）起動。" ;;
        step_dns_check) echo "手順：接続ドメインのDNS確認。" ;;
        step_summary) echo "完了。設定とワンクリック導入リンクを表示します。" ;;
        ask_mode) echo "デプロイモードを選択してください:" ;;
        mode_ee_only) echo "EEのみ (FakeTLS / mtg)" ;;
        mode_dd_only) echo "DDのみ (padding / MTProxy)" ;;
        mode_both) echo "EE + DD（デュアル運用、推奨）" ;;
        ask_ee_domain) echo "EEの接続ドメイン（例：ee.example.com）: " ;;
        ask_dd_domain) echo "DDの接続ドメイン（例：dd.example.com）: " ;;
        ask_front_domain) echo "EEのfrontingドメイン（既定：www.cloudflare.com）: " ;;
        ask_fronting_mode) echo "frontingドメインの入力方式を選択してください:" ;;
        ask_ee_port) echo "EEのポート（推奨: 443）。番号を入力: " ;;
        ask_dd_port) echo "DDのポート（推奨: 8443）。番号を入力: " ;;
        ask_port_menu) echo "ポートオプションを選択してください:" ;;
        opt_manual_input) echo "手動入力" ;;
        opt_recommended) echo "推奨" ;;
        ask_enable_bbr) echo "BBR+fqを有効化（推奨）[Y/n]: " ;;
        ask_strict_ufw) echo "選択したIPに限定する厳格なUFWルールを有効化しますか？ [y/N]: " ;;
        ask_continue_anyway) echo "このまま続行しますか？ [y/N]: " ;;
        err_port_num) echo "ポートは1〜65535の数字である必要があります。" ;;
        err_port_conflict) echo "同一IPではEEとDDを同じポートにできません。" ;;
        err_port_in_use) echo "そのポートは既に使用中です。" ;;
        warn_443_busy) echo "選択したポートは既に使用中です。" ;;
        note_port_holders) echo "現在このポートで待受しているプロセス:" ;;
        ask_cleanup_proxy_443) echo "旧プロキシコンテナを停止してこのポートを再確認しますか？ [y/N]: " ;;
        note_cleanup_done) echo "クリーンアップを試行しました。選択ポートを再確認します..." ;;
        warn_cleanup_unavailable) echo "Dockerが見つからないため旧プロキシコンテナを自動停止できません。" ;;
        warn_443_still_busy) echo "クリーンアップ後も選択ポートは使用中です。" ;;
        err_empty) echo "空欄は不可です。" ;;
        err_choice_invalid) echo "選択が不正です。表示された番号を入力してください。" ;;
        err_mode_invalid) echo "モード入力が不正です。1、2、3から選択してください。" ;;
        err_domain_invalid) echo "ドメイン形式が不正です。例: sub.example.com" ;;
        warn_dns_unresolved) echo "警告：ドメインにAレコードがありません。" ;;
        warn_dns_mismatch) echo "警告：ドメインAレコードにこのサーバーIPv4がありません。" ;;
        warn_bbr_unsupported) echo "警告：カーネルがBBR対応を示していないためスキップします。" ;;
        warn_bbr_apply_fail) echo "警告：sysctl適用に失敗。BBR変更なしで続行します。" ;;
        tls_ok) echo "TLSハンドシェイクOK。" ;;
        tls_fail) echo "TLSハンドシェイク失敗/タイムアウト。" ;;
        tls_abort) echo "TLS確認失敗かつ続行確認なしのため中止しました。" ;;
        warn_front_fallback) echo "全候補のTLS確認に失敗しました。先頭候補で続行します:" ;;
        note_secret) echo "シークレットを公開しないでください。" ;;
        note_no_cdn) echo "重要：DNSはDNS only（CDNプロキシ禁止）。" ;;
        err_image_ref_invalid) echo "イメージ参照はdigest形式(name@sha256:64hex)である必要があります。MTG_IMAGE/DD_IMAGEを設定してください。" ;;
        menu_title) echo "メインメニュー" ;;
        ui_language) echo "Language / 语言 / 언어 / 言語" ;;
        ui_english) echo "English" ;;
        ui_chinese) echo "中文" ;;
        ui_korean) echo "한국어" ;;
        ui_japanese) echo "日本語" ;;
        ui_group_services) echo "サービスと診断" ;;
        ui_group_changes) echo "更新と復元" ;;
        ui_group_more) echo "その他" ;;
        ui_running) echo "稼働中" ;;
        ui_stopped) echo "停止中" ;;
        ui_unmanaged) echo "管理対象外" ;;
        ui_unknown) echo "状態を取得できません" ;;
        ui_back) echo "戻る" ;;
        ui_prompt) echo "番号を選択" ;;
        ui_keys) echo "↑/↓ 選択 · Enter 確定 · 番号 + Enter" ;;
        ui_shortcuts) echo "r 更新 · q / Esc 戻る、または終了" ;;
        ui_service_note) echo "サービスの状態です。詳細はヘルスチェックを使用してください" ;;
        menu_install) echo "インストール" ;;
        menu_healthcheck) echo "ヘルスチェック" ;;
        menu_self_heal) echo "自動復旧" ;;
        menu_upgrade) echo "イメージ更新（EE/DD）" ;;
        menu_self_update) echo "スクリプト自己更新" ;;
        menu_rotate_secret) echo "シークレット更新" ;;
        menu_region_diag) echo "ネットワーク・地域診断" ;;
        menu_uninstall) echo "アンインストール" ;;
        menu_help) echo "ヘルプ" ;;
        menu_exit) echo "終了" ;;
        menu_press_enter) echo "Enterキーでメニューに戻ります..." ;;
        ask_oper_mode) echo "モードを選択してください:" ;;
        ask_rotate_mode) echo "シークレット更新モードを選択してください:" ;;
        ask_new_mtg_image) echo "新しいMTGイメージdigestを入力（空欄=現状維持、auto=最新digest自動検出）: " ;;
        ask_new_dd_image) echo "新しいDDイメージdigestを入力（空欄=現状維持、auto=最新digest自動検出）: " ;;
        note_upgrade_scope) echo "この操作はイメージdigest更新とサービス再起動のみ行い、ドメイン・ポート・シークレットは変更しません。" ;;
        ask_new_secret_ee) echo "新しいEEシークレットを入力（空欄=自動生成）: " ;;
        ask_new_secret_dd) echo "新しいDDシークレットを入力（空欄=自動生成）: " ;;
        ask_front_for_auto_secret) echo "EE自動生成用front-domainを入力（空欄=現状維持）: " ;;
        ask_bind_ip_mode) echo "バインドIPを選択してください:" ;;
        opt_all_interfaces) echo "全インターフェース、推奨" ;;
        opt_primary_ipv4) echo "プライマリIPv4" ;;
        opt_primary_ipv6) echo "プライマリIPv6" ;;
        opt_disabled) echo "無効" ;;
        opt_unavailable) echo "利用不可" ;;
        ask_bind_ipv4) echo "バインドIPv4を入力（または0.0.0.0）: " ;;
        ask_bind_ipv6_mode) echo "バインドIPv6を選択してください:" ;;
        ask_bind_ipv6) echo "バインドIPv6を入力（または::）: " ;;
        err_primary_ipv4_unavailable) echo "プライマリIPv4は利用できません。" ;;
        err_primary_ipv6_unavailable) echo "プライマリIPv6は利用できません。" ;;
        err_ipv4_invalid) echo "IPv4形式が不正です。" ;;
        err_ipv6_invalid) echo "IPv6形式が不正です。" ;;
        err_bind_ip_not_found) echo "このホストにそのIPはありません。" ;;
        step_self_update) echo "手順：スクリプトリポジトリを更新（git pull --ff-only）。" ;;
        err_self_update_not_git) echo "self-update は .git を含む git clone ディレクトリで実行する必要があります。" ;;
        note_self_update_done) echo "スクリプト自己更新が完了しました。" ;;
        note_self_update_rerun) echo "新しいロジックを適用するには再実行してください:" ;;
        menu_migrate) echo "旧構成を移行" ;;
        menu_rollback) echo "ロールバック" ;;
        step_migrate) echo "手順：稼働中の旧コンテナを script 管理の systemd サービスへ移行。" ;;
        step_backup) echo "手順：変更前バックアップを作成。" ;;
        step_rollback) echo "手順：バックアップからロールバック。" ;;
        step_region_diag) echo "手順：地域ブロックのヒューリスティック診断を実行。" ;;
        ask_backup_id) echo "バックアップIDを入力（空欄=最新）: " ;;
        note_backup_saved) echo "バックアップ保存先:" ;;
        note_backup_latest) echo "最新バックアップを使用:" ;;
        note_backup_none) echo "バックアップがありません。" ;;
        note_rollback_done) echo "ロールバック完了。" ;;
        err_backup_not_found) echo "指定したバックアップIDが見つかりません。" ;;
        err_lock_busy) echo "別の install.sh プロセスが実行中です。しばらくして再試行してください。" ;;
        err_lock_unavailable) echo "flock が無いため単一起動ロックを有効化できません。" ;;
        err_migrate_no_legacy) echo "移行対象の旧プロキシコンテナが見つかりません。" ;;
        err_legacy_container_missing) echo "必要な旧コンテナが見つかりません。" ;;
        note_migrate_done) echo "移行が完了し、systemd 管理に切り替わりました。" ;;
        ask_existing_ee_secret) echo "既存EEシークレットを入力（ee...hex）: " ;;
        err_ee_secret_required) echo "移行にはEEシークレットが必要です。" ;;
        warn_image_not_digest) echo "現在のイメージはdigest固定ではないため、既定の固定digestへフォールバックします。" ;;
        note_using_digest) echo "使用するdigestイメージ:" ;;
        note_recent_logs) echo "直近のコンテナログ:" ;;
        warn_service_restarts) echo "サービス再起動回数が高めです:" ;;
        warn_container_restarts) echo "コンテナ再起動回数が高めです:" ;;
        err_port_binding_mismatch) echo "コンテナのポートバインドが設定IP/ポートと一致しません。" ;;
        err_unknown_arg) echo "不明な引数:" ;;
        err_unknown_cmd) echo "不明なコマンド:" ;;
        err_rotate_mode_required) echo "rotate-secret には --mode ee|dd が必要です" ;;
        err_mode_value_invalid) echo "モード値が不正です:" ;;
        err_not_installed_ee) echo "EE は未インストールです。" ;;
        err_not_installed_dd) echo "DD は未インストールです。" ;;
        err_invalid_mtg_image) echo "MTG イメージdigestが不正です:" ;;
        err_invalid_dd_image) echo "DD イメージdigestが不正です:" ;;
        err_upgrade_failed) echo "更新に失敗しました。以前の設定を復元します。" ;;
        err_upgrade_rollback_failed) echo "自動復旧に失敗しました。このバックアップを手動で復元してください:" ;;
        err_invalid_ee_secret) echo "EEシークレット形式が不正です（ee... hex）。" ;;
        err_invalid_dd_secret) echo "DDシークレット形式が不正です。" ;;
        err_migrate_port_missing) echo "旧コンテナからホスト側ポートバインドを検出できません。" ;;
        note_legacy_detected) echo "旧デプロイを検出：コンテナは稼働中ですが env ファイルがありません" ;;
        note_legacy_migrate) echo "migrate/install を実行して script 管理へ移行してください" ;;
        ask_new_ee_secret_cli) echo "新しいEEシークレットを入力（hex、空欄=自動生成）: " ;;
        ask_new_dd_secret_cli) echo "新しいDDシークレットを入力（32hex または dd+32hex、空欄=自動生成）: " ;;
        note_attempt_restart_ee) echo "[ee] 再起動を試行中..." ;;
        note_attempt_restart_dd) echo "[dd] 再起動を試行中..." ;;
        hc_not_installed) echo "未インストール（env ファイル不足）" ;;
        hc_service_not_active) echo "サービス停止" ;;
        hc_container_not_running) echo "コンテナ停止" ;;
        hc_port_not_listening) echo "ポート未待受" ;;
        hc_image_mismatch) echo "イメージ不一致" ;;
        hc_healthy) echo "正常" ;;
        critical_need_systemctl) echo "重大: systemctl が必要です。" ;;
        critical_need_apt) echo "重大: apt-get が必要です。" ;;
        preflight_warnings) echo "事前チェック警告:" ;;
        aborted_by_user) echo "ユーザーにより中断しました。" ;;
        note_a_records) echo "A レコード" ;;
        note_aaaa_records) echo "AAAA レコード" ;;
        note_server_ip) echo "サーバー IP" ;;
        note_server_ipv6) echo "サーバー IPv6" ;;
        label_running) echo "実行値" ;;
        label_configured) echo "設定値" ;;
        label_expected) echo "期待値" ;;
        label_actual) echo "実測値" ;;
        label_log) echo "ログ" ;;
        label_secret) echo "シークレット" ;;
        label_import_link) echo "インポートリンク" ;;
        note_rotate_done) echo "シークレット更新を適用し、サービスを再起動しました。" ;;
        summary_images) echo "イメージ" ;;
        summary_mtg) echo "MTG" ;;
        summary_dd) echo "DD" ;;
        summary_ee_link) echo "EE (FakeTLS)" ;;
        summary_dd_link) echo "DD (padding)" ;;
        usage_title) echo "使い方:" ;;
        usage_notes) echo "注記:" ;;
        usage_no_args) echo "引数なし: 対話式メニューを開きます。" ;;
        usage_self_update) echo "self-update: スクリプトリポジトリを fast-forward で更新します。" ;;
        usage_migrate) echo "migrate: 旧稼働コンテナを env+systemd 管理に取り込みます。" ;;
        usage_rollback) echo "rollback: 最新/指定バックアップから設定と unit を復元します。" ;;
        usage_install) echo "install コマンド: 対話式インストールを直接開始します。" ;;
        usage_rotate_dd) echo "DD の rotate-secret は 32-hex または dd+32-hex を受け付けます。" ;;
        usage_region_diag) echo "regional-diagnose はローカルのヒューリスティック診断を実行します。正確な国/ISP 判定には外部プローブが必要です。" ;;
        warn_ee_domain_fallback) echo "EE ドメインを検出できないため、サーバー IP を使用します:" ;;
        warn_dd_domain_fallback) echo "DD ドメインを検出できないため、サーバー IP を使用します:" ;;
        warn_front_domain_fallback) echo "fronting ドメインを検出できないため、既定値を使用します:" ;;
        err_ee_secret_autodetect_fail) echo "旧設定/コンテナから EE シークレットを自動検出できません。" ;;
        warn_dns_aaaa_unresolved) echo "警告：ドメインに AAAA レコードがありません。" ;;
        warn_dns_aaaa_mismatch) echo "警告：ドメイン AAAA レコードにこのサーバーIPv6がありません。" ;;
        diag_scope_note) echo "これはローカルのヒューリスティック診断です。DNS/fronting/IP/ポート問題の推定はできますが、どの国が遮断しているかを証明することはできません。" ;;
        diag_no_managed_service) echo "script 管理下の EE/DD サービスがまだありません。" ;;
        diag_server_ip) echo "検出したサーバー IPv4" ;;
        diag_entry_domain) echo "接続ドメイン" ;;
        diag_front_domain) echo "fronting ドメイン" ;;
        diag_bind) echo "バインド先" ;;
        diag_public_dns) echo "公開 DNS の見え方" ;;
        diag_literal_ipv4) echo "接続先は生の IPv4 です。A レコード確認をスキップします。" ;;
        diag_resolver_match) echo "サーバー IPv4 を含みます:" ;;
        diag_resolver_missing) echo "A レコードがありません。" ;;
        diag_resolver_mismatch) echo "サーバー IPv4 を含みません:" ;;
        diag_front_tls_ok) echo "この VPS から fronting ドメインへの TLS ハンドシェイクは成功しました。" ;;
        diag_front_tls_fail) echo "この VPS から fronting ドメインへの TLS ハンドシェイクは失敗しました。" ;;
        diag_local_issue_first) echo "先にローカルのサービス/設定問題が検出されました。地域ブロックを論じる前にまずこちらを直すべきです。" ;;
        diag_likely_dns_issue) echo "DNS/ドメインの不整合が見つかりました。国別ブロックより、ドメイン解決や伝播の問題らしさが高いです。" ;;
        diag_likely_ee_front_issue) echo "EE の fronting チェックがローカルで失敗しました。地域ブロックより front-domain または EE secret/front 組み合わせの問題が疑わしいです。" ;;
        diag_likely_region_block) echo "明確なローカルサービス/DNS問題は見当たりません。一部の国だけ失敗するなら、IP/ポート/プロトコル単位の遮断の可能性が高いです。" ;;
        diag_country_probe_needed) echo "正確な国や ISP の特定には、外部プローブまたはそのネットワーク側のユーザーテストが引き続き必要です。" ;;
        diag_tool_missing) echo "必要なツールが見つかりません" ;;
      esac
      ;;
  esac
}

# ---------- Utilities ----------
normalize_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] || return 1
  # Strip leading zeros before arithmetic, and reject numbers that could overflow.
  p="${p#"${p%%[!0]*}"}"
  [[ "${#p}" -ge 1 && "${#p}" -le 5 ]] || return 1
  ((p >= 1 && p <= 65535)) || return 1
  printf '%s' "$p"
}

is_port_number() {
  normalize_port "$1" >/dev/null
}

is_valid_domain() {
  local d="$1"
  [[ "$d" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

port_in_use() {
  local p=""
  p="$(normalize_port "$1")" || return 1
  if command -v ss >/dev/null 2>&1; then
    ss -lntp 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}$"
  elif command -v netstat >/dev/null 2>&1; then
    netstat -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}$"
  else
    return 1
  fi
}

diag_format_records() {
  local records="$1"
  local compact=""
  compact="$(tr '\n' ' ' <<<"$records" | xargs 2>/dev/null || true)"
  if [[ -n "$compact" ]]; then
    printf '%s' "$compact"
  else
    printf 'n/a'
  fi
}

resolve_domain_a_records_via_resolver() {
  local domain="$1"
  local resolver="$2"
  command -v dig >/dev/null 2>&1 || return 127
  dig @"$resolver" +short A "$domain" 2>/dev/null | awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/'
}

resolve_domain_aaaa_records_via_resolver() {
  local domain="$1"
  local resolver="$2"
  command -v dig >/dev/null 2>&1 || return 127
  dig @"$resolver" +short AAAA "$domain" 2>/dev/null | awk '/:/'
}

format_bind_targets() {
  local bind_ipv4="$1"
  local bind_ipv6="$2"
  local port="$3"
  local out=()
  if [[ -n "$bind_ipv4" ]]; then
    out+=("${bind_ipv4}:${port}")
  fi
  if [[ -n "$bind_ipv6" ]]; then
    out+=("[${bind_ipv6}]:${port}")
  fi
  printf '%s' "${out[*]}"
}

docker_publish_args() {
  local bind_ipv4="$1"
  local bind_ipv6="$2"
  local host_port="$3"
  local container_port="$4"
  local args=()
  if [[ -n "$bind_ipv4" ]]; then
    args+=("-p" "${bind_ipv4}:${host_port}:${container_port}")
  fi
  if [[ -n "$bind_ipv6" ]]; then
    args+=("-p" "[${bind_ipv6}]:${host_port}:${container_port}")
  fi
  printf '%s' "${args[*]}"
}

show_port_holders() {
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -lntp 2>/dev/null | awk -v port=":${p}" '$4 ~ port"$"'
  elif command -v netstat >/dev/null 2>&1; then
    netstat -lntp 2>/dev/null | awk -v port=":${p}" '$4 ~ port"$"'
  fi
}

cleanup_old_proxy_containers() {
  cleanup_port_targets "$@"
}

ask_domain() {
  local prompt_key="$1"
  local var_name="$2"
  local value=""
  while true; do
    echo -n "$(t "$prompt_key")"
    read -r value || return 1
    value="${value//[[:space:]]/}"
    value="${value,,}"
    if [[ -z "$value" ]]; then
      t err_empty
      continue
    fi
    if ! is_valid_domain "$value"; then
      t err_domain_invalid
      continue
    fi
    printf -v "$var_name" "%s" "$value"
    return 0
  done
}

ask_front_domain_with_options() {
  local choice=""
  while true; do
    t ask_fronting_mode
    echo "1) www.cloudflare.com ($(t opt_recommended))"
    echo "2) www.google.com"
    echo "3) www.microsoft.com"
    echo "4) aws.amazon.com"
    echo "5) $(t opt_manual_input)"
    read -rp "> " choice
    choice="${choice// /}"
    case "$choice" in
      1)
        FRONT_DOMAIN="www.cloudflare.com"
        return 0
        ;;
      2)
        FRONT_DOMAIN="www.google.com"
        return 0
        ;;
      3)
        FRONT_DOMAIN="www.microsoft.com"
        return 0
        ;;
      4)
        FRONT_DOMAIN="aws.amazon.com"
        return 0
        ;;
      5)
        ask_domain ask_front_domain FRONT_DOMAIN
        return 0
        ;;
      *)
        t err_choice_invalid
        ;;
    esac
  done
}

check_and_prepare_port() {
  local p=""
  local do_cleanup=""

  if ! p="$(normalize_port "$1")"; then
    t err_port_num
    return 1
  fi

  if port_in_use "$p"; then
    t warn_443_busy
    t note_port_holders
    show_port_holders "$p" || true
    echo -n "$(t ask_cleanup_proxy_443)"
    read -r do_cleanup
    if [[ "$do_cleanup" =~ ^[Yy]$ ]]; then
      if cleanup_old_proxy_containers "$p"; then
        t note_cleanup_done
      else
        t warn_cleanup_unavailable
      fi
      if port_in_use "$p"; then
        t warn_443_still_busy
        t note_port_holders
        show_port_holders "$p" || true
        t err_port_in_use
        return 1
      fi
      return 0
    fi
    t err_port_in_use
    return 1
  fi

  return 0
}

ask_port() {
  local prompt_key="$1"
  local var_name="$2"
  local p=""
  while true; do
    echo -n "$(t "$prompt_key")"
    read -r p
    p="${p// /}"
    if check_and_prepare_port "$p"; then
      p="$(normalize_port "$p")"
      printf -v "$var_name" "%s" "$p"
      return 0
    fi
  done
}

ask_port_with_options() {
  local prompt_key="$1"
  local var_name="$2"
  local opt1="$3"
  local opt2="$4"
  local opt3="$5"
  local choice=""
  local p=""

  while true; do
    t ask_port_menu
    echo "1) ${opt1} ($(t opt_recommended))"
    echo "2) ${opt2}"
    echo "3) ${opt3}"
    echo "4) $(t opt_manual_input)"
    read -rp "> " choice
    choice="${choice// /}"
    case "$choice" in
      1) p="$opt1" ;;
      2) p="$opt2" ;;
      3) p="$opt3" ;;
      4)
        ask_port "$prompt_key" "$var_name"
        return 0
        ;;
      *)
        t err_choice_invalid
        continue
        ;;
    esac

    if check_and_prepare_port "$p"; then
      p="$(normalize_port "$p")"
      printf -v "$var_name" "%s" "$p"
      return 0
    fi
  done
}

ask_deploy_mode() {
  local mode=""
  while true; do
    t ask_mode
    echo "1) $(t mode_ee_only)"
    echo "2) $(t mode_dd_only)"
    echo "3) $(t mode_both)"
    read -rp "> " mode
    mode="${mode// /}"
    case "$mode" in
      1)
        DEPLOY_EE=1
        DEPLOY_DD=0
        return 0
        ;;
      2)
        DEPLOY_EE=0
        DEPLOY_DD=1
        return 0
        ;;
      3)
        DEPLOY_EE=1
        DEPLOY_DD=1
        return 0
        ;;
      *)
        t err_mode_invalid
        ;;
    esac
  done
}

confirm_continue() {
  local ans=""
  echo -n "$(t ask_continue_anyway)"
  if [[ "$ASSUME_YES" -eq 1 ]]; then return 0; fi
  if [[ "$NON_INTERACTIVE" -eq 1 ]]; then return 1; fi
  read -r ans || return 1
  [[ "$ans" =~ ^[Yy]$ ]]
}

get_primary_ipv4() {
  local ip=""
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"
  if [[ -z "$ip" ]]; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  printf '%s' "$ip"
}

get_primary_ipv6() {
  local ip=""
  ip="$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"
  if [[ -z "$ip" ]]; then
    ip="$(ip -6 -o addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}')"
  fi
  printf '%s' "$ip"
}

resolve_domain_a_records() {
  local domain="$1"
  dig +short A "$domain" 2>/dev/null | awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/'
}

resolve_domain_aaaa_records() {
  local domain="$1"
  dig +short AAAA "$domain" 2>/dev/null | awk '/:/'
}

check_domain_dns() {
  local domain="$1"
  local server_ipv4="$2"
  local server_ipv6="$3"
  local need_ipv4="$4"
  local need_ipv6="$5"
  local records=""

  if [[ "$need_ipv4" == "1" ]]; then
    records="$(resolve_domain_a_records "$domain" || true)"
    if [[ -z "$records" ]]; then
      printf '%s (%s)\n' "$(t warn_dns_unresolved)" "${domain}"
      confirm_continue || return 1
      return 0
    fi

    if [[ -n "$server_ipv4" ]] && ! dns_records_match "$server_ipv4" "$records"; then
      printf '%s (%s)\n' "$(t warn_dns_mismatch)" "${domain}"
      echo "$(t note_a_records): $(tr '\n' ' ' <<<"$records" | xargs)"
      echo "$(t note_server_ip): ${server_ipv4}"
      confirm_continue || return 1
    fi
  fi

  if [[ "$need_ipv6" == "1" ]]; then
    records="$(resolve_domain_aaaa_records "$domain" || true)"
    if [[ -z "$records" ]]; then
      printf '%s (%s)\n' "$(t warn_dns_aaaa_unresolved)" "${domain}"
      confirm_continue || return 1
      return 0
    fi

    if [[ -n "$server_ipv6" ]] && ! dns_records_match "$server_ipv6" "$records"; then
      printf '%s (%s)\n' "$(t warn_dns_aaaa_mismatch)" "${domain}"
      echo "$(t note_aaaa_records): $(tr '\n' ' ' <<<"$records" | xargs)"
      echo "$(t note_server_ipv6): ${server_ipv6}"
      confirm_continue || return 1
    fi
  fi
}

collect_sshd_ports() {
  local ports
  ports="$(ss -lntp 2>/dev/null | awk '/sshd/ {print $4}' | sed -E 's/.*[:.]([0-9]+)$/\1/' | awk '/^[0-9]+$/' | sort -u || true)"
  if [[ -z "$ports" ]]; then
    echo "22"
  else
    echo "$ports"
  fi
}

is_valid_digest_image_ref() {
  local image_ref="$1"
  [[ "$image_ref" =~ ^[^[:space:]@]+@sha256:[a-f0-9]{64}$ ]]
}

validate_image_refs() {
  if [[ "$DEPLOY_EE" -eq 1 ]] && ! is_valid_digest_image_ref "$MTG_IMAGE"; then
    t err_image_ref_invalid
    echo "MTG_IMAGE=${MTG_IMAGE}"
    exit 1
  fi
  if [[ "$DEPLOY_DD" -eq 1 ]] && ! is_valid_digest_image_ref "$DD_IMAGE"; then
    t err_image_ref_invalid
    echo "DD_IMAGE=${DD_IMAGE}"
    exit 1
  fi
}

usage() {
  cat <<EOF
$(t usage_title)
  install.sh [install]
  install.sh migrate [--mode ee|dd|all] [--ee-domain DOMAIN] [--dd-domain DOMAIN] [--front-domain DOMAIN]
  install.sh rollback [--mode ee|dd|all] [--backup-id ID]
  install.sh self-update
  install.sh uninstall [--mode ee|dd|all]
  install.sh upgrade [--mode ee|dd|all] [--mtg-image IMAGE@sha256:...] [--dd-image IMAGE@sha256:...]
  install.sh healthcheck [--mode ee|dd|all]
  install.sh self-heal [--mode ee|dd|all]
  install.sh regional-diagnose [--mode ee|dd|all]
  install.sh rotate-secret --mode ee|dd [--secret SECRET] [--front-domain DOMAIN]

$(t usage_notes)
  - $(t usage_no_args)
  - $(t usage_migrate)
  - $(t usage_rollback)
  - $(t usage_self_update)
  - $(t usage_install)
  - $(t usage_rotate_dd)
  - $(t usage_region_diag)
EOF
}

set_mode_flags() {
  local mode="${1:-all}"
  case "$mode" in
    ee)
      DEPLOY_EE=1
      DEPLOY_DD=0
      ;;
    dd)
      DEPLOY_EE=0
      DEPLOY_DD=1
      ;;
    all)
      DEPLOY_EE=1
      DEPLOY_DD=1
      ;;
    *)
      printf '%s %s\n' "$(t err_mode_value_invalid)" "$mode"
      return 1
      ;;
  esac
}

is_valid_ipv4() {
  local octet=""
  local -a octets=()
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=. read -r -a octets <<<"$1"
  for octet in "${octets[@]}"; do ((10#$octet <= 255)) || return 1; done
}

is_valid_ipv6() { normalize_ipv6 "$1" >/dev/null; }

is_local_bind_ip() {
  local target="" address=""
  target="$(canonical_ip "$1")" || return 1
  [[ "$target" == 0.0.0.0 ]] && return 0
  while read -r address; do [[ "$(canonical_ip "$address")" == "$target" ]] && return 0; done < <(ip -4 -o addr show | awk '{split($4,a,"/"); print a[1]}')
  return 1
}

is_local_bind_ipv6() {
  local target="" address=""
  target="$(canonical_ip "$1")" || return 1
  [[ "$target" == :: ]] && return 0
  while read -r address; do [[ "$(canonical_ip "$address")" == "$target" ]] && return 0; done < <(ip -6 -o addr show | awk '{split($4,a,"/"); print a[1]}')
  return 1
}

ask_bind_ip_with_options() {
  local var_name="$1"
  local primary_ip="$2"
  local choice=""
  local input_ip=""
  while true; do
    t ask_bind_ip_mode
    echo "1) 0.0.0.0 ($(t opt_all_interfaces))"
    if [[ -n "$primary_ip" ]]; then
      echo "2) ${primary_ip} ($(t opt_primary_ipv4))"
    else
      echo "2) $(t opt_primary_ipv4) ($(t opt_unavailable))"
    fi
    echo "3) $(t opt_manual_input)"
    read -rp "> " choice
    choice="${choice// /}"
    case "$choice" in
      1)
        printf -v "$var_name" "0.0.0.0"
        return 0
        ;;
      2)
        if [[ -n "$primary_ip" ]]; then
          printf -v "$var_name" "%s" "$primary_ip"
          return 0
        fi
        t err_primary_ipv4_unavailable
        ;;
      3)
        read -rp "$(t ask_bind_ipv4)" input_ip
        input_ip="${input_ip// /}"
        if ! is_valid_ipv4 "$input_ip"; then
          t err_ipv4_invalid
          continue
        fi
        if ! is_local_bind_ip "$input_ip"; then
          t err_bind_ip_not_found
          continue
        fi
        printf -v "$var_name" "%s" "$input_ip"
        return 0
        ;;
      *)
        t err_choice_invalid
        ;;
    esac
  done
}

ask_bind_ipv6_with_options() {
  local var_name="$1"
  local primary_ip="$2"
  local choice=""
  local input_ip=""
  while true; do
    t ask_bind_ipv6_mode
    echo "1) $(t opt_disabled)"
    echo "2) :: ($(t opt_all_interfaces))"
    if [[ -n "$primary_ip" ]]; then
      echo "3) ${primary_ip} ($(t opt_primary_ipv6))"
    else
      echo "3) $(t opt_primary_ipv6) ($(t opt_unavailable))"
    fi
    echo "4) $(t opt_manual_input)"
    read -rp "> " choice
    choice="${choice// /}"
    case "$choice" in
      1)
        printf -v "$var_name" ""
        return 0
        ;;
      2)
        printf -v "$var_name" "::"
        return 0
        ;;
      3)
        if [[ -n "$primary_ip" ]]; then
          printf -v "$var_name" "%s" "$primary_ip"
          return 0
        fi
        t err_primary_ipv6_unavailable
        ;;
      4)
        read -rp "$(t ask_bind_ipv6)" input_ip
        input_ip="${input_ip// /}"
        if ! is_valid_ipv6 "$input_ip"; then
          t err_ipv6_invalid
          continue
        fi
        if ! is_local_bind_ipv6 "$input_ip"; then
          t err_bind_ip_not_found
          continue
        fi
        printf -v "$var_name" "%s" "$input_ip"
        return 0
        ;;
      *)
        t err_choice_invalid
        ;;
    esac
  done
}

ports_conflict_for_bindings() {
  local p1=""
  local ip1_v4="$2"
  local ip1_v6="$3"
  local p2=""
  local ip2_v4="$5"
  local ip2_v6="$6"
  if [[ -n "$ip1_v4" ]]; then ip1_v4="$(canonical_ip "$ip1_v4")" || return 1; fi
  if [[ -n "$ip2_v4" ]]; then ip2_v4="$(canonical_ip "$ip2_v4")" || return 1; fi
  if [[ -n "$ip1_v6" ]]; then ip1_v6="$(canonical_ip "$ip1_v6")" || return 1; fi
  if [[ -n "$ip2_v6" ]]; then ip2_v6="$(canonical_ip "$ip2_v6")" || return 1; fi
  p1="$(normalize_port "$1")" || return 1
  p2="$(normalize_port "$4")" || return 1
  [[ "$p1" == "$p2" ]] || return 1
  if [[ -n "$ip1_v4" && -n "$ip2_v4" ]] && [[ "$ip1_v4" == "0.0.0.0" || "$ip2_v4" == "0.0.0.0" || "$ip1_v4" == "$ip2_v4" ]]; then
    return 0
  fi
  if [[ -n "$ip1_v6" && -n "$ip2_v6" ]] && [[ "$ip1_v6" == "::" || "$ip2_v6" == "::" || "$ip1_v6" == "$ip2_v6" ]]; then
    return 0
  fi
  return 1
}

ufw_allow_proxy_port() {
  local p="$1"
  local bind_ip="$2"
  local strict="$3"
  if [[ -z "$bind_ip" ]]; then
    return 0
  fi
  if [[ "$strict" =~ ^[Yy]$ ]] && [[ "$bind_ip" != "0.0.0.0" && "$bind_ip" != "::" ]]; then
    ufw allow proto tcp from any to "$bind_ip" port "$p" >/dev/null
  else
    ufw allow "${p}/tcp" >/dev/null
  fi
}

preflight_checks() {
  local warnings=()
  local mem_kb=""
  local disk_mb=""
  local os_id="" os_version=""
  local ntp_sync=""

  if ! command -v systemctl >/dev/null 2>&1; then
    t critical_need_systemctl
    return 1
  fi
  if [[ "$(ps -p 1 -o comm= 2>/dev/null || true)" != "systemd" ]]; then
    t systemd_required
    return 1
  fi
  if ! command -v apt-get >/dev/null 2>&1; then
    t critical_need_apt
    return 1
  fi

  if [[ -r "$OS_RELEASE_FILE" ]]; then
    # shellcheck disable=SC1090
    . "$OS_RELEASE_FILE"
    os_id="${ID:-}"
    os_version="${VERSION_ID:-}"
    if [[ "$os_id" != "ubuntu" || "$os_version" != "$TARGET_UBUNTU_VERSION" ]]; then
      warnings+=("Target is tuned for Ubuntu ${TARGET_UBUNTU_VERSION} LTS; detected ${os_id:-unknown} ${os_version:-unknown}.")
    fi
  fi

  mem_kb="$(awk '/MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || true)"
  if [[ -n "$mem_kb" ]] && ((mem_kb < 524288)); then
    warnings+=("Memory is below 512MB; proxy stability may be poor.")
  fi

  disk_mb="$(df -Pm / 2>/dev/null | awk 'NR==2 {print $4}' || true)"
  if [[ -n "$disk_mb" ]] && ((disk_mb < 1024)); then
    warnings+=("Free disk is below 1GB.")
  fi

  if command -v timedatectl >/dev/null 2>&1; then
    ntp_sync="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
    if [[ "$ntp_sync" != "yes" ]]; then
      warnings+=("NTP is not synchronized; time skew can hurt TLS and networking.")
    fi
  fi

  if ! getent hosts registry-1.docker.io >/dev/null 2>&1; then
    warnings+=("DNS lookup for registry-1.docker.io failed; Docker pull may fail.")
  fi

  if ((${#warnings[@]} > 0)); then
    echo
    t preflight_warnings
    printf ' - %s\n' "${warnings[@]}"
    if ! confirm_continue; then
      t aborted_by_user
      return 1
    fi
  fi
}

ensure_config_dir() {
  mkdir -p "$CONFIG_DIR" || return 1
  chmod 700 "$CONFIG_DIR"
}

write_ee_env_file() {
  umask 077
  cat >"$EE_ENV_FILE" <<EOF
EE_DOMAIN=${EE_DOMAIN}
FRONT_DOMAIN=${FRONT_DOMAIN}
EE_PORT=${EE_PORT}
EE_BIND_IP=${EE_BIND_IP}
EE_BIND_IPV6=${EE_BIND_IPV6}
MTG_IMAGE=${MTG_IMAGE}
EE_SECRET=${EE_SECRET}
PUBLIC_IPV4=${PUBLIC_IPV4:-}
PUBLIC_IPV6=${PUBLIC_IPV6:-}
EOF
}

write_dd_env_file() {
  umask 077
  cat >"$DD_ENV_FILE" <<EOF
DD_DOMAIN=${DD_DOMAIN}
DD_PORT=${DD_PORT}
DD_BIND_IP=${DD_BIND_IP}
DD_BIND_IPV6=${DD_BIND_IPV6}
DD_BASE_SECRET=${DD_BASE_SECRET}
DD_SECRET=${DD_SECRET}
DD_IMAGE=${DD_IMAGE}
PUBLIC_IPV4=${PUBLIC_IPV4:-}
PUBLIC_IPV6=${PUBLIC_IPV6:-}
EOF
}

write_ee_systemd_unit() {
  local publish_args=""
  publish_args="$(docker_publish_args "${EE_BIND_IP-0.0.0.0}" "${EE_BIND_IPV6:-}" "${EE_PORT}" "3128")"
  cat >"${SYSTEMD_UNIT_DIR}/${EE_SERVICE_NAME}" <<EOF
[Unit]
Description=Telegram Proxy EE (mtg)
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
Restart=always
RestartSec=5
EnvironmentFile="${EE_ENV_FILE}"
ExecStartPre=-/usr/bin/docker rm -f mtg-ee
ExecStart=/usr/bin/docker run --name mtg-ee --cap-drop=ALL --security-opt=no-new-privileges --pids-limit=256 --log-opt max-size=10m --log-opt max-file=3 -v "${MTG_CONFIG_DIR}/config.toml:/config.toml:ro" ${publish_args} ${MTG_IMAGE} run /config.toml
ExecStop=/usr/bin/docker stop -t 10 mtg-ee
ExecStopPost=-/usr/bin/docker rm -f mtg-ee

[Install]
WantedBy=multi-user.target
EOF
  chmod 600 "${SYSTEMD_UNIT_DIR}/${EE_SERVICE_NAME}"
}

write_dd_systemd_unit() {
  local publish_args=""
  publish_args="$(docker_publish_args "${DD_BIND_IP-0.0.0.0}" "${DD_BIND_IPV6:-}" "${DD_PORT}" "443")"
  cat >"${SYSTEMD_UNIT_DIR}/${DD_SERVICE_NAME}" <<EOF
[Unit]
Description=Telegram Proxy DD (MTProxy padding)
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
Restart=always
RestartSec=5
EnvironmentFile="${DD_ENV_FILE}"
ExecStartPre=-/usr/bin/docker rm -f mtproto-dd
ExecStart=/usr/bin/docker run --name mtproto-dd --cap-drop=ALL --cap-add=NET_BIND_SERVICE --cap-add=SETGID --cap-add=SETUID --security-opt=no-new-privileges --pids-limit=256 --log-opt max-size=10m --log-opt max-file=3 ${publish_args} -e SECRET=${DD_BASE_SECRET} ${DD_IMAGE}
ExecStop=/usr/bin/docker stop -t 10 mtproto-dd
ExecStopPost=-/usr/bin/docker rm -f mtproto-dd

[Install]
WantedBy=multi-user.target
EOF
  chmod 600 "${SYSTEMD_UNIT_DIR}/${DD_SERVICE_NAME}"
}

systemd_reload() {
  systemctl daemon-reload
}

load_env_file() {
  local file="$1" line="" key="" value=""
  [[ -r "$file" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    key="${line%%=*}" value="${line#*=}"
    case "$key" in
      EE_DOMAIN | FRONT_DOMAIN | EE_PORT | EE_BIND_IP | EE_BIND_IPV6 | MTG_IMAGE | EE_SECRET | DD_DOMAIN | DD_PORT | DD_BIND_IP | DD_BIND_IPV6 | DD_IMAGE | DD_SECRET | DD_BASE_SECRET | PUBLIC_IPV4 | PUBLIC_IPV6)
        printf -v "$key" '%s' "$value"
        ;;
    esac
  done <"$file"
}

upsert_env_key() {
  local file="$1"
  local key="$2"
  local value="$3"
  if grep -q "^${key}=" "$file" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$file"
  else
    printf '%s=%s\n' "$key" "$value" >>"$file"
  fi
}

acquire_run_lock() {
  if ! command -v flock >/dev/null 2>&1; then
    t err_lock_unavailable
    return 1
  fi
  mkdir -p "$(dirname "$LOCK_FILE")"
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    t err_lock_busy
    return 1
  fi
}

ensure_backup_dir() {
  mkdir -p "$BACKUP_DIR" || return 1
  chmod 700 "$BACKUP_DIR"
}

latest_backup_path() {
  local latest=""
  latest="$(backup_paths | awk 'NR==1 {print}')"
  [[ -n "$latest" ]] || return 1
  printf '%s' "$latest"
}

resolve_backup_path() {
  local backup_id="$1"
  if [[ -z "$backup_id" ]]; then
    latest_backup_path
    return
  fi
  if [[ -d "$backup_id" ]]; then
    printf '%s' "$backup_id"
    return 0
  fi
  if [[ -d "${BACKUP_DIR}/${backup_id}" ]]; then
    printf '%s' "${BACKUP_DIR}/${backup_id}"
    return 0
  fi
  return 1
}

create_backup() {
  local action="$1"
  local stamp=""
  local backup_path=""
  stamp="$(date +%Y%m%d-%H%M%S)"
  LAST_BACKUP_PATH=""
  ensure_backup_dir || return 1
  backup_path="$(mktemp -d "${BACKUP_DIR}/${stamp}-${action}-XXXXXX")" || return 1
  chmod 700 "$backup_path" || return 1

  if [[ "$DEPLOY_EE" -eq 1 ]]; then
    if [[ -f "$EE_ENV_FILE" ]]; then
      cp -a "$EE_ENV_FILE" "${backup_path}/ee.env" || return 1
    fi
    if [[ -f "${SYSTEMD_UNIT_DIR}/${EE_SERVICE_NAME}" ]]; then
      cp -a "${SYSTEMD_UNIT_DIR}/${EE_SERVICE_NAME}" "${backup_path}/${EE_SERVICE_NAME}" || return 1
    fi
    if [[ -f "${MTG_CONFIG_DIR}/config.toml" ]]; then
      cp -a "${MTG_CONFIG_DIR}/config.toml" "${backup_path}/config.toml" || return 1
    fi
  fi
  if [[ "$DEPLOY_DD" -eq 1 ]]; then
    if [[ -f "$DD_ENV_FILE" ]]; then
      cp -a "$DD_ENV_FILE" "${backup_path}/dd.env" || return 1
    fi
    if [[ -f "${SYSTEMD_UNIT_DIR}/${DD_SERVICE_NAME}" ]]; then
      cp -a "${SYSTEMD_UNIT_DIR}/${DD_SERVICE_NAME}" "${backup_path}/${DD_SERVICE_NAME}" || return 1
    fi
  fi

  cat >"${backup_path}/meta.env" <<EOF || return 1
ACTION=${action}
DEPLOY_EE=${DEPLOY_EE}
DEPLOY_DD=${DEPLOY_DD}
CREATED_AT=$(date -Iseconds)
SNAPSHOT_VERSION=1
EE_ENV_PRESENT=$([[ -f "$EE_ENV_FILE" ]] && echo 1 || echo 0)
DD_ENV_PRESENT=$([[ -f "$DD_ENV_FILE" ]] && echo 1 || echo 0)
EE_UNIT_PRESENT=$([[ -f "${SYSTEMD_UNIT_DIR}/${EE_SERVICE_NAME}" ]] && echo 1 || echo 0)
DD_UNIT_PRESENT=$([[ -f "${SYSTEMD_UNIT_DIR}/${DD_SERVICE_NAME}" ]] && echo 1 || echo 0)
EE_CONFIG_PRESENT=$([[ -f "${MTG_CONFIG_DIR}/config.toml" ]] && echo 1 || echo 0)
EE_ACTIVE=$([[ ! -f "${CONFIG_DIR}/paused-ee" ]] && systemctl is-active --quiet "$EE_SERVICE_NAME" >/dev/null 2>&1 && echo 1 || echo 0)
DD_ACTIVE=$([[ ! -f "${CONFIG_DIR}/paused-dd" ]] && systemctl is-active --quiet "$DD_SERVICE_NAME" >/dev/null 2>&1 && echo 1 || echo 0)
EOF

  if [[ "$DEPLOY_EE" -eq 1 && -f "${CONFIG_DIR}/paused-ee" ]]; then cp -a "${CONFIG_DIR}/paused-ee" "${backup_path}/ee.paused" || return 1; fi
  if [[ "$DEPLOY_DD" -eq 1 && -f "${CONFIG_DIR}/paused-dd" ]]; then cp -a "${CONFIG_DIR}/paused-dd" "${backup_path}/dd.paused" || return 1; fi
  if [[ "$action" == uninstall || "$action" == rollback ]]; then
    local unit=""
    printf 'MONITOR_CAPTURED=1\nMONITOR_ACTIVE=%s\n' "$(systemctl is-active --quiet "$MONITOR_TIMER" >/dev/null 2>&1 && echo 1 || echo 0)" >>"${backup_path}/meta.env" || return 1
    for unit in "$MONITOR_SERVICE" "$MONITOR_TIMER"; do
      if [[ -f "${SYSTEMD_UNIT_DIR}/${unit}" ]]; then cp -a "${SYSTEMD_UNIT_DIR}/${unit}" "$backup_path/" || return 1; fi
    done
  fi
  touch "${backup_path}/.complete" || return 1
  LAST_BACKUP_PATH="$backup_path"
  t note_backup_saved
  echo "${backup_path}"
}

restore_backup() {
  local backup_path="$1"
  local restored=0
  local unit_changed=0
  if [[ "$(read_env_key "${backup_path}/meta.env" SNAPSHOT_VERSION || true)" == 1 ]]; then
    restore_snapshot "$backup_path"
    return
  fi

  if [[ "$DEPLOY_EE" -eq 1 ]]; then
    if [[ -f "${backup_path}/ee.env" ]]; then
      ensure_config_dir || return 1
      cp -a "${backup_path}/ee.env" "$EE_ENV_FILE" || return 1
      chmod 600 "$EE_ENV_FILE" || return 1
      restored=1
    fi
    if [[ -f "${backup_path}/${EE_SERVICE_NAME}" ]]; then
      cp -a "${backup_path}/${EE_SERVICE_NAME}" "${SYSTEMD_UNIT_DIR}/${EE_SERVICE_NAME}" || return 1
      unit_changed=1
      restored=1
    fi
    if [[ -f "${backup_path}/config.toml" ]]; then
      mkdir -p "$MTG_CONFIG_DIR" || return 1
      chmod 700 "$MTG_CONFIG_DIR" || return 1
      cp -a "${backup_path}/config.toml" "${MTG_CONFIG_DIR}/config.toml" || return 1
      chmod 600 "${MTG_CONFIG_DIR}/config.toml" || return 1
      restored=1
    fi
  fi

  if [[ "$DEPLOY_DD" -eq 1 ]]; then
    if [[ -f "${backup_path}/dd.env" ]]; then
      ensure_config_dir || return 1
      cp -a "${backup_path}/dd.env" "$DD_ENV_FILE" || return 1
      chmod 600 "$DD_ENV_FILE" || return 1
      restored=1
    fi
    if [[ -f "${backup_path}/${DD_SERVICE_NAME}" ]]; then
      cp -a "${backup_path}/${DD_SERVICE_NAME}" "${SYSTEMD_UNIT_DIR}/${DD_SERVICE_NAME}" || return 1
      unit_changed=1
      restored=1
    fi
  fi

  if [[ "$restored" -eq 0 ]]; then
    t err_backup_not_found
    return 1
  fi

  if [[ "$unit_changed" -eq 1 ]]; then
    systemd_reload || return 1
  fi
  if [[ "$DEPLOY_EE" -eq 1 ]] && [[ -f "$EE_ENV_FILE" ]] && [[ -f "${SYSTEMD_UNIT_DIR}/${EE_SERVICE_NAME}" ]]; then
    systemctl enable "$EE_SERVICE_NAME" || return 1
    systemctl restart "$EE_SERVICE_NAME" || return 1
  fi
  if [[ "$DEPLOY_DD" -eq 1 ]] && [[ -f "$DD_ENV_FILE" ]] && [[ -f "${SYSTEMD_UNIT_DIR}/${DD_SERVICE_NAME}" ]]; then
    systemctl enable "$DD_SERVICE_NAME" || return 1
    systemctl restart "$DD_SERVICE_NAME" || return 1
  fi
  return 0
}

normalize_image_to_digest() {
  local mode="$1"
  local image_ref="$2"
  local repo_digest=""

  [[ "$mode" == ee || "$mode" == dd ]] || return 1
  if is_valid_digest_image_ref "$image_ref"; then
    printf '%s' "$image_ref"
    return 0
  fi

  repo_digest="$(docker image inspect "$image_ref" --format '{{index .RepoDigests 0}}' 2>/dev/null || true)"
  if [[ -n "$repo_digest" ]] && is_valid_digest_image_ref "$repo_digest"; then
    printf '%s' "$repo_digest"
    return 0
  fi

  t warn_image_not_digest >&2
  return 1
}

docker_container_exists() {
  local name="$1"
  docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$name"
}

docker_env_value() {
  local container="$1"
  local key="$2"
  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null \
    | awk -F= -v k="$key" '$1 == k {sub($1"=","",$0); print; exit}'
}

docker_binding_lines() {
  local container="$1"
  local container_port="$2"
  docker inspect -f "{{with index .HostConfig.PortBindings \"${container_port}\"}}{{range .}}{{println .HostIp \" \" .HostPort}}{{end}}{{end}}" "$container" 2>/dev/null \
    | awk 'NF == 1 {print "0.0.0.0", $1; next} NF >= 2 {print $1, $2}'
}

docker_binding_port() {
  local container="$1"
  local container_port="$2"
  docker_binding_lines "$container" "$container_port" | awk 'NF {print $2; exit}'
}

docker_binding_ip() {
  local container="$1"
  local container_port="$2"
  docker_binding_lines "$container" "$container_port" | awk 'NF {print $1; exit}'
}

docker_binding_ip_by_family() {
  local container="$1"
  local container_port="$2"
  local family="$3"
  if [[ "$family" == "ipv6" ]]; then
    docker_binding_lines "$container" "$container_port" | awk '$1 ~ /:/ {print $1; exit}'
  else
    docker_binding_lines "$container" "$container_port" | awk '$1 !~ /:/ {print $1; exit}'
  fi
}

docker_binding_port_by_family() {
  local container="$1"
  local container_port="$2"
  local family="$3"
  if [[ "$family" == "ipv6" ]]; then
    docker_binding_lines "$container" "$container_port" | awk '$1 ~ /:/ {print $2; exit}'
  else
    docker_binding_lines "$container" "$container_port" | awk '$1 !~ /:/ {print $2; exit}'
  fi
}

detect_legacy_running_container() {
  local mode="$1"
  local preferred_name=""
  local image_re=""
  local container_port=""
  local candidate=""

  case "$mode" in
    ee)
      preferred_name="$EE_CONTAINER_NAME"
      image_re='(^|.*/)nineseconds/mtg(@sha256:|:)'
      container_port="3128/tcp"
      ;;
    dd)
      preferred_name="$DD_CONTAINER_NAME"
      image_re='(^|.*/)telegrammessenger/proxy(@sha256:|:)'
      container_port="443/tcp"
      ;;
    *)
      return 1
      ;;
  esac

  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$preferred_name"; then
    printf '%s' "$preferred_name"
    return 0
  fi

  while read -r candidate; do
    [[ -n "$candidate" ]] || continue
    if [[ -n "$(docker_binding_port "$candidate" "$container_port")" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done < <(docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null | awk -v re="$image_re" '$2 ~ re {print $1}')

  return 1
}

read_env_key() {
  local file="$1"
  local key="$2"
  [[ -f "$file" ]] || return 1
  awk -F= -v k="$key" '$1 == k {sub($1"=","",$0); print; exit}' "$file"
}

extract_ee_secret_from_config() {
  if [[ -f ${MTG_CONFIG_DIR}/config.toml ]]; then
    sed -n 's/^[[:space:]]*secret[[:space:]]*=[[:space:]]*"\([A-Za-z0-9]\+\)".*/\1/p' "${MTG_CONFIG_DIR}/config.toml" | head -n1
  fi
}

extract_ee_secret_from_container() {
  local container="$1"
  local config_src=""
  config_src="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/config.toml"}}{{println .Source}}{{end}}{{end}}' "$container" 2>/dev/null | head -n1 || true)"
  if [[ -n "$config_src" && -f "$config_src" ]]; then
    sed -n 's/^[[:space:]]*secret[[:space:]]*=[[:space:]]*"\([A-Za-z0-9]\+\)".*/\1/p' "$config_src" | head -n1
  fi
}

DIAG_LOCAL_ISSUE=0
DIAG_DNS_ISSUE=0
DIAG_FRONT_ISSUE=0
DIAG_ACTIVE_MODES=0

diag_reset_state() {
  DIAG_LOCAL_ISSUE=0
  DIAG_DNS_ISSUE=0
  DIAG_FRONT_ISSUE=0
  DIAG_ACTIVE_MODES=0
}

diag_domain_dns_view() {
  local domain="$1"
  local server_ipv4="$2"
  local server_ipv6="$3"
  local need_ipv4="$4"
  local need_ipv6="$5"
  local resolver=""
  local records=""
  printf '[info] %s: %s\n' "$(t diag_public_dns)" "$domain"
  if is_valid_ipv4 "$domain" || is_valid_ipv6 "$domain"; then
    printf '[info] %s\n' "$(t diag_literal_ipv4)"
    return 0
  fi
  if ! command -v dig >/dev/null 2>&1; then
    printf '[warn] %s: dig\n' "$(t diag_tool_missing)"
    DIAG_DNS_ISSUE=1
    return 0
  fi
  for resolver in 1.1.1.1 8.8.8.8 9.9.9.9; do
    if [[ "$need_ipv4" == "1" ]]; then
      records="$(resolve_domain_a_records_via_resolver "$domain" "$resolver" || true)"
      if [[ -z "$records" ]]; then
        printf '[warn] %s A %s\n' "$resolver" "$(t diag_resolver_missing)"
        DIAG_DNS_ISSUE=1
      elif [[ -n "$server_ipv4" ]] && ! dns_records_match "$server_ipv4" "$records"; then
        printf '[warn] %s A %s %s\n' "$resolver" "$(t diag_resolver_mismatch)" "$(diag_format_records "$records")"
        DIAG_DNS_ISSUE=1
      elif [[ -z "$server_ipv4" ]]; then
        printf '[info] %s A %s\n' "$resolver" "$(diag_format_records "$records")"
      else
        printf '[ok] %s A %s %s\n' "$resolver" "$(t diag_resolver_match)" "$(diag_format_records "$records")"
      fi
    fi
    if [[ "$need_ipv6" == "1" ]]; then
      records="$(resolve_domain_aaaa_records_via_resolver "$domain" "$resolver" || true)"
      if [[ -z "$records" ]]; then
        printf '[warn] %s AAAA %s\n' "$resolver" "$(t diag_resolver_missing)"
        DIAG_DNS_ISSUE=1
      elif [[ -n "$server_ipv6" ]] && ! dns_records_match "$server_ipv6" "$records"; then
        printf '[warn] %s AAAA %s %s\n' "$resolver" "$(t diag_resolver_mismatch)" "$(diag_format_records "$records")"
        DIAG_DNS_ISSUE=1
      elif [[ -z "$server_ipv6" ]]; then
        printf '[info] %s AAAA %s\n' "$resolver" "$(diag_format_records "$records")"
      else
        printf '[ok] %s AAAA %s %s\n' "$resolver" "$(t diag_resolver_match)" "$(diag_format_records "$records")"
      fi
    fi
  done
}

diag_mode_regional() {
  local mode="$1"
  local server_ipv4="$2"
  local server_ipv6="$3"
  local env_file=""
  local health_rc=0
  local entry_domain=""
  local bind_ipv4=""
  local bind_ipv6=""
  local port=""
  local front_domain=""

  case "$mode" in
    ee)
      env_file="$EE_ENV_FILE"
      ;;
    dd)
      env_file="$DD_ENV_FILE"
      ;;
    *)
      return 1
      ;;
  esac

  echo
  echo "---- ${mode} ----"
  check_mode_health "$mode" || health_rc=$?
  if [[ "$health_rc" -eq 1 ]]; then
    DIAG_LOCAL_ISSUE=1
  fi

  [[ -f "$env_file" ]] || return 0
  DIAG_ACTIVE_MODES=$((DIAG_ACTIVE_MODES + 1))

  load_mode_config "$mode" || return 1
  if [[ "$mode" == "ee" ]]; then
    entry_domain="${EE_DOMAIN:-}"
    bind_ipv4="${EE_BIND_IP-0.0.0.0}"
    bind_ipv6="${EE_BIND_IPV6:-}"
    port="${EE_PORT:-}"
    front_domain="${FRONT_DOMAIN:-}"
  else
    entry_domain="${DD_DOMAIN:-}"
    bind_ipv4="${DD_BIND_IP-0.0.0.0}"
    bind_ipv6="${DD_BIND_IPV6:-}"
    port="${DD_PORT:-}"
  fi

  printf '[info] %s: %s\n' "$(t diag_entry_domain)" "${entry_domain:-n/a}"
  printf '[info] %s: %s\n' "$(t diag_bind)" "$(format_bind_targets "${bind_ipv4:-}" "${bind_ipv6:-}" "${port:-n/a}")"
  if [[ -n "$entry_domain" ]]; then
    diag_domain_dns_view "$entry_domain" "$server_ipv4" "$server_ipv6" "$([[ -n "$bind_ipv4" ]] && echo 1 || echo 0)" "$([[ -n "$bind_ipv6" ]] && echo 1 || echo 0)"
  fi

  if [[ "$mode" == "ee" && -n "$front_domain" ]]; then
    printf '[info] %s: %s\n' "$(t diag_front_domain)" "$front_domain"
    if ! command -v openssl >/dev/null 2>&1; then
      printf '[warn] %s: openssl\n' "$(t diag_tool_missing)"
      DIAG_FRONT_ISSUE=1
    elif timeout 6 openssl s_client -connect "${front_domain}:443" -servername "${front_domain}" -verify_return_error -verify_hostname "$front_domain" </dev/null >/dev/null 2>&1; then
      printf '[ok] %s\n' "$(t diag_front_tls_ok)"
    else
      printf '[warn] %s\n' "$(t diag_front_tls_fail)"
      DIAG_FRONT_ISSUE=1
    fi
  fi
}

check_mode_health() {
  local mode="$1"
  local service_name=""
  local container_name=""
  local env_file=""
  local port=""
  local bind_ipv4=""
  local bind_ipv6=""
  local expected_image=""
  local container_port_key=""
  local ok=0
  local mode_container_running=0
  local service_restarts=0
  local container_restarts=0
  local running_image=""
  local actual_bind_ipv4=""
  local actual_bind_ipv6=""
  local actual_bind_ipv4_port=""
  local actual_bind_ipv6_port=""
  local legacy_container_name=""

  case "$mode" in
    ee)
      service_name="$EE_SERVICE_NAME"
      container_name="$EE_CONTAINER_NAME"
      env_file="$EE_ENV_FILE"
      container_port_key="3128/tcp"
      ;;
    dd)
      service_name="$DD_SERVICE_NAME"
      container_name="$DD_CONTAINER_NAME"
      env_file="$DD_ENV_FILE"
      container_port_key="443/tcp"
      ;;
    *)
      return 1
      ;;
  esac

  legacy_container_name="$(detect_legacy_running_container "$mode" || true)"
  if [[ -n "$legacy_container_name" ]]; then
    mode_container_running=1
  fi

  if [[ ! -f "$env_file" ]]; then
    if [[ "$mode_container_running" -eq 1 ]]; then
      printf '[%s] %s (%s)\n' "$mode" "$(t note_legacy_detected)" "$env_file"
      printf '[%s] %s\n' "$mode" "$(t note_legacy_migrate)"
      return 2
    fi
    printf '[%s] %s: %s\n' "$mode" "$(t hc_not_installed)" "$env_file"
    return 2
  fi

  if ! systemctl is-active --quiet "$service_name"; then
    printf '[%s] %s: %s\n' "$mode" "$(t hc_service_not_active)" "$service_name"
    ok=1
  fi

  if ! docker ps --format '{{.Names}}' | grep -qx "$container_name"; then
    printf '[%s] %s: %s\n' "$mode" "$(t hc_container_not_running)" "$container_name"
    ok=1
  fi

  load_mode_config "$mode" || return 1
  if [[ "$mode" == "ee" ]]; then
    port="${EE_PORT}"
    bind_ipv4="${EE_BIND_IP-0.0.0.0}"
    bind_ipv6="${EE_BIND_IPV6:-}"
    expected_image="${MTG_IMAGE:-}"
  else
    port="${DD_PORT}"
    bind_ipv4="${DD_BIND_IP-0.0.0.0}"
    bind_ipv6="${DD_BIND_IPV6:-}"
    expected_image="${DD_IMAGE:-}"
    if ! normalize_dd_secret "${DD_BASE_SECRET:-${DD_SECRET:-}}"; then
      printf '[%s] %s\n' "$mode" "$(t err_invalid_dd_secret)"
      ok=1
    fi
  fi

  service_restarts="$(systemctl show -p NRestarts --value "$service_name" 2>/dev/null || echo 0)"
  if [[ "$service_restarts" =~ ^[0-9]+$ ]] && ((service_restarts >= 5)); then
    printf '[%s] %s %s\n' "$mode" "$(t warn_service_restarts)" "$service_restarts"
  fi

  container_restarts="$(docker inspect -f '{{.RestartCount}}' "$container_name" 2>/dev/null || echo 0)"
  if [[ "$container_restarts" =~ ^[0-9]+$ ]] && ((container_restarts >= 5)); then
    printf '[%s] %s %s\n' "$mode" "$(t warn_container_restarts)" "$container_restarts"
  fi

  running_image="$(docker inspect -f '{{.Config.Image}}' "$container_name" 2>/dev/null || true)"
  if [[ -n "$expected_image" && -n "$running_image" && "$running_image" != "$expected_image" ]]; then
    printf '[%s] %s: %s=%s %s=%s\n' "$mode" "$(t hc_image_mismatch)" "$(t label_running)" "$running_image" "$(t label_configured)" "$expected_image"
    ok=1
  fi

  actual_bind_ipv4="$(docker_binding_ip_by_family "$container_name" "$container_port_key" "ipv4")"
  actual_bind_ipv4_port="$(docker_binding_port_by_family "$container_name" "$container_port_key" "ipv4")"
  actual_bind_ipv6="$(docker_binding_ip_by_family "$container_name" "$container_port_key" "ipv6")"
  actual_bind_ipv6_port="$(docker_binding_port_by_family "$container_name" "$container_port_key" "ipv6")"
  if [[ -n "$bind_ipv4" ]] && { [[ "$(canonical_ip "$actual_bind_ipv4" || true)" != "$(canonical_ip "$bind_ipv4" || true)" ]] || [[ "$actual_bind_ipv4_port" != "$port" ]]; }; then
    echo "[${mode}] $(t err_port_binding_mismatch)"
    echo "[${mode}] $(t label_expected)=$(format_bind_targets "$bind_ipv4" "$bind_ipv6" "$port") $(t label_actual)=$(format_bind_targets "$actual_bind_ipv4" "$actual_bind_ipv6" "${actual_bind_ipv4_port:-${actual_bind_ipv6_port:-}}")"
    ok=1
  fi
  if [[ -z "$bind_ipv4" && -n "$actual_bind_ipv4" ]]; then
    echo "[${mode}] $(t err_port_binding_mismatch)"
    echo "[${mode}] $(t label_expected)=$(format_bind_targets "$bind_ipv4" "$bind_ipv6" "$port") $(t label_actual)=$(format_bind_targets "$actual_bind_ipv4" "$actual_bind_ipv6" "${actual_bind_ipv4_port:-${actual_bind_ipv6_port:-}}")"
    ok=1
  fi
  if [[ -n "$bind_ipv6" ]] && { [[ "$(canonical_ip "$actual_bind_ipv6" || true)" != "$(canonical_ip "$bind_ipv6" || true)" ]] || [[ "$actual_bind_ipv6_port" != "$port" ]]; }; then
    echo "[${mode}] $(t err_port_binding_mismatch)"
    echo "[${mode}] $(t label_expected)=$(format_bind_targets "$bind_ipv4" "$bind_ipv6" "$port") $(t label_actual)=$(format_bind_targets "$actual_bind_ipv4" "$actual_bind_ipv6" "${actual_bind_ipv4_port:-${actual_bind_ipv6_port:-}}")"
    ok=1
  fi
  if [[ -z "$bind_ipv6" && -n "$actual_bind_ipv6" ]]; then
    echo "[${mode}] $(t err_port_binding_mismatch)"
    echo "[${mode}] $(t label_expected)=$(format_bind_targets "$bind_ipv4" "$bind_ipv6" "$port") $(t label_actual)=$(format_bind_targets "$actual_bind_ipv4" "$actual_bind_ipv6" "${actual_bind_ipv4_port:-${actual_bind_ipv6_port:-}}")"
    ok=1
  fi

  if ! port_in_use "$port"; then
    printf '[%s] %s: %s\n' "$mode" "$(t hc_port_not_listening)" "$port"
    ok=1
  fi

  if [[ "$ok" -eq 0 ]]; then
    printf '[%s] %s\n' "$mode" "$(t hc_healthy)"
    return 0
  fi
  if docker_container_exists "$container_name"; then
    echo "[${mode}] $(t note_recent_logs)"
    docker logs --tail 5 "$container_name" 2>&1 | sed "s/^/[${mode}] $(t label_log): /" || true
  fi
  return 1
}

cmd_healthcheck() {
  local hc_mode="" hc_rc=0 hc_ok=0 hc_missing=0 hc_failed=0
  while read -r hc_mode; do
    hc_rc=0
    safe_output check_mode_health "$hc_mode" || hc_rc=$?
    case "$hc_rc" in
      0) hc_ok=$((hc_ok + 1)) ;;
      2) hc_missing=$((hc_missing + 1)) ;;
      *) hc_failed=1 ;;
    esac
  done < <(selected_modes)
  if [[ "$hc_failed" -eq 1 ]]; then return 1; fi
  if [[ "$hc_ok" -eq 0 ]]; then return 2; fi
  if [[ "$hc_missing" -gt 0 && ("$DEPLOY_EE" -eq 0 || "$DEPLOY_DD" -eq 0) ]]; then return 2; fi
  return 0
}

wait_for_healthcheck() {
  local attempt
  for ((attempt = 1; attempt <= 10; attempt++)); do
    if cmd_healthcheck; then
      return 0
    fi
    if ((attempt < 10)); then
      sleep 1
    fi
  done
  return 1
}

cmd_self_heal() {
  local mode="" rc=0 failed=0 found=0
  while read -r mode; do
    rc=0
    safe_output check_mode_health "$mode" || rc=$?
    [[ "$rc" != 2 ]] || continue
    found=1
    if [[ "$rc" -ne 0 ]]; then
      t "note_attempt_restart_${mode}"
      rm -f "${CONFIG_DIR}/paused-${mode}" || return 1
      systemctl restart "$(mode_service "$mode")" || {
        failed=1
        continue
      }
      sleep 2
      safe_output check_mode_health "$mode" || failed=1
    fi
  done < <(selected_modes)
  [[ "$found" -eq 1 ]] || return 2
  return "$failed"
}

cmd_regional_diagnose() {
  local server_ipv4=""
  local server_ipv6=""
  diag_reset_state
  server_ipv4="$(diagnostic_public_address 4 || true)"
  server_ipv6="$(diagnostic_public_address 6 || true)"
  if [[ -z "$server_ipv4" && -z "$server_ipv6" ]]; then t public_unknown; fi

  echo
  t step_region_diag
  printf '[note] %s\n' "$(t diag_scope_note)"
  printf '[info] %s: %s\n' "$(t diag_server_ip)" "${server_ipv4:-n/a}"
  if [[ -n "$server_ipv6" ]]; then
    printf '[info] %s: %s\n' "$(t note_server_ipv6)" "${server_ipv6}"
  fi

  if [[ "$DEPLOY_EE" -eq 1 ]]; then
    diag_mode_regional ee "$server_ipv4" "$server_ipv6"
  fi
  if [[ "$DEPLOY_DD" -eq 1 ]]; then
    diag_mode_regional dd "$server_ipv4" "$server_ipv6"
  fi

  echo
  if [[ "$DIAG_ACTIVE_MODES" -eq 0 ]]; then
    printf '[summary] %s\n' "$(t diag_no_managed_service)"
    return 1
  fi

  if [[ "$DIAG_LOCAL_ISSUE" -eq 1 ]]; then
    printf '[summary] %s\n' "$(t diag_local_issue_first)"
  elif [[ "$DIAG_DNS_ISSUE" -eq 1 ]]; then
    printf '[summary] %s\n' "$(t diag_likely_dns_issue)"
  elif [[ "$DIAG_FRONT_ISSUE" -eq 1 ]]; then
    printf '[summary] %s\n' "$(t diag_likely_ee_front_issue)"
  else
    printf '[summary] %s\n' "$(t diag_likely_region_block)"
  fi
  printf '[note] %s\n' "$(t diag_country_probe_needed)"

  if [[ "$DIAG_DNS_ISSUE" -eq 1 ]]; then t dns_fix; fi
  if [[ "$DIAG_FRONT_ISSUE" -eq 1 ]]; then t tls_fix; fi
  if [[ "$DIAG_LOCAL_ISSUE" -eq 1 || "$DIAG_DNS_ISSUE" -eq 1 || "$DIAG_FRONT_ISSUE" -eq 1 ]]; then
    return 1
  fi
  return 0
}

cmd_uninstall() {
  manager_uninstall
}

cmd_rollback() {
  local backup_id="${1:-}"
  local backup_path=""
  local current=""

  echo
  t step_rollback
  if ! backup_path="$(resolve_backup_path "$backup_id")"; then
    if [[ -z "$backup_id" ]]; then
      t note_backup_none
    else
      t err_backup_not_found
      echo "$backup_id"
    fi
    return 1
  fi

  if [[ -z "$backup_id" ]]; then
    t note_backup_latest
  else
    t note_backup_saved
  fi
  echo "$backup_path"

  create_backup rollback || return 1
  current="$LAST_BACKUP_PATH"
  if ! restore_backup "$backup_path" || ! verify_recovery "$backup_path"; then
    recover_transaction "$current"
    return 1
  fi
  prune_backups "$BACKUP_KEEP" || return 1
  t note_rollback_done
}

cmd_migrate() {
  migrate_transaction "$@"
}

cmd_self_update() {
  local script_dir="$INSTALLER_DIR" dirty=""
  if ! git -C "$script_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    t err_self_update_not_git
    return 1
  fi
  dirty="$(git -C "$script_dir" status --porcelain)" || return 1
  [[ -z "$dirty" ]] || {
    t update_dirty
    return 1
  }
  t step_self_update
  git -C "$script_dir" pull --ff-only || return 1
  if [[ -f "${SYSTEMD_UNIT_DIR}/${MONITOR_TIMER}" ]]; then refresh_monitor_runner || return 1; fi
  t note_self_update_done
  t note_self_update_rerun
  printf 'sudo bash %q/install.sh\n' "$script_dir"
}

upgrade_tracking_ref() {
  local mode="$1"
  local current_image="$2"
  local repo=""
  local tag=""

  case "$mode" in
    ee)
      repo="nineseconds/mtg"
      tag="2"
      ;;
    dd)
      repo="telegrammessenger/proxy"
      tag="latest"
      ;;
    *)
      return 1
      ;;
  esac

  if is_valid_digest_image_ref "$current_image"; then
    repo="${current_image%@*}"
  fi

  printf '%s:%s' "$repo" "$tag"
}

resolve_upgrade_image_arg() {
  local mode="$1"
  local user_input="$2"
  local current_image="$3"
  local normalized_input=""
  local tracking_ref=""
  local resolved_digest=""

  normalized_input="${user_input//[[:space:]]/}"
  if [[ -z "$normalized_input" ]]; then
    printf '%s' "$current_image"
    return 0
  fi

  if [[ "${normalized_input,,}" == "auto" ]]; then
    tracking_ref="$(upgrade_tracking_ref "$mode" "$current_image")" || return 1
    docker pull "$tracking_ref" >/dev/null || return 1
    resolved_digest="$(docker image inspect "$tracking_ref" --format '{{index .RepoDigests 0}}' 2>/dev/null || true)"
    if ! is_valid_digest_image_ref "$resolved_digest"; then
      return 1
    fi
    printf '%s' "$resolved_digest"
    return 0
  fi

  printf '%s' "$normalized_input"
}

apply_upgrade_images() {
  local mtg_new_image="$1"
  local dd_new_image="$2"

  if [[ "$DEPLOY_EE" -eq 1 ]]; then
    upsert_env_key "$EE_ENV_FILE" "MTG_IMAGE" "$mtg_new_image" || return 1
    MTG_IMAGE="$mtg_new_image"
    write_ee_systemd_unit || return 1
  fi
  if [[ "$DEPLOY_DD" -eq 1 ]]; then
    upsert_env_key "$DD_ENV_FILE" "DD_BASE_SECRET" "$DD_BASE_SECRET" || return 1
    upsert_env_key "$DD_ENV_FILE" "DD_SECRET" "$DD_SECRET" || return 1
    upsert_env_key "$DD_ENV_FILE" "DD_IMAGE" "$dd_new_image" || return 1
    DD_IMAGE="$dd_new_image"
    write_dd_systemd_unit || return 1
  fi

  systemd_reload || return 1
  if [[ "$DEPLOY_EE" -eq 1 ]]; then
    systemctl restart "$EE_SERVICE_NAME" || return 1
  fi
  if [[ "$DEPLOY_DD" -eq 1 ]]; then
    systemctl restart "$DD_SERVICE_NAME" || return 1
  fi
  wait_for_healthcheck
}

cmd_upgrade() {
  local mtg_input="$1"
  local dd_input="$2"
  local mtg_new_image=""
  local dd_new_image=""
  local current_mtg_image=""
  local current_dd_image=""
  local backup_path=""

  echo
  t note_upgrade_scope

  # Resolve and validate every selected mode before changing persistent state.
  if [[ "$DEPLOY_EE" -eq 1 ]]; then
    [[ -f "$EE_ENV_FILE" ]] || {
      t err_not_installed_ee
      return 1
    }
    load_env_file "$EE_ENV_FILE" || return 1
    current_mtg_image="${MTG_IMAGE:-}"
    if ! mtg_new_image="$(resolve_upgrade_image_arg ee "$mtg_input" "$current_mtg_image")"; then
      printf '%s %s\n' "$(t err_invalid_mtg_image)" "${mtg_input:-auto}"
      return 1
    fi
    if [[ "${mtg_input//[[:space:]]/}" =~ ^[Aa][Uu][Tt][Oo]$ ]]; then
      printf '%s %s\n' "$(t note_using_digest)" "$mtg_new_image"
    fi
    if ! is_valid_digest_image_ref "$mtg_new_image"; then
      printf '%s %s\n' "$(t err_invalid_mtg_image)" "$mtg_new_image"
      return 1
    fi
  fi

  if [[ "$DEPLOY_DD" -eq 1 ]]; then
    [[ -f "$DD_ENV_FILE" ]] || {
      t err_not_installed_dd
      return 1
    }
    load_env_file "$DD_ENV_FILE" || return 1
    if ! normalize_dd_secret "${DD_BASE_SECRET:-${DD_SECRET:-}}"; then
      t err_invalid_dd_secret
      return 1
    fi
    current_dd_image="${DD_IMAGE:-}"
    if ! dd_new_image="$(resolve_upgrade_image_arg dd "$dd_input" "$current_dd_image")"; then
      printf '%s %s\n' "$(t err_invalid_dd_image)" "${dd_input:-auto}"
      return 1
    fi
    if [[ "${dd_input//[[:space:]]/}" =~ ^[Aa][Uu][Tt][Oo]$ ]]; then
      printf '%s %s\n' "$(t note_using_digest)" "$dd_new_image"
    fi
    if ! is_valid_digest_image_ref "$dd_new_image"; then
      printf '%s %s\n' "$(t err_invalid_dd_image)" "$dd_new_image"
      return 1
    fi
  fi

  # Pull all pinned artifacts before touching configs or restarting either service.
  if [[ "$DEPLOY_EE" -eq 1 ]]; then
    docker pull "$mtg_new_image" || return 1
  fi
  if [[ "$DEPLOY_DD" -eq 1 ]]; then
    docker pull "$dd_new_image" || return 1
  fi

  t step_backup
  create_backup "upgrade" || return 1
  backup_path="$LAST_BACKUP_PATH"
  if ! apply_upgrade_images "$mtg_new_image" "$dd_new_image"; then
    t err_upgrade_failed
    if ! restore_backup "$backup_path" || ! verify_recovery "$backup_path"; then
      t err_upgrade_rollback_failed
      echo "$backup_path"
    fi
    return 1
  fi
  prune_backups "$BACKUP_KEEP"
}

normalize_dd_secret() {
  local input="${1,,}"
  if [[ "$input" =~ ^dd[a-f0-9]{32}$ ]]; then
    DD_BASE_SECRET="${input#dd}"
    DD_SECRET="$input"
    return 0
  fi
  if [[ "$input" =~ ^[a-f0-9]{32}$ ]]; then
    DD_BASE_SECRET="$input"
    DD_SECRET="dd${input}"
    return 0
  fi
  return 1
}

command_install() {
  manager_install install
}

# ---------- terminal navigation ----------
prompt_mode_all() {
  local mode_choice=""
  ui_select mode_choice ask_oper_mode mode 3 \
    1:mode_ee_only 2:mode_dd_only 3:mode_both 0:ui_back >&2 || return 1
  case "$mode_choice" in
    1) echo ee ;;
    2) echo dd ;;
    3) echo all ;;
    0) echo back ;;
  esac
}

prompt_mode_rotate() {
  local mode_choice=""
  ui_select mode_choice ask_rotate_mode mode 1 \
    1:mode_ee_only 2:mode_dd_only 0:ui_back >&2 || return 1
  case "$mode_choice" in
    1) echo ee ;;
    2) echo dd ;;
    0) echo back ;;
  esac
}

pause_menu() {
  local _
  echo
  read -r -p "$(t menu_press_enter)" _ || return 0
  echo
}

interactive_menu() {
  manager_menu
}

main() {
  manager_main "$@"
}

INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/messages.sh
source "$INSTALLER_DIR/lib/messages.sh"
# shellcheck source=lib/management.sh
source "$INSTALLER_DIR/lib/management.sh"
# shellcheck source=lib/installer.sh
source "$INSTALLER_DIR/lib/installer.sh"
# shellcheck source=lib/operations.sh
source "$INSTALLER_DIR/lib/operations.sh"
# shellcheck source=lib/migration.sh
source "$INSTALLER_DIR/lib/migration.sh"
# shellcheck source=lib/cli.sh
source "$INSTALLER_DIR/lib/cli.sh"
# shellcheck source=lib/setup-ui.sh
source "$INSTALLER_DIR/lib/setup-ui.sh"
# shellcheck source=lib/terminal.sh
source "$INSTALLER_DIR/lib/terminal.sh"
# shellcheck source=lib/menu.sh
source "$INSTALLER_DIR/lib/menu.sh"

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
