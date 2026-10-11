#!/usr/bin/env bash
read_settings_file() {
  local file="$1" line="" key="" value=""
  [[ -r "$file" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" == *=* ]] || return 1
    key="${line%%=*}" value="${line#*=}"
    case "$key" in
      MODE) REQUEST[mode]="$value" ;;
      EE_DOMAIN | DD_DOMAIN | FRONT_DOMAIN | EE_PORT | DD_PORT | EE_BIND_IP | EE_BIND_IPV6 | DD_BIND_IP | DD_BIND_IPV6 | \
        PUBLIC_IPV4 | PUBLIC_IPV6 | ENABLE_BBR | FIREWALL_POLICY) REQUEST["$key"]="$value" ;;
      *)
        printf '%s %s\n' "$(t missing_argument)" "$key" >&2
        return 1
        ;;
    esac
  done <"$file"
}

cli_usage() {
  usage
  cat <<'EOF'
  install.sh install|configure [--mode ee|dd|all] [--config FILE] [--non-interactive] [--yes] [--dry-run]
    --ee-domain HOST --dd-domain HOST --ee-port PORT --dd-port PORT --front-domain HOST
    --ee-bind-ip IP --dd-bind-ip IP --ee-bind-ipv6 IP --dd-bind-ipv6 IP
    --public-ipv4 IP --public-ipv6 IP --bbr yes|no --firewall keep|enable --reinstall
    --domain HOST --port PORT --bind-ip IP --bind-ipv6 IP (single mode only)
  install.sh status [--mode ee|dd|all] [--json]
  install.sh links [--mode ee|dd|all] [--show-secret] [--qr]
  install.sh service --mode ee|dd|all --action start|stop|restart|logs [--lines 50]
  install.sh backups [--keep 20 --prune --yes]
  install.sh monitor --action status|enable|disable [--interval 5] [--max-retries 3] [--cooldown 300] [--yes]
  install.sh regional-diagnose [--mode ee|dd|all] [--public-ipv4 IP] [--public-ipv6 IP] [--report FILE]
  install.sh rotate-secret --mode ee|dd [--secret auto|SECRET | --secret-file FILE] [--yes] [--dry-run]
  install.sh language --lang en|zh|ko|ja
  --lang en|zh|ko|ja is supported by every command.
  healthcheck [--json]: 0=healthy, 1=unhealthy, 2=no managed mode. --mode all skips absent modes.
EOF
}

cli_option_allowed() {
  local allowed=""
  [[ "$2" == --lang ]] && return 0
  case "$1" in
    menu) allowed="" ;;
    language) allowed="--dry-run" ;;
    install | configure)
      allowed="--mode --config --non-interactive --yes --dry-run --domain --port --bind-ip --bind-ipv6 --ee-domain --dd-domain --ee-port --dd-port --ee-bind-ip --dd-bind-ip --ee-bind-ipv6 --dd-bind-ipv6 --front-domain --public-ipv4 --public-ipv6 --bbr --firewall --reinstall --show-secret --qr"
      ;;
    status | healthcheck) allowed="--mode --json" ;;
    links) allowed="--mode --show-secret --qr" ;;
    service) allowed="--mode --action --lines --dry-run" ;;
    monitor) allowed="--mode --action --interval --max-retries --cooldown --yes --dry-run" ;;
    watchdog) allowed="--mode --max-retries --cooldown --dry-run" ;;
    backups) allowed="--keep --prune --yes --dry-run" ;;
    regional-diagnose) allowed="--mode --public-ipv4 --public-ipv6 --report" ;;
    rotate-secret) allowed="--mode --secret --secret-file --front-domain --yes --non-interactive --dry-run --show-secret --qr" ;;
    upgrade) allowed="--mode --mtg-image --dd-image --yes --dry-run" ;;
    rollback) allowed="--mode --backup-id --yes --dry-run" ;;
    uninstall) allowed="--mode --yes --non-interactive --dry-run" ;;
    migrate) allowed="--mode --ee-domain --dd-domain --front-domain --yes --dry-run" ;;
    self-heal) allowed="--mode --dry-run" ;;
    self-update) allowed="--dry-run" ;;
  esac
  [[ " $allowed " == *" $2 "* ]]
}

