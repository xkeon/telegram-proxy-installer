#!/usr/bin/env bash
status_rows() {
  local mode="" file="" state="" host="" port="" image="" container="" stats="" uptime="" version="" bind4="" bind6=""
  while read -r mode; do
    file="$(mode_file "$mode")" state=not_installed host="" port="" image="" stats="" uptime="" version="" bind4="" bind6=""
    if [[ -r "$file" ]]; then
      host="$(read_env_key "$file" "${mode^^}_DOMAIN")"
      bind4="$(read_env_key "$file" "${mode^^}_BIND_IP")"
      bind6="$(read_env_key "$file" "${mode^^}_BIND_IPV6")"
      port="$(read_env_key "$file" "${mode^^}_PORT")"
      image="$(read_env_key "$file" "$([[ "$mode" == ee ]] && echo MTG_IMAGE || echo DD_IMAGE)")"
      state=stopped
      if systemctl is-active --quiet "$(mode_service "$mode")" 2>/dev/null; then state=running; fi
      uptime="$(systemctl show "$(mode_service "$mode")" -p ActiveEnterTimestamp --value 2>/dev/null || true)"
      container="$([[ "$mode" == ee ]] && echo "$EE_CONTAINER_NAME" || echo "$DD_CONTAINER_NAME")"
      stats="$(docker stats --no-stream --format '{{.CPUPerc}} / {{.MemUsage}} / {{.NetIO}}' "$container" 2>/dev/null || true)"
      version="$(docker image inspect "$image" --format '{{index .Config.Labels "org.opencontainers.image.version"}}' 2>/dev/null || true)"
      [[ "$version" != "<no value>" ]] || version=""
    elif [[ -d "$CONFIG_DIR" && ! -x "$CONFIG_DIR" ]]; then state=unavailable; fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$mode" "$state" "$host" "$port" "$image" "$version" "$uptime" "$stats" "$bind4" "$bind6"
  done < <(selected_modes)
}

cmd_status() {
  local json="${1:-0}"
  require_command python3 || return 1
  status_rows | python3 -c 'import json,sys
keys=("mode","state","host","port","image","version","active_since","resources","bind_ipv4","bind_ipv6")
rows=[dict(zip(keys,line.rstrip("\n").split("\t"))) for line in sys.stdin]
if sys.argv[1]=="1": print(json.dumps({"modes":rows},ensure_ascii=False))
else:
 for row in rows:
  print("{mode}: {state}  {host}:{port}".format(**row))
  print("  "+sys.argv[2]+": "+row["image"]+"  "+sys.argv[3]+": "+(row["version"] or "unknown"))
  print("  IPv4 / IPv6: "+(row["bind_ipv4"] or "-")+" / "+(row["bind_ipv6"] or "-"))
  print("  "+sys.argv[4]+": "+(row["active_since"] or "-"))
  print("  "+sys.argv[5]+": "+(row["resources"] or "unavailable"))' "$json" "$(t status_image)" "$(t status_version)" "$(t status_since)" "$(t status_resources)"
}

redact_report() {
  local input="$1" output="$2"
  require_command python3 || return 1
  python3 -c 'import pathlib,sys
text=pathlib.Path(sys.argv[1]).read_text()
for filename in sys.argv[3:]:
 try: lines=pathlib.Path(filename).read_text().splitlines()
 except OSError: continue
 for line in lines:
  key,sep,value=line.partition("=")
  if sep and key in ("EE_SECRET","DD_SECRET","DD_BASE_SECRET") and value: text=text.replace(value,"[REDACTED]")
pathlib.Path(sys.argv[2]).write_text(text)
' "$input" "$output" "$EE_ENV_FILE" "$DD_ENV_FILE"
}

safe_output() {
  local raw="" clean="" rc=0
  raw="$(mktemp)" || return 1
  clean="$(mktemp)" || {
    rm -f "$raw"
    return 1
  }
  "$@" >"$raw" 2>&1 || rc=$?
  if ! redact_report "$raw" "$clean"; then
    rm -f "$raw" "$clean"
    return 1
  fi
  cat "$clean" || rc=1
  rm -f "$raw" "$clean"
  return "$rc"
}

cmd_diagnose_report() {
  local output="$1" raw="" clean="" rc=0
  raw="$(mktemp)" || return 1
  clean="$(mktemp)" || {
    rm -f "$raw"
    return 1
  }
  cmd_regional_diagnose >"$raw" 2>&1 || rc=$?
  if ! redact_report "$raw" "$clean"; then
    rm -f "$raw" "$clean"
    return 1
  fi
  cat "$clean"
  if [[ -n "$output" ]]; then
    (
      umask 077
      cat "$clean" >"$output"
    ) || rc=1
    chmod 600 "$output" || rc=1
  fi
  rm -f "$raw" "$clean"
  return "$rc"
}

