#!/usr/bin/env bash
# Management workflows share validation and transaction recovery.
PUBLIC_IPV4=""
PUBLIC_IPV6=""
DRY_RUN=0
ASSUME_YES=0
NON_INTERACTIVE=0
SHOW_SECRET=0
SHOW_QR=0
REINSTALL=0
BACKUP_KEEP=20
PREFERENCES_FILE=""
MONITOR_SERVICE="telegram-proxy-monitor.service"
MONITOR_TIMER="telegram-proxy-monitor.timer"

require_root() {
  [[ "$EUID" -eq 0 ]] || {
    t root_needed >&2
    return 1
  }
}

selected_modes() {
  if [[ "$DEPLOY_EE" -eq 1 ]]; then echo ee; fi
  if [[ "$DEPLOY_DD" -eq 1 ]]; then echo dd; fi
}

mode_file() {
  case "$1" in ee) printf '%s' "$EE_ENV_FILE" ;; dd) printf '%s' "$DD_ENV_FILE" ;; *) return 1 ;; esac
}

mode_service() {
  case "$1" in ee) printf '%s' "$EE_SERVICE_NAME" ;; dd) printf '%s' "$DD_SERVICE_NAME" ;; *) return 1 ;; esac
}

require_command() {
  command -v "$1" >/dev/null 2>&1 && return 0
  printf '%s %s\n' "$(t dependency)" "$1" >&2
  return 1
}

