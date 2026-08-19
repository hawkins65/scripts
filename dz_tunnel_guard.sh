#!/usr/bin/env bash
set -Eeuo pipefail

# -----------------------------------
# Config (override via environment)
# -----------------------------------
DZ_CLI="${DZ_CLI:-/usr/bin/doublezero}"
CONNECT_ARGS="${CONNECT_ARGS:-connect ibrl}"
MAX_TRIES="${MAX_TRIES:-5}"
SLEEP_SECS="${SLEEP_SECS:-5}"
TARGET_NETWORK="${TARGET_NETWORK:-mainnet-beta}"
LOG_DIR="${LOG_DIR:-$HOME/logs}"
LOG_FILE="${LOG_FILE:-$LOG_DIR/doublezero_guard_$(date +%Y-%m-%d-%H-%M-%S).log}"
SCRIPT_PATH="$(readlink -f "$0")"

# Discord for alerts
source "$HOME/.config/validator/secrets.conf" 2>/dev/null
DISCORD_WEBHOOK="${DISCORD_WEBHOOK:-$DISCORD_WEBHOOK_TUNNEL}"
DISCORD_USERNAME="DoubleZero Guard"

# Discord notifications are OPTIONAL. If you have a helper that provides
# send_discord_embed, point DISCORD_EMBED_LIB at it; otherwise alerts fall back
# to a plain webhook POST, and if no webhook is set they go to the log only.
DISCORD_EMBED_LIB="${DISCORD_EMBED_LIB:-$HOME/discord_embed.sh}"
# shellcheck source=/dev/null
[ -r "$DISCORD_EMBED_LIB" ] && source "$DISCORD_EMBED_LIB"

if ! declare -F send_discord_embed >/dev/null 2>&1; then
    # Minimal stand-in: same first four positional args, extra key=value args
    # ignored. No webhook configured means log-only, which is a valid setup.
    send_discord_embed() {
        local webhook="$1" severity="$2" title="$3" description="$4"
        [ -n "$webhook" ] || return 0
        local color=3447003
        case "$severity" in
            critical) color=15158332 ;;
            error)    color=15105570 ;;
            warning)  color=16776960 ;;
        esac
        curl -s -m 10 -H 'Content-Type: application/json' -X POST "$webhook" \
            -d "$(jq -nc --arg t "$title" --arg d "$description" --argjson c "$color" \
                  '{embeds:[{title:$t,description:$d,color:$c}]}')" >/dev/null 2>&1 || true
    }
fi

mkdir -p "$LOG_DIR"

log() {
  local level="$1"; shift
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[$level] $ts - $*" | tee -a "$LOG_FILE"
}

discord_embed() {
  local severity="$1"
  local title="$2"
  local description="$3"

  send_discord_embed "$DISCORD_WEBHOOK" "$severity" \
      "$title" "$description" \
      username="$DISCORD_USERNAME" \
      script_path="$SCRIPT_PATH" \
      pagerduty=false
}

need_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    log "ERROR" "❌ 'jq' is required. Install it to parse 'doublezero status --json'."
    discord_embed "critical" "🚨 DoubleZero Guard — Missing Dependency" "jq not found on $(hostname). Cannot parse 'doublezero status --json'."
    exit 2
  fi
}

status_json() {
  # Return a single JSON object (entry) for the desired network, else first.
  "$DZ_CLI" status --json 2>>"$LOG_FILE" \
    | jq -c --arg NET "$TARGET_NETWORK" '
        (map(select(.network == $NET)) | .[0]) // .[0] // {}
      '
}

read_status_fields() {
  local j="$1"
  SESSION_STATUS="$(jq -r '.response.doublezero_status.session_status // empty' <<<"$j")"
  CURRENT_DEVICE="$(jq -r '.current_device // empty' <<<"$j")"
  LOWEST_DEVICE="$(jq -r '.lowest_latency_device // empty' <<<"$j")"
}

healthy_and_optimal() {
  # UP and current == lowest (dynamic, no pre-set device)
  [[ "$SESSION_STATUS" == "up" ]] || return 1
  [[ -n "$CURRENT_DEVICE" && -n "$LOWEST_DEVICE" ]] || return 1
  [[ "$CURRENT_DEVICE" == "$LOWEST_DEVICE" ]]
}

