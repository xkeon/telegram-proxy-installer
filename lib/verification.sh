#!/usr/bin/env bash
CHECK_WARNINGS=0

verification_item() {
  local state="$1" label="$2" detail="${3:-}" color=""
  case "$state" in
    pass) color="${UI_OK:-}" ;;
    fail | warn | pending) color="${UI_WARN:-}" ;;
    skip) color="${UI_MUTED:-}" ;;
  esac
  if [[ "$state" == warn ]]; then CHECK_WARNINGS=$((CHECK_WARNINGS + 1)); fi
  printf '  %s[%s]%s %s%s\n' "$color" "$(t "verify_${state}")" "${UI_RESET:-}" \
    "$(t "$label")" "${detail:+: $detail}"
}

tcp_connect() {
  valid_endpoint "$1" && normalize_port "$2" >/dev/null || return 1
  # Bound DNS resolution and the entire probe, including multiple DNS answers.
  timeout 5 python3 - "$1" "$2" "${3:-0}" <<'PY'
import socket
import sys

family = {0: socket.AF_UNSPEC, 4: socket.AF_INET, 6: socket.AF_INET6}[int(sys.argv[3])]
try:
    addresses = socket.getaddrinfo(sys.argv[1], int(sys.argv[2]), family, socket.SOCK_STREAM)
    for af, kind, proto, _, address in addresses:
        try:
            with socket.socket(af, kind, proto) as connection:
                connection.settimeout(2)
                connection.connect(address)
                sys.exit(0)
        except OSError:
            continue
except OSError:
    pass
sys.exit(1)
PY
}

saved_mode_config_valid() {
  local mode="$1" prefix="${1^^}" host_key="${1^^}_DOMAIN" port_key="${1^^}_PORT"
  local bind4_key="${prefix}_BIND_IP" bind6_key="${prefix}_BIND_IPV6" decoded=""
  [[ -r "${SYSTEMD_UNIT_DIR}/$(mode_service "$mode")" ]] || return 1
  valid_endpoint "${!host_key}" && normalize_port "${!port_key}" >/dev/null || return 1
  [[ -n "${!bind4_key}" || -n "${!bind6_key}" ]] || return 1
  [[ -z "${!bind4_key}" ]] || is_valid_ipv4 "${!bind4_key}" || return 1
  [[ -z "${!bind6_key}" ]] || is_valid_ipv6 "${!bind6_key}" || return 1
  if [[ "$mode" == ee ]]; then
    is_valid_digest_image_ref "$MTG_IMAGE" || return 1
    decoded="$(ee_secret_domain "$EE_SECRET")" || return 1
    [[ "$decoded" == "$FRONT_DOMAIN" ]] && is_valid_domain "$FRONT_DOMAIN" || return 1
    python3 - "${MTG_CONFIG_DIR}/config.toml" "$EE_ENV_FILE" <<'PY'
import pathlib
import sys
import tomllib

try:
    values = dict(line.split("=", 1) for line in pathlib.Path(sys.argv[2]).read_text().splitlines() if "=" in line)
    config = tomllib.loads(pathlib.Path(sys.argv[1]).read_text())
    valid = config.get("secret") == values.get("EE_SECRET") and config.get("bind-to") == "0.0.0.0:3128"
except (OSError, ValueError):
    valid = False
sys.exit(0 if valid else 1)
PY
  else
    is_valid_digest_image_ref "$DD_IMAGE" && normalize_dd_secret "${DD_BASE_SECRET:-$DD_SECRET}"
  fi
}

