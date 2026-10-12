#!/usr/bin/env bash
VERSION_ROWS=()
VERSION_CHECKED=0 VERSION_UPDATES=0 VERSION_UNKNOWN=0 VERSION_MISSING=0

version_row() {
  local field=""
  for field in "$@"; do
    field="${field//$'\t'/ }" field="${field//$'\n'/ }" field="${field//$'\r'/ }"
    printf '%s\t' "${field:--}"
  done
  echo
}

version_registry_digest() {
  local repository="$1" tag="$2" token="" headers="" digest=""
  token="$(curl -fsSL --connect-timeout 2 --max-time 3 \
    "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repository}:pull" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')" || return 1
  [[ "$token" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  # Keep the anonymous token out of command-line arguments and stored reports.
  headers="$(printf 'header = "Authorization: Bearer %s"\n' "$token" \
    | curl -fsSI --connect-timeout 2 --max-time 3 --config - \
      -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json' \
      "https://registry-1.docker.io/v2/${repository}/manifests/${tag}")" || return 1
  digest="$(awk 'tolower($1) == "docker-content-digest:" {gsub(/\r/, "", $2); print $2; exit}' <<<"$headers")"
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || return 1
  printf '%s' "$digest"
}

version_check_image() {
  local mode="$1" repository="" tag="" image="" file="" digest="" latest="" current="" state=unknown installed=0
  local container="" running="" actual=""
  file="$(mode_file "$mode")"
  if [[ "$mode" == ee ]]; then
    repository=nineseconds/mtg tag=2 image="$MTG_IMAGE"
  else repository=telegrammessenger/proxy tag=latest image="$DD_IMAGE"; fi
  if [[ -r "$file" ]]; then
    installed=1
    image="$(read_env_key "$file" "$([[ "$mode" == ee ]] && echo MTG_IMAGE || echo DD_IMAGE)")"
    container="$([[ "$mode" == ee ]] && echo "$EE_CONTAINER_NAME" || echo "$DD_CONTAINER_NAME")"
    running="$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || true)"
    if [[ "$running" == true ]]; then
      actual="$(docker inspect -f '{{.Config.Image}}' "$container" 2>/dev/null || true)"
      if is_valid_digest_image_ref "$actual"; then image="$actual"; fi
    fi
  fi
  current="${image##*@}"
  current="${current:0:19}"
  if [[ "${image%@*}" == "$repository" || "${image%@*}" == "docker.io/$repository" ]]; then
    digest="$(version_registry_digest "$repository" "$tag")" || digest=""
    if [[ -n "$digest" ]]; then
      latest="${digest:0:19}"
      if [[ "$installed" -eq 0 ]]; then
        state=missing
      elif [[ "${image##*@}" == "$digest" ]]; then
        state=latest
      else state=update; fi
    fi
  fi
  if [[ "$mode" == ee ]]; then
    local label=""
    label="$(docker image inspect "$image" --format '{{index .Config.Labels "org.opencontainers.image.version"}}' 2>/dev/null || true)"
    if [[ "$label" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      current="$label (${current})"
      if [[ "${image##*@}" == "$digest" ]]; then latest="$label"; fi
    fi
  fi
  if [[ "$installed" -eq 0 ]]; then current="$(t version_state_missing)"; fi
  version_row "version_${mode}" "$current" "$latest" "$state" "$repository:$tag"
}

version_check_script() {
  local current="" latest="" state=unknown dirty=""
  current="$(git -c "safe.directory=$INSTALLER_DIR" -C "$INSTALLER_DIR" rev-parse HEAD 2>/dev/null || true)"
  latest="$(GIT_TERMINAL_PROMPT=0 timeout 6 git ls-remote https://github.com/xkeon/telegram-proxy-installer.git refs/heads/main 2>/dev/null \
    | awk 'NR == 1 {print $1}')" || latest=""
  if [[ "$current" =~ ^[0-9a-f]{40}$ && "$latest" =~ ^[0-9a-f]{40}$ ]]; then
    if [[ "$current" == "$latest" ]]; then state=latest; else state=update; fi
  else latest=""; fi
  dirty="$(git -c "safe.directory=$INSTALLER_DIR" -C "$INSTALLER_DIR" status --porcelain 2>/dev/null || true)"
  if [[ -n "$dirty" && "$state" == latest ]]; then state=update; fi
  current="${current:0:10}"
  if [[ -n "$dirty" ]]; then current+=" ($(t versions_local_changes))"; fi
  version_row version_script "$current" "${latest:0:10}" "$state" GitHub/main
}

version_check_ubuntu() {
  local os="" current="" latest="" state=unknown
  os="$(read_env_key "$OS_RELEASE_FILE" ID || true)"
  current="$(read_env_key "$OS_RELEASE_FILE" VERSION_ID || true)"
  os="${os//\"/}" current="${current//\"/}"
  if [[ "$os" != ubuntu ]]; then
    version_row version_ubuntu "$os $current" "" skip Ubuntu/LTS
    return 0
  fi
  latest="$(curl -fsSL --connect-timeout 2 --max-time 4 https://changelogs.ubuntu.com/meta-release-lts \
    | python3 -c 'import sys,re,datetime,email.utils
versions=[]
for block in sys.stdin.read().split("\n\n"):
 fields=dict(line.split(": ",1) for line in block.splitlines() if ": " in line)
 match=re.match(r"([0-9]+\.[0-9]+)",fields.get("Version",""))
 if fields.get("Supported") != "1" or not match: continue
 release=match[1]
 try:
  date=email.utils.parsedate_to_datetime(fields["Date"])
  if date.date()>datetime.datetime.now(datetime.timezone.utc).date(): continue
 except (KeyError,ValueError,TypeError): continue
 versions.append((tuple(map(int,release.split("."))),release))
if not versions: sys.exit(1)
print(max(versions)[1])')" || latest=""
  if [[ "$current" =~ ^[0-9]+\.[0-9]+$ && "$latest" =~ ^[0-9]+\.[0-9]+$ ]]; then
    if dpkg --compare-versions "$current" eq "$latest"; then
      state=latest
    elif dpkg --compare-versions "$current" lt "$latest"; then
      state=update
    else state=newer; fi
  fi
  version_row version_ubuntu "$current" "$latest" "$state" Ubuntu/LTS
}

version_check_packages() {
  local fresh=0
  if [[ "$EUID" -eq 0 ]] && timeout 12 apt-get -o APT::Update::Error-Mode=any \
    -o Acquire::Retries=0 -o Acquire::http::Timeout=4 -o Acquire::https::Timeout=4 update -qq >/dev/null 2>&1; then fresh=1; fi
  version_packages_from_index "$fresh"
}

version_packages_from_index() {
  local fresh="$1" package="" current="" candidate="" state="" docker_package=""
  for package in docker-ce docker.io moby-engine; do
    if dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -qx 'install ok installed'; then
      docker_package="$package"
      break
    fi
  done
  if [[ -z "$docker_package" ]] && command -v docker >/dev/null 2>&1; then
    current="$(docker --version 2>/dev/null || true)"
    version_row version_docker "$current" "" unknown APT
  elif [[ -z "$docker_package" ]]; then
    docker_package=docker.io
  fi
  local -a packages=(git curl ca-certificates openssl python3 systemd ufw dnsutils iproute2 qrencode gnupg lsb-release)
  if [[ -n "$docker_package" ]]; then packages=("$docker_package" "${packages[@]}"); fi
  for package in "${packages[@]}"; do
    current="$(dpkg-query -W -f='${Status}\t${Version}' "$package" 2>/dev/null || true)"
    if [[ "$current" == 'install ok installed'$'\t'* ]]; then current="${current#*$'\t'}"; else current=""; fi
    candidate="" state=unknown
    if [[ "$fresh" -eq 1 ]]; then
      candidate="$(LC_ALL=C apt-cache policy "$package" 2>/dev/null | awk '/Candidate:/ {print $2; exit}')"
      [[ "$candidate" != '(none)' ]] || candidate=""
      if [[ -n "$candidate" ]]; then
        if [[ -z "$current" ]]; then
          state=missing
        elif dpkg --compare-versions "$current" lt "$candidate"; then
          state=update
        elif dpkg --compare-versions "$current" eq "$candidate"; then
          state=latest
        else state=newer; fi
      fi
    fi
    version_row "@$package" "$current" "$candidate" "$state" APT
  done
}

version_check_run() {
  local directory="" file="" row="" state="" pid=""
  local -a processes=()
  VERSION_ROWS=() VERSION_CHECKED=0 VERSION_UPDATES=0 VERSION_UNKNOWN=0 VERSION_MISSING=0
  directory="$(mktemp -d)" || return 0
  printf '\n%s\n' "$(t versions_checking)"
  # Independent, bounded queries run together; no package or image is upgraded.
  version_check_script </dev/null >"$directory/script" 2>"$directory/script-error" &
  processes+=("$!")
  version_check_ubuntu </dev/null >"$directory/os" 2>"$directory/os-error" &
  processes+=("$!")
  version_check_image ee </dev/null >"$directory/ee" 2>"$directory/ee-error" &
  processes+=("$!")
  version_check_image dd </dev/null >"$directory/dd" 2>"$directory/dd-error" &
  processes+=("$!")
  version_check_packages </dev/null >"$directory/packages" 2>"$directory/packages-error" &
  processes+=("$!")
  for pid in "${processes[@]}"; do wait "$pid" || true; done
  for file in script os ee dd packages; do
    if [[ ! -s "$directory/$file" ]]; then
      case "$file" in
        script) row=version_script ;; os) row=version_ubuntu ;; ee) row=version_ee ;; dd) row=version_dd ;; packages) row=versions_packages ;;
      esac
      version_row "$row" "" "" unknown "" >"$directory/$file"
    fi
    while IFS= read -r row; do
      [[ -n "$row" ]] || continue
      VERSION_ROWS+=("$row")
      IFS=$'\t' read -r _ _ _ state _ <<<"$row"
      case "$state" in update) VERSION_UPDATES=$((VERSION_UPDATES + 1)) ;; unknown) VERSION_UNKNOWN=$((VERSION_UNKNOWN + 1)) ;; missing) VERSION_MISSING=$((VERSION_MISSING + 1)) ;; esac
    done <"$directory/$file"
  done
  rm -rf "$directory"
  VERSION_CHECKED=1
  return 0
}

version_banner() {
  printf '%s: %s %s · %s %s · %s %s' "$(t versions_title)" "$VERSION_UPDATES" "$(t versions_updates)" \
    "$VERSION_UNKNOWN" "$(t versions_unknown)" "$VERSION_MISSING" "$(t versions_missing)"
}

version_report() {
  local row="" name="" current="" latest="" state="" source="" style=""
  ui_init
  printf '\n%s%s%s\n' "$UI_ACCENT" "$(t versions_title)" "$UI_RESET"
  version_banner
  echo
  printf '\n%s\n' "$(t versions_sources)"
  for row in "${VERSION_ROWS[@]}"; do
    IFS=$'\t' read -r name current latest state source <<<"$row"
    style="$UI_MUTED"
    case "$state" in latest) style="$UI_OK" ;; update | unknown) style="$UI_WARN" ;; esac
    printf '\n%s[%s]%s %s (%s)\n' "$style" "$(t "version_state_$state")" "$UI_RESET" "$(t "$name")" "$source"
    printf '  %s: %s  →  %s: %s\n' "$(t versions_current)" "$current" "$(t versions_latest)" "$latest"
  done
  printf '\n%s\n%s\n' "$(t versions_update_hint)" "$(t versions_unknown_hint)"
}