confirm_action() {
  [[ "$ASSUME_YES" -eq 1 ]] && return 0
  [[ "$NON_INTERACTIVE" -eq 1 ]] && return 1
  local answer=""
  read -r -p "$(t confirm)" answer || return 1
  [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}

load_preferences() {
  local saved=""
  saved="$(read_env_key "${PREFERENCES_FILE:-${CONFIG_DIR}/preferences.env}" UI_LANG || true)"
  local keep=""
  keep="$(read_env_key "${PREFERENCES_FILE:-${CONFIG_DIR}/preferences.env}" BACKUP_KEEP || true)"
  if [[ "$keep" =~ ^[0-9]{1,4}$ ]] && ((10#$keep >= 1 && 10#$keep <= 1000)); then BACKUP_KEEP="$keep"; fi
  case "$saved" in en | zh | ko | ja)
    UI_LANG="$saved"
    return 0
    ;;
  esac
  return 1
}

save_preferences() {
  [[ "$EUID" -eq 0 ]] || return 0
  ensure_config_dir || return 1
  local temp=""
  temp="$(mktemp "${CONFIG_DIR}/preferences.XXXXXX")" || return 1
  printf 'UI_LANG=%s\nBACKUP_KEEP=%s\n' "$UI_LANG" "$BACKUP_KEEP" >"$temp" || return 1
  chmod 600 "$temp" || return 1
  mv "$temp" "${PREFERENCES_FILE:-${CONFIG_DIR}/preferences.env}"
}

canonical_ip() {
  local value="" octet="" result=""
  local -a octets=()
  if is_valid_ipv4 "$1"; then
    IFS=. read -r -a octets <<<"$1"
    for octet in "${octets[@]}"; do result+="${result:+.}$((10#$octet))"; done
    printf '%s' "$result"
  else
    value="$(normalize_ipv6 "$1")" || return 1
    [[ "$value" != 0:0:0:0:0:0:0:0 ]] || value=::
    printf '%s' "$value"
  fi
}

valid_endpoint() {
  is_valid_domain "$1" || is_valid_ipv4 "$1" || is_valid_ipv6 "$1"
}

public_address() {
  local supplied="$1" candidate="$2" family="$3"
  require_command python3 || return 1
  if [[ -n "$supplied" ]]; then supplied="$(canonical_ip "$supplied")" || return 1; fi
  python3 -c 'import ipaddress,sys
try:
 a=ipaddress.ip_address(sys.argv[1] or sys.argv[2])
 if a.version != int(sys.argv[3]) or (not sys.argv[1] and not a.is_global): sys.exit(1)
 print(a)
except ValueError: sys.exit(1)' "$supplied" "$candidate" "$family"
}

dns_records_match() {
  local expected="" record=""
  expected="$(canonical_ip "$1")" || return 1
  while read -r record; do
    [[ "$expected" != "$(canonical_ip "$record" || true)" ]] || return 0
  done <<<"$2"
  return 1
}

diagnostic_public_address() {
  local family="$1" supplied="" mode="" saved="" key="PUBLIC_IPV${1}"
  supplied="${!key}"
  if [[ -z "$supplied" ]]; then
    while read -r mode; do
      saved="$(read_env_key "$(mode_file "$mode")" "$key" || true)"
      if [[ -n "$saved" ]]; then
        supplied="$saved"
        break
      fi
    done < <(selected_modes)
  fi
  if [[ "$family" == 4 ]]; then
    public_address "$supplied" "$(get_primary_ipv4)" 4
  else public_address "$supplied" "$(get_primary_ipv6)" 6; fi
}

load_mode_config() {
  local file="" key="" value="" prefix="${1^^}"
  file="$(mode_file "$1")" || return 1
  [[ -r "$file" ]] || return 2
  for key in "${prefix}_DOMAIN" "${prefix}_PORT" "${prefix}_BIND_IP" "${prefix}_BIND_IPV6" \
    "${prefix}_SECRET" PUBLIC_IPV4 PUBLIC_IPV6; do
    value="$(read_env_key "$file" "$key" || true)"
    printf -v "$key" '%s' "$value"
  done
  if [[ "$1" == ee ]]; then
    FRONT_DOMAIN="$(read_env_key "$file" FRONT_DOMAIN || true)"
    MTG_IMAGE="$(read_env_key "$file" MTG_IMAGE || true)"
  else
    DD_IMAGE="$(read_env_key "$file" DD_IMAGE || true)"
    value="$(read_env_key "$file" DD_BASE_SECRET || true)"
    normalize_dd_secret "${value:-$(read_env_key "$file" DD_SECRET)}" || return 1
  fi
}

restore_snapshot() {
  local path="$1" mode="" prefix="" env="" service="" found=0
  [[ -f "${path}/.complete" ]] || return 1
  while read -r mode; do
    prefix="${mode^^}"
    [[ "$(read_env_key "${path}/meta.env" "DEPLOY_${prefix}")" == 1 ]] || continue
    found=1
    env="$(mode_file "$mode")" service="$(mode_service "$mode")"
    if [[ "$(read_env_key "${path}/meta.env" "${prefix}_ENV_PRESENT")" == 0 && -f "${SYSTEMD_UNIT_DIR}/${service}" ]]; then
      systemctl disable --now "$service" || return 1
      docker rm -f "$([[ "$mode" == ee ]] && echo "$EE_CONTAINER_NAME" || echo "$DD_CONTAINER_NAME")" >/dev/null 2>&1 || true
    fi
    if [[ -f "${path}/${mode}.env" ]]; then
      ensure_config_dir || return 1
      cp -a "${path}/${mode}.env" "$env" || return 1
      chmod 600 "$env" || return 1
    elif [[ "$(read_env_key "${path}/meta.env" "${prefix}_ENV_PRESENT")" == 0 ]]; then
      rm -f "$env" || return 1
    else return 1; fi
    if [[ -f "${path}/${service}" ]]; then
      cp -a "${path}/${service}" "${SYSTEMD_UNIT_DIR}/${service}" || return 1
    elif [[ "$(read_env_key "${path}/meta.env" "${prefix}_UNIT_PRESENT")" == 0 ]]; then
      rm -f "${SYSTEMD_UNIT_DIR}/${service}" || return 1
    else return 1; fi
    if [[ "$mode" == ee ]]; then
      if [[ -f "${path}/config.toml" ]]; then
        mkdir -p "$MTG_CONFIG_DIR" || return 1
        chmod 700 "$MTG_CONFIG_DIR" || return 1
        cp -a "${path}/config.toml" "${MTG_CONFIG_DIR}/config.toml" || return 1
      elif [[ "$(read_env_key "${path}/meta.env" EE_CONFIG_PRESENT)" == 0 ]]; then
        rm -f "${MTG_CONFIG_DIR}/config.toml" || return 1
      fi
    fi
  done < <(selected_modes)
  [[ "$found" -eq 1 ]] || return 1
  if [[ "$(read_env_key "${path}/meta.env" MONITOR_CAPTURED || true)" == 1 ]]; then
    local unit=""
    for unit in "$MONITOR_SERVICE" "$MONITOR_TIMER"; do
      if [[ -f "${path}/${unit}" ]]; then
        cp -a "${path}/${unit}" "${SYSTEMD_UNIT_DIR}/${unit}" || return 1
      else rm -f "${SYSTEMD_UNIT_DIR}/${unit}" || return 1; fi
    done
  fi
  systemd_reload || return 1
  while read -r mode; do
    service="$(mode_service "$mode")"
    [[ "$(read_env_key "${path}/meta.env" "DEPLOY_${mode^^}")" == 1 ]] || continue
    if [[ -f "${path}/${mode}.paused" ]]; then
      ensure_config_dir || return 1
      cp -a "${path}/${mode}.paused" "${CONFIG_DIR}/paused-${mode}" || return 1
    else rm -f "${CONFIG_DIR}/paused-${mode}" || return 1; fi
    if [[ -f "$(mode_file "$mode")" && -f "${SYSTEMD_UNIT_DIR}/${service}" ]]; then
      if [[ "$(read_env_key "${path}/meta.env" "${mode^^}_ACTIVE")" != 0 ]]; then
        systemctl enable "$service" || return 1
        systemctl restart "$service" || return 1
      else systemctl stop "$service" || return 1; fi
    fi
  done < <(selected_modes)
  if [[ "$(read_env_key "${path}/meta.env" MONITOR_CAPTURED || true)" == 1 &&
  "$(read_env_key "${path}/meta.env" MONITOR_ACTIVE || true)" == 1 && -f "${path}/${MONITOR_TIMER}" ]]; then
    systemctl enable --now "$MONITOR_TIMER" || return 1
  elif [[ "$(read_env_key "${path}/meta.env" MONITOR_CAPTURED || true)" == 1 ]]; then
    systemctl stop "$MONITOR_TIMER" || return 1
  fi
}

verify_recovery() {
  local path="$1" previous_ee="$DEPLOY_EE" previous_dd="$DEPLOY_DD" rc=0
  if [[ "$(read_env_key "${path}/meta.env" SNAPSHOT_VERSION || true)" == 1 ]]; then
    DEPLOY_EE=0 DEPLOY_DD=0
    if [[ "$previous_ee" -eq 1 && -f "${path}/ee.env" && "$(read_env_key "${path}/meta.env" EE_ACTIVE)" != 0 ]]; then DEPLOY_EE=1; fi
    if [[ "$previous_dd" -eq 1 && -f "${path}/dd.env" && "$(read_env_key "${path}/meta.env" DD_ACTIVE)" != 0 ]]; then DEPLOY_DD=1; fi
  fi
  if [[ "$DEPLOY_EE" -eq 1 || "$DEPLOY_DD" -eq 1 ]]; then wait_for_healthcheck || rc=$?; fi
  DEPLOY_EE="$previous_ee" DEPLOY_DD="$previous_dd"
  return "$rc"
}

recover_transaction() {
  local backup="$1"
  t failure
  if ! restore_backup "$backup" || ! verify_recovery "$backup"; then
    printf '%s %s\n' "$(t recovery_failed)" "$backup" >&2
  fi
  return 1
}

run_transaction() {
  local action="$1" backup=""
  shift
  create_backup "$action" || return 1
  backup="$LAST_BACKUP_PATH"
  if ! "$@"; then
    recover_transaction "$backup"
    return 1
  fi
  prune_backups "$BACKUP_KEEP" || return 1
}

backup_paths() {
  [[ -d "$BACKUP_DIR" ]] || return 0
  local path=""
  while IFS= read -r path; do
    [[ -r "${path}/meta.env" ]] || continue
    [[ "$(read_env_key "${path}/meta.env" SNAPSHOT_VERSION)" != 1 || -f "${path}/.complete" ]] || continue
    printf '%s\n' "$path"
  done < <(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' | sort -nr | cut -d' ' -f2-)
}

cmd_backups() {
  local path="" mode="" index=0
  while IFS= read -r path; do
    [[ -r "${path}/meta.env" ]] || continue
    index=$((index + 1))
    printf '%s) %s  %s  %s\n' "$index" "$(basename "$path")" \
      "$(read_env_key "${path}/meta.env" CREATED_AT)" "$(read_env_key "${path}/meta.env" ACTION)"
    printf '   EE=%s DD=%s\n' "$(read_env_key "${path}/meta.env" DEPLOY_EE)" "$(read_env_key "${path}/meta.env" DEPLOY_DD)"
    for mode in ee dd; do
      [[ -f "${path}/${mode}.env" ]] || continue
      printf '   %s :%s %s\n' "${mode^^}" "$(read_env_key "${path}/${mode}.env" "${mode^^}_PORT")" \
        "$(read_env_key "${path}/${mode}.env" "$([[ "$mode" == ee ]] && echo MTG_IMAGE || echo DD_IMAGE)")"
    done
  done < <(backup_paths)
  if [[ "$index" -eq 0 ]]; then t note_backup_none; fi
}

prune_backups() {
  local keep="$1" count=0 path=""
  [[ "$keep" =~ ^[0-9]{1,4}$ ]] && ((10#$keep >= 1 && 10#$keep <= 1000)) || return 1
  while IFS= read -r path; do
    [[ -f "${path}/.complete" ]] || continue
    count=$((count + 1))
    if ((count > 10#$keep)); then rm -rf -- "$path" || return 1; fi
  done < <(backup_paths)
}

choose_backup() {
  local -a paths=()
  local answer=""
  mapfile -t paths < <(backup_paths)
  ((${#paths[@]})) || {
    t note_backup_none >&2
    return 1
  }
  cmd_backups >&2
  while read -r -p "$(t backup_hint) " answer; do
    [[ "$answer" == 0 || "$answer" == q ]] && return 1
    if [[ "$answer" =~ ^[0-9]{1,4}$ ]] && ((10#$answer >= 1 && 10#$answer <= ${#paths[@]})); then
      printf '%s' "${paths[10#$answer - 1]}"
      return 0
    fi
    t invalid >&2
  done
  return 1
}

write_proxy_config() {
  local mode="$1"
  ensure_config_dir || return 1
  mkdir -p "$SYSTEMD_UNIT_DIR" || return 1
  if [[ "$mode" == ee ]]; then
    mkdir -p "$MTG_CONFIG_DIR" || return 1
    chmod 700 "$MTG_CONFIG_DIR" || return 1
    (
      umask 077
      printf 'secret = "%s"\nbind-to = "0.0.0.0:3128"\n' "$EE_SECRET" >"${MTG_CONFIG_DIR}/config.toml"
    ) || return 1
    chmod 600 "${MTG_CONFIG_DIR}/config.toml" || return 1
    write_ee_env_file || return 1
    chmod 600 "$EE_ENV_FILE" || return 1
    write_ee_systemd_unit || return 1
  else
    write_dd_env_file || return 1
    chmod 600 "$DD_ENV_FILE" || return 1
    write_dd_systemd_unit || return 1
  fi
}

ee_secret_domain() {
  local secret="${1,,}"
  [[ "$secret" =~ ^ee[0-9a-f]{36,}$ && $((${#secret} % 2)) -eq 0 ]] || return 1
  require_command python3 || return 1
  python3 -c 'import sys
try: print(bytes.fromhex(sys.argv[1][34:]).decode("ascii"))
except (ValueError,UnicodeError): sys.exit(1)' "$secret"
}

apply_rotation() {
  local mode="$1" secret="$2" front="$3"
  if [[ "$mode" == ee ]]; then
    EE_SECRET="$secret" FRONT_DOMAIN="$front"
  else normalize_dd_secret "$secret" || return 1; fi
  write_proxy_config "$mode" || return 1
  rm -f "${CONFIG_DIR}/paused-${mode}" "${CONFIG_DIR}/watchdog-${mode}.env" || return 1
  systemd_reload || return 1
  systemctl restart "$(mode_service "$mode")" || return 1
  wait_for_healthcheck
}

cmd_rotate_secret() {
  local mode="$1" secret="$2" front="$3" decoded=""
  [[ "$mode" == ee || "$mode" == dd ]] || {
    t err_rotate_mode_required
    return 1
  }
  set_mode_flags "$mode" || return 1
  load_mode_config "$mode" || {
    t not_installed
    return 1
  }
  if [[ -z "$secret" && "$NON_INTERACTIVE" -eq 0 ]]; then
    read -r -s -p "$(t "ask_new_${mode}_secret_cli")" secret || return 1
    echo
  fi
  if [[ -z "$secret" || "${secret,,}" == auto ]]; then
    if [[ "$mode" == ee ]]; then
      front="${front:-$FRONT_DOMAIN}"
      is_valid_domain "$front" || return 1
      if [[ "$DRY_RUN" -eq 0 ]]; then
        secret="$(docker run --rm "$MTG_IMAGE" generate-secret --hex "$front")" || return 1
      else secret="$EE_SECRET"; fi
    else
      if [[ "$DRY_RUN" -eq 0 ]]; then
        secret="$(openssl rand -hex 16)" || return 1
      else secret="$DD_SECRET"; fi
    fi
  fi
  secret="${secret,,}"
  if [[ "$mode" == ee ]]; then
    decoded="$(ee_secret_domain "$secret")" || {
      t err_invalid_ee_secret
      return 1
    }
    is_valid_domain "$decoded" || return 1
    [[ -z "$front" || "$front" == "$decoded" ]] || {
      t err_invalid_ee_secret
      return 1
    }
    front="$decoded"
    if [[ "$DRY_RUN" -eq 0 && "$front" != "$FRONT_DOMAIN" ]] \
      && ! timeout 8 openssl s_client -connect "${front}:443" -servername "$front" -verify_return_error -verify_hostname "$front" </dev/null >/dev/null 2>&1; then
      t tls_fix
      return 1
    fi
  elif [[ "$mode" == dd ]]; then
    normalize_dd_secret "$secret" || {
      t err_invalid_dd_secret
      return 1
    }
  fi
  printf '%s: %s\n' "$(t menu_rotate_secret)" "${mode^^}"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    t no_changes
    return 0
  fi
  confirm_action || return 1
  run_transaction rotate-secret apply_rotation "$mode" "$secret" "$front" || return 1
  t note_rotate_done
  cmd_links "$SHOW_SECRET" "$SHOW_QR"
}

cmd_links() {
  local reveal="${1:-0}" qr="${2:-0}" mode="" file="" host="" port="" secret="" query="" found=0
  require_command python3 || return 1
  [[ "$qr" -eq 0 ]] || require_command qrencode || {
    t qr_missing
    return 1
  }
  while read -r mode; do
    file="$(mode_file "$mode")"
    [[ -r "$file" ]] || continue
    found=1
    host="$(read_env_key "$file" "${mode^^}_DOMAIN")"
    port="$(read_env_key "$file" "${mode^^}_PORT")"
    secret="$(read_env_key "$file" "${mode^^}_SECRET")"
    if [[ "$reveal" -eq 0 && "$qr" -eq 0 ]]; then secret='********'; fi
    query="$(python3 -c 'import sys,urllib.parse; print(urllib.parse.urlencode(dict(zip(("server","port","secret"),sys.argv[1:]))))' "$host" "$port" "$secret")" || return 1
    printf '%s  %s:%s\ntg://proxy?%s\nhttps://t.me/proxy?%s\n' "${mode^^}" "$host" "$port" "$query" "$query"
    if [[ "$qr" -eq 1 ]]; then printf 'https://t.me/proxy?%s' "$query" | qrencode -t ANSIUTF8 || return 1; fi
  done < <(selected_modes)
  [[ "$found" -eq 1 ]] || {
    t not_installed
    return 2
  }
  if [[ "$reveal" -eq 0 && "$qr" -eq 0 ]]; then t masked; fi
}

cleanup_port_targets() {
  local port="" id="" name="" image="" bound="" choice="" i=0
  local -a targets=() options=()
  port="$(normalize_port "$1")" || return 1
  require_command docker || return 1
  while read -r id; do
    [[ -n "$id" ]] || continue
    name="$(docker inspect -f '{{.Name}}' "$id")" || return 1
    image="$(docker inspect -f '{{.Config.Image}}' "$id")" || return 1
    name="${name#/}"
    case "$name:$image" in
      "$EE_CONTAINER_NAME":nineseconds/mtg:* | "$EE_CONTAINER_NAME":nineseconds/mtg@* | \
        "$DD_CONTAINER_NAME":telegrammessenger/proxy:* | "$DD_CONTAINER_NAME":telegrammessenger/proxy@*) ;;
      *) continue ;;
    esac
    bound="$(docker inspect -f '{{range .NetworkSettings.Ports}}{{range .}}{{println .HostPort}}{{end}}{{end}}' "$id")" || return 1
    grep -Fxq "$port" <<<"$bound" || continue
    targets+=("$id")
    i=$((i + 1))
    options+=("${i}:@${name} (${id}) :${port}")
  done < <(docker ps -q)
  ((${#targets[@]})) || return 1
  ui_select choice note_port_holders mode 0 "${options[@]}" 0:ui_back || return 1
  [[ "$choice" != 0 ]] || return 1
  docker rm -f "${targets[choice - 1]}"
}

cmd_service() {
  local action="$1" lines="${2:-50}" mode="" service="" found=0
  case "$action" in start | stop | restart | logs) ;; *) return 1 ;; esac
  [[ "$lines" =~ ^[0-9]{1,4}$ ]] && ((10#$lines >= 1 && 10#$lines <= 1000)) || return 1
  while read -r mode; do
    [[ -f "$(mode_file "$mode")" ]] || continue
    found=1
    service="$(mode_service "$mode")"
    if [[ "$action" == logs ]]; then
      safe_output journalctl -u "$service" --no-pager -n "$lines" || return 1
    else
      if [[ "$action" == stop ]]; then
        systemctl stop "$service" || return 1
        ensure_config_dir || return 1
        (
          umask 077
          touch "${CONFIG_DIR}/paused-${mode}"
        ) || return 1
      else
        systemctl "$action" "$service" || return 1
        rm -f "${CONFIG_DIR}/paused-${mode}" "${CONFIG_DIR}/watchdog-${mode}.env" || return 1
      fi
    fi
  done < <(selected_modes)
  [[ "$found" -eq 1 ]] || {
    t not_installed
    return 2
  }
  if [[ "$action" == start || "$action" == restart ]]; then wait_for_healthcheck; fi
}