manager_main() {
  local cmd="" option="" value="" key="" mode=all json=0 action=status interval=5 retries=3 cooldown=300 lines=50
  local backup="" mtg="" dd="" secret="" front="" report="" prune=0 explicit_lang=0 rc=0
  local -a remaining=()
  REQUEST=()
  DRY_RUN=0 ASSUME_YES=0 NON_INTERACTIVE=0 SHOW_SECRET=0 SHOW_QR=0 REINSTALL=0 BACKUP_KEEP=20
  load_preferences || true
  # Accept language before the command as well as after it.
  while [[ "${1:-}" == --lang ]]; do
    [[ "$#" -ge 2 ]] || {
      t missing_argument >&2
      return 2
    }
    UI_LANG="$2" explicit_lang=1
    shift 2
  done
  cmd="${1:-menu}"
  if (($#)); then shift; fi
  case "$cmd" in -h | --help | help)
    cli_usage
    return 0
    ;;
  self_update) cmd=self-update ;; self_heal) cmd=self-heal ;; rotate_secret) cmd=rotate-secret ;; regional_diagnose) cmd=regional-diagnose ;; esac
  case "$cmd" in menu | install | configure | status | links | service | backups | monitor | watchdog | \
    language | healthcheck | self-heal | self-update | migrate | rollback | uninstall | upgrade | rotate-secret | regional-diagnose) ;;
  *)
    printf '%s %s\n' "$(t err_unknown_cmd)" "$cmd" >&2
    return 2
    ;;
  esac
  # Settings files are read first; explicit flags always take precedence.
  remaining=("$@")
  while (($#)); do
    if [[ "$1" == --config ]]; then
      [[ "$cmd" == install || "$cmd" == configure ]] || {
        t missing_argument >&2
        return 2
      }
      [[ "$#" -ge 2 ]] || {
        t missing_argument >&2
        return 2
      }
      read_settings_file "$2" || return 2
      shift 2
    else shift; fi
  done
  set -- "${remaining[@]}"
  while (($#)); do
    option="$1"
    cli_option_allowed "$cmd" "$option" || {
      printf "%s %s\n" "$(t missing_argument)" "$option" >&2
      return 2
    }
    case "$option" in
      --yes)
        ASSUME_YES=1
        shift
        continue
        ;;
      --non-interactive)
        NON_INTERACTIVE=1
        shift
        continue
        ;;
      --dry-run)
        DRY_RUN=1 NON_INTERACTIVE=1
        shift
        continue
        ;;
      --json)
        json=1
        shift
        continue
        ;;
      --show-secret)
        SHOW_SECRET=1
        shift
        continue
        ;;
      --qr)
        SHOW_QR=1
        shift
        continue
        ;;
      --reinstall)
        REINSTALL=1
        shift
        continue
        ;;
      --prune)
        prune=1
        shift
        continue
        ;;
    esac
    [[ "$#" -ge 2 && "$2" != --* ]] || {
      printf '%s %s\n' "$(t missing_argument)" "$option" >&2
      return 2
    }
    value="$2"
    case "$option" in
      --lang) UI_LANG="$value" explicit_lang=1 ;;
      --mode)
        mode="$value"
        REQUEST[mode]="$value"
        ;;
      --config) : ;;
      --ee-domain) REQUEST[EE_DOMAIN]="$value" ;;
      --dd-domain) REQUEST[DD_DOMAIN]="$value" ;;
      --front-domain)
        REQUEST[FRONT_DOMAIN]="$value"
        front="$value"
        ;;
      --ee-port) REQUEST[EE_PORT]="$value" ;;
      --dd-port) REQUEST[DD_PORT]="$value" ;;
      --ee-bind-ip) REQUEST[EE_BIND_IP]="$value" ;;
      --dd-bind-ip) REQUEST[DD_BIND_IP]="$value" ;;
      --ee-bind-ipv6) REQUEST[EE_BIND_IPV6]="$value" ;;
      --dd-bind-ipv6) REQUEST[DD_BIND_IPV6]="$value" ;;
      --public-ipv4) REQUEST[PUBLIC_IPV4]="$value" ;;
      --public-ipv6) REQUEST[PUBLIC_IPV6]="$value" ;;
      --bbr) REQUEST[ENABLE_BBR]="$value" ;;
      --firewall) REQUEST[FIREWALL_POLICY]="$value" ;;
      --domain | --port | --bind-ip | --bind-ipv6) REQUEST["$option"]="$value" ;;
      --mtg-image) mtg="$value" ;;
      --dd-image) dd="$value" ;;
      --backup-id) backup="$value" ;;
      --secret) secret="$value" ;;
      --secret-file)
        [[ -f "$value" && -r "$value" ]] || return 2
        [[ "$(stat -c %a "$value")" =~ ^[046]00$ ]] || {
          t invalid >&2
          return 2
        }
        secret="$(cat "$value")"
        ;;
      --action) action="$value" ;;
      --interval) interval="$value" ;;
      --max-retries) retries="$value" ;;
      --cooldown) cooldown="$value" ;;
      --lines) lines="$value" ;;
      --keep) BACKUP_KEEP="$value" ;;
      --report) report="$value" ;;
      *)
        printf '%s %s\n' "$(t missing_argument)" "$option" >&2
        return 2
        ;;
    esac
    shift 2
  done
  case "$UI_LANG" in en | zh | ko | ja) ;; *)
    t invalid >&2
    return 2
    ;;
  esac
  mode="${REQUEST[mode]:-$mode}"
  set_mode_flags "$mode" || return 2
  for option in --domain --port --bind-ip --bind-ipv6; do
    [[ -v "REQUEST[$option]" ]] || continue
    [[ "$mode" == ee || "$mode" == dd ]] || {
      t invalid >&2
      return 2
    }
    case "$option" in --domain) key="${mode^^}_DOMAIN" ;; --port) key="${mode^^}_PORT" ;; --bind-ip) key="${mode^^}_BIND_IP" ;; --bind-ipv6) key="${mode^^}_BIND_IPV6" ;; esac
    REQUEST["$key"]="${REQUEST[$option]}"
    unset 'REQUEST[$option]'
  done
  PUBLIC_IPV4="${REQUEST[PUBLIC_IPV4]:-}" PUBLIC_IPV6="${REQUEST[PUBLIC_IPV6]:-}"
  [[ "$BACKUP_KEEP" =~ ^[0-9]{1,4}$ ]] && ((10#$BACKUP_KEEP >= 1 && 10#$BACKUP_KEEP <= 1000)) || return 2
  if [[ "$cmd" == service ]]; then
    case "$action" in start | stop | restart | logs) ;; *)
      t invalid >&2
      return 2
      ;;
    esac
    [[ "$lines" =~ ^[0-9]{1,4}$ ]] && ((10#$lines >= 1 && 10#$lines <= 1000)) || return 2
  fi
  if [[ "$cmd" == monitor ]]; then
    case "$action" in status | enable | disable) ;; *)
      t invalid >&2
      return 2
      ;;
    esac
  fi
  if [[ "$cmd" == monitor || "$cmd" == watchdog ]]; then
    [[ "$interval" =~ ^[0-9]{1,4}$ ]] && ((10#$interval >= 1 && 10#$interval <= 1440)) || return 2
    [[ "$retries" =~ ^[0-9]{1,2}$ ]] && ((10#$retries >= 1 && 10#$retries <= 10)) || return 2
    [[ "$cooldown" =~ ^[0-9]{1,5}$ ]] && ((10#$cooldown >= 60 && 10#$cooldown <= 86400)) || return 2
  fi
  valid_field PUBLIC_IPV4 "$PUBLIC_IPV4" && valid_field PUBLIC_IPV6 "$PUBLIC_IPV6" || return 2
  # Dry runs and read-only commands never create a lock or change preferences.
  case "$cmd" in
    menu | install | configure | service | monitor | watchdog | language | self-heal | self-update | migrate | rollback | uninstall | upgrade | rotate-secret)
      if [[ "$DRY_RUN" -eq 0 && ("$cmd" != service || "$action" != logs) && ("$cmd" != monitor || "$action" != status) ]]; then
        require_root || return 1
        acquire_run_lock || return 1
      fi
      ;;
    backups) if [[ "$prune" -eq 1 && "$DRY_RUN" -eq 0 ]]; then
      require_root || return 1
      acquire_run_lock || return 1
    fi ;;
  esac
  case "$cmd" in
    menu)
      if [[ "$explicit_lang" -eq 1 ]]; then save_preferences || return 1; fi
      interactive_menu
      ;;
    install | configure) manager_install "$cmd" ;;
    status) cmd_status "$json" ;;
    links) cmd_links "$SHOW_SECRET" "$SHOW_QR" ;;
    healthcheck) if [[ "$json" -eq 1 ]]; then healthcheck_json; else cmd_healthcheck; fi ;;
    regional-diagnose) cmd_diagnose_report "$report" ;;
    service)
      if [[ "$DRY_RUN" -eq 1 ]]; then
        printf '%s %s\n' "$mode" "$action"
        t no_changes
      else cmd_service "$action" "$lines"; fi
      ;;
    backups)
      cmd_backups
      if [[ "$prune" -eq 1 ]]; then
        printf '%s: %s\n' "$(t backup_keep)" "$BACKUP_KEEP"
        if [[ "$DRY_RUN" -eq 1 ]]; then t no_changes; else confirm_action && prune_backups "$BACKUP_KEEP" && save_preferences; fi
      fi
      ;;
    monitor)
      case "$action" in
        status) monitor_status ;;
        enable) monitor_enable "$interval" "$retries" "$cooldown" ;;
        disable) if [[ "$DRY_RUN" -eq 1 ]]; then t no_changes; else confirm_action && monitor_disable; fi ;;
        *)
          t invalid
          return 2
          ;;
      esac
      ;;
    watchdog) if [[ "$DRY_RUN" -eq 1 ]]; then t no_changes; else cmd_watchdog "$retries" "$cooldown"; fi ;;
    language) if [[ "$DRY_RUN" -eq 1 ]]; then t no_changes; else save_preferences; fi ;;
    self-heal) if [[ "$DRY_RUN" -eq 1 ]]; then t no_changes; else cmd_self_heal; fi ;;
    self-update) if [[ "$DRY_RUN" -eq 1 ]]; then t no_changes; else cmd_self_update; fi ;;
    migrate)
      if [[ "$DRY_RUN" -eq 1 ]]; then
        t step_migrate
        t no_changes
      else confirm_action && cmd_migrate "${REQUEST[EE_DOMAIN]:-}" "${REQUEST[DD_DOMAIN]:-}" "$front"; fi
      ;;
    rollback)
      backup="$(resolve_backup_path "$backup")" || {
        t err_backup_not_found
        return 1
      }
      printf '%s %s\n' "$(t step_rollback)" "$backup"
      if [[ "$DRY_RUN" -eq 1 ]]; then t no_changes; else confirm_action && cmd_rollback "$backup"; fi
      ;;
    uninstall) manager_uninstall ;;
    upgrade)
      printf '%s: %s\nEE: %s\nDD: %s\n' "$(t menu_upgrade)" "$mode" "${mtg:-unchanged}" "${dd:-unchanged}"
      if [[ "$DRY_RUN" -eq 1 ]]; then t no_changes; else confirm_action && cmd_upgrade "$mtg" "$dd"; fi
      ;;
    rotate-secret) cmd_rotate_secret "$mode" "$secret" "$front" ;;
  esac
  rc=$?
  return "$rc"
}
