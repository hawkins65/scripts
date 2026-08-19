#!/usr/bin/env bash
# check_logs.sh — Report errors and warnings from shredstream-proxy logs.
#
# Usage:
#   ./check_logs.sh                                        # interactive config, then run
#   ./check_logs.sh journalctl                             # use journalctl
#   ./check_logs.sh /var/log/shredstream-proxy.log         # use log file
#
# All variables can also be preset via environment before running.

set -euo pipefail

# ── Colors (needed early for the config menu) ────────────────────────────────
if [[ -z "${NO_COLOR:-}" && -t 1 ]]; then
    RED='\033[0;31m'
    YELLOW='\033[0;33m'
    CYAN='\033[0;36m'
    GREEN='\033[0;32m'
    BOLD='\033[1m'
    DIM='\033[2m'
    RESET='\033[0m'
else
    RED='' YELLOW='' CYAN='' GREEN='' BOLD='' DIM='' RESET=''
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
die() { printf '%bERROR: %s%b\n' "${RED}" "$*" "${RESET}" >&2; exit 1; }

print_header() {
    echo
    printf '%b%s%b\n' "${BOLD}" "$1" "${RESET}"
    printf '%*s\n' "${#1}" '' | tr ' ' '-'
}

count_matches() {
    grep -c . || true
}

