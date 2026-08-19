#!/bin/bash
#
# set-bam-node.sh — Switch BAM endpoint at runtime (no restart needed)
#
# Apply mechanism: agave-validator CLI (`set-bam-config --bam-url`).
#
# Usage:
#   bash set-bam-node.sh [region|ip|hostname] [--mainnet|--testnet]
#
# Examples:
#   bash set-bam-node.sh slc              # set to slc on default network
#   bash set-bam-node.sh --testnet        # interactive region picker for testnet
#   bash set-bam-node.sh ny --mainnet     # set to ny on mainnet
#   bash set-bam-node.sh 10.0.0.5         # set BAM to a specific IP   (health-verified)
#   bash set-bam-node.sh bam.example.com  # set BAM to a specific host (health-verified)
#   bash set-bam-node.sh --off            # disable BAM
#   bash set-bam-node.sh --auto           # non-interactive: pick lowest-latency
#                                         # healthy region and apply (used by
#                                         # role-bam-sync.sh on primary).
#
# Passing a raw IP or hostname is non-interactive: the node is health-checked
# first and the switch is REFUSED (exit 1) if it isn't healthy, so it's safe
# to call from automation.
#

set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────
VALIDATOR_SH="/home/sol/validator.sh"
# shellcheck source=lib-env.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib-env.sh"
LEDGER_DIR=$(detect_ledger_dir)
PING_THRESHOLD_MS=30
PING_COUNT=3
# ─────────────────────────────────────────────────────────────────────

# ── BAM regions per network ──────────────────────────────────────────
# Fetched live from the official BAM validators page so the list never
# drifts from https://bam.dev/validators/#step-3-choose-your-region.
# Falls back to a baked-in snapshot only if the page is unreachable, so
# automation (role-bam-sync, failover) keeps working during an outage.
BAM_REGIONS_URL="https://bam.dev/validators/"
# IATA airport codes — matches what the page now advertises. BAM's DNS
# still resolves the old city names too, but we key everything off the
# codes and translate legacy names via REGION_ALIASES below.
FALLBACK_MAINNET_REGIONS="ams dfw dub ewr fra iad lax lon pit sin slc sqq tyo"
FALLBACK_TESTNET_REGIONS="dfw ewr fra sea slc"

# ── Legacy city name → IATA code aliases ─────────────────────────────
# BAM renamed its regions from city names to IATA airport codes but its
# DNS still resolves the old names. We accept either spelling on the
# command line by folding a legacy/city name to the IATA code the page
# now uses; the interactive picker only ever shows the scraped IATA codes.
declare -A REGION_ALIASES=(
    [amsterdam]=ams   [ashburn]=iad     [dallas]=dfw      [dublin]=dub
    [frankfurt]=fra   [london]=lon      [losangeles]=lax  [newyork]=ewr
    [ny]=ewr          [pittsburgh]=pit  [saltlakecity]=slc
    [seattle]=sea     [siauliai]=sqq    [singapore]=sin   [tokyo]=tyo
)

# Normalize a region token: lowercase, then map any legacy/city name to
# its IATA code. Unknown tokens pass through unchanged (validated later).
normalize_region() {
    local r="${1,,}"
    echo "${REGION_ALIASES[$r]:-$r}"
}

# Scrape <region>.<network>.bam.jito.wtf hostnames from the page and echo a
# space-separated, de-duplicated region list. Empty echo on any failure.
fetch_regions() {
    local network="$1" html out
    html=$(curl -fsS -m 10 "$BAM_REGIONS_URL" 2>/dev/null) || { echo ""; return 0; }
    out=$(printf '%s' "$html" \
        | grep -oE "[a-z0-9-]+\.${network}\.bam\.jito\.wtf" \
        | sed -E "s/\.${network}\..*//" \
        | sort -u | paste -sd' ' || true)
    echo "$out"
    return 0
}

# Live region list for a network, falling back to the snapshot on failure.
get_regions() {
    local network="$1" regions=""
    regions=$(fetch_regions "$network")
    if [[ -z "$regions" ]]; then
        case "$network" in
            mainnet) regions="$FALLBACK_MAINNET_REGIONS" ;;
            testnet) regions="$FALLBACK_TESTNET_REGIONS" ;;
        esac
        echo "Warning: could not fetch BAM region list from ${BAM_REGIONS_URL}; using built-in fallback." >&2
    fi
    echo "$regions"
}

