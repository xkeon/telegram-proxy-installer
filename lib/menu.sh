#!/usr/bin/env bash
menu_run() {
  local result=0
  "$@" || result=$?
  if [[ "$result" -ne 0 ]]; then printf '%s: %s\n' "$(t operation_failed)" "$result" >&2; fi
  pause_menu
}

menu_mode() {
  local mode=""
  mode="$(prompt_mode_all)" || return 1
  [[ "$mode" != back ]] || return 1
  set_mode_flags "$mode"
}

manager_menu() {
  local choice="" action="" mode="" backup="" value="" mtg="" dd="" secret="" front=""
  if ! load_preferences; then select_language || return 0; fi
  while true; do
    REQUEST=()
    DRY_RUN=0 ASSUME_YES=0 NON_INTERACTIVE=0 SHOW_SECRET=0 SHOW_QR=0 REINSTALL=0
    ui_select choice menu_title main "$(ui_main_default)" "${UI_MAIN_OPTIONS[@]}" || return 0
    case "$choice" in
      0) return 0 ;;
      1) menu_run manager_install install ;;
      2)
        menu_mode || continue
        menu_run cmd_healthcheck
        ;;
      3)
        menu_mode || continue
        menu_run cmd_self_heal
        ;;
      4)
        menu_mode || continue
        mtg="" dd=""
        t note_upgrade_scope
        if [[ "$DEPLOY_EE" -eq 1 ]]; then read -r -p "$(t ask_new_mtg_image)" mtg || return 0; fi
        if [[ "$DEPLOY_DD" -eq 1 ]]; then read -r -p "$(t ask_new_dd_image)" dd || return 0; fi
        confirm_action || continue
        menu_run cmd_upgrade "$mtg" "$dd"
        ;;
      5) menu_run cmd_self_update ;;
      6)
        menu_mode || continue
        confirm_action || continue
        menu_run cmd_migrate "" "" ""
        ;;
      7)
        menu_mode || continue
        backup="$(choose_backup)" || continue
        printf '%s: %s\n' "$(t step_rollback)" "$(basename "$backup")"
        confirm_action || continue
        menu_run cmd_rollback "$backup"
        ;;
      8)
        mode="$(prompt_mode_rotate)" || return 0
        [[ "$mode" != back ]] || continue
        read -r -s -p "$(t "ask_new_secret_${mode}")" secret || return 0
        echo
        secret="${secret:-auto}" front=""
        if [[ "$mode" == ee ]]; then read -r -p "$(t ask_front_for_auto_secret)" front || return 0; fi
        menu_run cmd_rotate_secret "$mode" "$secret" "$front"
        ;;
      9)
        menu_mode || continue
        menu_run cmd_diagnose_report ""
        ;;
      10)
        menu_mode || continue
        menu_run manager_uninstall
        ;;
      11) menu_run cli_usage ;;
      12)
        menu_mode || continue
        if [[ "$DEPLOY_EE" -eq 1 && "$DEPLOY_DD" -eq 1 ]]; then
          mode=all
        elif [[ "$DEPLOY_EE" -eq 1 ]]; then
          mode=ee
        else mode="dd"; fi
        REQUEST[mode]="$mode"
        menu_run manager_install configure
        ;;
      13)
        menu_mode || continue
        cmd_links 0 0 || true
        ui_select action menu_links mode 0 1:show_links 2:show_qr 0:ui_back || return 0
        case "$action" in 1) menu_run cmd_links 1 0 ;; 2) menu_run cmd_links 1 1 ;; esac
        ;;
      14)
        ui_select action menu_backups mode 1 1:backup_list 2:backup_restore 3:backup_prune 0:ui_back || return 0
        case "$action" in
          1) menu_run cmd_backups ;;
          2)
            menu_mode || continue
            backup="$(choose_backup)" || continue
            printf '%s: %s\n' "$(t step_rollback)" "$(basename "$backup")"
            confirm_action || continue
            menu_run cmd_rollback "$backup"
            ;;
          3)
            cmd_backups
            read -r -p "$(t backup_keep) [20]: " value || return 0
            value="${value:-20}"
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
        ;;
      15)
        set_mode_flags all
        menu_run cmd_status 0
        ;;
      16)
        menu_mode || continue
        ui_select action menu_services mode 0 1:start 2:stop 3:restart 4:logs 0:ui_back || return 0
        case "$action" in 1) menu_run cmd_service start ;; 2) menu_run cmd_service stop ;; 3) menu_run cmd_service restart ;; 4) menu_run cmd_service logs ;; esac
        ;;
      17)
        ui_select action menu_monitor mode 0 1:enable 2:disable 3:menu_status 0:ui_back || return 0
        case "$action" in
          1)
            menu_mode || continue
            read -r -p "$(t monitor_interval) [5]: " value || return 0
            menu_run monitor_enable "${value:-5}" 3 300
            ;;
          2)
            confirm_action || continue
            menu_run monitor_disable
            ;;
          3) menu_run monitor_status ;;
        esac
        ;;
      18) select_language || continue ;;
    esac
  done
}