healthcheck_json() {
  local mode="" rc=0 failed=0 healthy=0 missing=0 payload="" raw="" clean="" detail=""
  raw="$(mktemp)" || return 1
  clean="$(mktemp)" || {
    rm -f "$raw"
    return 1
  }
  while read -r mode; do
    rc=0
    check_mode_health "$mode" >"$raw" 2>&1 || rc=$?
    redact_report "$raw" "$clean" || {
      rm -f "$raw" "$clean"
      return 1
    }
    detail="$(cat "$clean")"
    payload+="$(python3 -c 'import json,sys; print(json.dumps(dict(mode=sys.argv[1],exit_code=int(sys.argv[2]),details=sys.argv[3])))' "$mode" "$rc" "$detail")"$'\n'
    case "$rc" in 0) healthy=$((healthy + 1)) ;; 2) missing=$((missing + 1)) ;; *) failed=1 ;; esac
  done < <(selected_modes)
  rm -f "$raw" "$clean"
  printf '%s' "$payload" | python3 -c 'import json,sys; print(json.dumps({"modes":[json.loads(line) for line in sys.stdin if line.strip()]}))'
  [[ "$failed" -eq 0 ]] || return 1
  [[ "$healthy" -gt 0 ]] || return 2
  if [[ "$missing" -gt 0 && ("$DEPLOY_EE" -eq 0 || "$DEPLOY_DD" -eq 0) ]]; then return 2; fi
}

apply_uninstall() {
  local mode="" service="" file="" container=""
  while read -r mode; do
    service="$(mode_service "$mode")" file="$(mode_file "$mode")"
    container="$([[ "$mode" == ee ]] && echo "$EE_CONTAINER_NAME" || echo "$DD_CONTAINER_NAME")"
    if [[ -f "${SYSTEMD_UNIT_DIR}/${service}" ]]; then systemctl disable --now "$service" || return 1; fi
    if docker_container_exists "$container"; then docker rm -f "$container" || return 1; fi
    rm -f "${SYSTEMD_UNIT_DIR}/${service}" "$file" "${CONFIG_DIR}/paused-${mode}" "${CONFIG_DIR}/watchdog-${mode}.env" || return 1
    if [[ "$mode" == ee ]]; then rm -f "${MTG_CONFIG_DIR}/config.toml" || return 1; fi
  done < <(selected_modes)
  systemd_reload || return 1
  if [[ ! -f "$EE_ENV_FILE" && ! -f "$DD_ENV_FILE" && -f "${SYSTEMD_UNIT_DIR}/${MONITOR_TIMER}" ]]; then monitor_disable || return 1; fi
}

manager_uninstall() {
  t uninstall_scope
  cmd_status 0 || return 1
  if [[ "$DRY_RUN" -eq 1 ]]; then
    t no_changes
    return 0
  fi
  confirm_action || return 1
  run_transaction uninstall apply_uninstall || return 1
  t "done"
}

monitor_status() {
  if [[ ! -f "${SYSTEMD_UNIT_DIR}/${MONITOR_TIMER}" ]]; then
    t ui_unmanaged
    return 0
  fi
  local rc=0
  systemctl status "$MONITOR_TIMER" --no-pager || rc=$?
  [[ "$rc" -eq 0 || "$rc" -eq 3 ]]
}

monitor_disable() {
  if [[ -f "${SYSTEMD_UNIT_DIR}/${MONITOR_TIMER}" ]]; then systemctl disable --now "$MONITOR_TIMER" || return 1; fi
  rm -f "${SYSTEMD_UNIT_DIR}/${MONITOR_TIMER}" "${SYSTEMD_UNIT_DIR}/${MONITOR_SERVICE}" || return 1
  systemd_reload
}

refresh_monitor_runner() {
  local staging="" previous="${CONFIG_DIR}/runner.previous"
  ensure_config_dir || return 1
  staging="$(mktemp -d "${CONFIG_DIR}/runner.XXXXXX")" || return 1
  if ! mkdir -p "${staging}/lib" || ! cp "${INSTALLER_DIR}/install.sh" "$staging/" \
    || ! cp "${INSTALLER_DIR}/lib/"*.sh "${staging}/lib/" || ! chmod -R go-rwx "$staging"; then
    rm -rf -- "$staging"
    return 1
  fi
  [[ ! -e "$previous" ]] || {
    rm -rf -- "$staging"
    return 1
  }
  if [[ -d "${CONFIG_DIR}/runner" ]]; then mv "${CONFIG_DIR}/runner" "$previous" || return 1; fi
  if ! mv "$staging" "${CONFIG_DIR}/runner"; then
    if [[ -d "$previous" ]]; then mv "$previous" "${CONFIG_DIR}/runner" || return 1; fi
    return 1
  fi
  rm -rf -- "$previous"
}

write_monitor_units() {
  local interval="$1" retries="$2" cooldown="$3" mode="$4"
  cat >"${SYSTEMD_UNIT_DIR}/${MONITOR_SERVICE}" <<EOF || return 1
[Unit]
Description=Telegram proxy scheduled health check
After=docker.service network-online.target
[Service]
Type=oneshot
ExecStart=/usr/bin/bash "${CONFIG_DIR}/runner/install.sh" watchdog --mode ${mode} --max-retries ${retries} --cooldown ${cooldown}
TimeoutStartSec=90
EOF
  cat >"${SYSTEMD_UNIT_DIR}/${MONITOR_TIMER}" <<EOF || return 1
[Unit]
Description=Telegram proxy health check timer
[Timer]
OnBootSec=2min
OnUnitActiveSec=${interval}min
RandomizedDelaySec=20s
Persistent=true
[Install]
WantedBy=timers.target
EOF
  systemd_reload || return 1
  systemctl enable --now "$MONITOR_TIMER"
}