# ── Resolve positional parameter ──────────────────────────────────────────────
# Accept an optional first argument: "journalctl" or a file path.
ARG="${1:-}"
if [[ -n "${ARG}" ]]; then
    if [[ "${ARG}" == "journalctl" ]]; then
        LOG_SOURCE="journalctl"
    elif [[ -f "${ARG}" || "${ARG}" == /* ]]; then
        LOG_SOURCE="file"
        LOG_FILE="${ARG}"
    else
        die "Argument '${ARG}' is not 'journalctl' or a valid file path"
    fi
fi

# ── Configuration defaults (env overrides apply before menu) ──────────────────
LOG_SOURCE="${LOG_SOURCE:-journalctl}"
LOOKBACK_HOURS="${LOOKBACK_HOURS:-12}"
LOG_FILE="${LOG_FILE:-}"
SHOW_CONTEXT_LINES="${SHOW_CONTEXT_LINES:-0}"
NO_COLOR="${NO_COLOR:-}"

# ── Auto-detect systemd service unit from /etc/systemd/system/*shred* ────────
_detected_unit=""
if [[ -d /etc/systemd/system ]]; then
    _svc_file=$(compgen -G '/etc/systemd/system/*shred*' 2>/dev/null | head -1 || true)
    if [[ -n "${_svc_file}" ]]; then
        _detected_unit=$(basename "${_svc_file}" .service)
    fi
fi
JOURNALCTL_UNIT="${JOURNALCTL_UNIT:-${_detected_unit:-shredstream-proxy}}"

# ── Auto-detect log file in ~/logs/<unit>.log ─────────────────────────────────
# If the user hasn't already specified a source/file via env or CLI arg,
# check whether ~/logs/<unit>.log exists and was modified within the lookback
# window. If so, prefer it over journalctl.
if [[ "${LOG_SOURCE}" == "journalctl" && -z "${LOG_FILE}" ]]; then
    _candidate="${HOME}/logs/${JOURNALCTL_UNIT}.log"
    if [[ -f "${_candidate}" ]]; then
        _recent=$(find "${_candidate}" -maxdepth 0 \
            -newermt "${LOOKBACK_HOURS} hours ago" 2>/dev/null || true)
        if [[ -n "${_recent}" ]]; then
            LOG_SOURCE="file"
            LOG_FILE="${_candidate}"
        fi
    fi
fi

# ── Interactive configuration menu ───────────────────────────────────────────
show_menu() {
    printf '\n%b  shredstream-proxy log checker — configuration%b\n' "${BOLD}" "${RESET}"
    printf '%b  ──────────────────────────────────────────────%b\n' "${DIM}" "${RESET}"
    printf '  %b1)%b  LOG_SOURCE          = %b%s%b\n'  "${BOLD}" "${RESET}" "${CYAN}" "${LOG_SOURCE}"          "${RESET}"
    printf '  %b2)%b  JOURNALCTL_UNIT     = %b%s%b\n'  "${BOLD}" "${RESET}" "${CYAN}" "${JOURNALCTL_UNIT}"     "${RESET}"
    printf '  %b3)%b  LOOKBACK_HOURS      = %b%s%b\n'  "${BOLD}" "${RESET}" "${CYAN}" "${LOOKBACK_HOURS}"      "${RESET}"
    printf '  %b4)%b  LOG_FILE            = %b%s%b\n'  "${BOLD}" "${RESET}" "${CYAN}" "${LOG_FILE:-(not set)}" "${RESET}"
    printf '  %b5)%b  SHOW_CONTEXT_LINES  = %b%s%b\n'  "${BOLD}" "${RESET}" "${CYAN}" "${SHOW_CONTEXT_LINES}"  "${RESET}"
    printf '  %b6)%b  NO_COLOR            = %b%s%b\n'  "${BOLD}" "${RESET}" "${CYAN}" "${NO_COLOR:-(not set)}" "${RESET}"
    printf '%b  ──────────────────────────────────────────────%b\n' "${DIM}" "${RESET}"
    printf '  %b0)%b  Continue and run\n' "${GREEN}${BOLD}" "${RESET}"
    printf '\n'
}

# Present a numbered list of fixed choices.
# Sets global _selected_value; never runs in a subshell.
_selected_value=""
select_value() {
    local label="$1" current="$2"; shift 2
    local -a opts=("$@")
    local i pick
    printf '%b%s%b\n' "${BOLD}" "${label}" "${RESET}"
    for i in "${!opts[@]}"; do
        if [[ "${opts[$i]}" == "${current}" ]]; then
            printf '  %b%d) %s  ◀ current%b\n' "${CYAN}" "$(( i + 1 ))" "${opts[$i]}" "${RESET}"
        else
            printf '  %d) %s\n' "$(( i + 1 ))" "${opts[$i]}"
        fi
    done
    while true; do
        printf 'Choice [1-%d, Enter to keep current]: ' "${#opts[@]}"
        read -r pick
        if [[ -z "${pick}" ]]; then
            _selected_value="${current}"; return
        fi
        if [[ "${pick}" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#opts[@]} )); then
            _selected_value="${opts[$(( pick - 1 ))]}"; return
        fi
        printf '%bInvalid — enter a number between 1 and %d.%b\n' "${RED}" "${#opts[@]}" "${RESET}"
    done
}

config_menu() {
    while true; do
        show_menu
        printf '%bSelect a variable to modify, or Enter/0 to continue:%b ' "${BOLD}" "${RESET}"
        read -r choice

        case "${choice}" in
            0|'') break ;;
            1)
                select_value "LOG_SOURCE" "${LOG_SOURCE}" journalctl file
                LOG_SOURCE="${_selected_value}"
                ;;
            2)
                printf 'JOURNALCTL_UNIT [%s]: ' "${JOURNALCTL_UNIT}"
                read -r val
                [[ -n "${val}" ]] && JOURNALCTL_UNIT="${val}"
                ;;
            3)
                printf 'LOOKBACK_HOURS [%s]: ' "${LOOKBACK_HOURS}"
                read -r val
                [[ -n "${val}" ]] && LOOKBACK_HOURS="${val}"
                ;;
            4)
                while true; do
                    printf 'LOG_FILE (full path) [%s]: ' "${LOG_FILE}"
                    read -r val
                    [[ -z "${val}" ]] && break
                    val="${val/#\~/$HOME}"
                    if [[ -f "${val}" ]]; then
                        LOG_FILE="${val}"
                        break
                    fi
                    printf '%bFile not found: %s%b\n' "${RED}" "${val}" "${RESET}"
                    printf 'Enter a valid path, or press Enter to keep current value.\n'
                done
                ;;
            5)
                printf 'SHOW_CONTEXT_LINES [%s]: ' "${SHOW_CONTEXT_LINES}"
                read -r val
                [[ -n "${val}" ]] && SHOW_CONTEXT_LINES="${val}"
                ;;
            6)
                select_value "NO_COLOR" "${NO_COLOR:-enabled}" enabled disabled
                NO_COLOR="${_selected_value}"
                [[ "${NO_COLOR}" == "enabled" ]] && NO_COLOR=""
                if [[ -z "${NO_COLOR}" && -t 1 ]]; then
                    RED='\033[0;31m' YELLOW='\033[0;33m' CYAN='\033[0;36m'
                    GREEN='\033[0;32m' BOLD='\033[1m' DIM='\033[2m' RESET='\033[0m'
                else
                    RED='' YELLOW='' CYAN='' GREEN='' BOLD='' DIM='' RESET=''
                fi
                ;;
            *)
                printf '%bInvalid choice. Enter 1-6 or 0 to continue.%b\n' "${RED}" "${RESET}"
                ;;
        esac
    done
}

# Only show the menu when stdin is a terminal (skip in piped/CI contexts)
if [[ -t 0 ]]; then
    config_menu
fi

# ── Effective command line ────────────────────────────────────────────────────
build_cmdline() {
    local cmd="$0"
    [[ "${LOG_SOURCE}" == "file" ]]      && cmd="LOG_SOURCE=file ${cmd}"
    [[ -n "${NO_COLOR}" ]]               && cmd="NO_COLOR=1 ${cmd}"
    [[ "${SHOW_CONTEXT_LINES}" != "0" ]] && cmd="SHOW_CONTEXT_LINES=${SHOW_CONTEXT_LINES} ${cmd}"
    if [[ "${LOG_SOURCE}" == "journalctl" ]]; then
        [[ "${JOURNALCTL_UNIT}" != "${_detected_unit:-shredstream-proxy}" ]] \
            && cmd="JOURNALCTL_UNIT=${JOURNALCTL_UNIT} ${cmd}"
        [[ "${LOOKBACK_HOURS}" != "12" ]] \
            && cmd="LOOKBACK_HOURS=${LOOKBACK_HOURS} ${cmd}"
        cmd="${cmd} journalctl"
    else
        [[ "${LOOKBACK_HOURS}" != "12" ]] \
            && cmd="LOOKBACK_HOURS=${LOOKBACK_HOURS} ${cmd}"
        cmd="${cmd} ${LOG_FILE}"
    fi
    echo "${cmd}"
}

# ── Input validation ──────────────────────────────────────────────────────────
case "${LOG_SOURCE}" in
    journalctl)
        command -v journalctl &>/dev/null || die "journalctl not found; set LOG_SOURCE=file"
        ;;
    file)
        [[ -n "${LOG_FILE}" ]] || die "LOG_SOURCE=file requires LOG_FILE to be set"
        [[ -f "${LOG_FILE}" ]] || die "Log file not found: ${LOG_FILE}"
        ;;
    *)
        die "LOG_SOURCE must be 'journalctl' or 'file' (got: '${LOG_SOURCE}')"
        ;;
esac

# ── Fetch raw log stream ──────────────────────────────────────────────────────
# For journalctl: --since handles the window.
# For files: filter lines by comparing the embedded ISO8601 timestamp against
# the computed UTC cutoff; lines without a timestamp (e.g. panic backtraces)
# are always included.
get_log_stream() {
    if [[ "${LOG_SOURCE}" == "journalctl" ]]; then
        journalctl \
            --unit="${JOURNALCTL_UNIT}" \
            --since="${LOOKBACK_HOURS} hours ago" \
            --no-pager \
            --output=short-iso 2>/dev/null
    else
        local cutoff
        cutoff=$(date -u -d "${LOOKBACK_HOURS} hours ago" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || true)
        if [[ -z "${cutoff}" ]]; then
            # date -d not available (non-GNU); fall back to full file
            cat "${LOG_FILE}"
        else
            awk -v cutoff="${cutoff}" '
                match($0, /[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}/) {
                    if (substr($0, RSTART, RLENGTH) >= cutoff) print
                    next
                }
                { print }
            ' "${LOG_FILE}"
        fi
    fi
}

# ── Pattern definitions ───────────────────────────────────────────────────────
ERROR_PATTERN='[[:space:]]ERROR[[:space:]]'
WARN_PATTERN='[[:space:]]WARN[[:space:]]'
PANIC_PATTERN='thread.*panicked|panicked at|exiting process'
HEARTBEAT_PATTERN='Error sending heartbeat|Failed to connect to block engine|No shreds received recently, restarting'
DISCOVERY_PATTERN='Failed to fetch from discovery service|destination_refresh_error'
SHRED_PATTERN='Failed to decode shred|failed to deshred slot'
NETWORK_PATTERN='Failed to bind IPv[46]|Failed joining IPv[46]'

context_flag=""
if [[ "${SHOW_CONTEXT_LINES}" -gt 0 ]]; then
    context_flag="-C${SHOW_CONTEXT_LINES}"
fi

# ── Progress indicator ────────────────────────────────────────────────────────
# Prints a status message to stderr, overwriting the previous one on a tty.
_progress() {
    if [[ -t 2 ]]; then
        printf '\r\033[K  %b%s...%b' "${DIM}" "$1" "${RESET}" >&2
    else
        printf '  %s...\n' "$1" >&2
    fi
}
_progress_done() {
    [[ -t 2 ]] && printf '\r\033[K' >&2   # clear the progress line on a tty
}

# ── Collect matching lines (no per-line output) ───────────────────────────────
_progress "Scanning for errors"
error_lines=$(get_log_stream | grep -E  "${ERROR_PATTERN}"     ${context_flag} || true)
_progress "Scanning for warnings"
warn_lines=$( get_log_stream | grep -E  "${WARN_PATTERN}"      ${context_flag} || true)
_progress "Scanning for panics"
panic_lines=$(get_log_stream | grep -iE "${PANIC_PATTERN}"     ${context_flag} || true)
_progress "Scanning heartbeat / block engine"
hb_lines=$(   get_log_stream | grep -iE "${HEARTBEAT_PATTERN}" ${context_flag} || true)
_progress "Scanning endpoint discovery"
disc_lines=$( get_log_stream | grep -iE "${DISCOVERY_PATTERN}" ${context_flag} || true)
_progress "Scanning shred decode failures"
shred_lines=$(get_log_stream | grep -iE "${SHRED_PATTERN}"     ${context_flag} || true)
_progress "Scanning network / socket issues"
net_lines=$(  get_log_stream | grep -iE "${NETWORK_PATTERN}"   ${context_flag} || true)
_progress "Determining log span"

# ── Report banner ─────────────────────────────────────────────────────────────
# Determine the actual span of data returned by the source in one pass.
_first_ts=""
_last_ts=""
read -r _first_ts _last_ts < <(
    get_log_stream \
        | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}' \
        | awk 'NR==1{first=$0} {last=$0} END{print first, last}' \
    || true
) || true

_progress_done

echo
printf '%b===  shredstream-proxy log report  ===%b\n' "${BOLD}" "${RESET}"
if [[ "${LOG_SOURCE}" == "journalctl" ]]; then
    printf 'Source  : journalctl  unit=%s  lookback=%s hours\n' \
        "${JOURNALCTL_UNIT}" "${LOOKBACK_HOURS}"
else
    printf 'Source  : file  path=%s  lookback=%s hours\n' "${LOG_FILE}" "${LOOKBACK_HOURS}"
fi
printf 'Date    : %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
if [[ -z "${_first_ts}" ]]; then
    printf '%bSpan    : no data found in this window%b\n' "${YELLOW}" "${RESET}"
elif [[ "${_first_ts}" == "${_last_ts}" ]]; then
    printf 'Span    : %s  (single entry)\n' "${_first_ts}"
else
    printf 'Span    : %s  →  %s\n' "${_first_ts}" "${_last_ts}"
fi
printf '%bCmdline : %s%b\n' "${DIM}" "$(build_cmdline)" "${RESET}"

# ── Section counts (no individual lines) ─────────────────────────────────────
print_header "COUNTS BY CATEGORY"

_count_line() {
    local label="$1" lines="$2" pattern="$3" color="$4"
    if [[ -z "${lines}" ]]; then
        printf '  %-32s %b%s%b\n' "${label}" "${CYAN}" "0" "${RESET}"
    else
        local n
        n=$(echo "${lines}" | grep -cE "${pattern}" || true)
        printf '  %-32s %b%s%b\n' "${label}" "${color}" "${n}" "${RESET}"
    fi
}

_count_line "Errors:"                  "${error_lines}"  "${ERROR_PATTERN}"   "${RED}"
_count_line "Warnings:"                "${warn_lines}"   "${WARN_PATTERN}"    "${YELLOW}"
_count_line "Panics / fatal exits:"    "${panic_lines}"  "."                  "${RED}"
_count_line "Heartbeat / block engine:" "${hb_lines}"   "."                  "${YELLOW}"
_count_line "Endpoint discovery:"      "${disc_lines}"   "."                  "${YELLOW}"
_count_line "Shred decode failures:"   "${shred_lines}"  "."                  "${YELLOW}"
_count_line "Network / socket:"        "${net_lines}"    "."                  "${YELLOW}"

# ── Unique issue breakdown ────────────────────────────────────────────────────
total_errors=0
total_warns=0
total_panics=0
[[ -n "${error_lines}" ]] && total_errors=$(echo "${error_lines}" | grep -cE "${ERROR_PATTERN}" || true)
[[ -n "${warn_lines}" ]]  && total_warns=$( echo "${warn_lines}"  | grep -cE "${WARN_PATTERN}"  || true)
[[ -n "${panic_lines}" ]] && total_panics=$(echo "${panic_lines}" | count_matches)

all_issues=""
[[ -n "${error_lines}" ]] && all_issues+="${error_lines}"$'\n'
[[ -n "${warn_lines}" ]]  && all_issues+="${warn_lines}"$'\n'
[[ -n "${panic_lines}" ]] && all_issues+="${panic_lines}"$'\n'

print_header "UNIQUE ISSUES"
if [[ -z "${all_issues}" ]]; then
    printf '%bNone%b\n' "${CYAN}" "${RESET}"
else
    # Normalize before dedup:
    #  1. Replace ISO8601 timestamps so lines differing only by time collapse.
    #  2. Strip gRPC details/metadata/message fields (variable per-request data).
    #  3. Strip trailing punctuation.
    echo "${all_issues}" \
        | grep -v '^$' \
        | sed \
            -e 's/[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}T[0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\}[Z+][^ ]*/TIMESTAMP/g' \
            -e 's/, details:.*$//' \
            -e 's/, metadata:.*$//' \
            -e 's/, message: "[^"]*"//g' \
            -e 's/[,. ]*$//' \
        | sort \
        | uniq -c \
        | sort -rn \
        | while read -r cnt msg; do
            if echo "${msg}" | grep -qE "${ERROR_PATTERN}|${PANIC_PATTERN}"; then
                printf '  %b%4dx%b  %s\n' "${RED}${BOLD}"    "${cnt}" "${RESET}" "${msg}"
            else
                printf '  %b%4dx%b  %s\n' "${YELLOW}${BOLD}" "${cnt}" "${RESET}" "${msg}"
            fi
          done
fi
echo

if [[ "${total_errors}" -eq 0 && "${total_warns}" -eq 0 && "${total_panics}" -eq 0 ]]; then
    printf '%bAll clear — no errors or warnings detected.%b\n\n' "${CYAN}" "${RESET}"
else
    printf '%bIssues detected.%b\n\n' "${RED}" "${RESET}"
    exit 1
fi
