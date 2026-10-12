#!/usr/bin/env bash
declare -A REQUEST=()
INSTALL_MODE=ee
ENABLE_BBR=no
FIREWALL_POLICY=keep
EE_DOMAIN="" DD_DOMAIN="" FRONT_DOMAIN=""
EE_PORT=443 DD_PORT=8443
EE_BIND_IP=0.0.0.0 DD_BIND_IP=0.0.0.0
EE_BIND_IPV6="" DD_BIND_IPV6=""
EE_SECRET="" DD_SECRET="" DD_BASE_SECRET=""
declare -a ADDED_FIREWALL_PORTS=()
FIREWALL_WAS_ACTIVE=1
BBR_FILE="/etc/sysctl.d/99-bbr.conf"
BBR_PREVIOUS=""
BBR_CHANGED=0
BBR_FILE_PRESENT=0
BBR_OLD_QDISC=""
BBR_OLD_CONGESTION=""

normalize_ipv6() {
  local value="${1,,}" left="" right="" group="" result="" suffix=""
  local -a before=() after=() octets=() groups=()
  if [[ "$value" == *.* ]]; then
    suffix="${value##*:}"
    is_valid_ipv4 "$suffix" || return 1
    IFS=. read -r -a octets <<<"$suffix"
    printf -v suffix '%x:%x' "$(((10#${octets[0]} << 8) + 10#${octets[1]}))" "$(((10#${octets[2]} << 8) + 10#${octets[3]}))"
    value="${value%:*}:$suffix"
  fi
  [[ "$value" =~ ^[0-9a-f:]+$ && "$value" != *:::* ]] || return 1
  if [[ "$value" == *::* ]]; then
    left="${value%%::*}" right="${value#*::}"
    [[ "$right" != *::* ]] || return 1
    if [[ -n "$left" ]]; then IFS=: read -r -a before <<<"$left"; fi
    if [[ -n "$right" ]]; then IFS=: read -r -a after <<<"$right"; fi
    ((${#before[@]} + ${#after[@]} < 8)) || return 1
    groups=("${before[@]}")
    while ((${#groups[@]} + ${#after[@]} < 8)); do groups+=(0); done
    groups+=("${after[@]}")
  else
    [[ "$value" != :* && "$value" != *: ]] || return 1
    IFS=: read -r -a groups <<<"$value"
    ((${#groups[@]} == 8)) || return 1
  fi
  for group in "${groups[@]}"; do
    [[ "$group" =~ ^[0-9a-f]{1,4}$ ]] || return 1
    printf -v group '%x' "$((16#$group))"
    result+="${result:+:}$group"
  done
  printf '%s' "$result"
}

prepare_settings() {
  local purpose="$1" key="" value=""
  INSTALL_MODE=ee
  EE_DOMAIN="" DD_DOMAIN="" FRONT_DOMAIN=www.cloudflare.com
  EE_PORT=443 DD_PORT=8443
  EE_BIND_IP=0.0.0.0 DD_BIND_IP=0.0.0.0 EE_BIND_IPV6="" DD_BIND_IPV6=""
  EE_SECRET="" DD_SECRET="" DD_BASE_SECRET="" PUBLIC_IPV4="" PUBLIC_IPV6=""
  ENABLE_BBR=no FIREWALL_POLICY=keep
  if [[ -f "$EE_ENV_FILE" ]]; then load_mode_config ee || return 1; fi
  if [[ -f "$DD_ENV_FILE" ]]; then load_mode_config dd || return 1; fi
  if [[ -f "$EE_ENV_FILE" && -f "$DD_ENV_FILE" ]]; then
    INSTALL_MODE=all
  elif [[ -f "$DD_ENV_FILE" ]]; then INSTALL_MODE="dd"; fi
  INSTALL_MODE="${REQUEST[mode]:-$INSTALL_MODE}"
  for key in EE_DOMAIN DD_DOMAIN FRONT_DOMAIN EE_PORT DD_PORT EE_BIND_IP DD_BIND_IP EE_BIND_IPV6 DD_BIND_IPV6 \
    PUBLIC_IPV4 PUBLIC_IPV6 ENABLE_BBR FIREWALL_POLICY; do
    if [[ -v "REQUEST[$key]" ]]; then
      value="${REQUEST[$key]}"
      printf -v "$key" '%s' "$value"
    fi
  done
  if [[ "$purpose" == configure ]]; then
    set_mode_flags "$INSTALL_MODE" || return 1
    local mode=""
    while read -r mode; do
      [[ -f "$(mode_file "$mode")" ]] || {
        t not_installed
        return 1
      }
    done < <(selected_modes)
  fi
}

field_label() {
  case "$1" in
    INSTALL_MODE) echo field_mode ;;
    FRONT_DOMAIN) echo field_front ;;
    *_DOMAIN) echo field_host ;;
    *_PORT) echo field_port ;;
    *_BIND_IP) echo field_bind4 ;;
    *_BIND_IPV6) echo field_bind6 ;;
    PUBLIC_IPV4) echo field_public4 ;;
    PUBLIC_IPV6) echo field_public6 ;;
    ENABLE_BBR) echo field_bbr ;;
    FIREWALL_POLICY) echo field_firewall ;;
  esac
}