# ── Parse args ───────────────────────────────────────────────────────
NETWORK=""
REGION=""
DISABLE=false
AUTO=false

for arg in "$@"; do
    case "$arg" in
        --mainnet)  NETWORK="mainnet" ;;
        --testnet)  NETWORK="testnet" ;;
        --off)      DISABLE=true ;;
        --auto)     AUTO=true ;;
        -*)         echo "Unknown flag: $arg"; exit 1 ;;
        *)          REGION="$arg" ;;
    esac
done

# ── Detect whether the positional arg is a raw IP/hostname ───────────
# Region names are bare single tokens (slc, ny). Anything with a dot
# (IPv4 or FQDN) or a colon (host:port) is treated as a direct BAM host
# to set verbatim — bypassing the region map, the network requirement,
# and the full cluster probe.
is_direct_host() {
    local s="$1"
    [[ "$s" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}(:[0-9]+)?$ ]] && return 0   # IPv4[:port]
    [[ "$s" == *.* || "$s" == *:* ]] && return 0                         # FQDN or host:port
    return 1
}

TARGET_HOST=""
if [[ -n "$REGION" ]] && is_direct_host "$REGION"; then
    TARGET_HOST="$REGION"
    REGION=""
fi

# Accept a legacy city name (or any case) as well as the IATA code.
if [[ -n "$REGION" ]]; then
    REGION=$(normalize_region "$REGION")
fi

# ── Auto-detect network if not specified on command line ─────────────
if [[ -z "$NETWORK" && -z "$TARGET_HOST" ]]; then
    DETECTED=""

    # Method 1: solana config get — check RPC URL
    if command -v solana &>/dev/null; then
        RPC_URL=$(solana config get 2>/dev/null | awk '/RPC URL/ {print $3}')
        if [[ "$RPC_URL" == *"mainnet"* ]]; then
            DETECTED="mainnet"
        elif [[ "$RPC_URL" == *"testnet"* ]]; then
            DETECTED="testnet"
        elif [[ "$RPC_URL" == *"devnet"* ]]; then
            DETECTED=""  # devnet not supported, will prompt
        fi
    fi

    # Method 2: check validator.sh entrypoints
    if [[ -z "$DETECTED" && -f "$VALIDATOR_SH" ]]; then
        if grep -q "mainnet" "$VALIDATOR_SH" 2>/dev/null; then
            DETECTED="mainnet"
        elif grep -q "testnet" "$VALIDATOR_SH" 2>/dev/null; then
            DETECTED="testnet"
        fi
    fi

    # Method 3: check current --bam-url in validator process
    if [[ -z "$DETECTED" ]]; then
        BAM_PROC=$(ps aux 2>/dev/null | grep -oP '\-\-bam-url\s+\S+' | head -1 | awk '{print $2}')
        if [[ "$BAM_PROC" == *"mainnet"* ]]; then
            DETECTED="mainnet"
        elif [[ "$BAM_PROC" == *"testnet"* ]]; then
            DETECTED="testnet"
        fi
    fi

    if [[ -n "$DETECTED" ]]; then
        echo -e "Auto-detected network: \033[1m${DETECTED}\033[0m"
        NETWORK="$DETECTED"
    else
        echo "Could not auto-detect network."
        echo -ne "  [1] mainnet  [2] testnet  : "
        read -r NET_CHOICE
        case "$NET_CHOICE" in
            1) NETWORK="mainnet" ;;
            2) NETWORK="testnet" ;;
            *) echo "Invalid choice."; exit 1 ;;
        esac
    fi
fi

if [[ -n "$TARGET_HOST" ]]; then
    REGIONS=""                       # direct host — region map not used
elif [[ "$NETWORK" == "mainnet" ]]; then
    REGIONS=$(get_regions mainnet)
elif [[ "$NETWORK" == "testnet" ]]; then
    REGIONS=$(get_regions testnet)
else
    echo "Invalid network: $NETWORK (use mainnet or testnet)"
    exit 1
fi

