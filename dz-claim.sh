#!/usr/bin/env bash
#
# dz-claim.sh — Monitor (and, if needed, settle) DoubleZero publisher rewards.
#
# DoubleZero runs its own distributor, which credits the reward ATA once per
# subscription epoch on a constant ~8-epoch lag (subscription epoch N lands
# during Solana epoch N+8). So on a healthy day there is nothing for us to
# settle, and the old "N distributed" count was always zero.
#
# This script therefore reports on what DoubleZero paid, using the read-only
# per-epoch table from `publisher-rewards status`:
#
#   claimed     DoubleZero already credited our ATA — report the amount
#   ready       accumulated but not distributed — WE settle it (configure)
#   not ready   DoubleZero has not finalized it yet; normal inside the lag
#               window, an alert once it is older than DZ_LAG_EPOCHS
#   no rewards  published no shreds that epoch — an alert if leader slots > 0
#
# A `configure` transaction is submitted ONLY when at least one epoch is
# `ready` (or with --force-configure). Every run sends one Discord summary
# whose severity reflects the state, so silence means the script itself failed.
#
# Usage:
#   ./dz-claim.sh                   # report; settle only if something is ready
#   ./dz-claim.sh --show            # print PDA fields + table, change nothing
#   ./dz-claim.sh --dry-run         # simulate any settle transaction only
#   ./dz-claim.sh -y                # skip the confirmation prompt (cron uses this)
#   ./dz-claim.sh --force-configure # submit configure even with nothing ready
#   ./dz-claim.sh --no-discord      # never send a Discord notification
#   ./dz-claim.sh --num-epochs 30   # widen the status scan
#   ./dz-claim.sh -- --verbose      # pass extra args through to the CLI (after --)
#
# Secrets: paid RPC endpoints and the Discord webhook are read from a private
# file (default ~/.config/dz-claim/secrets.env, chmod 600), sourced at startup.
# Override its path with DZ_CLAIM_SECRETS. The status scan is slow against the
# public RPC, so the first endpoint found among HELIUS/QUICKNODE/ALCHEMY/TRITON
# *_RPC_URL is passed to the CLI. USD prices come from CoinGecko (Jupiter
# fallback).
#
# Configuration (all overridable via environment / the secrets file):
#   Required (set in the secrets file or the environment; no defaults baked in):
#     NODE_ID               Validator node identity being reported on
#     REWARDS_TOKEN_OWNER   Wallet that owns the ATA receiving rewards
#     KEYPAIR               Signer keypair (defaults to mainnet-staked-identity-<NODE_ID>.json)
#   Optional:
#     REWARDS_TOKEN_MINT    base58 mint or alias 2z / usdc / wsol (default: 2z)
#     SOLANA_URL            RPC URL/moniker the CLI submits through (default: first paid endpoint)
#     RPC_URL_OVERRIDE      Force a specific RPC at the front of the pool
#     DZ_NUM_EPOCHS         Epochs to scan in the status table (default: 20)
#     DZ_LAG_EPOCHS         Epochs after which an unpaid epoch is overdue (default: 9)
#     DZ_STATE_FILE         Where claimed-epoch history is recorded
#     VOTE_ACCOUNT          Vote pubkey to display (default: looked up from NODE_ID)
#     DZ_ADDRESS            DoubleZero address to display (default: `doublezero address`)
#     CLI_BIN               CLI binary name (default: doublezero-solana)
#     DISCORD_WEBHOOK_URL   Discord webhook for notifications (unset = disabled)
#     DISCORD_USERNAME      Bot display name (default below)
#     DISCORD_AVATAR_URL    Bot avatar URL
#     LOG_DIR               Where to write logs (default: ~/logs)

set -euo pipefail

# ---------------------------------------------------------------------------
# Secrets — load paid RPC endpoints / webhook overrides from a private file.
# The file is shell assignments (VAR="value") and is sourced if readable; it
# should be chmod 600 and kept out of version control. Anything it sets becomes
# a default below (env vars passed on the command line still win).
# ---------------------------------------------------------------------------
DZ_CLAIM_SECRETS="${DZ_CLAIM_SECRETS:-$HOME/.config/dz-claim/secrets.env}"
if [[ -f "$DZ_CLAIM_SECRETS" ]]; then
    if [[ -r "$DZ_CLAIM_SECRETS" ]]; then
        # shellcheck disable=SC1090
        set -a; source "$DZ_CLAIM_SECRETS"; set +a
    else
        echo "[!] Secrets file exists but is not readable: $DZ_CLAIM_SECRETS" >&2
    fi
fi

# ---------------------------------------------------------------------------
# Configuration (override via environment)
# ---------------------------------------------------------------------------
# NODE_ID and REWARDS_TOKEN_OWNER are account-specific; set them in the secrets
# file ($DZ_CLAIM_SECRETS) or pass on the command line. Validated as non-empty
# below. No defaults are baked in, so this script carries no private info.
NODE_ID="${NODE_ID:-}"
REWARDS_TOKEN_OWNER="${REWARDS_TOKEN_OWNER:-}"
KEYPAIR="${KEYPAIR:-/home/sol/mainnet-staked-identity-${NODE_ID}.json}"
# Reward mint: base58 pubkey or one of the aliases 2z / usdc / wsol. Default 2z.
REWARDS_TOKEN_MINT="${REWARDS_TOKEN_MINT:-2z}"