valid_field() {
  local key="$1" value="$2"
  case "$key" in
    INSTALL_MODE) [[ "$value" == ee || "$value" == dd || "$value" == all ]] ;;
    FRONT_DOMAIN) is_valid_domain "$value" ;;
    *_DOMAIN) valid_endpoint "$value" ;;
    *_PORT) normalize_port "$value" >/dev/null ;;
    *_BIND_IP) [[ -z "$value" ]] || { is_valid_ipv4 "$value" && is_local_bind_ip "$value"; } ;;
    *_BIND_IPV6) [[ -z "$value" ]] || { is_valid_ipv6 "$value" && is_local_bind_ipv6 "$value"; } ;;
    PUBLIC_IPV4) [[ -z "$value" ]] || is_valid_ipv4 "$value" ;;
    PUBLIC_IPV6) [[ -z "$value" ]] || is_valid_ipv6 "$value" ;;
    ENABLE_BBR) [[ "$value" == yes || "$value" == no ]] ;;
    FIREWALL_POLICY) [[ "$value" == keep || "$value" == enable ]] ;;
    *) return 1 ;;
  esac
}

settings_fields() {
  echo INSTALL_MODE
  if [[ "$INSTALL_MODE" == ee || "$INSTALL_MODE" == all ]]; then
    printf '%s\n' EE_DOMAIN FRONT_DOMAIN EE_PORT EE_BIND_IP EE_BIND_IPV6
  fi
  if [[ "$INSTALL_MODE" == dd || "$INSTALL_MODE" == all ]]; then
    printf '%s\n' DD_DOMAIN DD_PORT DD_BIND_IP DD_BIND_IPV6
  fi
  printf '%s\n' PUBLIC_IPV4 PUBLIC_IPV6 ENABLE_BBR FIREWALL_POLICY
}

settings_summary() {
  local field="" mode="" file="" old_front=""
  t review
  while read -r field; do printf '  %s: %s\n' "$(t "$(field_label "$field")")" "${!field:--}"; done < <(settings_fields)
  while read -r mode; do
    file="$(mode_file "$mode")"
    if [[ -f "$file" ]]; then
      printf '  %s: %s\n' "${mode^^}" "$(t menu_config)"
    else printf '  %s: %s\n' "${mode^^}" "$(t menu_install)"; fi
  done < <(selected_modes)
  old_front="$(read_env_key "$EE_ENV_FILE" FRONT_DOMAIN || true)"
  if [[ -n "$EE_SECRET" && -n "$old_front" && "$old_front" != "$FRONT_DOMAIN" ]]; then t secret_changed; fi
}