check_mode_health() {
  local mode="$1" file="" service="" container="" port="" bind4="" bind6="" image="" running_image="" key=""
  local actual4="" actual6="" actual_port4="" actual_port6="" target="" family="" bind="" ok=0 restarts=""
  [[ "$mode" == ee || "$mode" == dd ]] || return 1
  file="$(mode_file "$mode")" service="$(mode_service "$mode")"
  if [[ "$mode" == ee ]]; then container="$EE_CONTAINER_NAME" key=3128/tcp; else container="$DD_CONTAINER_NAME" key=443/tcp; fi
  if [[ ! -r "$file" ]]; then
    if [[ -n "$(detect_legacy_running_container "$mode" || true)" ]]; then
      printf '[%s] %s\n' "$mode" "$(t note_legacy_migrate)"
    else printf '[%s] %s: %s\n' "$mode" "$(t hc_not_installed)" "$file"; fi
    return 2
  fi
  printf '\n%s\n' "${mode^^}"
  if load_mode_config "$mode" && saved_mode_config_valid "$mode"; then
    verification_item pass verify_config "$file"
  else
    verification_item fail verify_config "$(t verify_config_fix)"
    ok=1
  fi
  if systemctl is-active --quiet "$service"; then
    verification_item pass verify_service "$service"
  else
    verification_item fail verify_service "$service"
    ok=1
  fi
  if docker ps --format '{{.Names}}' | grep -qx "$container"; then
    verification_item pass verify_container "$container"
  else
    verification_item fail verify_container "$container"
    ok=1
  fi
  if [[ "$mode" == ee ]]; then
    port="$EE_PORT" bind4="$EE_BIND_IP" bind6="$EE_BIND_IPV6" image="$MTG_IMAGE"
  else port="$DD_PORT" bind4="$DD_BIND_IP" bind6="$DD_BIND_IPV6" image="$DD_IMAGE"; fi
  running_image="$(docker inspect -f '{{.Config.Image}}' "$container" 2>/dev/null || true)"
  if [[ -n "$image" && "$running_image" == "$image" ]]; then
    verification_item pass verify_image "$image"
  else
    verification_item fail verify_image "$(t hc_image_mismatch)"
    ok=1
  fi
  actual4="$(docker_binding_ip_by_family "$container" "$key" ipv4)"
  actual6="$(docker_binding_ip_by_family "$container" "$key" ipv6)"
  actual_port4="$(docker_binding_port_by_family "$container" "$key" ipv4)"
  actual_port6="$(docker_binding_port_by_family "$container" "$key" ipv6)"
  if [[ -n "$bind4" || -n "$bind6" ]] && normalize_port "$port" >/dev/null \
    && [[ "$(canonical_ip "$actual4" || true)" == "$(canonical_ip "$bind4" || true)" &&
    "$(canonical_ip "$actual6" || true)" == "$(canonical_ip "$bind6" || true)" ]] \
    && { [[ -z "$bind4" ]] || [[ "$actual_port4" == "$port" ]]; } \
    && { [[ -z "$bind6" ]] || [[ "$actual_port6" == "$port" ]]; }; then
    verification_item pass verify_mapping "$(format_bind_targets "$bind4" "$bind6" "$port")"
  else
    verification_item fail verify_mapping "$(t err_port_binding_mismatch)"
    printf '    %s=%s\n' "$(t label_expected)" "$(format_bind_targets "$bind4" "$bind6" "$port")"
    printf '    %s=%s %s\n' "$(t label_actual)" \
      "$(format_bind_targets "$actual4" "" "$actual_port4")" "$(format_bind_targets "" "$actual6" "$actual_port6")"
    ok=1
  fi
  for family in 4 6; do
    if [[ "$family" == 4 ]]; then bind="$bind4"; else bind="$bind6"; fi
    [[ -n "$bind" ]] || continue
    target="$bind"
    if [[ "$bind" == 0.0.0.0 ]]; then target=127.0.0.1; elif [[ "$(canonical_ip "$bind" || true)" == :: ]]; then target=::1; fi
    if tcp_connect "$target" "$port" "$family"; then
      verification_item pass verify_local_tcp "IPv${family} $(format_bind_targets "$([[ "$family" == 4 ]] && echo "$target")" "$([[ "$family" == 6 ]] && echo "$target")" "$port")"
    else
      verification_item fail verify_local_tcp "IPv${family} ${target}:${port} — $(t verify_tcp_fix)"
      ok=1
    fi
  done
  restarts="$(systemctl show -p NRestarts --value "$service" 2>/dev/null || true)"
  if [[ "$restarts" =~ ^[0-9]+$ ]] && ((restarts >= 5)); then verification_item warn verify_service "$(t warn_service_restarts) $restarts"; fi
  restarts="$(docker inspect -f '{{.RestartCount}}' "$container" 2>/dev/null || true)"
  if [[ "$restarts" =~ ^[0-9]+$ ]] && ((restarts >= 5)); then verification_item warn verify_container "$(t warn_container_restarts) $restarts"; fi
  if [[ "$ok" -eq 0 ]]; then return 0; fi
  if docker_container_exists "$container"; then
    printf '[%s] %s\n' "$mode" "$(t note_recent_logs)"
    docker logs --tail 5 "$container" 2>&1 | sed "s/^/[${mode}] $(t label_log): /" || true
  fi
  return 1
}