CLI_BIN="${CLI_BIN:-doublezero-solana}"

# How far back the status table scans, and how many epochs behind the current
# one an unpaid epoch may sit before we call it overdue. DoubleZero's observed
# lag is a constant 8 epochs, so epoch (current - 8) is the one being paid right
# now and (current - 9) and older should already be claimed.
DZ_NUM_EPOCHS="${DZ_NUM_EPOCHS:-20}"
DZ_LAG_EPOCHS="${DZ_LAG_EPOCHS:-9}"

# Records the epochs already reported as claimed, so each run can report only
# what is new. Lines are: <epoch>\t<iso8601 first seen>\t<amount>
DZ_STATE_FILE="${DZ_STATE_FILE:-$HOME/.local/state/dz-claim/claimed_epochs.tsv}"

# Identity fields shown in the report so a wrong node can be spotted at a glance.
# Both are resolved at runtime when left empty; set them here only to pin a value.
VOTE_ACCOUNT="${VOTE_ACCOUNT:-}"
DZ_ADDRESS="${DZ_ADDRESS:-}"

# Base58 pubkey shape — used to reject junk from the lookups below.
B58_RE='^[1-9A-HJ-NP-Za-km-z]{32,44}$'

# RPC pool. The status scan makes many calls and is slow against the public
# endpoint, so prefer a paid one from the secrets file. RPC_URL_OVERRIDE jumps
# the queue; SOLANA_URL (if set) still wins for what the CLI submits through.
RPC_POOL=()
[[ -n "${RPC_URL_OVERRIDE:-}" ]] && RPC_POOL+=("$RPC_URL_OVERRIDE")
# MAINNET_3 and COGENT were removed 2026-08-19: COGENT was deleted at the
# provider on 08-12, and MAINNET_3 is IP-restricted to a single host, so from
# anywhere else it only adds a guaranteed-failing entry to the failover pool.
for _v in HELIUS_RPC_URL QUICKNODE_RPC_URL QUICKNODE_MAINNET_2_RPC_URL \
          ALCHEMY_RPC_URL TRITON_RPC_URL; do
    [[ -n "${!_v:-}" ]] && RPC_POOL+=("${!_v}")
done
RPC_POOL+=("https://api.mainnet-beta.solana.com")
RPC_URL="${RPC_POOL[0]}"                    # used for balance lookups
SOLANA_URL="${SOLANA_URL:-$RPC_URL}"        # what the CLI talks to

# Discord notification settings (notifications disabled if webhook is empty).
# Configure these in the secrets file ($DZ_CLAIM_SECRETS); see template there.
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"
DISCORD_USERNAME="${DISCORD_USERNAME:-DoubleZero Publisher Rewards Bot}"
DISCORD_AVATAR_URL="${DISCORD_AVATAR_URL:-https://trillium.so/images/validator-monitor.png}"

# Price feed for USD valuation (CoinGecko by mint, no API key; Jupiter fallback).
COINGECKO_TOKEN_URL="https://api.coingecko.com/api/v3/simple/token_price/solana"
JUPITER_PRICE_URL="https://lite-api.jup.ag/price/v3"

# Severity colors (decimal for Discord embeds)
COLOR_OK=5361510        # 0x51CF66 green
COLOR_INFO=3382000      # 0x339AF0 blue
COLOR_WARNING=16002055  # 0xF4AC07 gold
COLOR_ERROR=16738155    # 0xFF6B6B red

# ---------------------------------------------------------------------------
# Logging (tee everything to a log file)
# ---------------------------------------------------------------------------
LOG_DIR="${LOG_DIR:-$HOME/logs}"
SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"
# Record whether we started attached to a real terminal, before any redirection,
# so colors and the confirmation prompt still behave correctly under tee.
STDOUT_IS_TTY=0; [[ -t 1 ]] && STDOUT_IS_TTY=1
STDIN_IS_TTY=0;  [[ -t 0 ]] && STDIN_IS_TTY=1

if mkdir -p "$LOG_DIR" 2>/dev/null; then
    # Stable filename so logrotate (/etc/logrotate.d/sol-logs) manages a single
    # file. A per-run timestamp here would leave one orphan file per invocation,
    # which logrotate then re-rotates daily forever, producing empty .log stubs
    # and a trail of 20-byte empty .gz files.
    LOG_FILE="$LOG_DIR/$(basename "$0" .sh).log"
    if touch "$LOG_FILE" 2>/dev/null; then
        exec &> >(stdbuf -oL tee -a "$LOG_FILE" 2>>"$LOG_FILE")
    else
        LOG_FILE=""
    fi
else
    LOG_FILE=""
fi

