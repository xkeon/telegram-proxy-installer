#!/usr/bin/env bash
set -euo pipefail

# Standalone entry point: prepare the checkout before loading its management menu.
BOOTSTRAP_STAGE=""

bootstrap_cleanup() {
  if [[ -n "$BOOTSTRAP_STAGE" && -d "$BOOTSTRAP_STAGE" ]]; then rm -rf -- "$BOOTSTRAP_STAGE"; fi
}

bootstrap_as_root() {
  if [[ "$EUID" -eq 0 ]]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    printf '%s\n' 'Root or sudo is required / 需要 root 或 sudo 权限。' >&2
    return 1
  fi
}

bootstrap_check_checkout() {
  local directory="$1" file=""
  for file in install.sh lib/cli.sh lib/installer.sh lib/management.sh lib/menu.sh \
    lib/messages.sh lib/migration.sh lib/operations.sh lib/terminal.sh lib/setup-ui.sh lib/verification.sh; do
    [[ -r "${directory}/${file}" ]] || {
      printf '%s %s\n' 'Incomplete download / 项目文件不完整：' "$file" >&2
      return 1
    }
  done
}

bootstrap_main() {
  local language="" directory="${TELEGRAM_PROXY_DIR:-${HOME}/telegram-proxy-installer}" dirty="" contents=""
  while (($#)); do
    case "$1" in
      --lang)
        [[ "$#" -ge 2 ]] || return 2
        case "$2" in en | zh | ko | ja) language="$2" ;; *) return 2 ;; esac
        shift 2
        ;;
      -h | --help)
        printf '%s\n' 'Usage: bash bootstrap.sh [--lang en|zh|ko|ja]' \
          'Installs Git if needed, downloads or updates the project, and opens the management menu.' \
          '自动安装所需的 Git，下载或更新项目，然后进入实际管理菜单。'
        return 0
        ;;
      *)
        printf '%s %s\n' 'Unsupported argument / 不支持的参数：' "$1" >&2
        return 2
        ;;
    esac
  done
  [[ "$directory" == /* && "$directory" != / ]] || {
    printf '%s\n' 'TELEGRAM_PROXY_DIR must be an absolute directory / 请使用绝对目录路径。' >&2
    return 2
  }

  if ! command -v git >/dev/null 2>&1 || [[ ! -r /etc/ssl/certs/ca-certificates.crt ]]; then
    command -v apt-get >/dev/null 2>&1 || {
      printf '%s\n' 'apt-get is required / 需要 apt-get 安装依赖。' >&2
      return 1
    }
    bootstrap_as_root apt-get update || return 1
    bootstrap_as_root apt-get install -y git ca-certificates || return 1
  fi

  if [[ -e "${directory}/.git" ]]; then
    dirty="$(git -C "$directory" status --porcelain)" || return 1
    [[ -z "$dirty" ]] || {
      printf '%s\n' 'Local changes found; preserve them before updating / 仓库有本地变更，请先保存后再更新。' >&2
      return 1
    }
    git -C "$directory" pull --ff-only || return 1
    bootstrap_check_checkout "$directory" || return 1
  else
    if [[ -e "$directory" ]]; then
      [[ -d "$directory" ]] || return 1
      contents="$(find "$directory" -mindepth 1 -maxdepth 1 -print -quit)" || return 1
      [[ -z "$contents" ]] || {
        printf '%s %s\n' 'Directory is not an empty checkout / 目录不是空目录或 Git 项目：' "$directory" >&2
        return 1
      }
    fi
    mkdir -p "$(dirname "$directory")" || return 1
    BOOTSTRAP_STAGE="$(mktemp -d "$(dirname "$directory")/.telegram-proxy-download.XXXXXX")" || return 1
    if ! git clone --branch main --single-branch https://github.com/xkeon/telegram-proxy-installer.git "$BOOTSTRAP_STAGE" \
      || ! bootstrap_check_checkout "$BOOTSTRAP_STAGE" || ! mv -T "$BOOTSTRAP_STAGE" "$directory"; then
      bootstrap_cleanup
      BOOTSTRAP_STAGE=""
      return 1
    fi
    BOOTSTRAP_STAGE=""
  fi

  if [[ -n "$language" ]]; then
    bootstrap_as_root bash "${directory}/install.sh" --lang "$language"
  else bootstrap_as_root bash "${directory}/install.sh"; fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  trap bootstrap_cleanup EXIT
  bootstrap_main "$@"
fi