# ── Detect this host's validator identity pubkey ─────────────────────
# Used by the BAM-side current-connection lookup (probe /api/v1/validators
# on every region; the region listing this pubkey is where we're connected).
# Testing/debug override: export IDENTITY_PUBKEY_OVERRIDE=<pubkey> to skip
# auto-detection (useful for verifying BAM-side lookup from a non-validator host).
#
# Priority: agave-validator contact-info returns the *current* running
# identity, which is what BAM tracks us by. The --identity process arg is
# the startup identity (often unstaked) and won't match BAM's roster after
# `set-identity` hot-swap, so it's only a fallback.
IDENTITY_PUBKEY="${IDENTITY_PUBKEY_OVERRIDE:-}"
if [[ -z "$IDENTITY_PUBKEY" ]] && command -v agave-validator &>/dev/null; then
    IDENTITY_PUBKEY=$(agave-validator --ledger "$LEDGER_DIR" contact-info 2>/dev/null \
        | awk '/^Identity:/ {print $2; exit}' || true)
fi
if [[ -z "$IDENTITY_PUBKEY" ]]; then
    IDENTITY_PATH=$(ps aux 2>/dev/null | grep -oP -- '--identity\s+\S+' | head -1 | awk '{print $2}' || true)
    if [[ -n "$IDENTITY_PATH" && -f "$IDENTITY_PATH" ]] && command -v solana-keygen &>/dev/null; then
        IDENTITY_PUBKEY=$(solana-keygen pubkey "$IDENTITY_PATH" 2>/dev/null || true)
    fi
fi
if [[ -z "$IDENTITY_PUBKEY" ]] && command -v solana &>/dev/null; then
    IDENTITY_PUBKEY=$(solana address 2>/dev/null || true)
fi

