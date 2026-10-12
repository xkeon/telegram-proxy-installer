#!/usr/bin/env bash
# Terminal rendering and input stay independent from service operations.
UI_NAVIGATION=0 UI_WIDTH=76 UI_HEIGHT=24 UI_COLUMNS=1 UI_UNICODE=0
UI_ACCENT="" UI_MUTED="" UI_RESET="" UI_SELECTED="" UI_OK="" UI_WARN=""
UI_MARK=">" UI_DOT="*" UI_TEXT_RESULT=""
UI_BREADCRUMB="" UI_CONTEXT="" UI_SCOPE=""
declare -A UI_MODE_STATE=() UI_MODE_ENDPOINT=()
UI_MAIN_OPTIONS=(1:home_connect 2:home_health 3:home_config 4:home_updates 5:home_monitor 6:home_more 0:menu_exit)
UI_EMPTY_OPTIONS=(1:home_install 2:home_migrate 3:home_more 0:menu_exit)

ui_dimensions() {
  local cols="${COLUMNS:-80}" lines="${LINES:-24}" size=""
  if [[ -t 0 ]] && command -v stty >/dev/null 2>&1; then size="$(stty size 2>/dev/null)" || true; fi
  if [[ "$size" =~ ^[0-9]+\ [0-9]+$ ]]; then read -r lines cols <<<"$size"; fi
  [[ "$cols" =~ ^[0-9]{1,4}$ ]] || cols=80
  [[ "$lines" =~ ^[0-9]{1,4}$ ]] || lines=24
  UI_WIDTH=$((10#$cols)) UI_HEIGHT=$((10#$lines))
  if ((UI_WIDTH > 88)); then UI_WIDTH=88; fi
  if ((UI_WIDTH < 1)); then UI_WIDTH=1; fi
}

ui_init() {
  UI_NAVIGATION=0 UI_UNICODE=0 UI_COLUMNS=1
  UI_ACCENT="" UI_MUTED="" UI_RESET="" UI_SELECTED="" UI_OK="" UI_WARN=""
  UI_MARK=">" UI_DOT="*"
  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *[Uu][Tt][Ff]-8* | *[Uu][Tt][Ff]8*) UI_UNICODE=1 UI_MARK="›" UI_DOT="●" ;;
  esac
  ui_dimensions
  if [[ -t 0 && -t 1 && "${TERM:-dumb}" != dumb ]] && ((UI_WIDTH >= 32 && UI_HEIGHT >= 14)); then
    UI_NAVIGATION=1
    local colors=8
    if command -v tput >/dev/null 2>&1; then colors="$(tput colors 2>/dev/null)" || colors=0; fi
    if [[ -z "${NO_COLOR+x}" && "$colors" =~ ^[0-9]+$ ]] && ((colors >= 8)); then
      UI_ACCENT=$'\033[1;36m' UI_MUTED=$'\033[2m' UI_RESET=$'\033[0m'
      UI_SELECTED=$'\033[1;37;44m' UI_OK=$'\033[32m' UI_WARN=$'\033[33m'
      if ((colors >= 256)); then
        UI_ACCENT=$'\033[1;38;5;81m' UI_MUTED=$'\033[38;5;245m'
        UI_SELECTED=$'\033[1;38;5;231;48;5;24m'
        UI_OK=$'\033[38;5;114m' UI_WARN=$'\033[38;5;215m'
      fi
    fi
  fi
}

ui_char_width() {
  local code=0
  printf -v code '%d' "'$1"
  UI_CHAR_WIDTH=1
  if ((code >= 0x300 && code <= 0x36f)); then
    UI_CHAR_WIDTH=0
  elif ((code >= 0x1100 && (code <= 0x115f || (code >= 0x2e80 && code <= 0xa4cf) || (\
    code >= 0xac00 && code <= 0xd7a3) || (code >= 0xf900 && code <= 0xfaff) || (\
    code >= 0xfe10 && code <= 0xfe6f) || (code >= 0xff01 && code <= 0xff60) || (\
    code >= 0xffe0 && code <= 0xffe6) || code >= 0x20000))); then UI_CHAR_WIDTH=2; fi
}

ui_fit_text() {
  local input="$1" limit="$2" char="" used=0 position=0 suffix="…"
  UI_TEXT_RESULT=""
  [[ "$UI_UNICODE" -eq 1 ]] || suffix="."
  for ((position = 0; position < ${#input}; position++)); do
    char="${input:position:1}"
    ui_char_width "$char"
    if ((used + UI_CHAR_WIDTH > limit)); then break; fi
    UI_TEXT_RESULT+="$char"
    used=$((used + UI_CHAR_WIDTH))
  done
  if ((position < ${#input} && limit > 0)); then
    # Leave one display cell for the truncation marker.
    if ((used == limit)); then
      char="${UI_TEXT_RESULT: -1}"
      ui_char_width "$char"
      UI_TEXT_RESULT="${UI_TEXT_RESULT%?}"
      used=$((used - UI_CHAR_WIDTH))
    fi
    UI_TEXT_RESULT+="$suffix"
    used=$((used + 1))
  fi
  local padding=""
  printf -v padding '%*s' "$((limit - used))" ""
  UI_TEXT_RESULT+="$padding"
}

ui_cell() {
  local text="$1" width="$2" style="${3:-}"
  LC_ALL=C.UTF-8 ui_fit_text "$text" "$width"
  printf '%s%s%s' "$style" "$UI_TEXT_RESULT" "$UI_RESET"
}

ui_collect_mode() {
  local mode="$1" file="" service="" host="" port=""
  file="$(mode_file "$mode")" service="$(mode_service "$mode")"
  UI_MODE_STATE["$mode"]=ui_unmanaged UI_MODE_ENDPOINT["$mode"]="-"
  if [[ -r "$file" ]]; then
    port="$(read_env_key "$file" "${mode^^}_PORT")"
    port="$(normalize_port "$port")" || port="?"
    host="$(read_env_key "$file" "${mode^^}_DOMAIN")"
    valid_endpoint "$host" || host="-"
    UI_MODE_ENDPOINT["$mode"]="${host}:${port}"
    if ! command -v systemctl >/dev/null 2>&1; then
      UI_MODE_STATE["$mode"]=ui_unknown
    elif systemctl is-active --quiet "$service" 2>/dev/null; then
      UI_MODE_STATE["$mode"]=ui_running
    else UI_MODE_STATE["$mode"]=ui_stopped; fi
  elif [[ -e "$file" || -e "${SYSTEMD_UNIT_DIR}/${service}" || (-d "$CONFIG_DIR" && ! -x "$CONFIG_DIR") ]]; then
    UI_MODE_STATE["$mode"]=ui_unknown
  fi
}

ui_refresh_status() {
  ui_collect_mode ee
  ui_collect_mode dd
}

ui_main_default() { echo 1; }

ui_home_options() {
  if [[ -f "$EE_ENV_FILE" || -f "$DD_ENV_FILE" ]]; then
    printf '%s\n' "${UI_MAIN_OPTIONS[@]}"
  else printf '%s\n' "${UI_EMPTY_OPTIONS[@]}"; fi
}

ui_border() {
  local width="$1" left="$2" right="$3" fill="─" repeated=""
  [[ "$UI_UNICODE" -eq 1 ]] || {
    left="+"
    right="+"
    fill="-"
  }
  printf -v repeated '%*s' "$((width - 2))" ""
  printf '%s%s%s%s%s' "$UI_MUTED" "$left" "${repeated// /$fill}" "$right" "$UI_RESET"
}

ui_status_card_line() {
  local mode="$1" width="$2" line="$3" edge="│" state="" color="$UI_MUTED" title=""
  [[ "$UI_UNICODE" -eq 1 ]] || edge="|"
  state="${UI_MODE_STATE[$mode]:-ui_unmanaged}"
  case "$state" in ui_running) color="$UI_OK" ;; ui_stopped) color="$UI_WARN" ;; esac
  if [[ "$line" == 0 ]]; then
    ui_border "$width" "╭" "╮"
  elif [[ "$line" == 3 ]]; then
    ui_border "$width" "╰" "╯"
  else
    printf '%s%s%s ' "$UI_MUTED" "$edge" "$UI_RESET"
    if [[ "$line" == 1 ]]; then
      if [[ "$mode" == ee ]]; then title="EE · FakeTLS"; else title="DD · Padding"; fi
      ui_cell "$title" "$((width / 2 - 3))" "$UI_ACCENT"
      ui_cell "${UI_DOT} $(t "$state")" "$((width - width / 2 - 1))" "$color"
    else ui_cell "${UI_MODE_ENDPOINT[$mode]:--}" "$((width - 4))" "$UI_MUTED"; fi
    printf ' %s%s%s' "$UI_MUTED" "$edge" "$UI_RESET"
  fi
}

ui_dashboard() {
  local width="$((UI_WIDTH - 4))" half=0 line=0
  if [[ ! -f "$EE_ENV_FILE" && ! -f "$DD_ENV_FILE" ]]; then
    printf '  %s%s%s\n' "$UI_ACCENT" "$(t home_empty)" "$UI_RESET"
    if ((UI_WIDTH >= 60)); then printf '  %s%s%s\n' "$UI_MUTED" "$(t home_empty_hint)" "$UI_RESET"; fi
    return
  fi
  if ((UI_WIDTH >= 70)); then
    half=$(((width - 2) / 2))
    for ((line = 0; line < 4; line++)); do
      printf '  '
      ui_status_card_line ee "$half" "$line"
      printf '  '
      ui_status_card_line dd "$((width - half - 2))" "$line"
      echo
    done
  else
    local mode=""
    for mode in ee dd; do
      printf '  '
      ui_cell "${mode^^} ${UI_DOT} $(t "${UI_MODE_STATE[$mode]:-ui_unmanaged}") ${UI_MODE_ENDPOINT[$mode]:--}" "$width"
      echo
    done
  fi
}

ui_option_line() {
  local item="$1" width="$2" selected="$3" detail="${4:-0}" id="" key="" style="" marker=" "
  id="${item%%:*}" key="${item#*:}"
  if [[ "$selected" -eq 1 && "$UI_NAVIGATION" -eq 1 ]]; then
    style="$UI_SELECTED"
    marker="$UI_MARK"
  fi
  if [[ "$detail" -eq 1 ]]; then
    local hint=""
    hint="$(t "hint_${key}")"
    [[ "$hint" != "hint_${key}" ]] || hint=""
    ui_cell "     ${hint}" "$width" "${style:-$UI_MUTED}"
  else ui_cell " ${marker} ${id}  $(t "$key")" "$width" "$style"; fi
}

ui_render() {
  local title="$1" kind="$2" index="$3" digits="$4" error="$5"
  shift 5
  local -a items=("$@")
  local start=0 end="${#items[@]}" limit=0 i=0 left=0 right=0 width="$((UI_WIDTH - 4))" half=0 detail=0 selected=0
  ui_dimensions
  width=$((UI_WIDTH - 4))
  if ((width < 12)); then width=12; fi
  UI_COLUMNS=1
  if [[ "$kind" == main && "$UI_NAVIGATION" -eq 1 ]] && ((UI_WIDTH >= 70 && UI_HEIGHT >= 22 + VERSION_CHECKED && ${#items[@]} == 7)); then UI_COLUMNS=2; fi
  if [[ "$UI_NAVIGATION" -eq 1 ]]; then printf '\033[H\033[2J'; fi
  echo
  printf '  %sTELEGRAM PROXY%s\n' "$UI_ACCENT" "$UI_RESET"
  printf '  '
  ui_cell "${UI_BREADCRUMB:+${UI_BREADCRUMB} / }$(t "$title")" "$width" "$UI_ACCENT"
  echo
  if [[ "$kind" == main ]]; then ui_dashboard; fi
  if [[ "$kind" == main && "$VERSION_CHECKED" -eq 1 ]]; then
    local version_style="$UI_WARN"
    if [[ "$VERSION_UPDATES" -eq 0 && "$VERSION_UNKNOWN" -eq 0 && "$VERSION_MISSING" -eq 0 ]]; then version_style="$UI_OK"; fi
    printf '  '
    ui_cell "$(version_banner)" "$width" "$version_style"
    echo
  fi
  if [[ "$kind" == panel && -n "$UI_SCOPE" && ("$title" == home_config || "$title" == home_updates || "$title" == home_monitor) ]]; then
    printf '  '
    ui_cell "$(t managed_scope): $UI_SCOPE" "$width" "$UI_MUTED"
    echo
  fi
  if [[ "$kind" == review && -n "$UI_CONTEXT" ]]; then
    local context_line=""
    while IFS= read -r context_line; do
      printf '  '
      ui_cell "$context_line" "$width"
      echo
    done <<<"$UI_CONTEXT"
  fi
  echo
  if [[ "$UI_COLUMNS" -eq 2 ]]; then
    half=$(((width - 2) / 2))
    for ((left = 0; left < 6; left += 2)); do
      right=$((left + 1))
      for detail in 0 1; do
        printf '  '
        selected=0
        [[ "$index" -ne "$left" ]] || selected=1
        ui_option_line "${items[left]}" "$half" "$selected" "$detail"
        printf '  '
        selected=0
        [[ "$index" -ne "$right" ]] || selected=1
        ui_option_line "${items[right]}" "$((width - half - 2))" "$selected" "$detail"
        echo
      done
      echo
    done
    printf '  '
    selected=0
    [[ "$index" -ne 6 ]] || selected=1
    ui_option_line "${items[6]}" "$width" "$selected"
    echo
  else
    limit=$((UI_HEIGHT - 11))
    if [[ "$kind" == main && "$VERSION_CHECKED" -eq 1 ]]; then limit=$((limit - 1)); fi
    if [[ "$kind" != main ]]; then limit=$((UI_HEIGHT - 8)); fi
    if ((limit < 3)); then limit=3; fi
    if [[ "$UI_NAVIGATION" -eq 1 ]]; then
      if ((index >= limit)); then start=$((index - limit + 1)); fi
      if ((end > start + limit)); then end=$((start + limit)); fi
    fi
    for ((i = start; i < end; i++)); do
      printf '  '
      selected=0
      [[ "$index" -ne "$i" ]] || selected=1
      ui_option_line "${items[i]}" "$width" "$selected"
      echo
    done
    if [[ "$kind" == main ]] && ((UI_WIDTH >= 60 && UI_HEIGHT >= 22)); then
      local hint=""
      hint="$(t "hint_${items[index]#*:}")"
      printf '\n  %s%s%s\n' "$UI_MUTED" "$hint" "$UI_RESET"
    fi
  fi
  echo
  printf '  '
  if [[ "$UI_NAVIGATION" -eq 1 ]]; then
    ui_cell "$(t ui_keys)" "$width" "$UI_MUTED"
  else ui_cell "$(t ui_keys_plain)" "$width" "$UI_MUTED"; fi
  echo
  if [[ -n "$error" ]]; then
    printf '  '
    ui_cell "$error" "$width" "$UI_WARN"
    echo
  elif [[ -n "$digits" ]]; then
    printf '  %s: %s\n' "$(t ui_prompt)" "$digits"
  elif [[ "$UI_NAVIGATION" -eq 1 ]]; then
    printf '  '
    ui_cell "$(t ui_shortcuts)" "$width" "$UI_MUTED"
    echo
  fi
}

ui_option_index() {
  local wanted="$1" item="" position=0
  shift
  for item in "$@"; do
    if [[ "${item%%:*}" == "$wanted" ]]; then
      printf '%s' "$position"
      return 0
    fi
    position=$((position + 1))
  done
  return 1
}

ui_select() {
  local destination="$1" title="$2" kind="$3" default="$4"
  shift 4
  local -a items=("$@")
  local index=0 match=0 input="" key="" next="" arrow="" digits="" error="" stride=1
  ui_init
  if [[ "$kind" == review && -n "$UI_CONTEXT" ]]; then
    local context_rows=0 context_line=""
    while IFS= read -r context_line; do context_rows=$((context_rows + 1)); done <<<"$UI_CONTEXT"
    # Long reviews stay in scrollback so no configuration is hidden by redraws.
    if ((context_rows + ${#items[@]} + 8 > UI_HEIGHT)); then UI_NAVIGATION=0; fi
  fi
  index="$(ui_option_index "$default" "${items[@]}")" || return 1
  if [[ "$kind" == main ]]; then ui_refresh_status; fi
  ui_render "$title" "$kind" "$index" "" "" "${items[@]}"
  if [[ "$UI_NAVIGATION" -eq 0 ]]; then
    while read -r -p "$(t ui_prompt) [${default}]: " input; do
      input="${input// /}"
      case "$input" in q | Q) input=0 ;; "") input="$default" ;;
      r | R)
        if [[ "$kind" == main ]]; then ui_refresh_status; fi
        ui_render "$title" "$kind" "$index" "" "" "${items[@]}"
        continue
        ;;
      esac
      if ui_option_index "$input" "${items[@]}" >/dev/null; then
        printf -v "$destination" '%s' "$input"
        return 0
      fi
      t err_choice_invalid
    done
    return 1
  fi
  while IFS= read -r -s -n 1 key; do
    error=""
    case "$key" in
      $'\033')
        next="" arrow=""
        if ! IFS= read -r -s -n 1 -t 0.15 next; then
          printf -v "$destination" '%s' 0
          echo
          return 0
        fi
        if [[ "$next" != "[" && "$next" != O ]]; then continue; fi
        IFS= read -r -s -n 1 -t 0.15 arrow || true
        stride="$UI_COLUMNS"
        case "$arrow" in
          A) if ((index < stride)); then index=$((${#items[@]} - 1)); else index=$((index - stride)); fi ;;
          B)
            if ((index == ${#items[@]} - 1)); then
              index=0
            else
              index=$((index + stride))
              if ((index >= ${#items[@]})); then index=$((${#items[@]} - 1)); fi
            fi
            ;;
          C) index=$(((index + 1) % ${#items[@]})) ;;
          D) index=$(((index + ${#items[@]} - 1) % ${#items[@]})) ;;
          H) index=0 ;; F) index=$((${#items[@]} - 1)) ;; *) continue ;;
        esac
        digits=""
        ;;
      "" | $'\r')
        input="${items[index]%%:*}"
        if [[ -n "$digits" ]]; then input="$digits"; fi
        if ui_option_index "$input" "${items[@]}" >/dev/null; then
          printf -v "$destination" '%s' "$input"
          echo
          return 0
        fi
        digits="" error="$(t err_choice_invalid)"
        ;;
      [0-9])
        if ((${#digits} >= 2)); then digits=""; fi
        digits+="$key"
        if match="$(ui_option_index "$digits" "${items[@]}")"; then index="$match"; fi
        ;;
      $'\177' | $'\b')
        digits="${digits%?}"
        if [[ -n "$digits" ]] && match="$(ui_option_index "$digits" "${items[@]}")"; then index="$match"; fi
        ;;
      q | Q)
        printf -v "$destination" '%s' 0
        echo
        return 0
        ;;
      $'\004')
        echo
        return 1
        ;;
      r | R)
        digits=""
        if [[ "$kind" == main ]]; then ui_refresh_status; fi
        ;;
      *) continue ;;
    esac
    ui_render "$title" "$kind" "$index" "$digits" "$error" "${items[@]}"
  done
  echo
  return 1
}