# ---------------------------------------------------------------------------
# Pretty logging (color only when the original stdout was a TTY)
# ---------------------------------------------------------------------------
if [[ $STDOUT_IS_TTY -eq 1 ]]; then
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_BLU=$'\033[34m'; C_RST=$'\033[0m'
else
    C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_RST=''
fi
log()  { printf '%s[*]%s %s\n' "$C_BLU" "$C_RST" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YEL" "$C_RST" "$*"; }

# ---------------------------------------------------------------------------
# Discord
# ---------------------------------------------------------------------------
NOTIFY=1   # toggled off by --no-discord

# send_discord_embed <severity> <title> <description>
send_discord_embed() {
    local severity="$1" title="$2" description="$3"

    [[ $NOTIFY -eq 1 ]] || return 0
    if [[ -z "$DISCORD_WEBHOOK_URL" ]]; then
        return 0
    fi
    if ! command -v jq >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
        warn "jq/curl missing — cannot send Discord notification."
        return 0
    fi

    local color
    case "$severity" in
        ok)      color=$COLOR_OK ;;
        info)    color=$COLOR_INFO ;;
        warning) color=$COLOR_WARNING ;;
        error)   color=$COLOR_ERROR ;;
        *)       color=$COLOR_INFO ;;
    esac

    local footer_ts payload resp
    footer_ts=$(date -u '+%Y-%m-%d %H:%M UTC')
    payload=$(jq -n \
        --arg username "$DISCORD_USERNAME" \
        --arg avatar_url "$DISCORD_AVATAR_URL" \
        --arg title "$title" \
        --arg desc "$description" \
        --argjson color "$color" \
        --arg footer "${SCRIPT_PATH} • ${footer_ts}" \
        '{username: $username, avatar_url: $avatar_url,
          embeds: [{title: $title, description: $desc, color: $color, footer: {text: $footer}}]}')

    resp=$(curl -s -H "Content-Type: application/json" -X POST -d "$payload" "$DISCORD_WEBHOOK_URL" 2>&1) \
        || warn "Failed to POST to Discord: $resp"
}

# die <message>  — log, notify Discord, and exit non-zero.
die() {
    printf '%s[x]%s %s\n' "$C_RED" "$C_RST" "$*"
    send_discord_embed "error" "❌ DoubleZero Publisher Rewards — Error" \
        "$(printf '%s\n\nNode: `%s`\nHost: `%s`\nTime: %s' \
            "$1" "$NODE_ID" "$(hostname 2>/dev/null || echo unknown)" \
            "$(date -u +'%Y-%m-%d %H:%M:%S UTC')")"
    exit 1
}

# get_field <output> <label>  — value after a "Label:   value" line, trimmed.
# Always returns 0 (empty when the label is absent) so it is safe under `set -e`.
get_field() {
    printf '%s\n' "$1" | grep -m1 -F "$2" | cut -d: -f2- | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' || true
}

# ---------------------------------------------------------------------------
# Formatting helpers
# ---------------------------------------------------------------------------

# Short symbol for the reward mint (for display), derived from the alias or mint.
mint_symbol() {
    case "$REWARDS_TOKEN_MINT" in
        2z|2Z)     echo "2Z" ;;
        usdc|USDC) echo "USDC" ;;
        wsol|wSOL) echo "wSOL" ;;
        *)         echo "${1:0:4}" ;;   # first 4 chars of the resolved mint
    esac
}

# fetch_price <mint_address>  — echo USD price per token, or "0" if unavailable.
fetch_price() {
    local mint="$1" price=""
    command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || { echo 0; return; }

    # Stablecoins: skip the lookup.
    case "$REWARDS_TOKEN_MINT" in usdc|USDC) echo 1; return ;; esac

    price=$(curl -s --max-time 15 "${COINGECKO_TOKEN_URL}?contract_addresses=${mint}&vs_currencies=usd" 2>/dev/null \
            | jq -r --arg m "$mint" '.[$m].usd // empty' 2>/dev/null || true)
    if [[ -z "$price" ]]; then
        price=$(curl -s --max-time 15 "${JUPITER_PRICE_URL}?ids=${mint}" 2>/dev/null \
                | jq -r --arg m "$mint" '.[$m].usdPrice // empty' 2>/dev/null || true)
    fi
    [[ "$price" =~ ^[0-9]+(\.[0-9]+)?$ ]] && echo "$price" || echo 0
}

# usd <token_amount> <price>  — echo token_amount * price, 2dp.
usd() {
    awk -v a="${1:-0}" -v p="${2:-0}" 'BEGIN{ printf "%.2f", a*p }'
}

# commafy <number>  — add thousands separators to the integer part.
commafy() {
    local n="${1:-0}" int dec
    int="${n%.*}"; dec=""
    [[ "$n" == *.* ]] && dec=".${n#*.}"
    printf '%s%s' "$(printf '%s' "$int" | sed -E ':a;s/([0-9])([0-9]{3})($|,)/\1,\2\3/;ta')" "$dec"
}

