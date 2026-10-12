#!/usr/bin/env bash
# Additional UI strings kept together so all four languages share the same keys.
extra_translation() {
  local key="$1" index=0
  local -a texts=()
  if [[ "$key" == @* ]]; then
    printf '%s\n' "${key#@}"
    return 0
  fi
  case "$key" in
    managed_scope) texts=('Applies to' '操作范围' '적용 대상' '操作対象') ;;
    mode_all_managed) texts=('All installed proxies' '全部已安装代理' '설치된 모든 프록시' '設定済みの全プロキシ') ;;
    menu_title) texts=('Dashboard' '控制台' '대시보드' 'ダッシュボード') ;;
    ui_keys) texts=('↑↓ select · ←→ move · Enter confirm · Esc back' '↑↓ 选择 · ←→ 切换 · 回车确认 · Esc 返回' '↑↓ 선택 · ←→ 이동 · Enter 확인 · Esc 뒤로' '↑↓ 選択 · ←→ 移動 · Enter 決定 · Esc 戻る') ;;
    ui_keys_plain) texts=('Number + Enter · 0 / q back · r refresh' '编号 + 回车选择 · 0 / q 返回 · r 刷新' '번호 + Enter 선택 · 0 / q 뒤로 · r 새로고침' '番号 + Enter 選択 · 0 / q 戻る · r 更新') ;;
    ui_shortcuts) texts=('Number + Enter · r refresh · q exit' '编号 + 回车 · r 刷新 · q 退出' '번호 + Enter · r 새로고침 · q 종료' '番号 + Enter · r 更新 · q 終了') ;;
    home_connect) texts=('Connection info' '连接信息' '연결 정보' '接続情報') ;;
    home_health) texts=('Check & repair' '检查与修复' '점검 및 복구' '点検と修復') ;;
    home_config) texts=('Settings & services' '配置与运行' '설정 및 서비스' '設定とサービス') ;;
    home_updates) texts=('Backups & updates' '备份与更新' '백업 및 업데이트' 'バックアップと更新') ;;
    home_monitor) texts=('Automatic care' '自动维护' '자동 관리' '自動メンテナンス') ;;
    home_more) texts=('More settings' '更多设置' '추가 설정' 'その他の設定') ;;
    home_install) texts=('Set up a proxy' '开始安装' '프록시 설치' 'プロキシを設定') ;;
    home_migrate) texts=('Import existing proxy' '接管已有代理' '기존 프록시 가져오기' '既存プロキシを移行') ;;
    migrate_apply) texts=('Import and keep existing secrets' '确认接管，保留原有密钥' '기존 키를 유지하고 가져오기' '既存のキーを保持して移行') ;;
    home_empty) texts=('Welcome. No proxy is installed yet.' '还没有代理，从安装开始。' '아직 프록시가 없습니다. 설치부터 시작하세요.' 'プロキシは未設定です。まず設定しましょう。') ;;
    home_empty_hint) texts=('Enter a public address and port; other options have defaults.' '填入公网地址和端口，其余使用默认配置。' '공개 주소와 포트만 입력하면 됩니다.' '公開アドレスとポートを入力します。') ;;
    hint_home_connect) texts=('Usable links and local QR codes' '查看链接与二维码' '연결 링크와 로컬 QR' 'リンクとローカル QR') ;;
    hint_home_health) texts=('Check health and solve problems' '检查状态，处理连接故障' '상태 점검 및 문제 해결' '状態点検と問題の解決') ;;
    hint_home_config) texts=('Address, port, restart and logs' '修改地址、端口或重启' '주소, 포트, 재시작 및 로그' 'アドレス、ポート、再起動') ;;
    hint_home_updates) texts=('Upgrade or restore a backup' '更新镜像或恢复备份' '업데이트 또는 백업 복원' '更新やバックアップの復元') ;;
    hint_home_monitor) texts=('Scheduled checks and repairs' '开启定时检查与修复' '예약 점검 및 복구' '定期的な点検と修復') ;;
    hint_home_more) texts=('Language, help and advanced tools' '语言、帮助与高级操作' '언어, 도움말 및 고급 기능' '言語、ヘルプ、高度な操作') ;;
    hint_home_install) texts=('Address and port are all you need' '只需填写地址和端口' '주소와 포트만 입력' 'アドレスとポートを入力') ;;
    hint_home_migrate) texts=('Keep an existing proxy'\''s secret' '保留已有代理的密钥' '기존 프록시의 키 유지' '既存のキーを保持') ;;
    choose_proxy) texts=('Choose a proxy' '选择要操作的代理' '프록시 선택' 'プロキシを選択') ;;
    mode_fake_tls) texts=('FakeTLS / EE (recommended)' 'FakeTLS / EE（推荐）' 'FakeTLS / EE (권장)' 'FakeTLS / EE（推奨）') ;;
    mode_padding) texts=('Padding / DD' 'Padding / DD' 'Padding / DD' 'Padding / DD') ;;
    mode_both_friendly) texts=('Both EE and DD' '同时部署 EE 与 DD' 'EE 및 DD 모두' 'EE と DD の両方') ;;
    operation_progress) texts=('Working…' '正在执行…' '처리 중…' '処理中…') ;;
    operation_done) texts=('Done. Review the results above.' '已完成，请查看上方结果。' '완료. 위 결과를 확인하세요.' '完了。上の結果を確認してください。') ;;
    operation_problem) texts=('Could not complete. See the details above.' '未能完成，请查看上方原因。' '완료하지 못했습니다. 위 내용을 확인하세요.' '完了できませんでした。上の原因を確認してください。') ;;
    connection_actions) texts=('Enter: back · 1 + Enter: QR codes' '回车返回 · 输入 1 回车显示二维码' 'Enter: 뒤로 · 1 + Enter: QR 표시' 'Enter: 戻る · 1 + Enter: QR 表示') ;;
    health_actions) texts=('Enter: back · 1: repair · 2: network diagnosis' '回车返回 · 1 修复故障 · 2 网络诊断：' 'Enter: 뒤로 · 1 복구 · 2 네트워크 점검:' 'Enter: 戻る · 1 修復 · 2 ネットワーク診断：') ;;
    config_basic) texts=('Change address and port' '修改地址与端口' '주소 및 포트 변경' 'アドレスとポートを変更') ;;
    update_auto) texts=('Upgrade proxy (latest image)' '升级代理（自动获取最新镜像）' '프록시 업데이트 (최신 이미지)' 'プロキシ更新（最新イメージ）') ;;
    monitor_recommended) texts=('Enable with recommended settings' '开启自动维护（推荐配置）' '권장 설정으로 활성화' '推奨設定で有効化') ;;
    monitor_custom) texts=('Custom check interval' '自定义检查间隔' '점검 간격 변경' '点検間隔を変更') ;;
    advanced_actions) texts=('Advanced operations' '高级操作' '고급 기능' '高度な操作') ;;
    add_proxy) texts=('Add or reinstall a proxy' '添加或重新安装代理' '프록시 추가 또는 재설치' 'プロキシを追加・再設定') ;;
    setup_mode) texts=('1 · Choose proxy type' '1 · 选择代理类型' '1 · 프록시 종류 선택' '1 · プロキシの種類を選択') ;;
    setup_address_hint) texts=('Use your VPS public IP or a domain pointing to it.' '填写 VPS 公网 IP，或已经解析到它的域名。' 'VPS 공개 IP 또는 연결된 도메인을 입력하세요.' 'VPS の公開 IP または対応するドメインを入力します。') ;;
    setup_value_hint) texts=('Enter keeps the value · 0 goes back · q cancels' '回车保留当前值 · 0 返回上一步 · q 取消' 'Enter 유지 · 0 이전 · q 취소' 'Enter 保持 · 0 前へ · q 取消') ;;
    setup_review) texts=('Ready to apply' '确认配置' '설정 확인' '設定を確認') ;;
    setup_apply) texts=('Start installation / apply settings' '开始安装 / 保存配置' '설치 시작 / 설정 저장' '設定を適用') ;;
    setup_edit) texts=('Edit address or port' '修改地址或端口' '주소 또는 포트 수정' 'アドレスやポートを編集') ;;
    setup_advanced) texts=('Advanced options (optional)' '高级选项（可选）' '고급 옵션 (선택)' '高度な設定（任意）') ;;
    setup_optional_hint) texts=('Enter keeps it · - clears it · 0 returns' '回车保留 · - 清空 · 0 返回' 'Enter 유지 · - 비우기 · 0 뒤로' 'Enter 保持 · - 消去 · 0 戻る') ;;
    setup_protocol) texts=('Proxy type' '代理类型' '프록시 종류' 'プロキシの種類') ;;
    field_front) texts=('HTTPS cover domain' '伪装域名（HTTPS）' 'HTTPS 위장 도메인' 'HTTPS 偽装ドメイン') ;;
    status_image) texts=('Image' '镜像' '이미지' 'イメージ') ;;
    status_version) texts=('Version' '版本' '버전' 'バージョン') ;;
    status_since) texts=('Active since' '本次启动时间' '활성 시작 시각' '起動時刻') ;;
    status_resources) texts=('CPU / memory / network' 'CPU / 内存 / 网络' 'CPU / 메모리 / 네트워크' 'CPU / メモリ / ネットワーク') ;;
    wizard_presets) texts=('Use :presets for domain or port suggestions.' '域名或端口可输入 :presets 选择常用值。' '도메인 또는 포트 추천은 :presets를 입력하세요.' 'ドメインやポート候補には :presets を入力してください。') ;;
    systemd_required) texts=('PID 1 must be systemd to manage services. Run on a supported VPS.' '需要 systemd 作为 PID 1 才能管理服务，请在支持的 VPS 上运行。' '서비스 관리에는 systemd PID 1이 필요합니다. 지원되는 VPS에서 실행하세요.' 'サービス管理には systemd PID 1 が必要です。対応する VPS で実行してください。') ;;
    update_dirty) texts=('Repository has local changes. Commit or preserve them before self-update.' '仓库有本地变更，请先提交或保存，再执行自更新。' '로컬 변경 사항을 커밋하거나 보관한 후 업데이트하세요.' 'ローカル変更をコミットまたは保存してから更新してください。') ;;
    already_managed) texts=('Selected mode is already managed. Use configure or upgrade.' '所选模式已由脚本托管，请使用配置或升级。' '이미 관리 중인 모드입니다. 설정 또는 업그레이드를 사용하세요.' '管理中のモードです。設定または更新を使用してください。') ;;
    legacy_retained) texts=('Stopped legacy container retained for client verification:' '已保留停止的旧容器，方便验证客户端连接后清理：' '클라이언트 확인을 위해 중지한 기존 컨테이너를 보관했습니다:' 'クライアント確認のため停止した旧コンテナを保持しました：') ;;
    operation_failed) texts=('Operation failed, exit code' '操作失败，退出码' '작업 실패, 종료 코드' '操作失敗、終了コード') ;;
    backup_prune) texts=('Remove old backups' '清理旧备份' '오래된 백업 삭제' '古いバックアップを削除') ;;
    backup_list) texts=('List backups' '列出备份' '백업 목록' 'バックアップ一覧') ;;
    backup_restore) texts=('Select and restore a backup' '选择备份并回滚' '백업 선택 및 복원' 'バックアップを選択して復元') ;;
    mode_help) texts=('ee: FakeTLS; dd: padding; all: both. Choose the mode supported by your Telegram client.' 'ee 使用 FakeTLS；dd 使用 padding；all 同时部署。请选择客户端支持的模式。' 'ee: FakeTLS; dd: padding; all: 둘 다. Telegram 클라이언트가 지원하는 모드를 선택하세요.' 'ee: FakeTLS、dd: padding、all: 両方。クライアント対応のモードを選択してください。') ;;
    menu_config) texts=('Change settings' '修改配置' '설정 변경' '設定変更') ;;
    menu_links) texts=('Connection information' '连接信息' '연결 정보' '接続情報') ;;
    menu_backups) texts=('Backup history' '备份历史' '백업 기록' 'バックアップ履歴') ;;
    menu_status) texts=('Status and resources' '状态与资源' '상태 및 리소스' '状態とリソース') ;;
    menu_services) texts=('Start / stop / restart / logs' '启动 / 停止 / 重启 / 日志' '시작 / 중지 / 재시작 / 로그' '起動・停止・再起動・ログ') ;;
    menu_monitor) texts=('Scheduled health checks' '定时健康检查' '예약 상태 점검' '定期ヘルスチェック') ;;
    menu_language) texts=('Language' '界面语言' '언어' '言語') ;;
    field_mode) texts=('Mode (ee / dd / all)' '模式（ee / dd / all）' '모드 (ee / dd / all)' 'モード (ee / dd / all)') ;;
    field_host) texts=('Public domain or IP' '公网域名或 IP' '공개 도메인 또는 IP' '公開ドメインまたは IP') ;;
    field_port) texts=('Port' '端口' '포트' 'ポート') ;;
    field_bind4) texts=('Local IPv4 bind' '本机 IPv4 绑定地址' '로컬 IPv4 바인딩' 'ローカル IPv4 バインド') ;;
    field_bind6) texts=('Local IPv6 bind (empty disables it)' '本机 IPv6 绑定（空值禁用）' '로컬 IPv6 바인딩 (비우면 비활성화)' 'ローカル IPv6 バインド（空で無効）') ;;
    field_public4) texts=('Public IPv4 (optional, for NAT)' '公网 IPv4（可选，适用于 NAT）' '공개 IPv4 (선택, NAT용)' '公開 IPv4（任意、NAT 用）') ;;
    field_public6) texts=('Public IPv6 (optional)' '公网 IPv6（可选）' '공개 IPv6 (선택)' '公開 IPv6（任意）') ;;
    field_bbr) texts=('Enable BBR (yes / no)' '启用 BBR（yes / no）' 'BBR 활성화 (yes / no)' 'BBR を有効化 (yes / no)') ;;
    field_firewall) texts=('Firewall (keep / enable)' '防火墙（keep 保持 / enable 启用）' '방화벽 (keep / enable)' 'ファイアウォール (keep / enable)') ;;
    wizard_hint) texts=('Enter keeps the value; - clears it; :back goes back; :cancel exits.' '回车保留当前值；- 清空；:back 上一步；:cancel 取消。' 'Enter 유지; - 비우기; :back 이전; :cancel 취소.' 'Enter で保持、- で消去、:back で前へ、:cancel で取消。') ;;
    review) texts=('Review changes' '检查变更' '변경 검토' '変更を確認') ;;
    apply) texts=('Apply changes' '执行变更' '변경 적용' '変更を適用') ;;
    edit) texts=('Edit inputs' '返回修改' '입력 수정' '入力を修正') ;;
    cancel) texts=('Cancel' '取消' '취소' '取消') ;;
    confirm) texts=('Apply these changes? [y/N]: ' '确认执行这些变更？[y/N]：' '변경을 적용할까요? [y/N]: ' '変更を適用しますか？[y/N]: ') ;;
    invalid) texts=('Invalid value.' '输入不合法。' '잘못된 값입니다.' '値が不正です。') ;;
    failure) texts=('Operation failed. Previous configuration was restored where possible.' '操作失败，已尝试恢复原配置。' '작업 실패. 가능한 경우 이전 설정을 복원했습니다.' '操作に失敗し、可能な範囲で元の設定を復元しました。') ;;
    recovery_failed) texts=('Recovery failed; restore from this backup:' '自动恢复失败，请使用此备份恢复：' '복구 실패. 이 백업으로 복원하세요:' '復元に失敗しました。このバックアップを使用してください：') ;;
    not_installed) texts=('Selected mode is not managed by this installer.' '所选模式尚未由本脚本托管。' '선택 모드는 이 설치 프로그램에서 관리하지 않습니다.' '選択モードはこのスクリプトの管理対象外です。') ;;
    secret_changed) texts=('Changing the FakeTLS domain also rotates its secret and connection links.' '更换 FakeTLS 域名会同时轮换密钥，需要更新连接链接。' 'FakeTLS 도메인을 바꾸면 시크릿과 연결 링크도 바뀝니다.' 'FakeTLS ドメイン変更でシークレットと接続リンクも変わります。') ;;
    masked) texts=('Secret hidden. Use --show-secret to reveal links, or --qr for a local QR code.' '密钥已隐藏。使用 --show-secret 显示完整链接，或 --qr 生成本地二维码。' '시크릿 숨김. --show-secret으로 링크 표시, --qr로 로컬 QR 생성.' 'シークレット非表示。--show-secret でリンク表示、--qr でローカル QR 作成。') ;;
    show_links) texts=('Show full connection links' '显示完整连接链接' '전체 연결 링크 표시' '接続リンクを表示') ;;
    show_qr) texts=('Show local QR codes' '显示本地二维码' '로컬 QR 표시' 'ローカル QR 表示') ;;
    qr_missing) texts=('qrencode is required; install it with apt-get install qrencode.' '需要 qrencode；请执行 apt-get install qrencode 安装。' 'qrencode 필요: apt-get install qrencode.' 'qrencode が必要です：apt-get install qrencode。') ;;
    backup_hint) texts=('Choose a backup number; 0 cancels.' '选择备份编号；0 取消。' '백업 번호 선택; 0 취소.' 'バックアップ番号を選択、0 で取消。') ;;
    backup_keep) texts=('Keep backups (1-1000)' '保留备份数量（1-1000）' '백업 보관 개수 (1-1000)' 'バックアップ保持数（1-1000）') ;;
    start) texts=('Start' '启动' '시작' '起動') ;;
    stop) texts=('Stop' '停止' '중지' '停止') ;;
    restart) texts=('Restart' '重启' '재시작' '再起動') ;;
    logs) texts=('Recent logs' '最近日志' '최근 로그' '最近のログ') ;;
    enable) texts=('Enable' '启用' '활성화' '有効化') ;;
    disable) texts=('Disable' '关闭' '비활성화' '無効化') ;;
    monitor_interval) texts=('Check interval in minutes (1-1440)' '检查间隔，分钟（1-1440）' '점검 간격, 분 (1-1440)' '点検間隔、分（1-1440）') ;;
    monitor_limits) texts=('Automatic repair uses limited retries and a cooldown; images are never auto-upgraded.' '自动修复有重试次数与冷却时间限制，镜像不会自动升级。' '자동 복구는 제한된 재시도와 대기 시간을 사용하며 이미지 자동 업그레이드는 없습니다.' '自動修復は再試行回数と待機時間を制限し、イメージは自動更新しません。') ;;
    monitor_cooldown) texts=('Repair is cooling down or retry limit was reached.' '正在冷却或已达到修复次数限制。' '복구 대기 중이거나 재시도 제한에 도달했습니다.' '待機中、または修復回数の上限に達しました。') ;;
    public_unknown) texts=('Public IP is unknown. Set public IPv4/IPv6 for NAT; local bind addresses are checked separately.' '公网 IP 未知。NAT 环境可填写公网 IPv4/IPv6；绑定地址单独检查。' '공개 IP 미확인. NAT 환경에서는 공개 IPv4/IPv6를 지정하세요. 바인딩은 별도로 점검합니다.' '公開 IP 不明。NAT 環境では公開 IPv4/IPv6 を指定してください。バインドは別に点検します。') ;;
    dns_fix) texts=('Check DNS A/AAAA records and cloud firewall rules; test from a Telegram client.' '检查 DNS A/AAAA 记录与云防火墙规则，并从 Telegram 客户端测试。' 'DNS A/AAAA와 클라우드 방화벽을 확인하고 Telegram 클라이언트에서 테스트하세요.' 'DNS A/AAAA とクラウドのファイアウォールを確認し、Telegram クライアントでテストしてください。') ;;
    tls_fix) texts=('TLS failed or timed out. Verify the HTTPS domain or choose another front domain.' 'TLS 失败或超时。请检查 HTTPS 域名，或更换 FakeTLS 域名。' 'TLS 실패 또는 시간 초과. HTTPS 도메인을 확인하거나 교체하세요.' 'TLS 失敗または時間切れ。HTTPS ドメインを確認するか変更してください。') ;;
    uninstall_scope) texts=('Removes selected services, containers and proxy configuration. Backups, packages and existing firewall rules remain.' '删除所选服务、容器和代理配置；保留备份、软件包与已有防火墙规则。' '선택 서비스, 컨테이너, 설정을 삭제합니다. 백업, 패키지, 방화벽 규칙은 유지됩니다.' '選択サービス、コンテナ、設定を削除します。バックアップ、パッケージ、既存ファイアウォールは保持します。') ;;
    missing_argument) texts=('Missing or unsupported argument:' '参数缺失或不受支持：' '인수가 없거나 지원되지 않습니다:' '引数が不足、または未対応です：') ;;
    root_needed) texts=('This operation requires root.' '此操作需要 root 权限。' '이 작업에는 root 권한이 필요합니다.' 'この操作には root 権限が必要です。') ;;
    no_changes) texts=('Dry run; no changes applied.' '试运行，未执行变更。' '시험 실행: 변경 없음.' 'ドライラン。変更なし。') ;;
    done) texts=('Completed.' '已完成。' '완료.' '完了。') ;;
    dependency) texts=('Required command is missing:' '缺少必需命令：' '필수 명령 없음:' '必要なコマンドがありません：') ;;
    *) return 1 ;;
  esac
  case "$UI_LANG" in zh) index=1 ;; ko) index=2 ;; ja) index=3 ;; esac
  printf '%s\n' "${texts[index]}"
}
