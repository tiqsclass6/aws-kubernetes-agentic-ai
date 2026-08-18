#!/usr/bin/env bash
# Shared terminal colors and section helpers for lab scripts.
# Source this file; do not execute it.
#
# COLOR_OUTPUT=auto|always|never  (default: auto)
# NO_COLOR=1                      disables color in auto mode

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  printf 'ERROR: Do not execute %s. Source it from another script.\n' "${BASH_SOURCE[0]}" >&2
  exit 2
fi

if [[ -n "${_AGENTIC_UI_LOADED:-}" ]]; then
  return 0
fi
_AGENTIC_UI_LOADED=1

COLOR_OUTPUT="${COLOR_OUTPUT:-auto}"
USE_COLOR=false

case "${COLOR_OUTPUT}" in
  always)
    USE_COLOR=true
    ;;
  never)
    USE_COLOR=false
    ;;
  auto)
    if [[ -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" && ( -t 1 || -t 2 ) ]]; then
      USE_COLOR=true
    fi
    ;;
  *)
    printf 'ERROR: COLOR_OUTPUT must be auto, always, or never.\n' >&2
    exit 2
    ;;
esac

if $USE_COLOR; then
  RESET=$'\033[0m'
  BOLD=$'\033[1m'
  DIM=$'\033[2m'
  RED=$'\033[0;31m'
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[1;33m'
  BLUE=$'\033[0;34m'
  MAGENTA=$'\033[0;35m'
  CYAN=$'\033[0;36m'
  BRIGHT_BLUE=$'\033[1;34m'
  BRIGHT_MAGENTA=$'\033[1;35m'
  BRIGHT_CYAN=$'\033[1;36m'
  WHITE=$'\033[1;37m'
else
  RESET=''
  BOLD=''
  DIM=''
  RED=''
  GREEN=''
  YELLOW=''
  BLUE=''
  MAGENTA=''
  CYAN=''
  BRIGHT_BLUE=''
  BRIGHT_MAGENTA=''
  BRIGHT_CYAN=''
  WHITE=''
fi

timestamp_utc() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

emit() {
  local color="$1"
  local level="$2"
  shift 2

  printf '%b[%s] %-9s %s%b\n' \
    "$color" \
    "$(timestamp_utc)" \
    "[${level}]" \
    "$*" \
    "$RESET"
}

log() {
  emit "$CYAN" "INFO" "$*"
}

success() {
  emit "$GREEN" "OK" "$*"
}

warn() {
  emit "$YELLOW" "WARNING" "$*"
}

error() {
  emit "$RED" "ERROR" "$*" >&2
}

action() {
  emit "$BRIGHT_MAGENTA" "ACTION" "$*"
}

die() {
  error "$*"
  exit 1
}

section_with_color() {
  local color="$1"
  shift

  printf '\n%b%s%b\n' "${color}${BOLD}" \
    '================================================================' "$RESET"
  printf '%b%s%b\n' "${color}${BOLD}" "$*" "$RESET"
  printf '%b%s%b\n' "${color}${BOLD}" \
    '================================================================' "$RESET"
}

section() {
  section_with_color "$BRIGHT_CYAN" "$*"
}

success_section() {
  section_with_color "$GREEN" "$*"
}

warn_section() {
  section_with_color "$YELLOW" "$*"
}

require_command() {
  local command_name="$1"
  command -v "$command_name" >/dev/null 2>&1 ||
    die "Required command not found: ${command_name}"
}
