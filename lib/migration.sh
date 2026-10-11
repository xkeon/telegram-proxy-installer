#!/usr/bin/env bash
# Keep legacy containers stopped under temporary names until the new services pass health checks.
migrate_transaction() {
  local ee_host="$1" dd_host="$2" front="$3" mode="" container="" prefix="" port_key="" image="" secret="" decoded=""
  local backup="" key="" held="" value="" changed=0 recovery=0
  local -A originals=() retained=()
  if [[ "$DEPLOY_EE" -eq 0 && -f "$EE_ENV_FILE" ]]; then load_mode_config ee || return 1; fi
  if [[ "$DEPLOY_DD" -eq 0 && -f "$DD_ENV_FILE" ]]; then load_mode_config dd || return 1; fi
  while read -r mode; do
    if [[ -f "$(mode_file "$mode")" ]]; then
      t already_managed
      return 1
    fi
    container="$(detect_legacy_running_container "$mode")" || {
      t err_legacy_container_missing
      return 1
    }
    originals["$mode"]="$container"
    prefix="${mode^^}"
    if [[ "$mode" == ee ]]; then port_key=3128/tcp; else port_key=443/tcp; fi
    key="${prefix}_BIND_IP"
    printf -v "$key" '%s' "$(docker_binding_ip_by_family "$container" "$port_key" ipv4)"
    key="${prefix}_BIND_IPV6"
    printf -v "$key" '%s' "$(docker_binding_ip_by_family "$container" "$port_key" ipv6)"
    key="${prefix}_PORT"
    printf -v "$key" '%s' "$(docker_binding_port_by_family "$container" "$port_key" ipv4)"
    if [[ -z "${!key}" ]]; then printf -v "$key" '%s' "$(docker_binding_port_by_family "$container" "$port_key" ipv6)"; fi
    value="$(normalize_port "${!key}")" || {
      t err_migrate_port_missing
      return 1
    }
    printf -v "$key" '%s' "$value"
    image="$(docker inspect -f '{{.Config.Image}}' "$container")" || return 1
    image="$(normalize_image_to_digest "$mode" "$image")" || return 1
    docker pull "$image" || return 1
    if [[ "$mode" == ee ]]; then
      MTG_IMAGE="$image"
      EE_DOMAIN="${ee_host:-$(diagnostic_public_address 4 || diagnostic_public_address 6 || true)}"
      secret="$(extract_ee_secret_from_container "$container" || true)"
      if [[ -z "$secret" ]]; then secret="$(extract_ee_secret_from_config || true)"; fi
      EE_SECRET="${secret,,}"
      decoded="$(ee_secret_domain "$EE_SECRET")" || {
        t err_ee_secret_autodetect_fail
        return 1
      }
      FRONT_DOMAIN="${front:-$decoded}"
      [[ "$FRONT_DOMAIN" == "$decoded" ]] || {
        t secret_changed
        return 1
      }
      if ! valid_endpoint "$EE_DOMAIN" || ! is_valid_domain "$FRONT_DOMAIN"; then
        t invalid
        return 1
      fi
    else
      DD_IMAGE="$image"
      DD_DOMAIN="${dd_host:-$(diagnostic_public_address 4 || diagnostic_public_address 6 || true)}"
      valid_endpoint "$DD_DOMAIN" || {
        t invalid
        return 1
      }
      secret="$(docker_env_value "$container" SECRET)" || return 1
      normalize_dd_secret "$secret" || {
        t err_invalid_dd_secret
        return 1
      }
    fi
  done < <(selected_modes)
  ((${#originals[@]})) || return 1
  if [[ ("$DEPLOY_EE" -eq 1 || -f "$EE_ENV_FILE") && ("$DEPLOY_DD" -eq 1 || -f "$DD_ENV_FILE") ]] \
    && ports_conflict_for_bindings "$EE_PORT" "$EE_BIND_IP" "$EE_BIND_IPV6" "$DD_PORT" "$DD_BIND_IP" "$DD_BIND_IPV6"; then
    t err_port_conflict
    return 1
  fi
  validate_network_settings || return 1
  t step_migrate
  create_backup migrate || return 1
  backup="$LAST_BACKUP_PATH"
  while read -r mode; do
    container="${originals[$mode]}"
    held="telegram-proxy-legacy-${mode}-$(basename "$backup")"
    if ! docker rename "$container" "$held"; then
      changed=1
      break
    fi
    retained["$mode"]="$held"
    if ! docker stop "$held"; then
      changed=1
      break
    fi
  done < <(selected_modes)
  if [[ "$changed" -eq 0 ]] && apply_settings; then
    # Preserve stopped originals for explicit operator cleanup after testing clients.
    for mode in "${!retained[@]}"; do printf '%s %s\n' "$(t legacy_retained)" "${retained[$mode]}"; done
    prune_backups "$BACKUP_KEEP" || return 1
    t note_migrate_done
    return 0
  fi
  restore_backup "$backup" || recovery=1
  for mode in "${!retained[@]}"; do
    if ! docker rename "${retained[$mode]}" "${originals[$mode]}" || ! docker start "${originals[$mode]}"; then recovery=1; fi
  done
  if [[ "$recovery" -eq 1 ]]; then printf '%s %s\n' "$(t recovery_failed)" "$backup" >&2; fi
  return 1
}
