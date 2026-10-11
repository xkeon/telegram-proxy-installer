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
    field_front) texts=('FakeTLS HTTPS domain' 'FakeTLS HTTPS 域名' 'FakeTLS HTTPS 도메인' 'FakeTLS HTTPS ドメイン') ;;
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