# ── Colors ───────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ── Detect current BAM connection ────────────────────────────────────
# Priority:
#   1. BAM-side lookup — find which region's /api/v1/validators lists our
#      identity pubkey (lowest heartbeat_age_ms = active). Authoritative:
#      reflects what BAM actually sees, including runtime RPC switches.
#      Requires probe_all_regions to have populated IDENTITY_HEARTBEAT.
#   2. Live process args --bam-url — STARTUP value only. Stale after any
#      `set-bam-config` runtime change; agave doesn't expose a getter or
#      log URL switches in a parseable form, so this is the only fallback.
# Returns "url|source" so both values survive the subshell.
detect_current_bam() {
    local bam_url=""

    # Method 1: BAM-side lookup via /api/v1/validators (authoritative)
    if [[ -n "$IDENTITY_PUBKEY" ]] && [[ ${#IDENTITY_HEARTBEAT[@]} -gt 0 ]]; then
        local best_r="" best_hb=999999999 r hb
        for r in "${!IDENTITY_HEARTBEAT[@]}"; do
            hb="${IDENTITY_HEARTBEAT[$r]}"
            if [[ -z "$hb" ]] || ! [[ "$hb" =~ ^[0-9]+$ ]]; then continue; fi
            if (( hb < best_hb )); then
                best_hb=$hb
                best_r=$r
            fi
        done
        if [[ -n "$best_r" ]]; then
            echo "http://${best_r}.${NETWORK}.bam.jito.wtf|BAM /api/v1/validators (heartbeat ${best_hb}ms)"
            return
        fi
    fi

    # Method 2: live process args (startup config — may be stale)
    bam_url=$(ps aux 2>/dev/null | grep -oP '\-\-bam-url\s+\S+' | head -1 | awk '{print $2}')
    if [[ -n "$bam_url" ]]; then
        echo "${bam_url}|startup --bam-url (may be stale if changed via RPC)"
        return
    fi

    echo "|"
}

# Extract region name from a BAM URL like http://slc.mainnet.bam.jito.wtf
extract_region_from_url() {
    local url="$1"
    echo "$url" | sed -E 's|https?://([^.]+)\..*|\1|'
}

# ── Disable BAM ──────────────────────────────────────────────────────
disable_bam() {
    echo ""
    echo "Disabling BAM..."
    if agave-validator --ledger "$LEDGER_DIR" set-bam-config --bam-url; then
        echo "Done."
        return 0
    fi
    echo "agave-validator set-bam-config failed."
    return 1
}

# ── Build URL from region ───────────────────────────────────────────
make_url() { echo "http://${1}.${NETWORK}.bam.jito.wtf"; }

# ── Ping a raw host, return avg latency in ms (integer) or "timeout" ─
ping_host() {
    local host="$1"
    local count="${2:-$PING_COUNT}"
    local avg
    avg=$(ping -c "$count" -W 1 "$host" 2>/dev/null \
        | awk -F'/' '/^rtt|^round-trip/ {printf "%.0f", $5}')
    if [[ -z "$avg" ]]; then
        echo "timeout"
    else
        echo "$avg"
    fi
}

# Region wrapper — pings <region>.<network>.bam.jito.wtf
ping_region() { ping_host "${1}.${NETWORK}.bam.jito.wtf" "${2:-$PING_COUNT}"; }

# ── Health-check a BAM node via /api/v1/health/* ────────────────────
# Returns: ok | unhealthy:<reason> | down
# Uses if/elif (not [[ ]] && {...}) because we run inside set -e and a
# false [[ ]] short-circuit at the end of an && list trips errexit,
# killing the subshell before echo runs.
# BAM rate-limits to ~1 call/sec/server/source-IP, so we sleep 1s between
# the two health calls. Running per-region in a bg job, this adds ~1s
# wallclock but stays under the 429 threshold.
bam_health_check_host() {
    local host="$1"
    local resp sd

    resp=$(curl -sS -m 3 "http://${host}:9090/api/v1/health/validator" 2>/dev/null) || { echo "down"; return 0; }

    if   [[ "$resp" != *'"healthy":true'* ]];             then echo "unhealthy:not-healthy"
    elif [[ "$resp" != *'"validator_caught_up":true'* ]]; then echo "unhealthy:not-caught-up"
    elif [[ "$resp" != *'"scheduler_ready":true'* ]];     then echo "unhealthy:scheduler-not-ready"
    elif [[ "$resp" != *'"startup_ready":true'* ]];       then echo "unhealthy:startup-not-ready"
    else
        sleep 1
        sd=$(curl -sS -m 3 "http://${host}:9090/api/v1/health/shutting_down" 2>/dev/null) || sd=""
        if [[ "$sd" == *'"shutting_down":true'* ]]; then
            echo "unhealthy:shutting-down"
        else
            echo "ok"
        fi
    fi
    return 0
}

# Region wrapper — health-checks <region>.<network>.bam.jito.wtf
bam_health_check() { bam_health_check_host "${1}.${NETWORK}.bam.jito.wtf"; }

# ── BAM-side: does our identity appear in this region's roster? ─────
# Returns heartbeat_age_ms (digits) if found, empty otherwise.
# /api/v1/validators returns a flat JSON array of flat objects, so a
# bounded {…validator_pubkey:PK…} grep is reliable without jq.
bam_validator_heartbeat() {
    if [[ -z "$IDENTITY_PUBKEY" ]]; then return 0; fi
    local host="${1}.${NETWORK}.bam.jito.wtf"
    local resp match hb
    resp=$(curl -sS -m 5 "http://${host}:9090/api/v1/validators" 2>/dev/null) || return 0
    match=$(echo "$resp" | grep -oE "\{[^{}]*\"validator_pubkey\":\"${IDENTITY_PUBKEY}\"[^{}]*\}" | head -1 || true)
    if [[ -n "$match" ]]; then
        hb=$(echo "$match" | grep -oE '"heartbeat_age_ms":[0-9]+' | grep -oE '[0-9]+' || echo "")
        echo "$hb"
    fi
    return 0
}

# ── Fan out ICMP ping + HTTP probes for all $REGIONS in parallel ────
# 2N background jobs: ICMP ping (parallel) and an HTTP-chain worker per
# region (parallel across regions, serialized within-region).
# Within-region serialization avoids the per-server burst rate-limit
# (~3 concurrent HTTP calls triggers 429 on the same BAM endpoint).
# Wallclock ≈ max(slowest ping, slowest HTTP chain) ≈ 3-5s.
# Populates LATENCIES[r], HEALTH[r], IDENTITY_HEARTBEAT[r].
declare -A LATENCIES=()
declare -A HEALTH=()
declare -A IDENTITY_HEARTBEAT=()
RESULT_FILE=""
probe_all_regions() {
    LATENCIES=()
    HEALTH=()
    IDENTITY_HEARTBEAT=()
    RESULT_FILE=$(mktemp)
    trap 'rm -f "$RESULT_FILE"' EXIT

    local r
    for r in $REGIONS; do
        ( echo "PING|${r}|$(ping_region "$r")" >> "$RESULT_FILE" ) &
        (
            h=$(bam_health_check "$r")
            sleep 1                              # rate-limit spacing
            ident=$(bam_validator_heartbeat "$r")
            {
                echo "HEALTH|${r}|${h}"
                echo "IDENT|${r}|${ident}"
            } >> "$RESULT_FILE"
        ) &
    done
    wait

    local kind v
    while IFS='|' read -r kind r v; do
        if [[ -z "$kind" ]]; then continue; fi
        case "$kind" in
            PING)   LATENCIES[$r]="$v"          ;;
            HEALTH) HEALTH[$r]="$v"             ;;
            IDENT)  IDENTITY_HEARTBEAT[$r]="$v" ;;
        esac
    done < "$RESULT_FILE"

    # Unreachable host → force health to "down" regardless of curl result
    for r in "${!LATENCIES[@]}"; do
        if [[ "${LATENCIES[$r]}" == "timeout" ]]; then
            HEALTH[$r]="down"
        fi
    done
    return 0
}