# range_fmt <sorted ascending integers…>  — "1002-1005, 1008" style compression.
range_fmt() {
    local out="" start="" prev="" n
    for n in "$@"; do
        if [[ -z "$start" ]]; then
            start="$n"; prev="$n"; continue
        fi
        if (( n == prev + 1 )); then prev="$n"; continue; fi
        out+="${out:+, }$start"; [[ "$start" != "$prev" ]] && out+="-$prev"
        start="$n"; prev="$n"
    done
    if [[ -n "$start" ]]; then
        out+="${out:+, }$start"; [[ "$start" != "$prev" ]] && out+="-$prev"
    fi
    printf '%s' "${out:-none}"
}

# days_since <iso8601>  — whole days between the timestamp and now ("?" if unparseable).
days_since() {
    local then now
    then=$(date -u -d "$1" +%s 2>/dev/null) || { printf '?'; return; }
    now=$(date -u +%s)
    printf '%d' $(( (now - then) / 86400 ))
}

# ---------------------------------------------------------------------------
# Identity lookups (display only — a failure must never stop the run)
# ---------------------------------------------------------------------------

# resolve_vote_account  — echo the vote pubkey for NODE_ID, or "" if unknown.
# getVoteAccounts is the only mapping from identity to vote account, and it has
# no server-side filter on nodePubkey, so the whole list comes back and jq picks
# our row. Delinquents are kept so a non-voting node still reports its key.
resolve_vote_account() {
    local out=""
    command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || { printf ''; return; }
    out="$(curl -s --max-time 20 "$RPC_URL" -X POST -H 'Content-Type: application/json' \
        -d '{"jsonrpc":"2.0","id":1,"method":"getVoteAccounts","params":[{"keepUnstakedDelinquents":true}]}' 2>/dev/null \
        | jq -r --arg n "$NODE_ID" \
            'first(([.result.current[]?, .result.delinquent[]?] | .[] | select(.nodePubkey == $n) | .votePubkey)) // empty' \
            2>/dev/null || true)"
    [[ "$out" =~ $B58_RE ]] && printf '%s' "$out" || printf ''
}

# resolve_dz_address  — echo this host's DoubleZero address, or "" if unknown.
# `doublezero address` reads the local DZ client keypair, so it describes the
# host the script runs on. On a failover partner it would print that host's own
# DZ identity, which is a different account from the one publishing here.
resolve_dz_address() {
    local out=""
    command -v doublezero >/dev/null 2>&1 || { printf ''; return; }
    out="$(doublezero address 2>/dev/null | tr -d '[:space:]' || true)"
    [[ "$out" =~ $B58_RE ]] && printf '%s' "$out" || printf ''
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
ACTION="report"        # report | show
DRY_RUN=0
ASSUME_YES=0
FORCE_CONFIGURE=0
EXTRA_ARGS=()

usage() { sed -n '3,60p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --show)             ACTION="show" ;;
        --dry-run)          DRY_RUN=1 ;;
        -y|--yes)           ASSUME_YES=1 ;;
        --force-configure)  FORCE_CONFIGURE=1 ;;
        --no-discord)       NOTIFY=0 ;;
        # Guard the shift: a trailing bare --num-epochs would otherwise empty
        # "$@" and make the loop's own shift fail under `set -e`.
        --num-epochs)       DZ_NUM_EPOCHS="${2:-20}"; if [[ $# -gt 1 ]]; then shift; fi ;;
        -h|--help)          usage 0 ;;
        --)                 shift; EXTRA_ARGS+=("$@"); break ;;
        *)                  EXTRA_ARGS+=("$1") ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# Pre-flight validation
# ---------------------------------------------------------------------------
command -v "$CLI_BIN" >/dev/null 2>&1 \
    || die "'$CLI_BIN' not found on PATH. Install the DoubleZero Solana CLI."

if ! "$CLI_BIN" shreds publisher-rewards status --help >/dev/null 2>&1; then
    die "'$CLI_BIN' does not support 'shreds publisher-rewards status'. Update the CLI (current: $($CLI_BIN --version 2>/dev/null || echo unknown))."
fi

[[ -n "$NODE_ID" ]]             || die "NODE_ID is empty."
[[ -n "$REWARDS_TOKEN_OWNER" ]] || die "REWARDS_TOKEN_OWNER is empty."

# ---------------------------------------------------------------------------
# Current PDA state (instant — a single account read)
# ---------------------------------------------------------------------------
log "DoubleZero publisher rewards — node $NODE_ID"
SHOW_OUT="$("$CLI_BIN" shreds publisher-rewards show --node-id "$NODE_ID" -u "$SOLANA_URL" 2>&1)" \
    || die "'publisher-rewards show' failed: $SHOW_OUT"

r_owner="$(get_field "$SHOW_OUT" 'Rewards owner')"
r_mint="$(get_field "$SHOW_OUT" 'Rewards mint')"
r_ata="$(get_field "$SHOW_OUT" 'Resolved ATA')"
[[ -z "$r_ata" ]] && r_ata="$(get_field "$SHOW_OUT" 'Rewards ATA')"
ata_status="$(get_field "$SHOW_OUT" 'ATA status')"

