#!/usr/bin/env bash
WIZARD_APPROVED=0

setup_basic_fields() {
  if [[ "$INSTALL_MODE" == ee || "$INSTALL_MODE" == all ]]; then printf '%s\n' EE_DOMAIN EE_PORT; fi
  if [[ "$INSTALL_MODE" == dd || "$INSTALL_MODE" == all ]]; then printf '%s\n' DD_DOMAIN DD_PORT; fi
}

setup_label() {
  local prefix=""
  case "$1" in EE_*) prefix="EE · " ;; DD_*) prefix="DD · " ;; esac
  printf '%s%s' "$prefix" "$(t "$(field_label "$1")")"
}

setup_edit_field() {
  local field="$1" input="" choice=""
  if [[ "$field" == ENABLE_BBR ]]; then
    ui_select choice field_bbr mode "$([[ "$ENABLE_BBR" == yes ]] && echo 1 || echo 2)" 1:enable 2:disable 0:ui_back || return 0
    case "$choice" in 1) ENABLE_BBR=yes ;; 2) ENABLE_BBR=no ;; esac
    return 0
  elif [[ "$field" == FIREWALL_POLICY ]]; then
    ui_select choice field_firewall mode "$([[ "$FIREWALL_POLICY" == enable ]] && echo 2 || echo 1)" 1:@keep 2:enable 0:ui_back || return 0
    case "$choice" in 1) FIREWALL_POLICY=keep ;; 2) FIREWALL_POLICY=enable ;; esac
    return 0
  fi
  while true; do
    printf '\n%s [%s]\n' "$(setup_label "$field")" "${!field:--}"
    t setup_optional_hint
    read -r -p '> ' input || return 130
    case "$input" in 0 | q) return 0 ;; "") return 0 ;; -) input="" ;; esac
    if ! valid_field "$field" "$input"; then
      t invalid
      continue
    fi
    if [[ "$field" == *_PORT ]]; then input="$(normalize_port "$input")"; fi
    printf -v "$field" '%s' "$input"
    return 0
  done
}

setup_advanced_fields() {
  if [[ "$INSTALL_MODE" == ee || "$INSTALL_MODE" == all ]]; then printf '%s\n' FRONT_DOMAIN EE_BIND_IP EE_BIND_IPV6; fi
  if [[ "$INSTALL_MODE" == dd || "$INSTALL_MODE" == all ]]; then printf '%s\n' DD_BIND_IP DD_BIND_IPV6; fi
  printf '%s\n' PUBLIC_IPV4 PUBLIC_IPV6 ENABLE_BBR FIREWALL_POLICY
}

setup_advanced() {
  local choice="" field="" position=0
  local -a fields=() options=()
  while true; do
    mapfile -t fields < <(setup_advanced_fields)
    options=() position=0
    for field in "${fields[@]}"; do
      position=$((position + 1))
      options+=("${position}:@$(setup_label "$field"): ${!field:--}")
    done
    ui_select choice setup_advanced wizard 1 "${options[@]}" 0:ui_back || return 0
    [[ "$choice" != 0 ]] || return 0
    setup_edit_field "${fields[choice - 1]}" || return 130
  done
}

setup_review_context() {
  local mode="" prefix="" field=""
  UI_CONTEXT="$(t setup_protocol): ${INSTALL_MODE^^}"
  while read -r mode; do
    prefix="${mode^^}"
    local host="${prefix}_DOMAIN" port="${prefix}_PORT"
    UI_CONTEXT+=$'\n'"${prefix}: ${!host}:${!port}"
    if [[ "$mode" == ee ]]; then UI_CONTEXT+=$'\n'"$(t field_front): ${FRONT_DOMAIN}"; fi
    for field in "${prefix}_BIND_IP" "${prefix}_BIND_IPV6"; do
      if [[ "${!field}" != 0.0.0.0 && -n "${!field}" ]]; then UI_CONTEXT+=$'\n'"$(setup_label "$field"): ${!field}"; fi
    done
  done < <(selected_modes)
  for field in PUBLIC_IPV4 PUBLIC_IPV6; do
    if [[ -n "${!field}" ]]; then UI_CONTEXT+=$'\n'"$(setup_label "$field"): ${!field}"; fi
  done
  if [[ "$ENABLE_BBR" == yes ]]; then UI_CONTEXT+=$'\n'"BBR: $(t enable)"; fi
  if [[ "$FIREWALL_POLICY" == enable ]]; then UI_CONTEXT+=$'\n'"UFW: $(t enable)"; fi
  local previous=""
  previous="$(read_env_key "$EE_ENV_FILE" FRONT_DOMAIN || true)"
  if [[ -n "$previous" && "$previous" != "$FRONT_DOMAIN" ]]; then UI_CONTEXT+=$'\n'"$(t secret_changed)"; fi
}

settings_wizard() {
  local purpose="${1:-install}" choice="" step=0 field="" input="" default=1 position=0
  local -a fields=() options=()
  WIZARD_APPROVED=0 UI_CONTEXT=""
  if [[ "$purpose" == install ]]; then
    case "$INSTALL_MODE" in dd) default=2 ;; all) default=3 ;; esac
    ui_select choice setup_mode wizard "$default" 1:mode_fake_tls 2:mode_padding 3:mode_both_friendly 0:cancel || return 130
    case "$choice" in 1) INSTALL_MODE=ee ;; 2) INSTALL_MODE="dd" ;; 3) INSTALL_MODE=all ;; *) return 130 ;; esac
  fi
  set_mode_flags "$INSTALL_MODE" || return 1
  mapfile -t fields < <(setup_basic_fields)
  while true; do
    if ((step >= ${#fields[@]})); then
      setup_review_context
      ui_select choice setup_review review 0 1:setup_apply 2:setup_edit 3:setup_advanced 0:cancel || {
        UI_CONTEXT=""
        return 130
      }
      UI_CONTEXT=""
      case "$choice" in
        0) return 130 ;;
        1) if validate_settings; then
          WIZARD_APPROVED=1
          return 0
        else pause_menu; fi ;;
        2)
          options=() position=0
          for field in "${fields[@]}"; do
            position=$((position + 1))
            options+=("${position}:@$(setup_label "$field"): ${!field:--}")
          done
          ui_select choice setup_edit wizard 0 "${options[@]}" 0:ui_back || return 130
          [[ "$choice" == 0 ]] || step=$((choice - 1))
          ;;
        3) setup_advanced || return 130 ;;
      esac
      continue
    fi
    field="${fields[step]}"
    if [[ "$field" == DD_DOMAIN && -z "$DD_DOMAIN" && -n "$EE_DOMAIN" ]]; then DD_DOMAIN="$EE_DOMAIN"; fi
    printf '\n%s%s%s  [%s/%s]\n' "$UI_ACCENT" "$(setup_label "$field")" "$UI_RESET" "$((step + 1))" "${#fields[@]}"
    if [[ "$field" == *_DOMAIN ]]; then t setup_address_hint; fi
    printf '%s [%s]\n' "$(t setup_value_hint)" "${!field:--}"
    read -r -p '> ' input || return 130
    case "$input" in
      q | :cancel) return 130 ;;
      0 | :back)
        if ((step > 0)); then step=$((step - 1)); else return 130; fi
        continue
        ;;
      "") input="${!field}" ;;
    esac
    if ! valid_field "$field" "$input"; then
      t invalid
      continue
    fi
    if [[ "$field" == *_PORT ]]; then input="$(normalize_port "$input")"; fi
    printf -v "$field" '%s' "$input"
    step=$((step + 1))
  done
}