verify_disconnected_once() {
  local j s
  j="$(status_json)" || return 1
  s="$(jq -r '.response.doublezero_status.session_status // empty' <<<"$j")"
  [[ "$s" == "disconnected" ]]
}

# -----------------------------------
# Main
# -----------------------------------
if [[ ! -x "$DZ_CLI" ]]; then
  log "ERROR" "❌ DoubleZero CLI not found at: $DZ_CLI"
  discord_embed "critical" "🚨 DoubleZero Guard — CLI Not Found" "DoubleZero CLI not found at \`$DZ_CLI\` on $(hostname)."
  exit 2
fi

need_jq

log "INFO" "=== DoubleZero Guard Start ===  network=$TARGET_NETWORK  log=$LOG_FILE"

# 1) Initial check
J="$(status_json)"
read_status_fields "$J"

if healthy_and_optimal; then
  log "INFO" "✅ UP and optimal: current='$CURRENT_DEVICE' == lowest='$LOWEST_DEVICE'."
  exit 0
fi

log "WARN" "⚠️ Not optimal yet. session='$SESSION_STATUS', current='$CURRENT_DEVICE', lowest='$LOWEST_DEVICE'"

# 2) Clean disconnect -> verify "disconnected" (with 1 retry)
log "INFO" "Running: $DZ_CLI disconnect"
if ! "$DZ_CLI" disconnect >>"$LOG_FILE" 2>&1; then
  log "ERROR" "❌ 'doublezero disconnect' failed."
  discord_embed "error" "❌ DoubleZero Guard — Disconnect Failed" "disconnect command failed on $(hostname).\\n\\n\`\`\`\\nsession: ${SESSION_STATUS}\\ncurrent: ${CURRENT_DEVICE}\\nlowest:  ${LOWEST_DEVICE}\\n\`\`\`"
  exit 3
fi

if ! verify_disconnected_once; then
  log "WARN" "⚠️ Not 'disconnected' yet; waiting ${SLEEP_SECS}s and retrying once…"
  sleep "$SLEEP_SECS"
  if ! verify_disconnected_once; then
    log "ERROR" "❌ Still not 'disconnected' after retry. Aborting."
    discord_embed "error" "❌ DoubleZero Guard — Disconnect Stuck" "Session still not disconnected after retry on $(hostname)."
    exit 4
  fi
fi
log "INFO" "✅ Verified 'disconnected'."

# 3) Connect (let DZ choose best/lowest automatically)
log "INFO" "Running: $DZ_CLI $CONNECT_ARGS"
if ! "$DZ_CLI" $CONNECT_ARGS >>"$LOG_FILE" 2>&1; then
  log "ERROR" "❌ 'doublezero $CONNECT_ARGS' failed."
  discord_embed "error" "❌ DoubleZero Guard — Connect Failed" "connect command failed on $(hostname).\\n\\nCommand: \`$DZ_CLI $CONNECT_ARGS\`"
  exit 5
fi
log "INFO" "Connect issued; polling for UP + lowest match…"

# 4) Poll up to MAX_TRIES for UP & (current == lowest)
for ((i=1; i<=MAX_TRIES; i++)); do
  sleep "$SLEEP_SECS"
  J="$(status_json)" || true
  read_status_fields "$J"
  if healthy_and_optimal; then
    log "INFO" "✅ Healthy after attempt $i/$MAX_TRIES: UP with current='$CURRENT_DEVICE' (matches lowest)."
    exit 0
  fi
  if (( i < MAX_TRIES )); then
    log "INFO" "⚠️ Attempt $i/$MAX_TRIES: session='$SESSION_STATUS', current='$CURRENT_DEVICE', lowest='$LOWEST_DEVICE' — waiting ${SLEEP_SECS}s…"
  fi
done

log "ERROR" "❌ Not healthy/optimal after $MAX_TRIES attempts (~$((MAX_TRIES*SLEEP_SECS))s)."
discord_embed "error" "❌ DoubleZero Guard — Recovery Failed" "Failed to reach UP + optimal after $MAX_TRIES attempts (~$((MAX_TRIES*SLEEP_SECS))s) on $(hostname).\\n\\n\`\`\`\\nsession: ${SESSION_STATUS}\\ncurrent: ${CURRENT_DEVICE}\\nlowest:  ${LOWEST_DEVICE}\\n\`\`\`"
exit 6