# ── Apply the BAM URL ───────────────────────────────────────────────
apply_bam_url() {
    local url="$1"
    echo ""
    echo "Setting BAM URL to: $url"

    if agave-validator --ledger "$LEDGER_DIR" set-bam-config --bam-url "$url"; then
        echo "Done."
        return 0
    fi
    echo "agave-validator set-bam-config failed."
    return 1
}

# Apply a URL and exit with the real result. Terminal apply points used this
# followed by an unconditional `exit 0`, which only avoided reporting success on
# a failed apply because `set -e` aborted first — fragile and misleading. The
# `if` makes the exit code explicit (0 set / 1 failed) without relying on errexit.
apply_and_exit() {
    local url="$1"
    if apply_bam_url "$url"; then
        exit 0
    fi
    echo -e "${RED}Did not switch BAM to ${url}.${RESET}" >&2
    exit 1
}

# ── Direct IP/hostname target: verify health, then set verbatim ──────
# Non-interactive by design (automation-safe): if the node isn't healthy
# we refuse to switch and exit non-zero. The BAM health endpoint
# (/api/v1/health on :9090) is authoritative; ping latency is shown for
# context only, since ICMP may be filtered even when BAM is reachable.
set_direct_host() {
    local input="$1"
    local host="${input#http://}"; host="${host#https://}"
    host="${host%%/*}"                 # strip any path
    local probe_host="${host%%:*}"     # host without :port for probing
    local url="http://${host}"

    echo -e "${BOLD}Verifying BAM node ${host} before switching...${RESET}"

    local latency health lat_disp
    latency=$(ping_host "$probe_host")
    health=$(bam_health_check_host "$probe_host")

    lat_disp="$latency"
    [[ "$latency" != "timeout" ]] && lat_disp="${latency}ms"
    printf "  %-24s  %-10s  %s\n" "Host"  "Latency"  "Health"
    printf "  %-24s  %-10s  %s\n" "$host" "$lat_disp" "$health"
    echo ""

    # Gate 1: BAM health must be ok (authoritative).
    if [[ "$health" != "ok" ]]; then
        echo -e "${RED}${host} is NOT healthy (BAM health: ${health}).${RESET}"
        echo -e "${RED}Did not switch BAM to ${host}.${RESET}"
        exit 1
    fi

    # Gate 2: latency must be within threshold when measurable. ICMP may be
    # filtered on a raw host even while BAM is reachable, so a ping timeout
    # is a warning (proceed), not a failure; an over-threshold RTT is refused.
    if [[ "$latency" == "timeout" ]]; then
        echo -e "${YELLOW}${host} is healthy but latency is unknown (ICMP filtered/blocked). Proceeding.${RESET}"
    elif (( latency > PING_THRESHOLD_MS )); then
        echo -e "${RED}${host} is healthy but latency is ${latency}ms (threshold: ${PING_THRESHOLD_MS}ms).${RESET}"
        echo -e "${RED}Did not switch BAM to ${host}.${RESET}"
        exit 1
    else
        echo -e "${GREEN}${host} is healthy (${latency}ms). Proceeding.${RESET}"
    fi

    if apply_bam_url "$url"; then
        exit 0
    fi
    echo -e "${RED}Failed to set BAM to ${host}.${RESET}"
    exit 1
}