managed_socket_owner() {
  local mode="$1" port="$2" address="$3" family="$4" container=""
  container="$([[ "$mode" == ee ]] && echo "$EE_CONTAINER_NAME" || echo "$DD_CONTAINER_NAME")"
  docker_container_running "$container" || return 1
  [[ "$(docker_binding_port_by_family "$container" "$([[ "$mode" == ee ]] && echo 3128/tcp || echo 443/tcp)" "$family")" == "$port" ]] || return 1
  [[ "$(docker_binding_ip_by_family "$container" "$([[ "$mode" == ee ]] && echo 3128/tcp || echo 443/tcp)" "$family")" == "$address" ]]
}

validate_binding_availability() {
  local mode="$1" port="$2" bind4="$3" bind6="$4" family="" address="" host=""
  command -v ss >/dev/null 2>&1 || return 0
  for family in 4 6; do
    while read -r address; do
      [[ -n "$address" ]] || continue
      host="${address%:*}"
      host="${host#[}" host="${host%]}"
      if [[ "$family" == 4 ]]; then
        [[ "$host" != "*" ]] || host=0.0.0.0
        ports_conflict_for_bindings "$port" "$bind4" "" "$port" "$host" "" || continue
      else
        [[ "$host" != "*" ]] || host=::
        ports_conflict_for_bindings "$port" "" "$bind6" "$port" "" "$host" || continue
      fi
      managed_socket_owner "$mode" "$port" "$host" "ipv${family}" && continue
      printf '%s: %s\n' "$(t err_port_in_use)" "$address" >&2
      return 1
    done < <(ss "-$family" -H -lnt 2>/dev/null | awk -v p="$port" '$4 ~ (":"p"$") {print $4}')
  done
}

validate_settings() {
  local field="" mode="" prefix=""
  set_mode_flags "$INSTALL_MODE" || return 1
  while read -r field; do
    valid_field "$field" "${!field}" || {
      printf '%s: %s\n' "$(t invalid)" "$field" >&2
      return 1
    }
  done < <(settings_fields)
  if [[ "$DEPLOY_EE" -eq 1 ]]; then EE_PORT="$(normalize_port "$EE_PORT")"; fi
  if [[ "$DEPLOY_DD" -eq 1 ]]; then DD_PORT="$(normalize_port "$DD_PORT")"; fi
  if [[ ("$DEPLOY_EE" -eq 1 || -f "$EE_ENV_FILE") && ("$DEPLOY_DD" -eq 1 || -f "$DD_ENV_FILE") ]] \
    && ports_conflict_for_bindings "$EE_PORT" "$EE_BIND_IP" "$EE_BIND_IPV6" "$DD_PORT" "$DD_BIND_IP" "$DD_BIND_IPV6"; then
    t err_port_conflict
    return 1
  fi
  while read -r mode; do
    prefix="${mode^^}"
    local port_key="${prefix}_PORT" bind4_key="${prefix}_BIND_IP" bind6_key="${prefix}_BIND_IPV6"
    [[ -n "${!bind4_key}" || -n "${!bind6_key}" ]] || {
      t invalid
      return 1
    }
    validate_binding_availability "$mode" "${!port_key}" "${!bind4_key}" "${!bind6_key}" || return 1
  done < <(selected_modes)
  if [[ "$DEPLOY_EE" -eq 1 ]]; then is_valid_digest_image_ref "$MTG_IMAGE" || return 1; fi
  if [[ "$DEPLOY_DD" -eq 1 ]]; then is_valid_digest_image_ref "$DD_IMAGE" || return 1; fi
}