monitor_enable() {
  local interval="$1" retries="$2" cooldown="$3" mode=all
  [[ -f "$EE_ENV_FILE" || -f "$DD_ENV_FILE" ]] || {
    t not_installed
    return 2
  }
  if [[ "$DEPLOY_EE" -eq 0 ]]; then mode="dd"; elif [[ "$DEPLOY_DD" -eq 0 ]]; then mode=ee; fi
  [[ "$interval" =~ ^[0-9]{1,4}$ ]] && ((10#$interval >= 1 && 10#$interval <= 1440)) || return 1
  [[ "$retries" =~ ^[0-9]{1,2}$ ]] && ((10#$retries >= 1 && 10#$retries <= 10)) || return 1
  [[ "$cooldown" =~ ^[0-9]{1,5}$ ]] && ((10#$cooldown >= 60 && 10#$cooldown <= 86400)) || return 1
  t monitor_limits
  printf '%s min / %s retries / %s sec\n' "$interval" "$retries" "$cooldown"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    t no_changes
    return 0
  fi
  confirm_action || return 1
  refresh_monitor_runner || return 1
  mkdir -p "$SYSTEMD_UNIT_DIR" || return 1
  local saved="" unit="" active=0
  saved="$(mktemp -d)" || return 1
  systemctl is-active --quiet "$MONITOR_TIMER" && active=1
  for unit in "$MONITOR_SERVICE" "$MONITOR_TIMER"; do
    if [[ -f "${SYSTEMD_UNIT_DIR}/${unit}" ]]; then cp -a "${SYSTEMD_UNIT_DIR}/${unit}" "$saved/" || return 1; fi
  done
  if ! write_monitor_units "$interval" "$retries" "$cooldown" "$mode"; then
    local recovery=0
    if [[ ! -f "${saved}/${MONITOR_TIMER}" ]]; then systemctl disable --now "$MONITOR_TIMER" || recovery=1; fi
    for unit in "$MONITOR_SERVICE" "$MONITOR_TIMER"; do
      if [[ -f "${saved}/${unit}" ]]; then
        cp -a "${saved}/${unit}" "${SYSTEMD_UNIT_DIR}/${unit}" || recovery=1
      else rm -f "${SYSTEMD_UNIT_DIR}/${unit}" || recovery=1; fi
    done
    systemd_reload || recovery=1
    if [[ "$active" -eq 1 && -f "${saved}/${MONITOR_TIMER}" ]]; then systemctl restart "$MONITOR_TIMER" || recovery=1; fi
    if [[ "$recovery" -eq 1 ]]; then
      printf '%s %s\n' "$(t recovery_failed)" "$saved" >&2
    else rm -rf -- "$saved"; fi
    return 1
  fi
  rm -rf -- "$saved"
}

cmd_watchdog() {
  local retries="$1" cooldown="$2" mode="" rc=0 count=0 last=0 now="" state="" failed=0
  [[ "$retries" =~ ^[0-9]{1,2}$ ]] && ((10#$retries >= 1 && 10#$retries <= 10)) || return 1
  [[ "$cooldown" =~ ^[0-9]{1,5}$ ]] && ((10#$cooldown >= 60 && 10#$cooldown <= 86400)) || return 1
  now="$(date +%s)"
  ensure_config_dir || return 1
  while read -r mode; do
    [[ -f "$(mode_file "$mode")" ]] || continue
    state="${CONFIG_DIR}/watchdog-${mode}.env"
    rc=0
    safe_output check_mode_health "$mode" || rc=$?
    if [[ "$rc" -eq 0 ]]; then
      rm -f "$state" || return 1
      continue
    fi
    count="$(read_env_key "$state" COUNT || true)" last="$(read_env_key "$state" LAST || true)"
    [[ "$count" =~ ^[0-9]{1,2}$ ]] || count=0
    [[ "$last" =~ ^[0-9]{1,12}$ ]] || last=0
    # A deliberate operator stop must remain stopped.
    if [[ "$(systemctl is-enabled "$(mode_service "$mode")" 2>/dev/null || true)" != enabled ]] \
      || [[ -f "${CONFIG_DIR}/paused-${mode}" ]]; then continue; fi
    if ((10#$count >= 10#$retries || now - 10#$last < 10#$cooldown)); then
      t monitor_cooldown
      failed=1
      continue
    fi
    count=$((10#$count + 1))
    (
      umask 077
      printf 'COUNT=%s\nLAST=%s\n' "$count" "$now" >"$state"
    ) || return 1
    if ! systemctl restart "$(mode_service "$mode")"; then
      failed=1
      continue
    fi
    sleep 2
    if safe_output check_mode_health "$mode"; then rm -f "$state" || return 1; else failed=1; fi
  done < <(selected_modes)
  return "$failed"
}