REWARD_MINT_ADDR="${r_mint}"
SYMBOL="$(mint_symbol "$REWARD_MINT_ADDR")"

# ---------------------------------------------------------------------------
# Per-epoch reward table (read-only; the source of truth for this report)
# ---------------------------------------------------------------------------
# read_status  — refresh STATUS_OUT and the EP_* maps from the CLI.
declare -A EP_STATUS EP_AMOUNT EP_SLOTS
EPOCHS=()
CUR_EPOCH=0

read_status() {
    local line ep rest slots mint amount st
    STATUS_OUT="$("$CLI_BIN" shreds publisher-rewards status \
                    --node-id "$NODE_ID" --num-epochs "$DZ_NUM_EPOCHS" -u "$SOLANA_URL" 2>&1)" \
        || die "'publisher-rewards status' failed: $STATUS_OUT"

    EP_STATUS=(); EP_AMOUNT=(); EP_SLOTS=(); EPOCHS=(); CUR_EPOCH=0
    while IFS= read -r line; do
        # | 1001  |          276 | 2Z   | 39.459 | claimed   |
        [[ "$line" =~ ^\|[[:space:]]*([0-9]+)[[:space:]]*\|(.*)$ ]] || continue
        ep="${BASH_REMATCH[1]}"; rest="${BASH_REMATCH[2]}"
        IFS='|' read -r slots mint amount st _ <<<"$rest"
        # trim each captured column
        slots="$(printf '%s' "$slots"   | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        amount="$(printf '%s' "$amount" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        st="$(printf '%s' "$st"         | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        EP_STATUS[$ep]="$st"
        EP_AMOUNT[$ep]="$amount"
        EP_SLOTS[$ep]="$slots"
        EPOCHS+=("$ep")
        (( ep > CUR_EPOCH )) && CUR_EPOCH="$ep"
    done <<<"$STATUS_OUT"

    [[ ${#EPOCHS[@]} -gt 0 ]] || die "Could not parse any epoch rows from 'publisher-rewards status'. Output:\n$STATUS_OUT"
}

log "Reading per-epoch status (last $DZ_NUM_EPOCHS epochs) via ${SOLANA_URL%%\?*}…"
read_status
printf '%s\n' "$STATUS_OUT"

# ---------------------------------------------------------------------------
# Classify the table
# ---------------------------------------------------------------------------
CLAIMED=(); READY=(); PENDING=(); OVERDUE=(); NOSHREDS=()

classify() {
    local ep
    CLAIMED=(); READY=(); PENDING=(); OVERDUE=(); NOSHREDS=()
    for ep in "${EPOCHS[@]}"; do
        case "${EP_STATUS[$ep]}" in
            claimed)     CLAIMED+=("$ep") ;;
            ready)       READY+=("$ep") ;;
            "not ready")
                # Inside the lag window this is normal; older than that it is late.
                if (( ep <= CUR_EPOCH - DZ_LAG_EPOCHS )); then OVERDUE+=("$ep"); else PENDING+=("$ep"); fi ;;
            "no rewards")
                # Only an anomaly if we actually had leader slots that epoch.
                [[ "${EP_SLOTS[$ep]}" =~ ^[0-9]+$ ]] && (( EP_SLOTS[$ep] > 0 )) && NOSHREDS+=("$ep") ;;
            *)           : ;;   # "no data" — the current epoch's export isn't out yet
        esac
    done
}
classify

