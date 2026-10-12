#!/usr/bin/env bash
MENU_CANCELLED=0
menu_run() {
  local result=0
  MENU_CANCELLED=0
  if [[ "$1" != manager_install ]]; then
    printf '\n%s%s%s\n' "$UI_ACCENT" "$(t operation_progress)" "$UI_RESET"
  fi
  "$@" || result=$?
  if [[ "$MENU_CANCELLED" -eq 1 ]]; then return 0; fi
  if [[ "$result" -eq 0 && "$1" == manager_install && "$CHECK_WARNINGS" -gt 0 ]]; then
    printf '\n%s%s%s\n' "$UI_WARN" "$(t verify_warning_summary)" "$UI_RESET"
  elif [[ "$result" -eq 0 ]]; then
    printf '\n%s%s%s\n' "$UI_OK" "$(t operation_done)" "$UI_RESET"
  else printf '\n%s%s%s\n' "$UI_WARN" "$(t operation_problem)" "$UI_RESET" >&2; fi
  pause_menu
}

menu_reset_request() {
  REQUEST=()
  DRY_RUN=0 ASSUME_YES=0 NON_INTERACTIVE=0 SHOW_SECRET=0 SHOW_QR=0 REINSTALL=0
}

menu_use_installed() {
  DEPLOY_EE=0 DEPLOY_DD=0
  [[ ! -f "$EE_ENV_FILE" ]] || DEPLOY_EE=1
  [[ ! -f "$DD_ENV_FILE" ]] || DEPLOY_DD=1
  UI_SCOPE=""
  if [[ "$DEPLOY_EE" -eq 1 ]]; then UI_SCOPE=EE; fi
  if [[ "$DEPLOY_DD" -eq 1 ]]; then UI_SCOPE+="${UI_SCOPE:+ + }DD"; fi
  [[ "$DEPLOY_EE" -eq 1 || "$DEPLOY_DD" -eq 1 ]] || {
    t not_installed
    return 1
  }
}

menu_single_mode() {
  local allow_all="${1:-0}"
  menu_use_installed || return 1
  if [[ "$DEPLOY_EE" -eq 1 && "$DEPLOY_DD" -eq 1 ]]; then
    local selected=""
    local -a choices=(1:mode_fake_tls 2:mode_padding)
    if [[ "$allow_all" -eq 1 ]]; then choices+=(3:mode_all_managed); fi
    ui_select selected choose_proxy mode 0 "${choices[@]}" 0:ui_back || return 1
    case "$selected" in 1) set_mode_flags ee ;; 2) set_mode_flags dd ;; 3) set_mode_flags all ;; *) return 1 ;; esac
  fi
}

menu_links() {
  local choice=""
  menu_use_installed || return 0
  # Choosing connection information explicitly reveals usable links.
  cmd_links 1 0 || {
    pause_menu
    return 0
  }
  read -r -p "$(t connection_actions) " choice || return 0
  if [[ "$choice" == 1 || "$choice" == qrcode ]]; then menu_run cmd_links 1 1; fi
}

menu_health() {
  local choice="" result=0
  menu_use_installed || return 0
  printf '\n%s%s%s\n' "$UI_ACCENT" "$(t home_health)" "$UI_RESET"
  cmd_healthcheck || result=$?
  if [[ "$result" -eq 0 ]]; then printf '\n%s%s%s\n' "$UI_OK" "$(t operation_done)" "$UI_RESET"; fi
  read -r -p "$(t health_actions) " choice || return 0
  case "$choice" in
    1 | r) menu_run cmd_self_heal ;;
    2 | d) menu_run cmd_diagnose_report "" ;;
  esac
}

menu_configuration() {
  local choice="" mode=""
  while true; do
    menu_use_installed || return 0
    UI_BREADCRUMB="$(t menu_title)"
    ui_select choice home_config panel 1 1:config_basic 2:restart 3:logs 4:start 5:stop 6:menu_status 0:ui_back || return 0
    menu_reset_request
    case "$choice" in
      0) return 0 ;;
      1)
        mode=all
        if [[ "$DEPLOY_EE" -eq 0 ]]; then mode="dd"; elif [[ "$DEPLOY_DD" -eq 0 ]]; then mode=ee; fi
        REQUEST[mode]="$mode"
        menu_run manager_install configure
        ;;
      2) menu_run cmd_service restart ;;
      3) menu_run cmd_service logs ;;
      4) menu_run cmd_service start ;;
      5)
        confirm_action || continue
        menu_run cmd_service stop
        ;;
      6) menu_run cmd_status 0 ;;
    esac
  done
}