# ── Interactive picker — uses already-populated probe arrays ────────
show_picker() {
    declare -a GOOD_REGIONS=()
    IDX=0

    printf "  %-4s  %-15s  %-10s  %s\n" "#"   "Region"          "Latency"  "Health"
    printf "  %-4s  %-15s  %-10s  %s\n" "---" "---------------" "--------" "--------------------"
    printf "  ${YELLOW}%-4s  %-15s  %-10s  %s${RESET}\n" "0" "(disable BAM)" "" ""

    for r in $REGIONS; do
        ms="${LATENCIES[$r]}"
        h="${HEALTH[$r]}"
        STAR=""
        [[ "$r" == "$CURRENT_BAM_REGION" ]] && STAR=" *"

        if [[ "$ms" == "timeout" ]]; then
            ms_disp="timeout"
            color="$RED"
        elif (( ms > PING_THRESHOLD_MS )); then
            ms_disp="${ms}ms"
            color="$RED"
        elif [[ "$h" != "ok" ]]; then
            ms_disp="${ms}ms"
            color="$YELLOW"
        else
            ms_disp="${ms}ms"
            color="$GREEN"
        fi

        if [[ "$ms" != "timeout" ]] && (( ms <= PING_THRESHOLD_MS )) && [[ "$h" == "ok" ]]; then
            IDX=$((IDX + 1))
            GOOD_REGIONS+=("$r")
            printf "  ${GREEN}%-4s  %-15s  %-10s  %s${RESET}%s\n" "$IDX" "$r" "$ms_disp" "$h" "$STAR"
        else
            printf "  ${color}%-4s  %-15s  %-10s  %s${RESET}%s\n" " -" "$r" "$ms_disp" "$h" "$STAR"
        fi
    done

    echo ""

    if [[ ${#GOOD_REGIONS[@]} -eq 0 ]]; then
        echo -e "${RED}No regions with latency <= ${PING_THRESHOLD_MS}ms AND healthy BAM service found.${RESET}"
        exit 1
    fi

    echo -ne "${YELLOW}Enter number to select, 0 to disable BAM, or 'q' to quit:${RESET} "
    read -r CHOICE

    if [[ "$CHOICE" == "q" || -z "$CHOICE" ]]; then
        echo "Cancelled."
        exit 0
    fi

    if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || (( CHOICE > ${#GOOD_REGIONS[@]} )); then
        echo "Invalid selection."
        exit 1
    fi

    if (( CHOICE == 0 )); then
        if disable_bam; then
            exit 0
        fi
        exit 1
    fi

    SELECTED="${GOOD_REGIONS[$((CHOICE - 1))]}"
    apply_and_exit "$(make_url "$SELECTED")"
}

# ── Probe BAM cluster once (parallel: ping + health + identity) ──────
# Skipped for --off. Results are reused by detect_current_bam,
# show_picker, and the explicit-region path — no double-probe.
if ! $DISABLE && [[ -z "$TARGET_HOST" ]]; then
    echo -e "${BOLD}Probing all BAM endpoints for ${NETWORK} (parallel: ping + health + identity)...${RESET}"
    probe_all_regions
    echo ""
fi

# ── Detect current BAM connection (uses probe data if populated) ─────
_BAM_RESULT=$(detect_current_bam)
CURRENT_BAM_URL="${_BAM_RESULT%%|*}"
BAM_DETECT_SOURCE="${_BAM_RESULT#*|}"
CURRENT_BAM_REGION=""
if [[ -n "$CURRENT_BAM_URL" ]]; then
    CURRENT_BAM_REGION=$(extract_region_from_url "$CURRENT_BAM_URL")
    # A still-running validator may report a legacy city-name URL; fold it
    # to the IATA code so the current-connection "*" marker matches the list.
    CURRENT_BAM_REGION=$(normalize_region "$CURRENT_BAM_REGION")
fi

# ── Show current BAM connection ──────────────────────────────────────
if [[ -n "$CURRENT_BAM_URL" ]]; then
    echo -e "Current BAM node: ${CYAN}${BOLD}${CURRENT_BAM_REGION}${RESET} (${CURRENT_BAM_URL}) — via ${BAM_DETECT_SOURCE}"
elif [[ -n "$BAM_DETECT_SOURCE" ]]; then
    echo -e "Current BAM node: ${YELLOW}none${RESET} — ${BAM_DETECT_SOURCE}"
else
    echo -e "Current BAM node: ${YELLOW}none (BAM not detected)${RESET}"
fi
echo ""

# ── --off branch: disable BAM and exit ───────────────────────────────
if $DISABLE; then
    if disable_bam; then
        exit 0
    fi
    exit 1
fi

# ── Direct IP/hostname target: health-verify, then set and exit ──────
if [[ -n "$TARGET_HOST" ]]; then
    set_direct_host "$TARGET_HOST"   # exits 0 (set) or 1 (unhealthy/failed)
fi

# ── --auto branch: pick lowest-latency healthy region, apply if needed
# Non-interactive entry point used by role-bam-sync.sh on primary.
# Exits 0 on apply success or already-on-best (no-op).
# Exits 1 if no region passes the latency+health gate, or apply fails.
if $AUTO; then
    BEST_REGION=""
    BEST_MS=999999
    for r in $REGIONS; do
        ms="${LATENCIES[$r]}"
        h="${HEALTH[$r]}"
        if [[ "$ms" != "timeout" ]] && (( ms <= PING_THRESHOLD_MS )) && [[ "$h" == "ok" ]]; then
            if (( ms < BEST_MS )); then
                BEST_MS=$ms
                BEST_REGION=$r
            fi
        fi
    done

    if [[ -z "$BEST_REGION" ]]; then
        echo -e "${RED}--auto: no BAM region passes ${PING_THRESHOLD_MS}ms+healthy gate. Leaving BAM URL unchanged.${RESET}" >&2
        exit 1
    fi

    DESIRED_URL=$(make_url "$BEST_REGION")
    if [[ "$CURRENT_BAM_URL" == "$DESIRED_URL" ]]; then
        echo -e "${GREEN}--auto: already on best healthy region ${BEST_REGION} (${BEST_MS}ms). No change.${RESET}"
        exit 0
    fi

    echo -e "--auto: best healthy region is ${GREEN}${BOLD}${BEST_REGION}${RESET} (${BEST_MS}ms)"
    apply_and_exit "$DESIRED_URL"
fi

# ── Validate explicit region ────────────────────────────────────────
if [[ -n "$REGION" ]]; then
    FOUND=false
    for r in $REGIONS; do
        [[ "$r" == "$REGION" ]] && FOUND=true && break
    done
    if ! $FOUND; then
        echo "Region '$REGION' is not valid for $NETWORK."
        echo "Available: $REGIONS"
        exit 1
    fi

    # probe data already populated by main flow
    BEST_REGION=""
    BEST_MS=999999

    printf "  %-15s  %-10s  %s\n" "Region"          "Latency"  "Health"
    printf "  %-15s  %-10s  %s\n" "---------------" "--------" "--------------------"

    for r in $REGIONS; do
        ms="${LATENCIES[$r]}"
        h="${HEALTH[$r]}"

        MARKER=""
        [[ "$r" == "$REGION" ]] && MARKER=" <=="
        [[ "$r" == "$CURRENT_BAM_REGION" ]] && MARKER="${MARKER} *"

        if [[ "$ms" == "timeout" ]]; then
            printf "  ${RED}%-15s  %-10s  %s${RESET}%s\n" "$r" "timeout" "$h" "$MARKER"
        elif (( ms > PING_THRESHOLD_MS )); then
            printf "  ${RED}%-15s  %-10s  %s${RESET}%s\n" "$r" "${ms}ms" "$h" "$MARKER"
        elif [[ "$h" != "ok" ]]; then
            printf "  ${YELLOW}%-15s  %-10s  %s${RESET}%s\n" "$r" "${ms}ms" "$h" "$MARKER"
        else
            printf "  ${GREEN}%-15s  %-10s  %s${RESET}%s\n" "$r" "${ms}ms" "$h" "$MARKER"
            if (( ms < BEST_MS )); then
                BEST_MS=$ms
                BEST_REGION=$r
            fi
        fi
    done

    echo ""

    REQUESTED_MS="${LATENCIES[$REGION]}"
    REQUESTED_HEALTH="${HEALTH[$REGION]}"

    # Requested region is unreachable
    if [[ "$REQUESTED_MS" == "timeout" ]]; then
        echo -e "${RED}${REGION} is unreachable.${RESET}"
        if [[ -n "$BEST_REGION" ]]; then
            echo -e "${YELLOW}Fastest healthy region: ${BEST_REGION} (${BEST_MS}ms)${RESET}"
            echo -ne "  [y] Use ${BEST_REGION} instead  [p] Pick from list  [q] Quit: "
            read -r ANSWER
            case "$ANSWER" in
                q|Q) echo "Cancelled."; exit 0 ;;
                p|P) echo ""; show_picker ;;
                *)   apply_and_exit "$(make_url "$BEST_REGION")" ;;
            esac
        else
            echo -e "${RED}No reachable + healthy regions found.${RESET}"
            exit 1
        fi

    # Requested region exceeds latency threshold
    elif (( REQUESTED_MS > PING_THRESHOLD_MS )); then
        echo -e "${YELLOW}${REGION} latency is ${REQUESTED_MS}ms (threshold: ${PING_THRESHOLD_MS}ms).${RESET}"
        [[ "$REQUESTED_HEALTH" != "ok" ]] && echo -e "${RED}  Plus BAM health: ${REQUESTED_HEALTH}${RESET}"
        if [[ -n "$BEST_REGION" ]]; then
            echo -e "${GREEN}Faster healthy option: ${BEST_REGION} (${BEST_MS}ms)${RESET}"
            echo -ne "  [b] Use ${BEST_REGION}  [y] Use ${REGION} anyway  [p] Pick from list  [q] Quit: "
            read -r ANSWER
            case "$ANSWER" in
                y|Y) apply_and_exit "$(make_url "$REGION")" ;;
                q|Q) echo "Cancelled."; exit 0 ;;
                p|P) echo ""; show_picker ;;
                *)   apply_and_exit "$(make_url "$BEST_REGION")" ;;
            esac
        else
            echo -ne "  No healthy regions under threshold. [y] Use ${REGION} anyway  [q] Quit: "
            read -r ANSWER
            case "$ANSWER" in
                y|Y) apply_and_exit "$(make_url "$REGION")" ;;
                *)   echo "Cancelled."; exit 0 ;;
            esac
        fi

    # Requested region has good latency but BAM service is unhealthy
    elif [[ "$REQUESTED_HEALTH" != "ok" ]]; then
        echo -e "${YELLOW}${REGION} latency is good (${REQUESTED_MS}ms) but BAM health: ${RED}${REQUESTED_HEALTH}${RESET}"
        if [[ -n "$BEST_REGION" ]]; then
            echo -e "${GREEN}Healthy alternative: ${BEST_REGION} (${BEST_MS}ms)${RESET}"
            echo -ne "  [b] Use ${BEST_REGION}  [y] Use ${REGION} anyway  [p] Pick from list  [q] Quit: "
            read -r ANSWER
            case "$ANSWER" in
                y|Y) apply_and_exit "$(make_url "$REGION")" ;;
                q|Q) echo "Cancelled."; exit 0 ;;
                p|P) echo ""; show_picker ;;
                *)   apply_and_exit "$(make_url "$BEST_REGION")" ;;
            esac
        else
            echo -ne "  No healthy regions found. [y] Use ${REGION} anyway  [q] Quit: "
            read -r ANSWER
            case "$ANSWER" in
                y|Y) apply_and_exit "$(make_url "$REGION")" ;;
                *)   echo "Cancelled."; exit 0 ;;
            esac
        fi

    # Requested region is good and healthy — but is there something faster?
    else
        if [[ -n "$BEST_REGION" && "$BEST_REGION" != "$REGION" ]] && (( BEST_MS < REQUESTED_MS - 3 )); then
            echo -e "${GREEN}${REGION} looks good at ${REQUESTED_MS}ms (healthy), but ${BEST_REGION} is faster at ${BEST_MS}ms.${RESET}"
            echo -ne "  [enter] Use ${REGION}  [b] Use ${BEST_REGION} instead  [q] Quit: "
            read -r ANSWER
            case "$ANSWER" in
                b|B) apply_and_exit "$(make_url "$BEST_REGION")" ;;
                q|Q) echo "Cancelled."; exit 0 ;;
                *)   apply_and_exit "$(make_url "$REGION")" ;;
            esac
        else
            echo -e "${GREEN}${REGION} is the best option at ${REQUESTED_MS}ms (healthy). Proceeding.${RESET}"
            apply_and_exit "$(make_url "$REGION")"
        fi
    fi
    # Unreachable: every branch above applies (apply_and_exit) or exits. If we
    # ever fall through here, nothing was set — fail rather than report success.
    exit 1
fi

# ── No region specified — go straight to picker ─────────────────────
show_picker