# ---------------------------------------------------------------------------
# Settle anything DoubleZero left for us (only when something is `ready`)
# ---------------------------------------------------------------------------
SETTLED_NOTE=""
if [[ "$ACTION" == "report" ]] && { [[ ${#READY[@]} -gt 0 ]] || [[ $FORCE_CONFIGURE -eq 1 ]]; }; then
    [[ -f "$KEYPAIR" ]] || die "Keypair file not found: $KEYPAIR"
    [[ -r "$KEYPAIR" ]] || die "Keypair file not readable: $KEYPAIR"

    # When no offchain --signature is passed, the signer keypair MUST be the node
    # identity (it signs directly). Verify locally for a clear failure.
    have_signature=0
    for a in "${EXTRA_ARGS[@]:-}"; do
        [[ "$a" == "--signature" ]] && have_signature=1
    done
    if [[ $have_signature -eq 0 ]] && command -v solana-keygen >/dev/null 2>&1; then
        actual_pubkey="$(solana-keygen pubkey "$KEYPAIR" 2>/dev/null || true)"
        if [[ -n "$actual_pubkey" && "$actual_pubkey" != "$NODE_ID" ]]; then
            die "Keypair pubkey ($actual_pubkey) != NODE_ID ($NODE_ID). Pass --signature/--deadline-slot for offchain signing, or use the identity keypair."
        fi
    fi

    cmd=("$CLI_BIN" shreds publisher-rewards configure
         --node-id "$NODE_ID"
         --rewards-token-owner "$REWARDS_TOKEN_OWNER"
         --rewards-token-mint "$REWARDS_TOKEN_MINT"
         -k "$KEYPAIR"
         -u "$SOLANA_URL")
    [[ $DRY_RUN -eq 1 ]] && cmd+=(--dry-run)
    [[ ${#EXTRA_ARGS[@]} -gt 0 ]] && cmd+=("${EXTRA_ARGS[@]}")

    log "Epoch(s) ready to settle: $(range_fmt "${READY[@]}")"
    log "Command: ${cmd[*]}"

    if [[ $DRY_RUN -eq 0 && $ASSUME_YES -eq 0 ]]; then
        if [[ $STDIN_IS_TTY -eq 1 ]]; then
            read -r -p "$(printf '%s[?]%s Submit this transaction? [y/N] ' "$C_YEL" "$C_RST")" reply
            [[ "$reply" =~ ^[Yy]$ ]] || die "Aborted by user."
        else
            die "Refusing to submit non-interactively without -y/--yes (use --dry-run to test)."
        fi
    fi

    set +e
    "${cmd[@]}" 2>&1
    cli_rc=$?
    set -e
    [[ $cli_rc -eq 0 ]] || die "Settle transaction failed (exit $cli_rc). See output above."

    if [[ $DRY_RUN -eq 0 ]]; then
        SETTLED_NOTE="$(printf 'Settled %s epoch(s) ourselves this run: %s' "${#READY[@]}" "$(range_fmt "${READY[@]}")")"
        ok "$SETTLED_NOTE"
        log "Re-reading status after settling…"
        read_status
        classify
    fi
elif [[ "$ACTION" == "report" ]]; then
    log "Nothing is 'ready' — no transaction submitted."
fi

# ---------------------------------------------------------------------------
# State: which claimed epochs have we already reported?
# ---------------------------------------------------------------------------
declare -A SEEN_TS
FIRST_RUN=0
if [[ -f "$DZ_STATE_FILE" ]]; then
    while IFS=$'\t' read -r s_ep s_ts _; do
        [[ "$s_ep" =~ ^[0-9]+$ ]] || continue
        SEEN_TS[$s_ep]="$s_ts"
    done <"$DZ_STATE_FILE"
else
    FIRST_RUN=1
fi

NOW_ISO="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
NEW_EPOCHS=()
for ep in "${CLAIMED[@]}"; do
    [[ -n "${SEEN_TS[$ep]:-}" ]] || NEW_EPOCHS+=("$ep")
done

# On the very first run every claimed epoch looks new. Record them as the
# baseline instead of announcing a pile of historical payments.
if [[ $FIRST_RUN -eq 1 ]]; then
    NEW_EPOCHS=()
    log "First run — recording ${#CLAIMED[@]} already-claimed epoch(s) as the baseline."
fi

# Newest claimed epoch and when we first saw it paid.
LAST_PAID_EPOCH=""; LAST_PAID_TS=""
for ep in "${CLAIMED[@]}"; do
    if [[ -z "$LAST_PAID_EPOCH" ]] || (( ep > LAST_PAID_EPOCH )); then LAST_PAID_EPOCH="$ep"; fi
done
[[ -n "$LAST_PAID_EPOCH" ]] && LAST_PAID_TS="${SEEN_TS[$LAST_PAID_EPOCH]:-$NOW_ISO}"

# Persist (only in report mode — --show and --dry-run must not move the baseline).
if [[ "$ACTION" == "report" && $DRY_RUN -eq 0 ]]; then
    if mkdir -p "$(dirname "$DZ_STATE_FILE")" 2>/dev/null; then
        {
            printf '# epoch\tfirst_seen_claimed\tamount\n'
            for ep in "${CLAIMED[@]}"; do
                printf '%s\t%s\t%s\n' "$ep" "${SEEN_TS[$ep]:-$NOW_ISO}" "${EP_AMOUNT[$ep]:-}"
            done
        } >"${DZ_STATE_FILE}.tmp" && mv "${DZ_STATE_FILE}.tmp" "$DZ_STATE_FILE"
    else
        warn "Cannot write state file $DZ_STATE_FILE — every run will look like the first."
    fi
fi

# ---------------------------------------------------------------------------
# Amounts + USD valuation
# ---------------------------------------------------------------------------
PRICE="0"
[[ -n "$REWARD_MINT_ADDR" ]] && PRICE="$(fetch_price "$REWARD_MINT_ADDR")"
price_fmt="$(commafy "$(awk -v p="$PRICE" 'BEGIN{printf "%.4f", p}')")"

new_total="0"
breakdown_console=""
breakdown_discord=""
for ep in "${NEW_EPOCHS[@]}"; do
    amt="${EP_AMOUNT[$ep]:-0}"
    [[ "$amt" =~ ^[0-9]+(\.[0-9]+)?$ ]] || amt="0"
    new_total="$(awk -v t="$new_total" -v a="$amt" 'BEGIN{printf "%.8f", t+a}')"
    breakdown_console+="$(printf '\n    Epoch %-5s %10s %-4s  ($%s)' "$ep" "$amt" "$SYMBOL" "$(commafy "$(usd "$amt" "$PRICE")")")"
    breakdown_discord+="$(printf '\nEpoch %-5s %10s %-4s  $%s' "$ep" "$amt" "$SYMBOL" "$(commafy "$(usd "$amt" "$PRICE")")")"
done
new_total_fmt="$(commafy "$(awk -v t="$new_total" 'BEGIN{printf "%.3f", t}')")"
new_total_usd="$(commafy "$(usd "$new_total" "$PRICE")")"

# Value still owed for the overdue epochs, estimated from the mean claimed amount.
overdue_est=""
if [[ ${#OVERDUE[@]} -gt 0 && ${#CLAIMED[@]} -gt 0 ]]; then
    mean="$(for ep in "${CLAIMED[@]}"; do printf '%s\n' "${EP_AMOUNT[$ep]}"; done \
            | awk '$1+0>0{s+=$1; n++} END{ if(n) printf "%.3f", s/n; else print 0 }')"
    est="$(awk -v m="$mean" -v n="${#OVERDUE[@]}" 'BEGIN{printf "%.0f", m*n}')"
    overdue_est="$(printf '~%s %s / ~$%s' "$(commafy "$est")" "$SYMBOL" "$(commafy "$(usd "$est" "$PRICE")")")"
fi

# Current reward-ATA balance + USD.
ata_balance=""
if [[ -n "$r_ata" ]] && command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    ata_balance="$(curl -s --max-time 15 "$RPC_URL" -X POST -H 'Content-Type: application/json' \
        -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getTokenAccountBalance\",\"params\":[\"$r_ata\"]}" 2>/dev/null \
        | jq -r '.result.value.uiAmountString // empty' 2>/dev/null || true)"
fi
ata_balance_fmt=""; ata_balance_usd=""
if [[ "$ata_balance" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    ata_balance_fmt="$(commafy "$(awk -v a="$ata_balance" 'BEGIN{printf "%.5f", a}')")"
    ata_balance_usd="$(commafy "$(usd "$ata_balance" "$PRICE")")"
fi

# ---------------------------------------------------------------------------
# Identity block — which node, vote account and DoubleZero address this is about
# ---------------------------------------------------------------------------
[[ -n "$VOTE_ACCOUNT" ]] || VOTE_ACCOUNT="$(resolve_vote_account)"
[[ -n "$DZ_ADDRESS" ]]   || DZ_ADDRESS="$(resolve_dz_address)"

identity_block="$(printf '```\nNode ID:    %s\nVote:       %s\nDZ address: %s\n```' \
    "$NODE_ID" "${VOTE_ACCOUNT:-unknown}" "${DZ_ADDRESS:-unknown}")"

# ---------------------------------------------------------------------------
# Console summary
# ---------------------------------------------------------------------------
log "Node $NODE_ID • vote ${VOTE_ACCOUNT:-unknown} • DZ ${DZ_ADDRESS:-unknown}"
[[ "$PRICE" != "0" ]] && log "${SYMBOL} price: \$${price_fmt}"
if [[ ${#NEW_EPOCHS[@]} -gt 0 ]]; then
    log "Paid by DoubleZero since the last run:"
    printf '%s\n' "$breakdown_console"
    ok "New total: ${new_total_fmt} ${SYMBOL} (\$${new_total_usd})"
else
    log "No new epochs paid since the last run."
fi
log "Pending inside the normal $((DZ_LAG_EPOCHS - 1))-epoch lag: $(range_fmt "${PENDING[@]}")"
[[ ${#READY[@]}    -gt 0 ]] && warn "Still 'ready' (unsettled): $(range_fmt "${READY[@]}")"
[[ ${#OVERDUE[@]}  -gt 0 ]] && warn "OVERDUE (DoubleZero has not finalized): $(range_fmt "${OVERDUE[@]}") ${overdue_est:+— $overdue_est}"
[[ ${#NOSHREDS[@]} -gt 0 ]] && warn "Leader slots but no rewards: $(range_fmt "${NOSHREDS[@]}")"
[[ -n "$ata_balance_fmt" ]] && log "ATA balance: ${ata_balance_fmt} ${SYMBOL} (\$${ata_balance_usd})"

# ---------------------------------------------------------------------------
# Discord summary — one embed per run, severity driven by the table
# ---------------------------------------------------------------------------
ts_utc="$(date -u +'%A, %B %d, %Y at %I:%M:%S %p UTC')"
ts_cst="$(TZ='America/Chicago' date +'%A, %B %d, %Y at %I:%M:%S %p %Z' 2>/dev/null || true)"
host="$(hostname 2>/dev/null || echo unknown)"

if [[ "$ACTION" == "show" ]]; then
    desc="$(printf '```\nNode ID:       %s\nVote:          %s\nDZ address:    %s\nRewards owner: %s\nRewards mint:  %s\nResolved ATA:  %s\nATA status:    %s\n```' \
        "$NODE_ID" "${VOTE_ACCOUNT:-unknown}" "${DZ_ADDRESS:-unknown}" \
        "${r_owner:-?}" "${r_mint:-?}" "${r_ata:-?}" "${ata_status:-unknown}")"
    desc+="$(printf '\n```\n%s\n```' "$(printf '%s\n' "$STATUS_OUT" | grep '^|' || true)")"
    [[ -n "$ata_balance_fmt" ]] && desc+="$(printf '\n```\nCurrent ATA balance: %s %s ($%s)\n```' "$ata_balance_fmt" "$SYMBOL" "$ata_balance_usd")"
    desc+="$(printf '\nReport generated %s' "$ts_utc")"
    send_discord_embed "info" "ℹ️ DoubleZero Publisher Rewards — Current State" "$desc"
    ok "Done.${LOG_FILE:+ Log: $LOG_FILE}"
    exit 0
fi

if [[ $DRY_RUN -eq 1 ]]; then
    ok "Dry run complete (no Discord notification sent for simulations)."
    exit 0
fi

# --- severity + title -------------------------------------------------------
severity="info"
title="ℹ️ DoubleZero Rewards — up to date"
if [[ ${#OVERDUE[@]} -gt 0 ]]; then
    severity="warning"
    since=""
    if [[ -n "$LAST_PAID_TS" ]]; then
        since="$(printf ' (last paid epoch %s, %s day(s) ago)' "$LAST_PAID_EPOCH" "$(days_since "$LAST_PAID_TS")")"
    fi
    title="$(printf '⚠️ DoubleZero Rewards — %s epoch(s) overdue%s' "${#OVERDUE[@]}" "$since")"
elif [[ ${#READY[@]} -gt 0 ]]; then
    severity="warning"
    title="$(printf '⚠️ DoubleZero Rewards — %s epoch(s) still unsettled after our settle pass' "${#READY[@]}")"
elif [[ ${#NOSHREDS[@]} -gt 0 ]]; then
    severity="warning"
    title="$(printf '⚠️ DoubleZero Rewards — %s epoch(s) with leader slots but no rewards' "${#NOSHREDS[@]}")"
elif [[ ${#NEW_EPOCHS[@]} -gt 0 ]]; then
    severity="ok"
    title="$(printf '✅ DoubleZero Rewards — %s epoch(s) paid, %s %s ($%s)' \
        "${#NEW_EPOCHS[@]}" "$new_total_fmt" "$SYMBOL" "$new_total_usd")"
fi

# --- body -------------------------------------------------------------------
desc=""
if [[ ${#NEW_EPOCHS[@]} -gt 0 ]]; then
    desc+="$(printf '```\nPaid by DoubleZero since the last run:%s\n%s\nTotal: %s %s  ($%s)\n```' \
        "$breakdown_discord" "$(printf '%.0s─' {1..38})" "$new_total_fmt" "$SYMBOL" "$new_total_usd")"
else
    desc+="$(printf '```\nNo new epochs paid since the last run.\n```')"
fi

desc+="$(printf '\n```\nCurrent epoch:  %s\nLast paid:      %s\nPending (lag):  %s\nOverdue:        %s\n```' \
    "$CUR_EPOCH" \
    "${LAST_PAID_EPOCH:-none}" \
    "$(range_fmt "${PENDING[@]}")" \
    "$(if [[ ${#OVERDUE[@]} -gt 0 ]]; then printf '%s  %s' "$(range_fmt "${OVERDUE[@]}")" "$overdue_est"; else printf 'none'; fi)")"

[[ ${#READY[@]}    -gt 0 ]] && desc+="$(printf '\n⚠️ Unsettled (`ready`) epochs remain: `%s`' "$(range_fmt "${READY[@]}")")"
[[ ${#NOSHREDS[@]} -gt 0 ]] && desc+="$(printf '\n⚠️ Leader slots but no rewards: `%s` — check the shred publisher path.' "$(range_fmt "${NOSHREDS[@]}")")"
[[ -n "$SETTLED_NOTE" ]]    && desc+="$(printf '\n%s' "$SETTLED_NOTE")"

if [[ ${#OVERDUE[@]} -gt 0 ]]; then
    desc+="$(printf '\nDoubleZero normally pays on a %s-epoch lag. Epochs older than that are late on their side — leader slots are recorded, so the node is publishing.' "$((DZ_LAG_EPOCHS - 1))")"
fi

desc+="$(printf '\n%s' "$identity_block")"

if [[ -n "$ata_balance_fmt" ]]; then
    desc+="$(printf '\n```\nCurrent ATA balance: %s %s ($%s)\n%s price:%*s$%s\n```' \
        "$ata_balance_fmt" "$SYMBOL" "$ata_balance_usd" \
        "$SYMBOL" $((13 - ${#SYMBOL})) "" "$price_fmt")"
fi

desc+="$(printf '\nHost: `%s` • generated %s%s' "$host" "$ts_utc" \
    "$([[ -n "$ts_cst" ]] && printf ' (%s)' "$ts_cst")")"

send_discord_embed "$severity" "$title" "$desc"

ok "Done.${LOG_FILE:+ Log: $LOG_FILE}"