menu_updates() {
  local choice="" backup="" value=""
  while true; do
    menu_use_installed || return 0
    UI_BREADCRUMB="$(t menu_title)"
    ui_select choice home_updates panel 0 1:update_auto 2:backup_list 3:backup_restore 4:menu_self_update 5:backup_prune 0:ui_back || return 0
    menu_reset_request
    case "$choice" in
      0) return 0 ;;
      1)
        t note_upgrade_scope
        confirm_action || continue
        menu_run cmd_upgrade auto auto
        ;;
      2) menu_run cmd_backups ;;
      3)
        backup="$(choose_backup)" || continue
        printf '%s: %s\n' "$(t step_rollback)" "$(basename "$backup")"
        confirm_action || continue
        menu_run cmd_rollback "$backup"
        ;;
      4) menu_run cmd_self_update ;;
      5)
        cmd_backups
        read -r -p "$(t backup_keep) [${BACKUP_KEEP}]: " value || return 0
        value="${value:-$BACKUP_KEEP}"
        if [[ ! "$value" =~ ^[0-9]{1,4}$ ]] || ((10#$value < 1 || 10#$value > 1000)); then
          t invalid
          pause_menu
          continue
        fi
        confirm_action || continue
        BACKUP_KEEP="$value"
        menu_run prune_backups "$value"
        save_preferences || return 1
        ;;
    esac
  done
}

menu_monitor() {
  local choice="" value=""
  while true; do
    menu_use_installed || return 0
    UI_BREADCRUMB="$(t menu_title)"
    ui_select choice home_monitor panel 0 1:monitor_recommended 2:disable 3:menu_status 4:monitor_custom 0:ui_back || return 0
    menu_reset_request
    case "$choice" in
      0) return 0 ;;
      1) menu_run monitor_enable 5 3 300 ;;
      2)
        confirm_action || continue
        menu_run monitor_disable
        ;;
      3) menu_run monitor_status ;;
      4)
        read -r -p "$(t monitor_interval) [5]: " value || return 0
        menu_run monitor_enable "${value:-5}" 3 300
        ;;
    esac
  done
}

menu_migrate() {
  local mode="" container="" choice="" address=""
  local -a modes=()
  for mode in ee dd; do
    [[ ! -f "$(mode_file "$mode")" ]] || continue
    container="$(detect_legacy_running_container "$mode")" || continue
    [[ -n "$container" ]] || continue
    modes+=("$mode")
  done
  if ((${#modes[@]} == 0)); then
    t err_migrate_no_legacy
    pause_menu
    return 0
  fi
  if ((${#modes[@]} == 2)); then
    ui_select choice home_migrate mode 3 1:mode_fake_tls 2:mode_padding 3:mode_both 0:ui_back || return 0
    case "$choice" in 1) mode=ee ;; 2) mode="dd" ;; 3) mode=all ;; *) return 0 ;; esac
  else mode="${modes[0]}"; fi
  set_mode_flags "$mode" || return 1
  t setup_address_hint
  while read -r -p "$(t field_domain) (0: $(t ui_back)): " address; do
    [[ "$address" != 0 && "$address" != q ]] || return 0
    valid_endpoint "$address" && break
    t invalid
  done
  valid_endpoint "$address" || return 0
  UI_CONTEXT="$(t setup_protocol): ${mode^^}"$'\n'"$(t field_domain): $address"$'\n'"$(t hint_home_migrate)"
  ui_select choice home_migrate review 0 1:migrate_apply 0:cancel || choice=0
  UI_CONTEXT=""
  [[ "$choice" == 1 ]] || return 0
  menu_run cmd_migrate "$address" "$address" ""
}

menu_advanced() {
  local choice="" mode="" front=""
  while true; do
    UI_BREADCRUMB="$(t home_more)"
    ui_select choice advanced_actions panel 0 1:add_proxy 2:menu_rotate_secret 3:home_migrate 4:menu_uninstall 5:menu_region_diag 0:ui_back || return 0
    menu_reset_request
    case "$choice" in
      0) return 0 ;;
      1) menu_run manager_install install ;;
      2)
        menu_single_mode || continue
        if [[ "$DEPLOY_EE" -eq 1 ]]; then mode=ee; else mode="dd"; fi
        front=""
        # New keys are generated automatically; manual keys remain available in the CLI.
        menu_run cmd_rotate_secret "$mode" auto "$front"
        ;;
      3) menu_migrate ;;
      4)
        menu_single_mode 1 || continue
        menu_run manager_uninstall
        ;;
      5)
        menu_use_installed || continue
        menu_run cmd_diagnose_report ""
        ;;
    esac
  done
}

menu_more() {
  local choice=""
  while true; do
    UI_BREADCRUMB="$(t menu_title)"
    ui_select choice home_more panel 0 1:menu_language 2:menu_help 3:advanced_actions 4:versions_title 0:ui_back || return 0
    case "$choice" in
      0) return 0 ;;
      1) select_language || continue ;;
      2) menu_run cli_usage ;;
      3) menu_advanced ;;
      4) menu_versions ;;
    esac
  done
}

menu_versions() {
  local choice=""
  version_report
  read -r -p "$(t versions_refresh_hint) " choice || return 0
  if [[ "$choice" == r || "$choice" == R ]]; then
    version_check_run
    version_report
    pause_menu
  fi
}

manager_menu() {
  local choice="" installed=0
  local -a options=()
  if ! load_preferences; then select_language || return 0; fi
  version_check_run
  while true; do
    menu_reset_request
    UI_BREADCRUMB=""
    installed=0
    if [[ -f "$EE_ENV_FILE" || -f "$DD_ENV_FILE" ]]; then installed=1; fi
    mapfile -t options < <(ui_home_options)
    ui_select choice menu_title main 1 "${options[@]}" || return 0
    [[ "$choice" != 0 ]] || return 0
    if [[ "$installed" -eq 0 ]]; then
      case "$choice" in
        1) menu_run manager_install install ;;
        2) menu_migrate ;;
        3) menu_more ;;
      esac
      continue
    fi
    case "$choice" in
      1) menu_links ;;
      2) menu_health ;;
      3) menu_configuration ;;
      4) menu_updates ;;
      5) menu_monitor ;;
      6) menu_more ;;
    esac
  done
}