verify_entry_dns() {
  local host="$1" family="$2" expected="$3" records="" label=verify_dns4
  if [[ "$family" == 6 ]]; then label=verify_dns6; fi
  if is_valid_ipv4 "$host" || is_valid_ipv6 "$host"; then
    verification_item skip "$label" "$(t verify_literal_ip)"
    return 0
  fi
  if [[ "$family" == 4 ]]; then
    records="$(resolve_domain_a_records "$host" || true)"
  else records="$(resolve_domain_aaaa_records "$host" || true)"; fi
  if [[ -z "$records" ]]; then
    verification_item warn "$label" "$host — $(t dns_fix)"
  elif [[ -z "$expected" ]]; then
    verification_item pass "$label" "$host → $(diag_format_records "$records")"
    verification_item pending verify_dns_target "$(t public_unknown)"
  elif dns_records_match "$expected" "$records"; then
    verification_item pass "$label" "$host → $expected"
  else
    verification_item warn "$label" "$host → $(diag_format_records "$records"); $(t label_expected)=$expected. $(t dns_fix)"
  fi
}

verify_installation() {
  local mode="" host="" port="" bind4="" bind6="" public4="" public6=""
  CHECK_WARNINGS=0
  printf '\n%s%s%s\n' "${UI_ACCENT:-}" "$(t verify_title)" "${UI_RESET:-}"
  if ! cmd_healthcheck; then
    t verify_local_failed
    return 1
  fi
  while read -r mode; do
    load_mode_config "$mode" || return 1
    if [[ "$mode" == ee ]]; then
      host="$EE_DOMAIN" port="$EE_PORT" bind4="$EE_BIND_IP" bind6="$EE_BIND_IPV6"
    else host="$DD_DOMAIN" port="$DD_PORT" bind4="$DD_BIND_IP" bind6="$DD_BIND_IPV6"; fi
    printf '\n%s — %s:%s\n' "${mode^^}" "$host" "$port"
    if systemctl is-enabled --quiet "$(mode_service "$mode")"; then
      verification_item pass verify_autostart
    else verification_item warn verify_autostart; fi
    public4="$(diagnostic_public_address 4 || true)" public6="$(diagnostic_public_address 6 || true)"
    if [[ -n "$bind4" ]]; then verify_entry_dns "$host" 4 "$public4"; fi
    if [[ -n "$bind6" ]]; then verify_entry_dns "$host" 6 "$public6"; fi
    if [[ "$mode" == ee ]]; then
      if timeout 8 openssl s_client -connect "${FRONT_DOMAIN}:443" -servername "$FRONT_DOMAIN" \
        -verify_return_error -verify_hostname "$FRONT_DOMAIN" </dev/null >/dev/null 2>&1; then
        verification_item pass verify_tls "$FRONT_DOMAIN"
      else verification_item warn verify_tls "$(t tls_fix)"; fi
    fi
    if tcp_connect "$host" "$port"; then
      verification_item pass verify_entry_tcp "$host:$port"
    else verification_item warn verify_entry_tcp "$host:$port — $(t verify_entry_fix)"; fi
    verification_item pending verify_external "$(t verify_external_fix) TCP $port"
    printf '    nc -vz -w 5 %s %s\n' "$host" "$port"
  done < <(selected_modes)
  if [[ "$ENABLE_BBR" == yes ]]; then
    if [[ "$(sysctl -n net.ipv4.tcp_congestion_control)" == bbr && "$(sysctl -n net.core.default_qdisc)" == fq ]]; then
      verification_item pass field_bbr
    else verification_item warn field_bbr "$(t warn_bbr_unsupported)"; fi
  fi
  if [[ "$FIREWALL_POLICY" == enable ]]; then
    if LC_ALL=C ufw status | grep -q '^Status: active'; then
      verification_item pass field_firewall
    else verification_item warn field_firewall "$(t verify_firewall_fix)"; fi
  fi
}

verification_summary() {
  if [[ "$CHECK_WARNINGS" -gt 0 ]]; then
    printf '\n%s%s (%s)%s\n' "${UI_WARN:-}" "$(t verify_warning_summary)" "$CHECK_WARNINGS" "${UI_RESET:-}"
  else printf '\n%s%s%s\n' "${UI_OK:-}" "$(t verify_local_ready)" "${UI_RESET:-}"; fi
}