validate_network_settings() {
  local mode="" key="" bind4_key="" bind6_key="" public4="" public6=""
  public4="$(public_address "$PUBLIC_IPV4" "$(get_primary_ipv4)" 4 || true)"
  public6="$(public_address "$PUBLIC_IPV6" "$(get_primary_ipv6)" 6 || true)"
  if [[ -z "$public4" && -z "$public6" ]]; then t public_unknown; fi
  while read -r mode; do
    key="${mode^^}_DOMAIN" bind4_key="${mode^^}_BIND_IP" bind6_key="${mode^^}_BIND_IPV6"
    if is_valid_domain "${!key}"; then
      check_domain_dns "${!key}" "$public4" "$public6" "$([[ -n "${!bind4_key}" ]] && echo 1 || echo 0)" "$([[ -n "${!bind6_key}" ]] && echo 1 || echo 0)" || return 1
    fi
  done < <(selected_modes)
  if [[ "$DEPLOY_EE" -eq 1 ]]; then
    if ! timeout 8 openssl s_client -connect "${FRONT_DOMAIN}:443" -servername "$FRONT_DOMAIN" \
      -verify_return_error -verify_hostname "$FRONT_DOMAIN" </dev/null >/dev/null 2>&1; then
      t tls_fix
      return 1
    fi
  fi
}

bootstrap_installer() {
  t step_update
  apt-get update -y || return 1
  apt-get install -y ca-certificates curl gnupg lsb-release ufw openssl jq dnsutils iproute2 python3 qrencode || return 1
  if ! command -v docker >/dev/null 2>&1; then apt-get install -y docker.io || return 1; fi
  systemctl enable --now docker || return 1
}

prepare_secrets() {
  local old_front=""
  if [[ "$DEPLOY_EE" -eq 1 ]]; then
    old_front="$(read_env_key "$EE_ENV_FILE" FRONT_DOMAIN || true)"
    if [[ -z "$EE_SECRET" || "$REINSTALL" -eq 1 || (-n "$old_front" && "$old_front" != "$FRONT_DOMAIN") ]]; then
      EE_SECRET="$(docker run --rm "$MTG_IMAGE" generate-secret --hex "$FRONT_DOMAIN")" || return 1
      local decoded=""
      decoded="$(ee_secret_domain "$EE_SECRET")" || return 1
      [[ "$decoded" == "$FRONT_DOMAIN" ]] || return 1
    fi
  fi
  if [[ "$DEPLOY_DD" -eq 1 && (-z "$DD_SECRET" || "$REINSTALL" -eq 1) ]]; then
    DD_BASE_SECRET="$(openssl rand -hex 16)" || return 1
    normalize_dd_secret "$DD_BASE_SECRET" || return 1
  fi
}

apply_settings() {
  local mode="" service=""
  while read -r mode; do write_proxy_config "$mode" || return 1; done < <(selected_modes)
  systemd_reload || return 1
  while read -r mode; do
    service="$(mode_service "$mode")"
    rm -f "${CONFIG_DIR}/paused-${mode}" "${CONFIG_DIR}/watchdog-${mode}.env" || return 1
    systemctl enable "$service" || return 1
    systemctl restart "$service" || return 1
  done < <(selected_modes)
  wait_for_healthcheck
}

apply_host_settings() {
  local port="" mode="" key=""
  ADDED_FIREWALL_PORTS=() BBR_CHANGED=0 FIREWALL_WAS_ACTIVE=1
  ufw status | grep -qi inactive && FIREWALL_WAS_ACTIVE=0
  if [[ "$FIREWALL_POLICY" == enable || "$FIREWALL_WAS_ACTIVE" -eq 1 ]]; then
    local previous_rules=""
    previous_rules="$(ufw show added)" || return 1
    while read -r port; do
      [[ -n "$port" ]] || continue
      if ! grep -Fxq "ufw allow ${port}/tcp" <<<"$previous_rules"; then
        ufw allow "${port}/tcp" || return 1
        ADDED_FIREWALL_PORTS+=("$port")
        previous_rules+=$'\n'"ufw allow ${port}/tcp"
      fi
    done < <(
      collect_sshd_ports
      while read -r mode; do
        key="${mode^^}_PORT"
        printf '%s\n' "${!key}"
      done < <(selected_modes)
    )
    if [[ "$FIREWALL_POLICY" == enable && "$FIREWALL_WAS_ACTIVE" -eq 0 ]]; then ufw --force enable || return 1; fi
    ufw reload || return 1
  fi
  if [[ "$ENABLE_BBR" == yes ]]; then
    sysctl net.ipv4.tcp_available_congestion_control | grep -qw bbr || {
      t warn_bbr_unsupported
      return 0
    }
    BBR_PREVIOUS="" BBR_FILE_PRESENT=0
    if [[ -f "$BBR_FILE" ]]; then
      BBR_FILE_PRESENT=1
      BBR_PREVIOUS="$(cat "$BBR_FILE")"
    fi
    BBR_OLD_QDISC="$(sysctl -n net.core.default_qdisc)" || return 1
    BBR_OLD_CONGESTION="$(sysctl -n net.ipv4.tcp_congestion_control)" || return 1
    BBR_CHANGED=1
    printf 'net.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr\n' >"$BBR_FILE" || return 1
    sysctl --system >/dev/null || return 1
  fi
}

undo_host_settings() {
  local port=""
  for port in "${ADDED_FIREWALL_PORTS[@]}"; do ufw --force delete allow "${port}/tcp" || return 1; done
  if [[ "$FIREWALL_WAS_ACTIVE" -eq 0 && "$FIREWALL_POLICY" == enable ]]; then ufw --force disable || return 1; fi
  if [[ "$BBR_CHANGED" -eq 1 ]]; then
    if [[ "$BBR_FILE_PRESENT" -eq 1 ]]; then
      printf '%s\n' "$BBR_PREVIOUS" >"$BBR_FILE" || return 1
    else rm -f "$BBR_FILE" || return 1; fi
    sysctl --system >/dev/null || return 1
    sysctl -w "net.core.default_qdisc=${BBR_OLD_QDISC}" "net.ipv4.tcp_congestion_control=${BBR_OLD_CONGESTION}" >/dev/null || return 1
  fi
}

apply_installation() {
  apply_host_settings || return 1
  apply_settings
}

manager_install() {
  local purpose="${1:-install}" backup="" rc=0
  WIZARD_APPROVED=0
  prepare_settings "$purpose" || return 1
  if [[ "$DRY_RUN" -eq 0 ]]; then
    preflight_checks || return 1
    if [[ "$NON_INTERACTIVE" -eq 0 ]]; then
      settings_wizard "$purpose" || rc=$?
      if [[ "$rc" -eq 130 ]]; then
        MENU_CANCELLED=1
        return 0
      fi
      [[ "$rc" -eq 0 ]] || return "$rc"
    fi
  fi
  validate_settings || return 1
  if [[ "$WIZARD_APPROVED" -ne 1 ]]; then settings_summary; fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    t no_changes
    return 0
  fi
  if [[ "$WIZARD_APPROVED" -ne 1 ]]; then confirm_action || return 1; fi
  if [[ "$purpose" == install ]]; then bootstrap_installer || return 1; fi
  validate_network_settings || return 1
  if [[ "$DEPLOY_EE" -eq 1 ]]; then docker pull "$MTG_IMAGE" || return 1; fi
  if [[ "$DEPLOY_DD" -eq 1 ]]; then docker pull "$DD_IMAGE" || return 1; fi
  prepare_secrets || return 1
  create_backup "$purpose" || return 1
  backup="$LAST_BACKUP_PATH"
  if ! apply_installation; then
    undo_host_settings || t recovery_failed
    recover_transaction "$backup"
    return 1
  fi
  prune_backups "$BACKUP_KEEP" || return 1
  t step_summary
  cmd_links "$SHOW_SECRET" "$SHOW_QR"
}
