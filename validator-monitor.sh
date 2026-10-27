#!/bin/bash

# Validator Node Monitor — ONE file for every Trillium validator host
# (new-amsterdam, ogden: mainnet · testnet-ogden: testnet · alpenglow: its own chain).
# Network: genesis hash (mainnet/testnet); the alpenglow host is keyed on its
# alpenglow.service unit. Client: Jito-Agave or FireBAM, detected each cycle.
# Reads the local JSON-RPC, the validator log (FireBAM: firebam-log-view.py and
# its :7999 metrics), the doublezerod socket and systemd. No `solana` CLI calls.
#
# Usage:
#   VOTE_PUBKEY=<vote-pubkey> ~/validator-monitor.sh        # live monitor
#   ~/validator-monitor.sh --once                            # single snapshot, then exit
#   ~/validator-monitor.sh --help                            # show usage
#
# VOTE_PUBKEY is required; if unset, falls back to VOTE_ACCOUNT in
# ~/.config/validator/rpc.conf so this host's monitor can be started with no env.
# The stack (Agave or FireBAM) is detected each cycle; VALIDATOR_CLIENT=agave|firebam forces it.
# CLUSTER_RPC_URL (rpc.conf MAINNET_/TESTNET_RPC_URL, or ~/secrets.env on
# alpenglow) adds an "outside view": an independent tip and the cluster's
# opinion of our vote account. Its endpoint is never printed.
#
# Press Ctrl+C to exit live mode.

trap 'echo -e "\n\nMonitoring stopped."; exit 0' INT

RUN_ONCE=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --once|--run-once) RUN_ONCE=true; shift ;;
        --help|-h)
            sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# Bump on every deploy (date.N); shown in the top line so a host running a stale copy is obvious.
SCRIPT_VERSION="2026.10.27.1"

# ---- Secrets ----
# Optional secrets file (external RPC endpoints with embedded tokens; used on the
# alpenglow host). Everything set here becomes a default for the config below,
# so credentials stay out of argv, the process table and this script.
SECRETS_ENV="${SECRETS_ENV:-$HOME/secrets.env}"
if [ -r "$SECRETS_ENV" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$SECRETS_ENV"
    set +a
fi

# ---- Host profile ----
# The alpenglow box runs a separate chain whose genesis hash changes on every
# regenesis, so it cannot be keyed by genesis like mainnet/testnet: key it on
# its unit. Everything else is "standard" (the sol-user mainnet/testnet hosts).
HOST_PROFILE=standard
if systemctl list-unit-files alpenglow.service --no-legend 2>/dev/null | grep -q .; then
    HOST_PROFILE=alpenglow
fi

RPC_URL="${RPC_URL:-http://127.0.0.1:8899}"
# CLUSTER_RPC_URL is an independent full RPC (a secret: env, rpc.conf or
# ~/secrets.env — never written into this file). Two uses:
#   1. "Outside view": an independent tip + the cluster's opinion of our vote
#      account (2 getSlot per cycle + one FILTERED getVoteAccounts per SLOW_REFRESH).
#   2. FireBAM only: getVoteAccounts / getRecentPerformanceSamples, which its
#      local RPC answers with HTTP 501. Agave keeps those on RPC_URL (an
#      unfiltered getVoteAccounts every cycle is not worth an external bill).
# Resolved after the network is known (detect_network): mainnet -> rpc.conf
# MAINNET_RPC_URL, testnet -> TESTNET_RPC_URL; alpenglow -> secrets.env
# QUICKNODE_ALPENGLOW_RPC_URL / QUICKNODE_RPC_URL. Empty = no outside view.
CLUSTER_RPC_URL="${CLUSTER_RPC_URL:-}"
if [ -z "$CLUSTER_RPC_URL" ] && [ "$HOST_PROFILE" = alpenglow ]; then
    CLUSTER_RPC_URL="${QUICKNODE_ALPENGLOW_RPC_URL:-${QUICKNODE_RPC_URL:-}}"
fi
# Screen label for the outside endpoint — never the URL (QuickNode puts the auth
# token in the path).
_cluster_rpc_label() {
    [ -n "${CLUSTER_RPC_LABEL_ENV:-}" ] && { CLUSTER_RPC_LABEL="$CLUSTER_RPC_LABEL_ENV"; return; }
    local h
    h=$(echo "$CLUSTER_RPC_URL" | sed -E 's#^[a-z]+://([^/]+).*#\1#')
    case "$h" in
        *quiknode.pro|*quicknode.com) CLUSTER_RPC_LABEL="quicknode" ;;
        "")                           CLUSTER_RPC_LABEL="outside" ;;
        *)                            CLUSTER_RPC_LABEL="$h" ;;
    esac
}
CLUSTER_RPC_LABEL_ENV="${CLUSTER_RPC_LABEL:-}"
# OUTSIDE_VIEW=0 turns the outside-view rows and their calls off (the FireBAM
# vote list still uses CLUSTER_RPC_URL, at most every VOTE_LIST_REFRESH).
OUTSIDE_VIEW="${OUTSIDE_VIEW:-1}"
_outside_on() { [ "$OUTSIDE_VIEW" = 1 ] && [ -n "$CLUSTER_RPC_URL" ] && [ "$CLUSTER_RPC_URL" != "$RPC_URL" ]; }
_cluster_rpc_label

# FireBAM's RPC rejects JSON-RPC batch arrays (-32700). Send each call alone and
# join the replies into one array. Prints nothing when no call got a reply.
rpc_batch() {
    local url="$1"; shift
    local arr="[]" reply body
    local ok=0
    for body in "$@"; do
        reply=$(curl -s --connect-timeout 3 -X POST -H 'Content-Type: application/json' \
            --data "$body" "$url" 2>/dev/null)
        if [ -n "$reply" ] && jq -e 'type=="object" and has("id")' <<<"$reply" >/dev/null 2>&1; then
            # Pipe the reply, not --argjson: vote-account replies exceed ARG_MAX.
            arr=$(printf '%s\n%s' "$arr" "$reply" | jq -cs '.[0] + [.[1]]')
            ok=1
        fi
    done
    [ "$ok" = 1 ] && echo "$arr"
}

if [ "$HOST_PROFILE" = alpenglow ]; then
    LEDGER_DIR="${LEDGER_DIR:-$HOME/ledger}"
    SNAPSHOT_DIR="${SNAPSHOT_DIR:-$HOME/ledger}"
    SERVICE_NAME="${SERVICE_NAME:-alpenglow}"
    NETWORK="${NETWORK:-alpenglow}"
fi
LEDGER_DIR="${LEDGER_DIR:-/mnt/ledger}"
SNAPSHOT_DIR="${SNAPSHOT_DIR:-/mnt/accounts1/snapshots}"
# Main validator unit. Empty = per stack (agave: sol, firebam: firebam); see detect_client.
_SERVICE_NAME_ENV="${SERVICE_NAME:-}"
SERVICE_NAME=""
# mainnet | testnet | alpenglow. Empty = probe getGenesisHash (see detect_network).
NETWORK="${NETWORK:-}"
# Jito is retiring shredstream region by region. Hosts that have moved to the
# DoubleZero multicast run a shredstream-proxy `forward-only` unit instead;
# that is the default here. Still on Jito? SHREDSTREAM_UNIT=jito-shredstream.service
SHREDSTREAM_UNIT="${SHREDSTREAM_UNIT:-dz-shred-forward.service}"
DOUBLEZERO_UNIT="${DOUBLEZERO_UNIT:-doublezerod.service}"
DZ_SOCKET="${DZ_SOCKET:-/run/doublezerod/doublezerod.sock}"
VALIDATOR_START_SCRIPT="${VALIDATOR_START_SCRIPT:-$HOME/validator.sh}"
LOG_FILE_FALLBACK="${LOG_FILE_FALLBACK:-$HOME/logs/validator.log}"

# ---- Log source: a file, or journald ----
#
# Not every operator runs with --log. Plenty let the validator write to stdout
# and read it back with journalctl, in which case there is no log file at all.
# Both are supported:
#
#   LOG_SOURCE=file      read $LOG_FILE
#   LOG_SOURCE=journal   read journalctl -u $LOG_UNIT
#   LOG_SOURCE=auto      (default) pick one, see below
#
# When a --log path IS declared, prefer the file: journald may be rate-limiting
# (RateLimitBurst) and silently dropping the very datapoint lines this monitor
# counts, whereas the file the validator writes itself is complete.
#
# Deriving the path beats assuming it. Two layouts look identical until they
# don't: a host logging to /mnt/ledger/logs/validator.log may match the
# historical /home/sol/logs default only because the latter is a symlink to it.
# Rebuild that host, the symlink is gone, and the monitor silently reads
# nothing — no error, just empty metrics.
_derive_log_file() {
    local f="$VALIDATOR_START_SCRIPT" p=""
    [ -f "$f" ] && p=$(grep -oE -- '--log[= ]+[^ \\]+' "$f" 2>/dev/null | head -1 | sed -E 's/^--log[= ]+//')
    printf '%s' "${p:-$LOG_FILE_FALLBACK}"
}
LOG_FILE="${LOG_FILE:-$(_derive_log_file)}"
_LOG_UNIT_ENV="${LOG_UNIT:-}"
_LOG_SOURCE_ENV="${LOG_SOURCE:-auto}"
# FireBAM writes firebam.log in its own format. While firedancer runs (CLIENT=firebam),
# this helper prints the Agave-style lines the monitor reads (see firebam-log-view.py).
# Fields it does not print are shown as n/a, not 0.
FIREBAM_LOG_VIEW="${FIREBAM_LOG_VIEW:-$HOME/bam-leader-activity/firebam-log-view.py}"

# ---- Validator stack: agave | firebam ----
#
# One script serves both. VALIDATOR_CLIENT=agave|firebam overrides detection.
# Otherwise: a running firedancer process = firebam, a running agave-validator
# = agave. With neither running (validator down or restarting) keep the last
# answer, and on the first pass fall back to which unit is installed, so a
# stopped FireBAM host reports firebam.service down, not a phantom sol.service.
# The client picks the main unit, the log source and the Agave-only rows.
CLIENT=""
detect_client() {
    local prev="$CLIENT"
    case "${VALIDATOR_CLIENT:-}" in
        agave|firebam) CLIENT="$VALIDATOR_CLIENT" ;;
        "")
            if pgrep -x firedancer >/dev/null 2>&1; then
                CLIENT=firebam
            elif pgrep -x agave-validator >/dev/null 2>&1; then
                CLIENT=agave
            elif [ -z "$CLIENT" ]; then
                if [ "$(_svc_state "${_SERVICE_NAME_ENV:-$( [ "$HOST_PROFILE" = alpenglow ] && echo alpenglow || echo sol )}")" = absent ] \
                   && [ "$(_svc_state firebam.service)" != absent ]; then
                    CLIENT=firebam
                else
                    CLIENT=agave
                fi
            fi
            ;;
        *) echo "ERROR: VALIDATOR_CLIENT must be agave or firebam (got '$VALIDATOR_CLIENT')." >&2; exit 1 ;;
    esac
    if [ "$CLIENT" = firebam ]; then SERVICE_NAME="${_SERVICE_NAME_ENV:-firebam}"
    else SERVICE_NAME="${_SERVICE_NAME_ENV:-$( [ "$HOST_PROFILE" = alpenglow ] && echo alpenglow || echo sol )}"; fi
    # Re-pick the log source when the stack changes (it depends on the unit name).
    [ "$CLIENT" != "$prev" ] && _select_log_source
}

# Agave log source. LOG_SOURCE=auto picks file or journal; FireBAM ignores it.
_select_log_source() {
    LOG_UNIT="${_LOG_UNIT_ENV:-$SERVICE_NAME}"
    LOG_SOURCE="$_LOG_SOURCE_ENV"
    if [ "$LOG_SOURCE" = auto ]; then
        if [ -r "$LOG_FILE" ]; then
            LOG_SOURCE=file
        elif command -v journalctl >/dev/null 2>&1 \
             && [ -n "$(journalctl -u "$LOG_UNIT" -n 1 --no-pager -o cat 2>/dev/null)" ]; then
            # Test for OUTPUT, not exit status: journalctl exits 0 for a unit that
            # has never logged anything, so a status check would happily select
            # journald for a unit name that does not exist.
            LOG_SOURCE=journal
        else
            LOG_SOURCE=file   # nothing readable either way; downstream shows empty
        fi
    fi
}

# Service state: active | inactive | failed | absent.
#
# `systemctl is-active` reports a unit that does not exist as "inactive", which
# is indistinguishable from one that is installed and stopped. That matters
# here: the Jito and DoubleZero units are optional, and treating "not installed"
# as "down" would leave a plain Agave node permanently red with two phantom
# issues.
_svc_state() {
    if ! systemctl list-unit-files "$1" --no-legend 2>/dev/null | grep -q . \
       && ! systemctl list-units --all "$1" --no-legend 2>/dev/null | grep -q .; then
        printf 'absent'
        return
    fi
    systemctl is-active "$1" 2>/dev/null
}

# FireBAM serves Prometheus metrics on 127.0.0.1:7999. One read per cycle fills
# the fb_* variables. Tile CPU = share of time in processing_* + backpressure_*
# regimes (tile_regime_duration_nanos_total), as a delta against the previous
# cycle; on the first cycle (and with --once) it is the average since boot.
FIREBAM_METRICS_URL="${FIREBAM_METRICS_URL:-http://127.0.0.1:7999/metrics}"
declare -A FB_PREV_BUSY FB_PREV_BP FB_PREV_TOT
# Per tile: "kind:id busy_ns bp_ns total_ns" from a metrics body.
_fb_tile_totals() {
    echo "$1" | awk '/^tile_regime_duration_nanos_total\{/ {
            match($0, /kind="[^"]*"/); k=substr($0, RSTART+6, RLENGTH-7)
            match($0, /kind_id="[^"]*"/); i=substr($0, RSTART+9, RLENGTH-10)
            match($0, /tile_regime="[^"]*"/); r=substr($0, RSTART+13, RLENGTH-14)
            key=k":"i; tot[key]+=$NF
            if (r ~ /^(processing|backpressure)_/) busy[key]+=$NF
            if (r ~ /^backpressure_/) bp[key]+=$NF }
        END { for (t in tot) printf "%s %.0f %.0f %.0f\n", t, busy[t], bp[t], tot[t] }'
}
# NIC counters summed over FireBAM's mlx5 queues: "rx_bytes tx_bytes rx_pkts tx_pkts rx_drops".
# FireBAM moves traffic through XDP, so the kernel's net-stats datapoint is gone.
_fb_nic_sums() {
    # mlx5_* = FireBAM's Mellanox driver (new-amsterdam); net_* = its generic
    # XDP net tile (testnet-ogden's igb). A host has one or the other.
    echo "$1" | awk '
        /^(mlx5|net)_pkt_rx_bytes_total[{ ]/                {rb+=$NF}
        /^mlx5_pkt_tx_completed_bytes_total[{ ]/            {tb+=$NF}
        /^net_pkt_tx_submitted_bytes_total[{ ]/             {tb+=$NF}
        /^(mlx5|net)_pkt_rx_total[{ ]/                      {rp+=$NF}
        /^(mlx5|net)_pkt_tx_completed_total[{ ]/            {tp+=$NF}
        /^(mlx5|net)_pkt_rx_dropped_total[{ ]/              {rd+=$NF}
        END {printf "%.0f %.0f %.0f %.0f %.0f\n", rb, tb, rp, tp, rd}'
}
# Shred tile: "accepted completed rejected parse_failed equivocated duplicate repair_rx".
_fb_shred_sums() {
    echo "$1" | awk '
        /^shred_processed_total[{]/ {
            match($0, /shred_process_result="[^"]*"/); r=substr($0, RSTART+22, RLENGTH-23); v[r]+=$NF }
        /^shred_repair_rx_total[{ ]/ {rx+=$NF}
        END {printf "%.0f %.0f %.0f %.0f %.0f %.0f %.0f\n", v["accepted"], v["completed"], v["rejected"],
             v["parse_failed"], v["equivocated"], v["duplicate"], rx}'
}
# Votor: "votes_ok certs_ok slashable sig_failed banned superseded".
_fb_votor_sums() {
    echo "$1" | awk '
        /^votor_vote_rx_total[{]/ && /vote_rx_result="success"/          {vo+=$NF}
        /^votor_cert_rx_total[{]/ && /cert_rx_result="success"/          {co+=$NF}
        /^votor_vote_rx_total[{]/ && /vote_rx_result="slashable"/        {sl+=$NF}
        /^votor_(vote|cert)_rx_total[{]/ && /_rx_result="signature_failed"/ {sf+=$NF}
        /^votor_(vote|cert)_rx_total[{]/ && /_rx_result="banned"/        {bn+=$NF}
        /^votor_leader_window_superseded_total[{ ]/                       {su+=$NF}
        END {printf "%.0f %.0f %.0f %.0f %.0f %.0f\n", vo, co, sl, sf, bn, su}'
}
FB_PREV_NIC=""; FB_PREV_SHRED=""; FB_PREV_VOTOR=""
_fb_seed_tiles() {
    FB_PREV_NIC=$(_fb_nic_sums "$1")
    FB_PREV_VOTOR=$(_fb_votor_sums "$1")
    FB_PREV_SHRED=$(_fb_shred_sums "$1")
    local key busy bp tot
    while read -r key busy bp tot; do
        [ -n "$key" ] || continue
        FB_PREV_BUSY[$key]=$busy; FB_PREV_BP[$key]=$bp; FB_PREV_TOT[$key]=$tot
    done <<< "$(_fb_tile_totals "$1")"
}
fb_collect_metrics() {
    local m tiles key busy bp tot pb pp pt db dp dt
    m=$(curl -s -m 3 "$FIREBAM_METRICS_URL" 2>/dev/null)
    [ -n "$m" ] || { fb_metrics_ok=0; return; }
    fb_metrics_ok=1
    # First cycle (always, with --once): no previous tile totals, and the
    # since-boot average is dominated by the snapshot load. Seed the previous
    # totals from this read and take the real sample 2 s later.
    if [ "${#FB_PREV_TOT[@]}" -eq 0 ]; then
        _fb_seed_tiles "$m"
        sleep 2
        m=$(curl -s -m 3 "$FIREBAM_METRICS_URL" 2>/dev/null)
        [ -n "$m" ] || { fb_metrics_ok=0; return; }
    fi
    _fbv() { echo "$m" | awk -v n="$1" -v f="${2:-}" 'index($0,n"{")==1 && (f=="" || index($0,f)) {print $NF; exit}'; }
    fb_final_cert=$(_fbv votor_highest_final_cert_slot);   fb_final_cert=${fb_final_cert%%.*}
    fb_wait_vote=$(_fbv votor_wait_to_vote_slot);          fb_wait_vote=${fb_wait_vote%%.*}
    fb_rank=$(_fbv votor_rank)
    fb_vh_writes=$(_fbv votor_vote_history_file_written_total)
    fb_pool_used=$(_fbv votor_pool_slot_used);  fb_pool_free=$(_fbv votor_pool_slot_free)
    fb_caught_up=$(_fbv replay_is_caught_up)
    fb_acc_used=$(_fbv accdb_account_used);     fb_acc_cap=$(_fbv accdb_account_capacity)
    fb_bam_healthy=$(_fbv bam_healthy)
    fb_peers_staked=$(_fbv gossip_crds_peer_count 'stake_class="staked"')
    fb_peers_unstaked=$(_fbv gossip_crds_peer_count 'stake_class="unstaked"')
    for v in fb_final_cert fb_wait_vote fb_vh_writes fb_pool_used fb_pool_free fb_caught_up fb_acc_used fb_acc_cap fb_bam_healthy fb_peers_staked fb_peers_unstaked; do
        [[ "${!v}" =~ ^[0-9]+$ ]] || printf -v "$v" 0
    done
    # votor_rank is 2^64-1 (prints as 1.8e19) when this identity holds no stake.
    if [[ "$fb_rank" =~ ^[0-9]+$ ]] && [ "${#fb_rank}" -lt 10 ]; then fb_role="staked (rank $fb_rank)"; else fb_role="junk (no rank)"; fi
    # Per tile: kind:id busy_ns bp_ns total_ns
    # NIC deltas against the previous read (the first cycle's seed is 2 s back).
    local nic prb ptb prp ptp prd crb ctb crp ctp crd
    nic=$(_fb_nic_sums "$m")
    read -r crb ctb crp ctp crd <<< "$nic"
    if [ -n "$FB_PREV_NIC" ]; then
        read -r prb ptb prp ptp prd <<< "$FB_PREV_NIC"
        fb_nic_rxb=$(( crb - prb )); fb_nic_txb=$(( ctb - ptb ))
        fb_nic_rxp=$(( crp - prp )); fb_nic_txp=$(( ctp - ptp )); fb_nic_rxd=$(( crd - prd ))
    else
        fb_nic_rxb=0; fb_nic_txb=0; fb_nic_rxp=0; fb_nic_txp=0; fb_nic_rxd=0
    fi
    FB_PREV_NIC=$nic
    # Shred deltas against the previous read.
    local sh pa pc pr pp pe pd px ca cc cr cp ce cd cx
    sh=$(_fb_shred_sums "$m")
    read -r ca cc cr cp ce cd cx <<< "$sh"
    if [ -n "$FB_PREV_SHRED" ]; then
        read -r pa pc pr pp pe pd px <<< "$FB_PREV_SHRED"
        fb_sh_acc=$(( ca - pa )); fb_sh_fec=$(( cc - pc )); fb_sh_rej=$(( cr - pr ))
        fb_sh_parse=$(( cp - pp )); fb_sh_equiv=$(( ce - pe )); fb_sh_dup=$(( cd - pd )); fb_sh_repair=$(( cx - px ))
    else
        fb_sh_acc=0; fb_sh_fec=0; fb_sh_rej=0; fb_sh_parse=0; fb_sh_equiv=0; fb_sh_dup=0; fb_sh_repair=0
    fi
    FB_PREV_SHRED=$sh
    # Votor deltas (per cycle) and totals since boot for the safety counters.
    local vt v1 v2 v3 v4 v5 v6 w1 w2 w3 w4 w5 w6
    vt=$(_fb_votor_sums "$m")
    read -r w1 w2 w3 w4 w5 w6 <<< "$vt"
    fb_vt_slashable=$w3; fb_vt_sigfail=$w4; fb_vt_banned=$w5; fb_vt_superseded=$w6
    if [ -n "$FB_PREV_VOTOR" ]; then
        read -r v1 v2 v3 v4 v5 v6 <<< "$FB_PREV_VOTOR"
        fb_vt_votes=$(( w1 - v1 )); fb_vt_certs=$(( w2 - v2 ))
    else
        fb_vt_votes=0; fb_vt_certs=0
    fi
    FB_PREV_VOTOR=$vt
    fb_vt_peers=$(_fbv votor_peer_conn_open); [[ "$fb_vt_peers" =~ ^[0-9]+$ ]] || fb_vt_peers=0
    tiles=$(_fb_tile_totals "$m")
    fb_tile_report=""; fb_busy_max=0; fb_busy_max_tile=""; fb_bp_max=0; fb_bp_max_tile=""; fb_tile_src="since boot"
    local rows=""
    while read -r key busy bp tot; do
        [ -n "$key" ] || continue
        pb=${FB_PREV_BUSY[$key]:-}; pp=${FB_PREV_BP[$key]:-}; pt=${FB_PREV_TOT[$key]:-}
        if [ -n "$pt" ] && [ "$tot" -gt "$pt" ]; then
            db=$(( busy - pb )); dp=$(( bp - pp )); dt=$(( tot - pt )); fb_tile_src="live"
        elif [ -n "$pt" ]; then
            # Counters frozen since the last read: the tile is not running
            # (e.g. the snapshot tiles after boot). Not a CPU consumer.
            FB_PREV_BUSY[$key]=$busy; FB_PREV_BP[$key]=$bp; FB_PREV_TOT[$key]=$tot
            continue
        else
            db=$busy; dp=$bp; dt=$tot
        fi
        FB_PREV_BUSY[$key]=$busy; FB_PREV_BP[$key]=$bp; FB_PREV_TOT[$key]=$tot
        [ "$dt" -gt 0 ] || continue
        rows+="$(awk -v b=$db -v p=$dp -v t=$dt -v k=$key 'BEGIN{printf "%.1f %.1f %s", b*100/t, p*100/t, k}')"$'\n'
    done <<< "$tiles"
    if [ -n "$rows" ]; then
        read -r fb_busy_max _ fb_busy_max_tile <<< "$(echo "$rows" | sort -k1,1 -rn | head -1)"
        read -r _ fb_bp_max fb_bp_max_tile <<< "$(echo "$rows" | sort -k2,2 -rn | head -1)"
        fb_tile_report=$(echo "$rows" | sort -k1,1 -rn | head -5 | awk '{printf "%s%s %s%%", (NR>1?", ":""), $3, $1}')
    fi
}

# Last N lines, oldest first — the same order `tail` gives.
# FireBAM: the helper's translated lines; no helper = plain tail of LOG_FILE.
_log_tail() {
    if [ "$CLIENT" = firebam ] && [ -x "$FIREBAM_LOG_VIEW" ]; then
        "$FIREBAM_LOG_VIEW" --lines "$1" 2>/dev/null
    elif [ "$LOG_SOURCE" = journal ]; then
        journalctl -u "$LOG_UNIT" -n "$1" --no-pager -o cat 2>/dev/null
    else
        tail -n "$1" "$LOG_FILE" 2>/dev/null
    fi
}

# Newest line matching a pattern, scanning backwards. $1=pattern $2=timeout secs.
# The timeout is load-bearing in file mode: `tac` on a multi-GB log with no match
# walks the entire file. journald gets the same guard for the same reason.
# FireBAM has no such history: the helper keeps only the last 6 h, so no backscan.
_log_rscan() {
    if [ "$CLIENT" = firebam ]; then
        return 0
    elif [ "$LOG_SOURCE" = journal ]; then
        timeout "$2" journalctl -u "$LOG_UNIT" -r --no-pager -o cat 2>/dev/null | grep -m1 "$1"
    else
        timeout "$2" tac "$LOG_FILE" 2>/dev/null | grep -m1 "$1"
    fi
}
IDENTITY_PUBKEY="${IDENTITY_PUBKEY:-}"      # auto-detected via getIdentity if empty

# Resolve VOTE_PUBKEY: env > rpc.conf VOTE_ACCOUNT
if [ -z "${VOTE_PUBKEY:-}" ] && [ -f "$HOME/.config/validator/rpc.conf" ]; then
    # shellcheck disable=SC1090,SC1091
    . "$HOME/.config/validator/rpc.conf" 2>/dev/null || true
    VOTE_PUBKEY="${VOTE_PUBKEY:-${VOTE_ACCOUNT:-}}"
fi
if [ -z "${VOTE_PUBKEY:-}" ]; then
    echo "ERROR: VOTE_PUBKEY env var is required (your vote account pubkey)." >&2
    echo "       Or set VOTE_ACCOUNT in ~/.config/validator/rpc.conf." >&2
    exit 1
fi

# Leader-schedule identity: the STAKED identity actually assigned leader slots.
# This host may run as an unstaked hot spare whose local getIdentity has NO leader
# slots, so the schedule must be looked up under the staked identity instead.
# Resolve: env LEADER_IDENTITY > rpc.conf VALIDATOR_IDENTITY > (fallback) local getIdentity.
if [ -z "${LEADER_IDENTITY:-}" ] && [ -f "$HOME/.config/validator/rpc.conf" ]; then
    # shellcheck disable=SC1090,SC1091
    . "$HOME/.config/validator/rpc.conf" 2>/dev/null || true
    LEADER_IDENTITY="${LEADER_IDENTITY:-${VALIDATOR_IDENTITY:-}}"
fi
# Timezone for the wall-clock "time of next leader slot" line (UTC is always shown too).
LEADER_TZ="${LEADER_TZ:-America/Chicago}"

LOG_TAIL_LINES="${LOG_TAIL_LINES:-7500}"
SLEEP_SECS="${SLEEP_SECS:-5}"
SLOW_REFRESH="${SLOW_REFRESH:-30}"          # slower cycle: doublezerod tunnel query, outside view
# FireBAM only: the full vote-account list comes from the external (paid)
# CLUSTER_RPC_URL, so it is refreshed this rarely and reused in between.
VOTE_LIST_REFRESH="${VOTE_LIST_REFRESH:-300}"

# Cached "rare-event" lookups (placeholder; ported helper kept for future use)
FULL_SCAN_INTERVAL=120

# ---- Health thresholds (mainnet-tuned; testnet overrides in detect_network) ----
PROC_LAG_WARN=2          # processed-vs-cluster (uses voted max from getVoteAccounts)
PROC_LAG_CRIT=8
FINAL_LAG_WARN=64        # processed - finalized
FINAL_LAG_CRIT=192
ROOT_STALL_WARN=4        # seconds without a new root
ROOT_STALL_CRIT=12
VOTE_LAG_WARN=16         # cluster_max_last_vote - me.lastVote (slots) — early "going delinquent" signal
VOTE_LAG_CRIT=64         # well below the ~128-slot hard delinquency cliff
MIN_PEERS_STAKED=600     # cluster_nodes_retransmit num_nodes_staked (observed ~768; --private-rpc blocks getClusterNodes)
# Vote reception: cluster_info_vote_listener received_count, averaged over the
# log tail. This is a LEADING indicator of under-packing other validators' votes
# — it drops the moment a host comes back degraded, hours before that host next
# has leader slots to under-pack, and ordinary liveness checks miss it (the node is
# voting fine, so every liveness check stays green).
# Calibration method: read the counter on a known-healthy host and a known-
# degraded one over the SAME minutes on the same cluster, then split the two.
# Measured once at ~1710 (healthy, packing ~676 vote tx) against ~1030
# (degraded, packing ~419 — a 40% deficit); 1300 sits between them with margin.
# These numbers track hardware, stake, and cluster conditions — recalibrate on
# your own nodes rather than adopting this threshold as-is.
VOTE_RX_WARN=1300
CPU_LOAD_WARN_RATIO=70
MEM_AVAIL_WARN_PCT=20
NET_ERR_DELTA_WARN=200
SHRED_LATENCY_WARN=800   # ms
BLOCK_DROP_RATE_WARN=5   # percent
# Block build (leader-slot start→cleared), as a fraction of the LIVE slot
# target rather than a fixed ms pair: the budget IS one slot, and at a 300ms
# slot a 400ms build has already blown it. Resolved per refresh into
# LEADER_BUILD_MS_WARN/_CRIT from slot_ms_target. At the historic 400ms target
# these still resolve to exactly 400 and 600.
LEADER_BUILD_WARN_RATIO=1.0   # a build inside one slot is on budget
LEADER_BUILD_CRIT_RATIO=1.5   # over this we're holding the slot dangerously long
LEADER_GROUPS_TO_SHOW=3  # next-leader groups to render
BUILD_SCAN_TIMEOUT_S="${BUILD_SCAN_TIMEOUT_S:-5}"  # cap the leader-build backscan (see ~line 590)
# The network slot target, which is no longer a constant: Solana is stepping it
# down by feature gate. Used as the "target" shown beside the live measurement
# (the live path measures slot time from getRecentPerformanceSamples, see slot_ms
# below), as the degraded-mode fallback when that sample is unavailable, and as
# the base for the block-build budget above. Resolved from the epoch (next block).
# DERIVED FROM THE EPOCH, not hand-mirrored: this file sat at 0.4 for four
# epochs after the 350ms gate because the hand-update never happened. Every
# refresh already holds `processed` (an absolute slot), and epoch =
# slot / 432000 (slots-per-epoch is NOT changed by a slot-time gate), so this
# costs no extra RPC call.
#
# Boundaries use the EFFECTIVE epoch, not the activation epoch: Solana feature
# gates go pending at E, activate at E+1 and are only effective at E+2. 350ms is
# effective from epoch 1020, 300ms from epoch 1024 (SIMD-0525 step 2), 250ms from 1037,
# 200ms from 1053. Mirrors config/slot_time.py SLOT_TARGET_SCHEDULE in trillium_live.
SLOTS_PER_EPOCH=432000
SLOT_MS_FALLBACK=200         # no absolute slot yet (first refresh): the newest row

slot_target_ms_at() {        # $1 = any absolute slot
    # Testnet's epoch numbers don't follow the mainnet gate schedule: flat 250ms
    # target (config/slot_time.py); it actually runs ~195ms and ETAs use the
    # measured rate anyway. The alpenglow chain runs its own 400ms cluster target.
    [ "$NETWORK" = testnet ] && { echo 250; return; }
    [ "$NETWORK" = alpenglow ] && { echo 400; return; }
    [ -n "${1:-}" ] && [ "$1" -gt 0 ] 2>/dev/null || { echo "$SLOT_MS_FALLBACK"; return; }
    local e=$(( $1 / SLOTS_PER_EPOCH ))
    if   [ "$e" -ge 1053 ]; then echo 200
    elif [ "$e" -ge 1037 ]; then echo 250
    elif [ "$e" -ge 1024 ]; then echo 300
    elif [ "$e" -ge 1020 ]; then echo 350
    else echo 400
    fi
}

# ---- Network detection ----
# Genesis hash from the local RPC (the cluster RPC when the local one will not
# answer). Re-probed every refresh while unknown, because the monitor is often
# started while the validator is still booting with RPC down; until then mainnet
# thresholds apply. Alpenglow is not keyed here on purpose: its genesis hash
# changes on every regenesis, and it runs a separate monitor.
detect_network() {
    local g url
    if [ -z "$NETWORK" ] || [ "$NETWORK" = unknown ]; then
        for url in "$RPC_URL" ${CLUSTER_RPC_URL:+"$CLUSTER_RPC_URL"}; do
            g=$(curl -s --connect-timeout 2 -X POST -H 'Content-Type: application/json' \
                --data '{"jsonrpc":"2.0","id":1,"method":"getGenesisHash"}' "$url" 2>/dev/null \
                | jq -r '.result // empty' 2>/dev/null)
            [ -n "$g" ] && break
        done
        case "$g" in
            5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d) NETWORK=mainnet ;;
            4uhcVJyU9pJkvQyS88uRDiswHXSCkY3zQawwpjk2NsNY) NETWORK=testnet ;;
            *) NETWORK=unknown; return ;;
        esac
    fi
    if [ "$NETWORK" = testnet ] && [ "${_net_applied:-}" != testnet ]; then
        PROC_LAG_WARN=4; PROC_LAG_CRIT=16
        FINAL_LAG_CRIT=256
        ROOT_STALL_WARN=8; ROOT_STALL_CRIT=20
        MIN_PEERS_STAKED=400     # testnet staked nodes: ~769 May 2026, ~485 Sep 2026
        NET_ERR_DELTA_WARN=100
        # VOTE_RX_WARN stays at the mainnet 1300: uncalibrated on testnet (read 1964
        # on testnet-ogden 2026-09-14, so it does not false-fire).
    fi
    if [ "$NETWORK" = alpenglow ] && [ "${_net_applied:-}" != alpenglow ]; then
        # Values carried over from the alpenglow host's former fork.
        PROC_LAG_WARN=4; PROC_LAG_CRIT=32
        FINAL_LAG_CRIT=256
        ROOT_STALL_WARN=8; ROOT_STALL_CRIT=20
        MIN_PEERS_STAKED=10      # small private cluster; the fork checked getClusterNodes >= 20
        NET_ERR_DELTA_WARN=50
    fi
    # Outside-view / FireBAM cluster endpoint from rpc.conf, once the network is known.
    if [ -z "$CLUSTER_RPC_URL" ] && [ -f "$HOME/.config/validator/rpc.conf" ]; then
        case "$NETWORK" in
            mainnet) CLUSTER_RPC_URL=$(. "$HOME/.config/validator/rpc.conf" 2>/dev/null; echo "${MAINNET_RPC_URL:-}") ;;
            testnet) CLUSTER_RPC_URL=$(. "$HOME/.config/validator/rpc.conf" 2>/dev/null; echo "${TESTNET_RPC_URL:-}") ;;
        esac
        _cluster_rpc_label
    fi
    _net_applied=$NETWORK
}

# ---- Delta tracking ----
prev_processed=0
prev_confirmed=0
prev_finalized=0
prev_root=0
prev_vote_lag=0
prev_blocks_on_fork=0
prev_dropped_blocks=0
prev_new_root_max=0
ext_ok=0; ext_processed=0; ext_finalized=0; ext_ts=0
ext_me_state="unknown"       # active | delinquent | missing | unknown
ext_me_last_vote=0; ext_vote_ts=0; ext_lag=0; ext_final_lag=0; ext_rel=""
last_ext_refresh=-999        # outside view: first cycle fetches, then every SLOW_REFRESH
cached_vote_batch="[]"; last_vote_list_refresh=-999   # FireBAM: external full vote list cache
prev_replay_slot=0
prev_log_warn_count=0
prev_log_error_count=0
prev_cost_block=0
prev_cost_txns=0
prev_cost_fee=0
prev_cost_priority=0
prev_shred_avg=0
prev_ts=0
last_root_change_ts=0

# Slot-time measurement (live fallback when perf samples are empty): anchor a
# (processed, ts) point and measure over a ~20s span so the ms/slot reading is
# stable instead of jittering with each short cycle.
SLOT_TIME_WINDOW=20
slot_anchor_processed=0
slot_anchor_ts=0
slot_anchor_txcount=0
cached_slot_ms="?"
cached_slot_ms_src="warming"
# getRecentPerformanceSamples is gated on this private RPC (-32601), so TPS and
# slots/s are derived from processed/transactionCount deltas over the same span.
cached_tps="?"
cached_sps="?"
cached_tps_src="warming"

# Slow-refresh cache (DoubleZero only)
cached_dz_status=""
cached_dz_tunnels=""
last_slow_refresh=0
[ "$RUN_ONCE" = true ] && last_slow_refresh=-999

# Last block-build line found beyond the recent tail (full-log fallback, rate-limited).
# Leader rotations are sparse (~once/epoch) so the build often falls outside the
# 7500-line tail; we scan back through the whole log to recover the real last build.
cached_build_line=""
last_build_scan=0

# Leader-schedule cache (refetched on epoch boundary)
cached_ls_epoch=""
cached_ls_slots=""           # space-separated absolute slots (future-only, sorted asc)
cached_ls_total=0            # total leader slots in this epoch for our identity
slot_duration_est=""         # refined each cycle from proc_delta

# ---- Helpers ----
fmt() {
    local n=${1%%.*}
    n=${n:-0}
    [[ "$n" =~ ^-?[0-9]+$ ]] || { echo "$1"; return; }
    echo "$n" | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta'
}

human_bytes() {
    local b=${1%%.*}; b=${b:-0}
    awk -v b="$b" 'BEGIN{
        if (b>=1073741824) printf "%.1fG", b/1073741824;
        else if (b>=1048576) printf "%.1fM", b/1048576;
        else if (b>=1024)    printf "%.0fK", b/1024;
        else                 printf "%dB", b;
    }'
}

human_uptime() {
    local secs=$1
    [ -z "$secs" ] || [ "$secs" -le 0 ] && { echo "?"; return; }
    local d=$((secs / 86400))
    local h=$(((secs % 86400) / 3600))
    local m=$(((secs % 3600) / 60))
    echo "${d}d ${h}h ${m}m"
}

resolve_identity() {
    local resp
    resp=$(curl -s --connect-timeout 3 -X POST -H 'Content-Type: application/json' \
        --data '{"jsonrpc":"2.0","id":1,"method":"getIdentity"}' "$RPC_URL")
    echo "$resp" | jq -r '.result.identity // empty' 2>/dev/null
}

get_service_start_epoch() {
    local s
    s=$(systemctl show "$SERVICE_NAME" -p ActiveEnterTimestampMonotonic --value 2>/dev/null)
    if [ -n "$s" ] && [ "$s" != "0" ]; then
        local boot_epoch now_mono
        boot_epoch=$(awk '{print systime() - int($1)}' /proc/uptime 2>/dev/null)
        now_mono=$(awk '{print int($1 * 1000000)}' /proc/uptime 2>/dev/null)
        if [ -n "$boot_epoch" ] && [ -n "$now_mono" ]; then
            echo $((boot_epoch + s / 1000000))
            return
        fi
    fi
    s=$(systemctl show "$SERVICE_NAME" -p ActiveEnterTimestamp --value 2>/dev/null)
    [ -n "$s" ] && date -d "$s" +%s 2>/dev/null
}

delta_icon() {
    local d=$1
    if [ "$d" -gt 0 ]; then echo "✅"
    elif [ "$d" -lt 0 ]; then echo "🔴"
    else echo "⏸️ "; fi
}

# Trend arrow (string compare friendly)
arrow() {
    local cur=${1:-0} prev=${2:-0}
    [ "$prev" = "0" ] && [ "$cur" = "0" ] && { echo ""; return; }
    [ "$prev" = "0" ] && { echo ""; return; }
    if   [ "$cur" -gt "$prev" ]; then echo "↑"
    elif [ "$cur" -lt "$prev" ]; then echo "↓"
    else echo "→"; fi
}

# Row for a field the running stack has no source for (FireBAM). Shows n/a, never 0.
# $1 = label, $2 = "last" for the closing └─ row of a section.
na_row() {
    local g="├"; [ "${2:-}" = last ] && g="└"
    printf "│   %s─ %-18s%s\n" "$g" "$1:" "n/a"
}

# ---- Collapsible sections (interactive in live mode) ----
# Each section has a stable id and a single-key hotkey. State lives in
# SECTION_COLLAPSED; a non-blocking key read in the main loop flips entries.
declare -A SECTION_COLLAPSED
SECTION_IDS=(slot consensus leader latest vote perf shred bam fd net dz svc sys)
# Seed initial collapsed set from COLLAPSED env (space/comma separated ids),
# e.g. COLLAPSED="perf shred bam net" ~/validator-monitor.sh
# Default (COLLAPSED unset): collapse everything except the Vote Account section.
if [ -n "${COLLAPSED+x}" ]; then
    for _cid in ${COLLAPSED//,/ }; do SECTION_COLLAPSED[$_cid]=1; done
else
    for _cid in "${SECTION_IDS[@]}"; do
        [ "$_cid" = "vote" ] || SECTION_COLLAPSED[$_cid]=1
    done
fi

is_collapsed() { [ "${SECTION_COLLAPSED[$1]:-0}" = "1" ]; }

# Header tag like "[1▼] " (expanded) or "[1▶] " (collapsed); empty in --once mode.
sec_tag() {
    [ "$RUN_ONCE" = true ] && return
    local mark
    if is_collapsed "$1"; then mark='▶'; else mark='▼'; fi
    printf '[%s%s] ' "$2" "$mark"
}

toggle_section() {
    if [ "${SECTION_COLLAPSED[$1]:-0}" = "1" ]; then
        SECTION_COLLAPSED[$1]=0
    else
        SECTION_COLLAPSED[$1]=1
    fi
}

set_all_collapsed() {
    local id
    for id in "${SECTION_IDS[@]}"; do SECTION_COLLAPSED[$id]=$1; done
}

handle_key() {
    case "$1" in
        1) toggle_section slot ;;
        2) toggle_section consensus ;;
        3) toggle_section leader ;;
        4) toggle_section latest ;;
        5) toggle_section vote ;;
        6) toggle_section perf ;;
        7) toggle_section shred ;;
        8) toggle_section bam ;;
        9) toggle_section net ;;
        0) toggle_section dz ;;
        s|S) toggle_section svc ;;
        y|Y) toggle_section sys ;;
        f|F) toggle_section fd ;;
        a|A) set_all_collapsed 0 ;;
        z|Z) set_all_collapsed 1 ;;
        q|Q) echo -e "\n\nMonitoring stopped."; exit 0 ;;
    esac
}

service_start_epoch=""
_start_epoch_unit=""

# Static host info (OS + kernel) — read once, doesn't change during the run
os_pretty=$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-${NAME:-Linux} ${VERSION:-}}")
os_pretty=${os_pretty:-unknown}
kernel_version=$(uname -r 2>/dev/null)
kernel_version=${kernel_version:-unknown}

if [ "$RUN_ONCE" != true ]; then
    clear
    echo "Validator Monitor — Press Ctrl+C to stop"
    echo "============================================================"
    echo ""
fi

while true; do
    now_epoch=$(date +%s)

    # ---- Stack + network, every refresh (a host can swap Agave<->FireBAM, and
    # the monitor is often started while RPC is still down) ----
    detect_client
    # Bridge for the FireBAM metrics blocks ported from new-amsterdam's copy.
    [ "$CLIENT" = firebam ] && CLIENT_LABEL=FireBAM || CLIENT_LABEL=Agave
    detect_network
    if [ "$SERVICE_NAME" != "$_start_epoch_unit" ]; then
        _start_epoch_unit=$SERVICE_NAME
        service_start_epoch=$(get_service_start_epoch)
    fi

    # ---- Resolve identity every refresh (set-identity hot-swaps change it
    # live during HA failover/failback; keep last known value on an RPC blip) ----
    id_now=$(resolve_identity)
    [ -n "$id_now" ] && IDENTITY_PUBKEY="$id_now"

    # ---- Batched RPC ----
    ALPENGLOW_EXTRA_RPC=()
    [ "$HOST_PROFILE" = alpenglow ] && ALPENGLOW_EXTRA_RPC=(
        '{"jsonrpc":"2.0","id":8,"method":"getMaxRetransmitSlot"}'
        '{"jsonrpc":"2.0","id":9,"method":"getMaxShredInsertSlot"}')
    # getClusterNodes / getMaxRetransmitSlot / getMaxShredInsertSlot are gated by
    # --private-rpc on this host (return -32601 method-not-found), so they're omitted.
    # Local calls: slots, epoch, version, health (from RPC_URL).
    batch=$(rpc_batch "$RPC_URL" \
        '{"jsonrpc":"2.0","id":1,"method":"getSlot","params":[{"commitment":"processed"}]}' \
        '{"jsonrpc":"2.0","id":2,"method":"getSlot","params":[{"commitment":"confirmed"}]}' \
        '{"jsonrpc":"2.0","id":3,"method":"getSlot","params":[{"commitment":"finalized"}]}' \
        '{"jsonrpc":"2.0","id":4,"method":"getEpochInfo"}' \
        '{"jsonrpc":"2.0","id":5,"method":"getVersion"}' \
        '{"jsonrpc":"2.0","id":6,"method":"getHealth"}' \
        "${ALPENGLOW_EXTRA_RPC[@]}")
    # Cluster calls: vote accounts and performance samples.
    if [ "$CLIENT" = firebam ]; then
        # FireBAM's RPC answers both with HTTP 501. The only other source is the
        # external (paid) CLUSTER_RPC_URL, so the FULL vote-account list is
        # fetched at most every VOTE_LIST_REFRESH seconds and reused in between
        # (user rule 2026-10-26: never the full list every cycle). Performance
        # samples are not fetched externally at all: TPS/slot time fall back to
        # the local getEpochInfo counters.
        if [ -n "$CLUSTER_RPC_URL" ] && [ $((now_epoch - last_vote_list_refresh)) -ge "$VOTE_LIST_REFRESH" ]; then
            _vl=$(rpc_batch "$CLUSTER_RPC_URL" '{"jsonrpc":"2.0","id":10,"method":"getVoteAccounts"}')
            if [ -n "$_vl" ]; then cached_vote_batch=$_vl; last_vote_list_refresh=$now_epoch; fi
        fi
        cluster_batch=$cached_vote_batch
    else
        cluster_batch=$(rpc_batch "$RPC_URL" \
            '{"jsonrpc":"2.0","id":10,"method":"getVoteAccounts"}' \
            '{"jsonrpc":"2.0","id":11,"method":"getRecentPerformanceSamples","params":[3]}')
    fi
    if [ -n "$batch" ]; then
        batch=$(printf '%s\n%s' "$batch" "${cluster_batch:-[]}" | jq -cs '.[0] + .[1]' 2>/dev/null)
    fi

    if [ -z "$batch" ]; then
        echo "$(date '+%H:%M:%S') Cannot reach RPC at $RPC_URL"
        [ "$RUN_ONCE" = true ] && exit 1
        sleep "$SLEEP_SECS"
        continue
    fi

    # ---- Outside view (independent endpoint) ----
    # Our own "cluster tip" is derived from the votes our node has seen; if it is
    # partitioned or lagging, that number lags with it. An external endpoint is
    # the only way to see the real tip and the cluster's opinion of our vote account.
    # Throttled to SLOW_REFRESH (external endpoints are paid): the tip and our
    # vote state refresh every 30 s by default, not every cycle.
    if _outside_on \
       && [ $((now_epoch - last_ext_refresh)) -ge "$SLOW_REFRESH" ]; then
        last_ext_refresh=$now_epoch
        ext_batch=$(rpc_batch "$CLUSTER_RPC_URL" \
            '{"jsonrpc":"2.0","id":1,"method":"getSlot","params":[{"commitment":"processed"}]}' \
            '{"jsonrpc":"2.0","id":2,"method":"getSlot","params":[{"commitment":"finalized"}]}')
        ext_p=$(echo "$ext_batch" | jq -r '[.[] | select(.id==1) | .result // empty] | .[0] // empty' 2>/dev/null)
        ext_f=$(echo "$ext_batch" | jq -r '[.[] | select(.id==2) | .result // empty] | .[0] // empty' 2>/dev/null)
        if [[ "$ext_p" =~ ^[0-9]+$ ]]; then
            ext_ok=1; ext_processed=$ext_p; ext_ts=$now_epoch
            [[ "$ext_f" =~ ^[0-9]+$ ]] && ext_finalized=$ext_f
        else
            ext_ok=0
        fi
        # The votePubkey filter keeps the response to one entry, not the whole set.
        if true; then
            ext_va=$(curl -s --connect-timeout 4 --max-time 12 -X POST -H 'Content-Type: application/json' \
                --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getVoteAccounts\",\"params\":[{\"votePubkey\":\"$VOTE_PUBKEY\"}]}" \
                "$CLUSTER_RPC_URL" 2>/dev/null)
            if echo "$ext_va" | jq -e '.result' >/dev/null 2>&1; then
                ext_me_state=$(echo "$ext_va" | jq -r '
                    if ((.result.delinquent // []) | length) > 0 then "delinquent"
                    elif ((.result.current // []) | length) > 0 then "active"
                    else "missing" end')
                ext_me_last_vote=$(echo "$ext_va" | jq -r '
                    [ (.result.current // [])[], (.result.delinquent // [])[] ]
                    | .[0].lastVote // 0')
                ext_vote_ts=$now_epoch
            elif [ "$ext_vote_ts" = 0 ]; then
                ext_me_state="unknown"
            fi
        fi
    fi

    # ---- Parse RPC ----
    rpc_json=$(echo "$batch" | jq -c '
        . as $a |
        {
          processed:   ([$a[] | select(.id==1)][0].result // 0),
          confirmed:   ([$a[] | select(.id==2)][0].result // 0),
          finalized:   ([$a[] | select(.id==3)][0].result // 0),
          epoch_info:  ([$a[] | select(.id==4)][0].result // {}),
          version:     ([$a[] | select(.id==5)][0].result // {}),
          health:      ([$a[] | select(.id==6)][0] | (.result // .error.message // "unknown")),
          vote:        ([$a[] | select(.id==10)][0].result // {}),
          perf:        ([$a[] | select(.id==11)][0].result // []),
          max_retx:    ([$a[] | select(.id==8)][0].result // 0),
          max_shred:   ([$a[] | select(.id==9)][0].result // 0)
        }
    ' 2>/dev/null)

    processed=$(echo "$rpc_json" | jq -r '.processed')
    confirmed=$(echo "$rpc_json" | jq -r '.confirmed')
    finalized=$(echo "$rpc_json" | jq -r '.finalized')
    epoch=$(echo "$rpc_json" | jq -r '.epoch_info.epoch // 0')
    slot_index=$(echo "$rpc_json" | jq -r '.epoch_info.slotIndex // 0')
    slots_in_epoch=$(echo "$rpc_json" | jq -r '.epoch_info.slotsInEpoch // 0')
    block_height=$(echo "$rpc_json" | jq -r '.epoch_info.blockHeight // 0')
    epoch_tx_count=$(echo "$rpc_json" | jq -r '.epoch_info.transactionCount // 0')
    sol_version=$(echo "$rpc_json" | jq -r '.version["solana-core"] // "?"')
    feature_set=$(echo "$rpc_json" | jq -r '.version["feature-set"] // 0')
    health=$(echo "$rpc_json" | jq -r '.health')
    max_retx=$(echo "$rpc_json" | jq -r '.max_retx // 0');   [[ "$max_retx" =~ ^[0-9]+$ ]] || max_retx=0
    max_shred=$(echo "$rpc_json" | jq -r '.max_shred // 0'); [[ "$max_shred" =~ ^[0-9]+$ ]] || max_shred=0

    # Vote-account self-view + cluster aggregates.
    me_view=$(echo "$rpc_json" | jq -c --arg vp "$VOTE_PUBKEY" '
        .vote as $v |
        ([ ($v.current // [])[]    | select(.votePubkey==$vp) ] | .[0]) as $me_cur |
        ([ ($v.delinquent // [])[] | select(.votePubkey==$vp) ] | .[0]) as $me_del |
        {
          delinquent_count: ($v.delinquent // [] | length),
          current_count:    ($v.current    // [] | length),
          total_stake:      ([($v.current // [])[].activatedStake] | add // 0),
          delinquent_stake: ([($v.delinquent // [])[].activatedStake] | add // 0),
          cluster_max_last_vote: ([($v.current // [])[].lastVote] | max // 0),
          # How many current validators trail the max by at least as much as we
          # do. lastVote advances in steps (under Votor ~1/3 of the cluster sits
          # 1-8 behind at any instant), so a lag is only news when few share it.
          peers_as_far_behind: (([($v.current // [])[].lastVote] | max // 0) as $mx |
            if $me_cur then ($mx - $me_cur.lastVote) as $lag |
              [($v.current // [])[] | select(($mx - .lastVote) >= $lag)] | length
            else 0 end),
          me: ($me_cur // $me_del // null),
          me_delinquent: ($me_del != null)
        }
    ')

    me_present=$(echo "$me_view" | jq -r '.me // empty')
    if [ -n "$me_present" ]; then
        me_last_vote=$(echo "$me_view" | jq -r '.me.lastVote // 0')
        me_root_slot=$(echo "$me_view" | jq -r '.me.rootSlot // 0')
        me_stake=$(echo "$me_view" | jq -r '.me.activatedStake // 0')
        me_commission=$(echo "$me_view" | jq -r '.me.commission // 0')
        # epochCredits entries are [epoch, cumulative, cumulative-at-epoch-start];
        # the per-epoch figure is the difference, not either field.
        me_credits=$(echo "$me_view" | jq -r '(.me.epochCredits[-1] // [0,0,0]) | .[1] - .[2]')
        me_prev_credits=$(echo "$me_view" | jq -r '(.me.epochCredits[-2] // [0,0,0]) | .[1] - .[2]')
    else
        me_last_vote=0; me_root_slot=0; me_stake=0; me_commission=0
        me_credits=0; me_prev_credits=0
    fi
    me_delinquent=$(echo "$me_view" | jq -r '.me_delinquent')
    current_count=$(echo "$me_view" | jq -r '.current_count')
    delinquent_count=$(echo "$me_view" | jq -r '.delinquent_count')
    total_stake=$(echo "$me_view" | jq -r '.total_stake')
    delinquent_stake=$(echo "$me_view" | jq -r '.delinquent_stake')
    # Non-numeric (empty/null when the vote-account call failed) reads as 0, so
    # the "!= 0" guards below hold and awk never divides by an empty value.
    [[ "$total_stake" =~ ^[0-9]+$ ]] || total_stake=0
    [[ "$delinquent_stake" =~ ^[0-9]+$ ]] || delinquent_stake=0
    cluster_max_last_vote=$(echo "$me_view" | jq -r '.cluster_max_last_vote')
    peers_as_far_behind=$(echo "$me_view" | jq -r '.peers_as_far_behind')

    # Vote lag — how far behind the cluster our staked vote account is voting.
    # Rising vote_lag with positive delta = "going delinquent" before the ~128-slot cliff.
    if [ "$me_last_vote" -gt 0 ] && [ "$cluster_max_last_vote" -gt 0 ]; then
        vote_lag=$(( cluster_max_last_vote - me_last_vote ))
        [ "$vote_lag" -lt 0 ] && vote_lag=0
    else
        vote_lag=0
    fi
    vote_lag_delta=$(( vote_lag - prev_vote_lag ))
    [ "$prev_vote_lag" = 0 ] && vote_lag_delta=0

    # Stake share — awk because lamport totals overflow int64 once multiplied.
    if [ "$total_stake" != "0" ]; then
        stake_share_pct=$(awk -v m=$me_stake -v t=$total_stake 'BEGIN{printf "%.4f", m*100/t}')
    else
        stake_share_pct="0.0000"
    fi

    # Performance samples (avg over up to 3 most recent 60s windows).
    perf_summary=$(echo "$rpc_json" | jq -r '
        .perf as $p |
        if ($p|length)==0 then "0|0|0|0"
        else
          ([ $p[] | .numTransactions ] | add) as $tx |
          ([ $p[] | .numSlots ] | add) as $slots |
          ([ $p[] | .samplePeriodSecs ] | add) as $secs |
          ([ $p[] | .numNonVoteTransactions // 0 ] | add) as $nvtx |
          "\($tx)|\($slots)|\($secs)|\($nvtx)"
        end
    ')
    IFS='|' read -r perf_tx perf_slots perf_secs perf_nvtx <<< "$perf_summary"
    perf_tx=${perf_tx:-0}; perf_slots=${perf_slots:-0}; perf_secs=${perf_secs:-0}; perf_nvtx=${perf_nvtx:-0}
    # Prefer getRecentPerformanceSamples (60s windows). It's gated on this
    # private RPC (-32601 -> empty), so when it's empty we derive TPS, slots/s,
    # and slot-time from processed/transactionCount advance over a ~20s anchored
    # span so readings are stable rather than per-cycle jittery. Non-vote TPS is
    # not exposed by getEpochInfo, so it stays "n/a" in the fallback path.
    if [ "$perf_secs" -gt 0 ]; then
        tps=$(awk -v t=$perf_tx -v s=$perf_secs 'BEGIN{printf "%.0f", t/s}')
        nvtps=$(awk -v t=$perf_nvtx -v s=$perf_secs 'BEGIN{printf "%.1f", t/s}')
        sps=$(awk -v sl=$perf_slots -v s=$perf_secs 'BEGIN{printf "%.2f", sl/s}')
        slot_ms=$(awk -v s=$perf_secs -v sl=$perf_slots 'BEGIN{printf "%.0f", s*1000/sl}')
        slot_ms_src="3min"; tps_src="3min"
    else
        if [ "$slot_anchor_ts" = 0 ]; then
            slot_anchor_ts=$now_epoch; slot_anchor_processed=$processed; slot_anchor_txcount=$epoch_tx_count
        fi
        slot_span=$(( now_epoch - slot_anchor_ts ))
        if [ "$slot_span" -ge "$SLOT_TIME_WINDOW" ] && [ "$processed" -gt "$slot_anchor_processed" ]; then
            slot_delta=$(( processed - slot_anchor_processed ))
            cached_slot_ms=$(awk -v e=$slot_span -v d=$slot_delta 'BEGIN{printf "%.0f", e*1000/d}')
            cached_slot_ms_src="${slot_span}s"
            cached_sps=$(awk -v d=$slot_delta -v e=$slot_span 'BEGIN{printf "%.2f", d/e}')
            if [ "$epoch_tx_count" -gt "$slot_anchor_txcount" ]; then
                cached_tps=$(awk -v d=$((epoch_tx_count - slot_anchor_txcount)) -v e=$slot_span 'BEGIN{printf "%.0f", d/e}')
                cached_tps_src="${slot_span}s"
            fi
            slot_anchor_ts=$now_epoch; slot_anchor_processed=$processed; slot_anchor_txcount=$epoch_tx_count
        fi
        slot_ms=$cached_slot_ms; slot_ms_src=$cached_slot_ms_src
        tps=$cached_tps; sps=$cached_sps; nvtps="n/a"; tps_src=$cached_tps_src
    fi
    slot_ms_target=$(slot_target_ms_at "$processed")
    LEADER_BUILD_MS_WARN=$(awk -v t="$slot_ms_target" -v r="$LEADER_BUILD_WARN_RATIO" 'BEGIN{printf "%.0f", t*r}')
    LEADER_BUILD_MS_CRIT=$(awk -v t="$slot_ms_target" -v r="$LEADER_BUILD_CRIT_RATIO" 'BEGIN{printf "%.0f", t*r}')

    # ---- Log tail: grab the most recent N lines once ----
    # Agave: the validator log (file or journald). FireBAM: firebam-log-view.py.
    log_tail=$(_log_tail "$LOG_TAIL_LINES")

    # Latest new root from stock-agave replay_stage:
    #   solana_core::replay_stage] new fork:N parent:N root:SLOT
    new_root_line=$(echo "$log_tail" | grep 'solana_core::replay_stage] new fork:' | tail -1)
    new_root_max=$(echo "$new_root_line" | sed -n 's/.* root:\([0-9]*\).*/\1/p')
    new_root_max=${new_root_max:-0}
    new_root_count=$(echo "$log_tail" | grep -c 'solana_core::replay_stage] new fork:')

    # Tower-vote / tower-observed
    tower_line=$(echo "$log_tail" | grep 'datapoint: tower-vote ' | tail -1)
    tower_latest=$(echo "$tower_line" | sed -n 's/.*latest=\([0-9]*\)i.*/\1/p')
    tower_root=$(echo "$tower_line"   | sed -n 's/.*root=\([0-9]*\)i.*/\1/p')
    tower_latest=${tower_latest:-0}; tower_root=${tower_root:-0}

    tobs_line=$(echo "$log_tail" | grep 'datapoint: tower-observed ' | tail -1)
    tobs_slot=$(echo "$tobs_line" | sed -n 's/.* slot=\([0-9]*\)i.*/\1/p')
    tobs_root=$(echo "$tobs_line" | sed -n 's/.* root=\([0-9]*\)i.*/\1/p')
    tobs_slot=${tobs_slot:-0}; tobs_root=${tobs_root:-0}

    # Alpenglow Votor (testnet since epoch 1043). Tower datapoints stop under
    # Votor, so these replace the tower rows; all zero on a TowerBFT cluster.
    # Ported from the alpenglow fork. Agave log lines only; FireBAM has no source.
    ag_finalized_count=$(echo "$log_tail" | grep -cE ': Finalized .* fast: ')
    votor_active=false; [ "$ag_finalized_count" -gt 0 ] && votor_active=true
    ag_finalized_fast=$(echo  "$log_tail" | grep -cE ': Finalized .* fast: true')
    ag_notar_count=$(echo "$log_tail"     | grep -c ': Block Notarized ')
    ag_notar_fb_count=$(echo "$log_tail"  | grep -c ': Block notar-fallback ')
    ag_skip_vote_count=$(echo "$log_tail" | grep -c ': Voting skip ')
    ag_timeout_crash_count=$(echo "$log_tail" | grep -c ': TimeoutCrashedLeader ')
    ag_standstill_count=$(echo "$log_tail" | grep -c ': Standstill ')
    cp_line=$(echo "$log_tail" | grep 'datapoint: consensus_pool ' | tail -1)
    cp_conflict=$(echo "$cp_line"       | sed -n 's/.* conflicting_votes=\([0-9]*\)i.*/\1/p')
    cp_incoming_votes=$(echo "$cp_line" | sed -n 's/.* incoming_votes=\([0-9]*\)i.*/\1/p')
    cp_incoming_certs=$(echo "$cp_line" | sed -n 's/.* incoming_certs=\([0-9]*\)i.*/\1/p')
    cp_conflict=${cp_conflict:-0}; cp_incoming_votes=${cp_incoming_votes:-0}; cp_incoming_certs=${cp_incoming_certs:-0}
    cps_line=$(echo "$log_tail" | grep 'datapoint: consensus_pool_service ' | tail -1)
    cps_certs_sent=$(echo "$cps_line"    | sed -n 's/.* certificates_sent=\([0-9]*\)i.*/\1/p')
    cps_certs_dropped=$(echo "$cps_line" | sed -n 's/.* certificates_dropped=\([0-9]*\)i.*/\1/p')
    # Logged as true/false, not 0/1 -- the alpenglow fork's numeric parse never matches.
    cps_standstill=$(echo "$cps_line" | sed -n 's/.* in_standstill_bool=\(true\|false\).*/\1/p')
    cps_certs_sent=${cps_certs_sent:-0}; cps_certs_dropped=${cps_certs_dropped:-0}; cps_standstill=${cps_standstill:-false}

    # Vote reception (cluster_info_vote_listener). Averaged across the tail,
    # never `tail -1` like its neighbours: consecutive samples swing hard
    # (1111, 984, 424 observed back-to-back), so one line is pure noise.
    vote_rx=$(echo "$log_tail" | grep -oE 'cluster_info_vote_listener received_count=[0-9]+' \
        | awk -F= '{s+=$2;n++} END{printf "%d", (n?s/n:0)}')
    vote_rx=${vote_rx:-0}
    if [ "$vote_rx" -eq 0 ]; then
        vote_rx_icon="❔ no samples in tail"
    elif [ "$vote_rx" -lt "$VOTE_RX_WARN" ]; then
        vote_rx_icon="⚠️  LOW — expect vote under-packing as leader (ops/ha/PLAYBOOK.md)"
    else
        vote_rx_icon="✅"
    fi

    # Bank frozen / optimistic
    frozen_slot=$(echo "$log_tail" | grep 'datapoint: bank_frozen ' | tail -1 \
        | sed -n 's/.*slot=\([0-9]*\)i.*/\1/p')
    optimistic_slot=$(echo "$log_tail" | grep 'datapoint: optimistic_slot ' | tail -1 \
        | sed -n 's/.*slot=\([0-9]*\)i.*/\1/p')
    frozen_slot=${frozen_slot:-0}; optimistic_slot=${optimistic_slot:-0}

    # block-commitment-cache
    bcc_line=$(echo "$log_tail" | grep 'datapoint: block-commitment-cache ' | tail -1)
    hsmr=$(echo "$bcc_line" | sed -n 's/.*highest-super-majority-root=\([0-9]*\)i.*/\1/p')
    hcs=$(echo "$bcc_line"  | sed -n 's/.*highest-confirmed-slot=\([0-9]*\)i.*/\1/p')
    agg_ms=$(echo "$bcc_line" | sed -n 's/.*aggregate-commitment-ms=\([0-9]*\)i.*/\1/p')
    hsmr=${hsmr:-0}; hcs=${hcs:-0}; agg_ms=${agg_ms:-0}

    # blocks_produced
    bp_line=$(echo "$log_tail" | grep 'datapoint: blocks_produced ' | tail -1)
    blocks_on_fork=$(echo "$bp_line" | sed -n 's/.*num_blocks_on_fork=\([0-9]*\)i.*/\1/p')
    dropped_blocks=$(echo "$bp_line" | sed -n 's/.*num_dropped_blocks_on_fork=\([0-9]*\)i.*/\1/p')
    blocks_on_fork=${blocks_on_fork:-0}; dropped_blocks=${dropped_blocks:-0}
    total_blocks=$((blocks_on_fork + dropped_blocks))
    if [ "$total_blocks" -gt 0 ]; then
        drop_rate=$(awk -v d=$dropped_blocks -v t=$total_blocks 'BEGIN{printf "%.1f", d*100/t}')
    else
        drop_rate="0.0"
    fi

    # replay-slot-stats
    rss_line=$(echo "$log_tail" | grep 'datapoint: replay-slot-stats ' | tail -1)
    replay_slot=$(echo "$rss_line" | sed -n 's/.*slot=\([0-9]*\)i.*/\1/p')
    replay_tx=$(echo "$rss_line"   | sed -n 's/.*total_transactions=\([0-9]*\)i.*/\1/p')
    replay_us=$(echo "$rss_line"   | sed -n 's/.*replay_total_elapsed=\([0-9]*\)i.*/\1/p')
    replay_slot=${replay_slot:-0}; replay_tx=${replay_tx:-0}; replay_us=${replay_us:-0}

    # CPU / memory / network datapoints
    cpu_line=$(echo "$log_tail" | grep 'datapoint: cpu-stats ' | tail -1)
    cpu_num=$(echo "$cpu_line" | sed -n 's/.*cpu_num=\([0-9]*\)i.*/\1/p')
    load1=$(echo  "$cpu_line" | sed -n 's/.*average_load_one_minute=\([0-9.]*\) .*/\1/p')
    load5=$(echo  "$cpu_line" | sed -n 's/.*average_load_five_minutes=\([0-9.]*\) .*/\1/p')
    load15=$(echo "$cpu_line" | sed -n 's/.*average_load_fifteen_minutes=\([0-9.]*\) .*/\1/p')
    threads=$(echo "$cpu_line" | sed -n 's/.*total_num_threads=\([0-9]*\)i.*/\1/p')
    cpu_num=${cpu_num:-0}; load1=${load1:-0}; load5=${load5:-0}; load15=${load15:-0}; threads=${threads:-0}

    mem_line=$(echo "$log_tail" | grep 'datapoint: memory-stats ' | tail -1)
    mem_free_pct=$(echo "$mem_line" | sed -n 's/.* free_percent=\([0-9.]*\) .*/\1/p')
    mem_avail_pct=$(echo "$mem_line"| sed -n 's/.* avail_percent=\([0-9.]*\) .*/\1/p')
    mem_used=$(echo "$mem_line"     | sed -n 's/.* used_bytes=\([0-9]*\)i.*/\1/p')
    # Anchor on " total=" (leading space) to avoid matching swap_total=
    mem_total=$(echo "$mem_line"    | sed -n 's/.* total=\([0-9]*\)i.*/\1/p')
    mem_free_pct=${mem_free_pct:-0}; mem_avail_pct=${mem_avail_pct:-0}
    mem_used=${mem_used:-0}; mem_total=${mem_total:-0}

    # ---- FireBAM: :7999 metrics + /proc (no cpu-stats/memory-stats datapoints) ----
    fb_metrics_ok=0
    if [ "$CLIENT_LABEL" = FireBAM ]; then
        fb_collect_metrics
        # System CPU/memory from /proc. The load average is NOT a health signal
        # on FireBAM (busy-polling tiles keep it near the tile count), so
        # cpu_icon below follows the busiest tile instead.
        cpu_num=$(nproc 2>/dev/null || echo 0)
        read -r load1 load5 load15 _ _ < /proc/loadavg
        threads=$(ps -eLo lwp= 2>/dev/null | wc -l)
        mem_total=$(awk '/^MemTotal:/{print $2*1024}' /proc/meminfo)
        mem_avail_b=$(awk '/^MemAvailable:/{print $2*1024}' /proc/meminfo)
        mem_free_b=$(awk '/^MemFree:/{print $2*1024}' /proc/meminfo)
        mem_used=$(( mem_total - mem_avail_b ))
        mem_free_pct=$(awk -v f=$mem_free_b -v t=$mem_total 'BEGIN{printf "%.2f", (t?f*100/t:0)}')
        mem_avail_pct=$(awk -v a=$mem_avail_b -v t=$mem_total 'BEGIN{printf "%.2f", (t?a*100/t:0)}')
        fb_huge2_total=$(cat /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages 2>/dev/null || echo 0)
        fb_huge2_used=$(( fb_huge2_total - $(cat /sys/kernel/mm/hugepages/hugepages-2048kB/free_hugepages 2>/dev/null || echo 0) ))
        fb_giant_used=$(( $(cat /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages 2>/dev/null || echo 0) - $(cat /sys/kernel/mm/hugepages/hugepages-1048576kB/free_hugepages 2>/dev/null || echo 0) ))
        fb_giant_total=$(cat /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages 2>/dev/null || echo 0)
    fi

    net_line=$(echo "$log_tail" | grep 'datapoint: net-stats-validator ' | tail -1)
    # Anchor each delta with leading space so e.g. " in_errors_delta=" does not match "in_csum_errors_delta="
    rx_bytes_delta=$(echo "$net_line" | sed -n 's/.* rx_bytes_delta=\([0-9]*\)i.*/\1/p')
    tx_bytes_delta=$(echo "$net_line" | sed -n 's/.* tx_bytes_delta=\([0-9]*\)i.*/\1/p')
    in_err_delta=$(echo "$net_line"   | sed -n 's/.* in_errors_delta=\([0-9]*\)i.*/\1/p')
    rcv_err_delta=$(echo "$net_line"  | sed -n 's/.* rcvbuf_errors_delta=\([0-9]*\)i.*/\1/p')
    rx_drops_delta=$(echo "$net_line" | sed -n 's/.* rx_drops_delta=\([0-9]*\)i.*/\1/p')
    rx_pkts_delta=$(echo "$net_line"  | sed -n 's/.* rx_packets_delta=\([0-9]*\)i.*/\1/p')
    tx_pkts_delta=$(echo "$net_line"  | sed -n 's/.* tx_packets_delta=\([0-9]*\)i.*/\1/p')
    rx_bytes_delta=${rx_bytes_delta:-0}; tx_bytes_delta=${tx_bytes_delta:-0}
    in_err_delta=${in_err_delta:-0};   rcv_err_delta=${rcv_err_delta:-0}
    rx_drops_delta=${rx_drops_delta:-0}
    rx_pkts_delta=${rx_pkts_delta:-0}; tx_pkts_delta=${tx_pkts_delta:-0}
    if [ "$CLIENT_LABEL" = FireBAM ] && [ "${fb_metrics_ok:-0}" = 1 ]; then
        rx_bytes_delta=$fb_nic_rxb; tx_bytes_delta=$fb_nic_txb
        rx_pkts_delta=$fb_nic_rxp;  tx_pkts_delta=$fb_nic_txp; rx_drops_delta=$fb_nic_rxd
    fi

    # Recent leader changes & next leader slot (from replay_stage)
    last_leader_change=$(echo "$log_tail" | grep 'LEADER CHANGE at slot:' | tail -1)
    last_leader_slot=$(echo "$last_leader_change" | sed -n 's/.*LEADER CHANGE at slot: \([0-9]*\) leader: .*/\1/p')
    last_leader_pubkey=$(echo "$last_leader_change" | sed -n 's/.*leader: \([A-Za-z0-9]*\).*/\1/p')
    leader_change_count=$(echo "$log_tail" | grep -c 'LEADER CHANGE at slot:')

    if [ -n "$IDENTITY_PUBKEY" ]; then
        my_next_leader=$(echo "$log_tail" \
            | grep -F "${IDENTITY_PUBKEY} reset PoH" \
            | tail -1 | sed -n 's/.*My next leader slot is \([0-9]*\).*/\1/p')
    else
        my_next_leader=""
    fi
    my_next_leader=${my_next_leader:-0}

    my_leader_slots_in_tail=$(echo "$log_tail" | grep -c 'datapoint: replay_stage-my_leader_slot ')
    my_last_leader_slot=$(echo "$log_tail" | grep 'datapoint: replay_stage-my_leader_slot ' | tail -1 \
        | sed -n 's/.*slot=\([0-9]*\)i.*/\1/p')
    my_last_leader_slot=${my_last_leader_slot:-0}
    leader_elapsed_line=$(echo "$log_tail" | grep 'datapoint: leader-slot-start-to-cleared-elapsed-ms ' | tail -1)
    # Fallback: if our last leader slot is older than the recent tail, scan back
    # through the full log (rate-limited; tac+grep -m1 stops at the first match
    # from EOF, so it only reads back to the last build, not the whole file).
    if [ -n "$leader_elapsed_line" ]; then
        build_from_history=0
    else
        if [ $((now_epoch - last_build_scan)) -ge "$FULL_SCAN_INTERVAL" ] || [ "$RUN_ONCE" = true ]; then
            last_build_scan=$now_epoch
            # timeout is load-bearing, not belt-and-braces. The comment above is
            # true ONLY while the pattern exists somewhere in the log: grep -m1
            # stops at the first hit, so tac reads back just to the last build.
            # On a host that has NOT been leader yet there is no hit at all, so
            # tac walks the ENTIRE file. Seen in practice: a freshly promoted
            # host with a 23 GB log containing zero of these datapoints hung the
            # whole monitor here — header printed, then nothing, no error.
            cached_build_line=$(_log_rscan 'datapoint: leader-slot-start-to-cleared-elapsed-ms ' \
                                  "$BUILD_SCAN_TIMEOUT_S")
        fi
        leader_elapsed_line=$cached_build_line
        build_from_history=1
    fi
    leader_elapsed_slot=$(echo "$leader_elapsed_line" | sed -n 's/.* slot=\([0-9]*\)i.*/\1/p')
    leader_elapsed_ms=$(echo "$leader_elapsed_line" | sed -n 's/.* elapsed=\([0-9]*\)i.*/\1/p')
    leader_elapsed_slot=${leader_elapsed_slot:-0}; leader_elapsed_ms=${leader_elapsed_ms:-0}

    # --- Block-build internals (only meaningful while WE are leader producing blocks) ---
    # Central-scheduler timing breakdown (microseconds) — emitted by banking_stage.
    bst_line=$(echo "$log_tail" | grep 'datapoint: banking_stage_scheduler_timing' | tail -1)
    bst_recv=$(echo "$bst_line"   | sed -n 's/.* receive_time_us=\([0-9]*\)i.*/\1/p')
    bst_buffer=$(echo "$bst_line" | sed -n 's/.* buffer_time_us=\([0-9]*\)i.*/\1/p')
    bst_sched=$(echo "$bst_line"  | sed -n 's/.* schedule_time_us=\([0-9]*\)i.*/\1/p')
    bst_clear=$(echo "$bst_line"  | sed -n 's/.* clear_time_us=\([0-9]*\)i.*/\1/p')
    bst_clean=$(echo "$bst_line"  | sed -n 's/.* clean_time_us=\([0-9]*\)i.*/\1/p')
    bst_recv=${bst_recv:-0}; bst_buffer=${bst_buffer:-0}; bst_sched=${bst_sched:-0}
    bst_clear=${bst_clear:-0}; bst_clean=${bst_clean:-0}
    # PoH recording cost — total_record_time_us is the time spent mixing txns into PoH.
    poh_line=$(echo "$log_tail" | grep 'datapoint: poh-service' | tail -1)
    poh_record_us=$(echo "$poh_line" | sed -n 's/.* total_record_time_us=\([0-9]*\)i.*/\1/p')
    poh_lock_us=$(echo "$poh_line"   | sed -n 's/.* total_lock_time_us=\([0-9]*\)i.*/\1/p')
    poh_record_us=${poh_record_us:-0}; poh_lock_us=${poh_lock_us:-0}

    # Build-timing health: only when we actually cleared a leader slot in the tail window.
    if [ -n "$leader_elapsed_line" ] && [ "$leader_elapsed_ms" -gt 0 ]; then
        have_build=1
        build_age=$(( processed - leader_elapsed_slot )); [ "$build_age" -lt 0 ] && build_age=0
        if   [ "$leader_elapsed_ms" -le "$LEADER_BUILD_MS_WARN" ]; then build_icon="🟢"
        elif [ "$leader_elapsed_ms" -le "$LEADER_BUILD_MS_CRIT" ]; then build_icon="🟡"
        else build_icon="🔴"; fi
    else
        have_build=0; build_age=0; build_icon="⏸️ "
    fi

    # --- Latest slot cost (cost_tracker_stats) ---
    cost_line=$(echo "$log_tail" | grep 'datapoint: cost_tracker_stats' | tail -1)
    cost_slot=$(echo "$cost_line" | sed -n 's/.* bank_slot=\([0-9]*\)i.*/\1/p')
    cost_block=$(echo "$cost_line" | sed -n 's/.* block_cost=\([0-9]*\)i.*/\1/p')
    cost_vote=$(echo "$cost_line"  | sed -n 's/.* vote_cost=\([0-9]*\)i.*/\1/p')
    cost_txns=$(echo "$cost_line"  | sed -n 's/.* transaction_count=\([0-9]*\)i.*/\1/p')
    cost_sigs=$(echo "$cost_line"  | sed -n 's/.* transaction_signature_count=\([0-9]*\)i.*/\1/p')
    cost_fee=$(echo "$cost_line"   | sed -n 's/.* total_transaction_fee=\([0-9]*\)i.*/\1/p')
    cost_priority=$(echo "$cost_line" | sed -n 's/.* total_priority_fee=\([0-9]*\)i.*/\1/p')
    cost_slot=${cost_slot:-0}; cost_block=${cost_block:-0}; cost_vote=${cost_vote:-0}
    cost_txns=${cost_txns:-0}; cost_sigs=${cost_sigs:-0}; cost_fee=${cost_fee:-0}; cost_priority=${cost_priority:-0}

    # --- Shred insertion (shred_insert_is_full) ---
    shred_line=$(echo "$log_tail" | grep 'datapoint: shred_insert_is_full' | tail -1)
    shred_slot=$(echo "$shred_line" | sed -n 's/.* slot=\([0-9]*\)i.*/\1/p')
    shred_time_ms=$(echo "$shred_line" | sed -n 's/.* total_time_ms=\([0-9]*\)i.*/\1/p')
    shred_repaired=$(echo "$shred_line" | sed -n 's/.* num_repaired=\([0-9]*\)i.*/\1/p')
    shred_recovered=$(echo "$shred_line" | sed -n 's/.* num_recovered=\([0-9]*\)i.*/\1/p')
    shred_last_idx=$(echo "$shred_line"  | sed -n 's/.* last_index=\([0-9]*\)i.*/\1/p')
    shred_slot=${shred_slot:-0}; shred_time_ms=${shred_time_ms:-0}
    shred_repaired=${shred_repaired:-0}; shred_recovered=${shred_recovered:-0}; shred_last_idx=${shred_last_idx:-0}
    # Avg latency over the last 10 shred_insert_is_full samples in the tail
    shred_avg=$(echo "$log_tail" | grep 'datapoint: shred_insert_is_full' | tail -10 \
        | grep -oP 'total_time_ms=\K[0-9]+' | awk '{s+=$1; c++} END {if(c>0) printf "%.0f", s/c; else print "0"}')
    shred_avg=${shred_avg:-0}

    # --- BAM (Jito) ---
    bam_line=$(echo "$log_tail" | grep 'datapoint: bam_connection-metrics' | tail -1)
    bam_present=0
    if [ -n "$bam_line" ]; then bam_present=1; fi
    bam_bundles=$(echo "$bam_line" | sed -n 's/.* bundle_received=\([0-9]*\)i.*/\1/p')
    bam_hb_recv=$(echo "$bam_line" | sed -n 's/.* heartbeat_received=\([0-9]*\)i.*/\1/p')
    bam_hb_sent=$(echo "$bam_line" | sed -n 's/.* heartbeat_sent=\([0-9]*\)i.*/\1/p')
    bam_unhealthy=$(echo "$bam_line" | sed -n 's/.* unhealthy_connection_count=\([0-9]*\)i.*/\1/p')
    bam_fwd_fail=$(echo "$bam_line"  | sed -n 's/.* bundle_forward_to_scheduler_fail=\([0-9]*\)i.*/\1/p')
    bam_out_fail=$(echo "$bam_line"  | sed -n 's/.* outbound_fail=\([0-9]*\)i.*/\1/p')
    bam_bundles=${bam_bundles:-0}; bam_hb_recv=${bam_hb_recv:-0}; bam_hb_sent=${bam_hb_sent:-0}
    bam_unhealthy=${bam_unhealthy:-0}; bam_fwd_fail=${bam_fwd_fail:-0}; bam_out_fail=${bam_out_fail:-0}

    # --- Cluster nodes retransmit ---
    cluster_line=$(echo "$log_tail" | grep 'datapoint: cluster_nodes_retransmit' | tail -1)
    cluster_nodes=$(echo "$cluster_line" | sed -n 's/.* num_nodes=\([0-9]*\)i.*/\1/p')
    cluster_staked=$(echo "$cluster_line" | sed -n 's/.* num_nodes_staked=\([0-9]*\)i.*/\1/p')
    cluster_dead=$(echo "$cluster_line"   | sed -n 's/.* num_nodes_dead=\([0-9]*\)i.*/\1/p')
    cluster_stale=$(echo "$cluster_line"  | sed -n 's/.* num_nodes_stale=\([0-9]*\)i.*/\1/p')
    cluster_nodes=${cluster_nodes:-0}; cluster_staked=${cluster_staked:-0}
    # FireBAM: no gossip datapoint in its log; take the peers from :7999.
    if [ "$CLIENT_LABEL" = FireBAM ] && [ "${fb_metrics_ok:-0}" = 1 ]; then
        cluster_staked=$fb_peers_staked
        cluster_nodes=$(( fb_peers_staked + fb_peers_unstaked ))
    fi
    cluster_dead=${cluster_dead:-0}; cluster_stale=${cluster_stale:-0}
    cluster_dead=${cluster_dead:-0}; cluster_stale=${cluster_stale:-0}

    # --- Accounts cache ---
    cache_line=$(echo "$log_tail" | grep 'datapoint: accounts_cache_size' | tail -1)
    cache_size=$(echo "$cache_line" | sed -n 's/.* total_size=\([0-9]*\)i.*/\1/p')
    cache_accounts=$(echo "$cache_line" | sed -n 's/.* total_accounts_count=\([0-9]*\)i.*/\1/p')
    cache_slots=$(echo "$cache_line"   | sed -n 's/.* num_slots=\([0-9]*\)i.*/\1/p')
    cache_size=${cache_size:-0}; cache_accounts=${cache_accounts:-0}; cache_slots=${cache_slots:-0}

    # --- bank-forks set_root (accounts_data_len, total_banks) ---
    setroot_line=$(echo "$log_tail" | grep 'datapoint: bank-forks_set_root' | tail -1)
    root_banks=$(echo "$setroot_line"        | sed -n 's/.* total_banks=\([0-9]*\)i.*/\1/p')
    accounts_data_len=$(echo "$setroot_line" | sed -n 's/.* accounts_data_len=\([0-9]*\)i.*/\1/p')
    root_banks=${root_banks:-0}; accounts_data_len=${accounts_data_len:-0}

    # --- bank_weight / fork weight ---
    weight_line=$(echo "$log_tail" | grep 'datapoint: bank_weight' | tail -1)
    fork_weight=$(echo "$weight_line" | grep -oP 'fork_weight=\K[0-9.]+')
    fork_weight=${fork_weight:-"?"}

    # --- Duplicate confirmation latency ---
    dup_line=$(echo "$log_tail" | grep 'datapoint: validator-duplicate-confirmation' | tail -1)
    dup_confirm_ms=$(echo "$dup_line" | sed -n 's/.* duration_ms=\([0-9]*\)i.*/\1/p')
    dup_confirm_ms=${dup_confirm_ms:-"?"}

    # --- Snapshots: filesystem read ---
    snap_file=$(ls -t "$SNAPSHOT_DIR"/incremental-snapshot-*.tar.zst "$SNAPSHOT_DIR"/snapshot-*.tar.zst 2>/dev/null | head -1)
    if [ -n "$snap_file" ]; then
        snap_base=$(basename "$snap_file")
        if [[ "$snap_base" == incremental-snapshot-* ]]; then
            snap_kind="incremental-snapshot"
            snap_slot=$(echo "$snap_base" | sed -n 's/^incremental-snapshot-[0-9]*-\([0-9]*\)-.*/\1/p')
        else
            snap_kind="snapshot"
            snap_slot=$(echo "$snap_base" | sed -n 's/^snapshot-\([0-9]*\)-.*/\1/p')
        fi
        snap_slot=${snap_slot:-0}
    else
        snap_kind="?"; snap_slot=0
    fi

    # WARN/ERROR counts in the tail window
    warn_count=$(echo "$log_tail" | grep -c ' WARN ')
    error_count=$(echo "$log_tail" | grep -c ' ERROR ')

    # --- Disk usage ---
    disk_ledger=$(df -h "$LEDGER_DIR" 2>/dev/null | awk 'NR==2{printf "%s/%s (%s)", $3, $2, $5}')
    disk_root=$(df -h / 2>/dev/null | awk 'NR==2{printf "%s/%s (%s)", $3, $2, $5}')

    # --- Service status ---
    svc_sol=$(systemctl is-active "$SERVICE_NAME" 2>/dev/null)
    svc_shred=$(_svc_state "$SHREDSTREAM_UNIT")
    svc_dz=$(_svc_state "$DOUBLEZERO_UNIT")

    # --- Running validator client (JitoLabs / Agave / Firedancer) ---
    # getVersion returns solana-core + feature-set but not the client, and the
    # installed active_release/ can be a staged upgrade that is not yet running.
    # The MainPID's own binary is the only thing that is true right now.
    # FireBAM: the version is the binary's own (`firedancer --version`, first
    # word); there is no client tag, so val_client stays empty.
    val_pid=$(systemctl show -p MainPID --value "$SERVICE_NAME" 2>/dev/null)
    # FireBAM's MainPID can be a `sudo` wrapper (testnet-ogden): ask for the real process.
    [ "$CLIENT" = firebam ] && val_pid=$(pgrep -x firedancer 2>/dev/null | head -1)
    if [ "${val_pid:-0}" -gt 0 ] && [ "$val_pid" != "${cached_val_pid:-}" ]; then
        cached_val_pid=$val_pid
        # A unit with CAP_SYS_NICE (testnet-ogden) makes the kernel's ptrace check
        # refuse /proc/PID/exe to a cap-less shell even at the same uid. sol has
        # passwordless sudo there; -n never prompts where it does not.
        val_exe_ver=$(/proc/"$val_pid"/exe --version 2>/dev/null \
            || sudo -n /proc/"$val_pid"/exe --version 2>/dev/null)
        val_client=$(echo "$val_exe_ver" | sed -n 's/.*client:\([^)]*\)).*/\1/p')
        fb_version=$(echo "$val_exe_ver" | awk 'NR==1{print $1}')
    fi
    [ "${val_pid:-0}" -gt 0 ] || { val_client=""; fb_version=""; }
    [ "$CLIENT" = firebam ] && val_client=""

    # --- Leader schedule (refetch only on epoch boundary) ---
    # Look up under the STAKED identity — the local (possibly hot-spare) identity
    # may have zero leader slots this epoch.
    LEADER_ID="${LEADER_IDENTITY:-$IDENTITY_PUBKEY}"
    if [ -n "$LEADER_ID" ] && { [ -z "$cached_ls_epoch" ] || [ "$cached_ls_epoch" != "$epoch" ]; }; then
        ls_resp=$(curl -s --connect-timeout 5 -X POST -H 'Content-Type: application/json' \
            --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getLeaderSchedule\",\"params\":[null,{\"identity\":\"$LEADER_ID\"}]}" \
            "$RPC_URL" 2>/dev/null)
        ls_idxs=$(echo "$ls_resp" | jq -r --arg ip "$LEADER_ID" '.result[$ip] // [] | .[]' 2>/dev/null | sort -n)
        cached_ls_total=$(echo "$ls_idxs" | grep -c '^[0-9]')
        if [ "$cached_ls_total" -gt 0 ]; then
            cached_ls_epoch=$epoch
            cached_ls_slots=$ls_idxs
        else
            cached_ls_total=0
            cached_ls_slots=""
        fi
    fi
    # Slot duration for leader-slot ETAs: prefer the live measured ms/slot (derived
    # from the anchored processed-advance span above); fall back to the mainnet target.
    if [[ "$slot_ms" =~ ^[0-9]+$ ]] && [ "$slot_ms" -gt 0 ]; then
        slot_dur=$(awk -v m="$slot_ms" 'BEGIN{printf "%.4f", m/1000}')
    else
        slot_dur=$(awk -v m="$slot_ms_target" 'BEGIN{printf "%.4f", m/1000}')
    fi

    # Group consecutive future leader slots and pick the first N groups.
    first_slot_in_epoch=$((processed - slot_index))
    [ "$first_slot_in_epoch" -lt 0 ] && first_slot_in_epoch=0
    ls_groups_render=""
    ls_remaining=0
    next_leader_abs=0
    if [ -n "$cached_ls_slots" ]; then
        # Each line: "<group_start> <group_end> <seconds_until_group_start>"
        ls_groups_render=$(echo "$cached_ls_slots" | awk \
            -v fs="$first_slot_in_epoch" -v cur="$processed" -v dur="$slot_dur" \
            -v max="$LEADER_GROUPS_TO_SHOW" '
            BEGIN { gs = ""; ge = ""; gcount = 0 }
            {
                a = fs + $1
                if (a <= cur) next
                if (gs == "") { gs = a; ge = a }
                else if (a == ge + 1) { ge = a }
                else {
                    if (gcount < max) { printf "%d %d %.0f\n", gs, ge, dur*(gs - cur); gcount++ }
                    gs = a; ge = a
                }
            }
            END {
                if (gs != "" && gcount < max) printf "%d %d %.0f\n", gs, ge, dur*(gs - cur)
            }')
        # Count future leader slots in the epoch
        ls_remaining=$(echo "$cached_ls_slots" | awk -v fs="$first_slot_in_epoch" -v cur="$processed" \
            '{ if (fs + $1 > cur) c++ } END { print c+0 }')
        next_leader_abs=$(echo "$ls_groups_render" | awk 'NR==1{print $1}')
        next_leader_abs=${next_leader_abs:-0}
    fi

    # Wall-clock time of the next leader slot (like show-my-next-leader-slot.sh):
    # ETA seconds = (next_leader_abs - processed) * slot_dur, projected from now.
    next_leader_eta_secs=0
    next_leader_at_utc=""
    next_leader_at_local=""
    if [ "$next_leader_abs" -gt 0 ]; then
        next_leader_eta_secs=$(awk -v n="$next_leader_abs" -v p="$processed" -v d="$slot_dur" \
            'BEGIN{v=(n-p)*d; if(v<0)v=0; printf "%d", v}')
        next_leader_at_utc=$(date -u -d "@$((now_epoch + next_leader_eta_secs))" '+%Y-%m-%d %H:%M:%S UTC')
        next_leader_at_local=$(TZ="$LEADER_TZ" date -d "@$((now_epoch + next_leader_eta_secs))" '+%H:%M:%S %Z')
    fi

    fmt_eta() {
        local s=$1
        s=${s%%.*}; s=${s:-0}
        if   [ "$s" -ge 3600 ]; then printf "%dh %dm" "$((s/3600))" "$(((s%3600)/60))"
        elif [ "$s" -ge 60 ];   then printf "%dm %ds" "$((s/60))" "$((s%60))"
        else                          printf "%ds" "$s"
        fi
    }

    # --- DoubleZero (slow refresh) ---
    if [ $((now_epoch - last_slow_refresh)) -ge "$SLOW_REFRESH" ]; then
        last_slow_refresh=$now_epoch
        dz_json=$(curl -s --connect-timeout 2 --unix-socket "$DZ_SOCKET" http://localhost/status 2>/dev/null)
        if [ -n "$dz_json" ] && echo "$dz_json" | jq -e . >/dev/null 2>&1; then
            cached_dz_tunnels=$(echo "$dz_json" | jq -r --argjson now "$now_epoch" '
                map(
                    (.doublezero_status.last_session_update // 0) as $ts |
                    ($now - $ts) as $age |
                    (if $age < 60 then "\($age)s ago"
                     elif $age < 3600 then "\($age/60 | floor)m ago"
                     else "\($age/3600 | floor)h \(($age % 3600)/60 | floor)m ago" end) as $age_str |
                    (.doublezero_status.session_status // "?") as $st |
                    (if ($st | test("Up")) then "🟢" else "🔴" end) as $icon |
                    "\($icon) \(.tunnel_name // "?"): \($st) | \(.user_type // "?") | src=\(.tunnel_src // "?") dst=\(.tunnel_dst // "?") | updated \($age_str)"
                ) | .[]
            ' 2>/dev/null)
            if echo "$cached_dz_tunnels" | grep -q "🔴"; then
                cached_dz_status="DEGRADED"
            elif [ -n "$cached_dz_tunnels" ]; then
                cached_dz_status="ALL_UP"
            else
                cached_dz_status="EMPTY"
            fi
        else
            cached_dz_status="UNREACHABLE"
            cached_dz_tunnels=""
        fi
    fi

    # ---- Numeric defaults / strip ----
    processed=${processed%%.*}; processed=${processed:-0}
    confirmed=${confirmed%%.*}; confirmed=${confirmed:-0}
    finalized=${finalized%%.*}; finalized=${finalized:-0}

    # FireBAM logs no "new fork ... root:" line. Root progress comes from the RPC
    # finalized slot instead, so the root-stall check does not fire on a silent log.
    [ "$CLIENT" = firebam ] && new_root_max=$finalized

    cluster_tip=$cluster_max_last_vote
    # Prefer the outside RPC's processed slot: a genuinely independent observation.
    if [ "$ext_ok" = 1 ] && [ "$ext_processed" -gt "$cluster_tip" ]; then
        cluster_tip=$ext_processed
    fi
    # Lag against the outside view. ext_lag drives icons/alerts (clamped at 0);
    # ext_rel keeps the sign, since leading the provider's node is the normal case.
    if [ "$ext_ok" = 1 ]; then
        ext_lag=$(( ext_processed - processed )); [ "$ext_lag" -lt 0 ] && ext_lag=0
        ext_final_lag=$(( ext_finalized - finalized )); [ "$ext_final_lag" -lt 0 ] && ext_final_lag=0
        if [ "$ext_lag" -gt 0 ]; then ext_rel="we trail by $(fmt $ext_lag)"
        else ext_rel="we lead by $(fmt $(( processed - ext_processed )))"; fi
    else
        ext_lag=0; ext_final_lag=0; ext_rel=""
    fi
    [ "$cluster_tip" -lt "$processed" ] && cluster_tip=$processed

    # ---- Lag ----
    cluster_lag=$(( cluster_tip - processed ))
    [ "$cluster_lag" -lt 0 ] && cluster_lag=0
    final_lag=$(( processed - finalized ))
    [ "$final_lag" -lt 0 ] && final_lag=0
    confirm_lag=$(( processed - confirmed ))
    [ "$confirm_lag" -lt 0 ] && confirm_lag=0

    # ---- Deltas ----
    proc_delta=$(( processed - prev_processed )); [ "$prev_processed" = 0 ] && proc_delta=0
    final_delta=$(( finalized - prev_finalized )); [ "$prev_finalized" = 0 ] && final_delta=0
    root_delta=$(( new_root_max - prev_new_root_max )); [ "$prev_new_root_max" = 0 ] && root_delta=0
    blocks_delta=$(( blocks_on_fork - prev_blocks_on_fork )); [ "$prev_blocks_on_fork" = 0 ] && blocks_delta=0
    dropped_delta=$(( dropped_blocks - prev_dropped_blocks )); [ "$prev_dropped_blocks" = 0 ] && dropped_delta=0
    replay_slot_delta=$(( replay_slot - prev_replay_slot )); [ "$prev_replay_slot" = 0 ] && replay_slot_delta=0
    warn_delta=$(( warn_count - prev_log_warn_count )); [ "$prev_log_warn_count" = 0 ] && warn_delta=0
    err_delta=$(( error_count - prev_log_error_count )); [ "$prev_log_error_count" = 0 ] && err_delta=0

    if [ "$new_root_max" != "$prev_new_root_max" ] || [ "$last_root_change_ts" = 0 ]; then
        last_root_change_ts=$now_epoch
    fi
    root_stall=$(( now_epoch - last_root_change_ts ))

    # ---- Icons ----
    if [ "$health" = "ok" ]; then health_icon="🟢"; else health_icon="🔴"; fi

    if   [ "$cluster_lag" -le "$PROC_LAG_WARN" ]; then proc_icon="🟢"; proc_status="Synced"
    elif [ "$cluster_lag" -le "$PROC_LAG_CRIT" ]; then proc_icon="🟡"; proc_status="Catching up"
    else proc_icon="🔴"; proc_status="Far behind"
    fi

    if   [ "$me_delinquent" = "true" ]; then vote_icon="🔴"; vote_status="DELINQUENT"
    elif [ -n "$me_present" ] && [ "$vote_lag" -gt "$VOTE_LAG_CRIT" ]; then
        vote_icon="🟠"; vote_status="Going delinquent (vote_lag $vote_lag)"
    elif [ -n "$me_present" ] && [ "$vote_lag" -gt "$VOTE_LAG_WARN" ]; then
        vote_icon="🟡"; vote_status="Voting behind (vote_lag $vote_lag)"
    elif [ -n "$me_present" ];          then vote_icon="🟢"; vote_status="Active"
    else vote_icon="🟡"; vote_status="Not found in vote accounts"
    fi

    if   [ "$root_stall" -le "$ROOT_STALL_WARN" ]; then root_icon="🟢"; root_status="Advancing"
    elif [ "$root_stall" -le "$ROOT_STALL_CRIT" ]; then root_icon="🟡"; root_status="Slow"
    else root_icon="🔴"; root_status="STALLED"
    fi

    proc_dicon=$(delta_icon $proc_delta)
    final_dicon=$(delta_icon $final_delta)
    root_dicon=$(delta_icon $root_delta)
    replay_dicon=$(delta_icon $replay_slot_delta)
    blocks_dicon=$(delta_icon $blocks_delta)
    if   [ "$dropped_delta" -gt 0 ]; then dropped_dicon="⚠️ "
    elif [ "$dropped_delta" -lt 0 ]; then dropped_dicon="🔴"
    else dropped_dicon="🟢"; fi
    # vote_lag delta: growing lag is BAD (inverse of delta_icon's default semantics)
    if   [ "$vote_lag_delta" -gt 0 ]; then vote_lag_dicon="⚠️ "
    elif [ "$vote_lag_delta" -lt 0 ]; then vote_lag_dicon="✅"
    else vote_lag_dicon="⏸️ "; fi

    # vote_lag line highlight — always bold so it catches the eye, color tracks severity
    vl_reset=$'\033[0m'
    if   [ "$me_delinquent" = "true" ]; then                          vl_color=$'\033[1;5;91m'  # bold blink bright-red
    elif [ -n "$me_present" ] && [ "$vote_lag" -gt "$VOTE_LAG_CRIT" ]; then vl_color=$'\033[1;91m'    # bold bright-red
    elif [ -n "$me_present" ] && [ "$vote_lag" -gt "$VOTE_LAG_WARN" ]; then vl_color=$'\033[1;93m'    # bold bright-yellow
    else                                                                    vl_color=$'\033[1;96m'    # bold bright-cyan
    fi

    if [ "$cpu_num" -gt 0 ]; then
        load_ratio=$(awk -v l=$load1 -v c=$cpu_num 'BEGIN{printf "%.0f", l*100/c}')
    else
        load_ratio=0
    fi
    [ "$load_ratio" -ge "$CPU_LOAD_WARN_RATIO" ] && cpu_icon="🟡" || cpu_icon="🟢"

    if awk -v p=$mem_avail_pct -v w=$MEM_AVAIL_WARN_PCT 'BEGIN{exit !(p<w)}'; then
        mem_icon="🟡"
    else
        mem_icon="🟢"
    fi

    # Outside view: reachability first, then how far behind the independent tip.
    if   ! _outside_on; then ext_icon="⏸️ "
    elif [ "$ext_ok" != 1 ];                   then ext_icon="🟡"
    elif [ "$ext_lag" -le "$PROC_LAG_WARN" ];  then ext_icon="🟢"
    elif [ "$ext_lag" -le "$PROC_LAG_CRIT" ];  then ext_icon="🟡"
    else ext_icon="🔴"; fi
    case "$ext_me_state" in
        active)     ext_vote_icon="🟢" ;;
        delinquent) ext_vote_icon="🔴" ;;
        missing)    ext_vote_icon="🟠" ;;
        *)          ext_vote_icon="⏳" ;;
    esac

    [ "$cluster_staked" -ge "$MIN_PEERS_STAKED" ] && peers_icon="🟢" || peers_icon="🟡"
    [ "$in_err_delta" -le "$NET_ERR_DELTA_WARN" ] && neterr_icon="🟢" || neterr_icon="🟡"
    [ "$shred_avg" -le "$SHRED_LATENCY_WARN" ] && shred_icon="🟢" || shred_icon="🟡"
    if [ "$CLIENT" = firebam ]; then
        # Datapoints with no FireBAM source: no health verdict, so no green/yellow.
        neterr_icon="❔"; shred_icon="❔"
        if [ "$fb_metrics_ok" = 1 ]; then
            # From :7999 (2026-10-26): NIC drops for the network, shred-tile results for reception.
            [ "$rx_drops_delta" -le "$NET_ERR_DELTA_WARN" ] && neterr_icon="🟢" || neterr_icon="🟡"
            fb_sh_bad=$(( fb_sh_rej + fb_sh_parse + fb_sh_equiv ))
            if   [ "$fb_sh_acc" -le 0 ];   then shred_icon="🔴"
            elif [ "$fb_sh_bad" -gt 0 ];   then shred_icon="🟡"
            else shred_icon="🟢"; fi
        fi
        # From :7999 and /proc (2026-10-26): peers, CPU (busiest tile), memory.
        [ "$fb_metrics_ok" = 1 ] || peers_icon="❔"
        if [ "$fb_metrics_ok" != 1 ]; then cpu_icon="❔"
        elif awk -v b="${fb_busy_max:-0}" 'BEGIN{exit !(b>=90)}'; then cpu_icon="🟡"
        else cpu_icon="🟢"; fi
    fi

    if [ "$bam_present" = 1 ] && [ "$bam_unhealthy" -eq 0 ] && [ "$bam_out_fail" -eq 0 ]; then
        bam_icon="🟢"
    elif [ "$bam_present" = 1 ]; then
        bam_icon="🔴"
    else
        bam_icon="⏸️ "
    fi

    if [ "$err_delta" -gt 0 ]; then logs_icon="🔴"
    elif [ "$warn_delta" -gt 0 ]; then logs_icon="🟡"
    else logs_icon="🟢"; fi

    svc_icon="🟢"
    [ "$svc_sol"   != "active" ] && svc_icon="🔴"
    # "absent" means the optional unit is not installed on this host — not a fault.
    [ "$svc_shred" != "active" ] && [ "$svc_shred" != "absent" ] && svc_icon="🔴"
    [ "$svc_dz"    != "active" ] && [ "$svc_dz"    != "absent" ] && svc_icon="🔴"

    case "$cached_dz_status" in
        ALL_UP)      dz_icon="🟢" ;;
        DEGRADED)    dz_icon="🔴" ;;
        UNREACHABLE) dz_icon="🟡" ;;
        EMPTY)       dz_icon="⏸️ " ;;
        *)           dz_icon="⏳" ;;
    esac

    drop_icon="🟢"
    if awk -v d=$drop_rate -v w=$BLOCK_DROP_RATE_WARN 'BEGIN{exit !(d>w)}'; then
        drop_icon="🟡"
    fi
    [ "$CLIENT" = firebam ] && drop_icon="❔"   # no blocks_produced datapoint on FireBAM

    # Leader proximity. FireBAM has no "My next leader slot is" log line: use the
    # RPC leader schedule instead (0 when the schedule is not available).
    [ "$CLIENT" = firebam ] && my_next_leader=$next_leader_abs
    leader_distance=$(awk -v n=$my_next_leader -v p=$processed 'BEGIN{d=n-p; if(d<0)d=0; print d}')
    if   [ "$leader_distance" -le 4 ] && [ "$my_next_leader" -gt 0 ]; then leader_icon="🎯"
    elif [ "$leader_distance" -le 32 ]; then leader_icon="🟢"
    else leader_icon="⏸️ "; fi

    # Service uptime
    if [ -n "$service_start_epoch" ] && [ "$service_start_epoch" -gt 0 ]; then
        uptime_display=$(human_uptime $(( now_epoch - service_start_epoch )))
    else
        uptime_display="?"
    fi

    # Stake formatting
    me_stake_sol=$(awk -v s=$me_stake 'BEGIN{printf "%.2f", s/1e9}')
    total_stake_sol=$(awk -v s=$total_stake 'BEGIN{printf "%.2f", s/1e9}')

    # Network throughput
    rx_kbps=$(awk -v b=$rx_bytes_delta 'BEGIN{printf "%.1f", b/1024}')
    tx_kbps=$(awk -v b=$tx_bytes_delta 'BEGIN{printf "%.1f", b/1024}')

    mem_free_pct_fmt=$(awk -v p=$mem_free_pct 'BEGIN{printf "%.2f", p}')
    mem_avail_pct_fmt=$(awk -v p=$mem_avail_pct 'BEGIN{printf "%.2f", p}')

    if [ "$total_stake" != "0" ]; then
        delinq_pct=$(awk -v d=$delinquent_stake -v t=$total_stake 'BEGIN{printf "%.2f", d*100/t}')
    else
        delinq_pct="0.00"
    fi

    # Epoch progress
    if [ "$slots_in_epoch" -gt 0 ] 2>/dev/null; then
        epoch_pct=$(awk -v i=$slot_index -v s=$slots_in_epoch 'BEGIN{printf "%.2f", i*100/s}')
    else
        epoch_pct="0.00"
    fi

    # ---- Render ----
    [ "$RUN_ONCE" != true ] && clear
    echo "🔍 Validator Monitor v$SCRIPT_VERSION ($NETWORK, $CLIENT) — $(date '+%Y-%m-%d %H:%M:%S')"
    echo "============================================================"
    # Role tag: compare the live identity to the staked (leader) identity so a
    # glance shows whether this host is ACTIVE or the hot spare.
    identity_role=""
    if [ -n "${LEADER_IDENTITY:-}" ] && [ -n "$IDENTITY_PUBKEY" ]; then
        if [ "$IDENTITY_PUBKEY" = "$LEADER_IDENTITY" ]; then
            identity_role=" — 🟢 STAKED (active)"
        else
            identity_role=" — 🟡 unstaked (hot spare)"
        fi
    fi
    echo "🆔 Identity:   ${IDENTITY_PUBKEY:-?}${identity_role}"
    echo "🗳️  Vote:       ${VOTE_PUBKEY}"
    if [ "$CLIENT" = firebam ]; then
        echo "📦 Version:    firebam ${fb_version:-$sol_version} | solana-core $sol_version | feature-set $feature_set | health $health_icon $health"
        if grep -qE '^\s*alpenglow\s*=\s*true' "$HOME/firebam/firedancer.toml" 2>/dev/null; then
            # FireBAM's votor_* metrics (:7999). No fast/slow finalization split exists
            # there (nor in its log), so the Agave "N/M fast" form has no source.
            if [ "${fb_metrics_ok:-0}" = 1 ]; then
                fb_vt_warn=""
                [ $(( fb_vt_slashable + fb_vt_sigfail )) -gt 0 ] && fb_vt_warn=" ⚠️  slashable ${fb_vt_slashable} / sig-failed ${fb_vt_sigfail} since boot"
                echo "⚙️  Consensus:  🌅 Alpenglow Votor (FireBAM) — final #$(fmt $fb_final_cert) | +$(fmt $fb_vt_votes) votes, +$(fmt $fb_vt_certs) certs /cycle | $(fmt $fb_vt_peers) votor peers${fb_vt_warn}"
            else
                echo "⚙️  Consensus:  🌅 Alpenglow Votor (FireBAM config; :7999 not answering)"
            fi
        else
            echo "⚙️  Consensus:  TowerBFT (FireBAM config)"
        fi
    else
        echo "📦 Version:    agave-validator $sol_version${val_client:+ (client:$val_client)} | feature-set $feature_set | health $health_icon $health"
        if [ "$votor_active" = true ]; then
            echo "⚙️  Consensus:  🌅 Alpenglow Votor (${ag_finalized_fast}/${ag_finalized_count} fast finalizations in tail)"
        else
            echo "⚙️  Consensus:  TowerBFT"
        fi
    fi
    echo "📅 Epoch:      $epoch | slot $slot_index of $(fmt $slots_in_epoch) (${epoch_pct}%)"
    echo "⏱️  Uptime:     $uptime_display"
    echo "🐧 OS:         $os_pretty | kernel $kernel_version"
    [ "$RUN_ONCE" != true ] && echo "⌨️  Toggle: 1-9/0 sections · f FireBAM · s services · y system · a expand-all · z collapse-all · q quit"
    echo ""
    echo "┌─ $(sec_tag slot 1)📊 Slot Status: $proc_icon $proc_status"
    if ! is_collapsed slot; then
    printf "│   ├─ Processed:        %s %s (+%d/cycle)\n"  "$(fmt $processed)" "$proc_dicon" "$proc_delta"
    printf "│   ├─ Confirmed:        %s (-%s behind processed)\n"  "$(fmt $confirmed)" "$(fmt $confirm_lag)"
    printf "│   ├─ Finalized:        %s %s (-%s behind, +%d/cycle)\n" "$(fmt $finalized)" "$final_dicon" "$(fmt $final_lag)" "$final_delta"
    printf "│   ├─ Cluster tip*:     %s (-%s behind)\n" "$(fmt $cluster_tip)" "$(fmt $cluster_lag)"
    if _outside_on; then
        if [ "$ext_ok" = 1 ]; then
            printf "│   ├─ %s Outside view:   processed %s / finalized %s — %s @ %s\n" \
                "$ext_icon" "$(fmt $ext_processed)" "$(fmt $ext_finalized)" "$ext_rel" "$CLUSTER_RPC_LABEL"
        elif [ "$ext_ts" -gt 0 ]; then
            printf "│   ├─ %s Outside view:   unreachable @ %s (last good %ss ago, tip %s)\n" \
                "$ext_icon" "$CLUSTER_RPC_LABEL" "$((now_epoch - ext_ts))" "$(fmt $ext_processed)"
        else
            printf "│   ├─ %s Outside view:   unreachable @ %s\n" "$ext_icon" "$CLUSTER_RPC_LABEL"
        fi
    fi
    if [ "$max_retx" -gt 0 ] || [ "$max_shred" -gt 0 ]; then   # alpenglow host only
    printf "│   ├─ Max retransmit:   %s | Max shred insert: %s\n" "$(fmt $max_retx)" "$(fmt $max_shred)"
    fi
    printf "│   └─ Block height:     %s\n" "$(fmt $block_height)"
    echo "│      * max(lastVote) across current vote accounts"
    fi
    echo "│"
    echo "├─ $(sec_tag consensus 2)🔗 Consensus: $root_icon $root_status"
    if ! is_collapsed consensus; then
    if [ "$CLIENT" = firebam ]; then
    na_row "New root (log)"
    printf "│   ├─ Root (RPC final): %s %s (+%d/cycle, stall %ds)\n" \
        "$(fmt $new_root_max)" "$root_dicon" "$root_delta" "$root_stall"
    na_row "Tower latest"
    na_row "Tower observed"
    printf "│   ├─ Last vote (RPC):  %s (root slot %s)\n" "$(fmt $me_last_vote)" "$(fmt $me_root_slot)"
    na_row "Vote reception"
    na_row "Bank frozen"
    na_row "Optimistic slot"
    na_row "Fork weight"
    na_row "Dup confirm"
    na_row "Hi super-maj root" last
    else
    printf "│   ├─ New root (log):   %s %s (+%d/cycle, %d roots in tail, stall %ds)\n" \
        "$(fmt $new_root_max)" "$root_dicon" "$root_delta" "$new_root_count" "$root_stall"
    if [ "$tower_latest" -gt 0 ] || [ "$votor_active" = false ]; then
    printf "│   ├─ Tower latest:     %s (root %s)\n" "$(fmt $tower_latest)" "$(fmt $tower_root)"
    printf "│   ├─ Tower observed:   slot %s (root %s)\n" "$(fmt $tobs_slot)" "$(fmt $tobs_root)"
    fi
    if [ "$votor_active" = true ]; then
        votor_icon="🟢"
        [ "$ag_timeout_crash_count" -gt 0 ] && votor_icon="🟡"
        [ "$ag_standstill_count" -gt 0 ] && votor_icon="🔴"
        printf "│   ├─ %s Votor:         finalized=%d (fast=%d) notar=%d notar-fb=%d skip-votes=%d timeout-crash=%d standstill=%d\n" \
            "$votor_icon" "$ag_finalized_count" "$ag_finalized_fast" "$ag_notar_count" "$ag_notar_fb_count" \
            "$ag_skip_vote_count" "$ag_timeout_crash_count" "$ag_standstill_count"
        pool_icon="🟢"
        [ "$cp_conflict" -gt 0 ] && pool_icon="🟡"
        [ "$cps_standstill" = "true" ] && pool_icon="🔴"
        printf "│   ├─ %s Consensus pool: votes=%s certs=%s conflicting=%s | sent=%s dropped=%s standstill=%s\n" \
            "$pool_icon" "$(fmt $cp_incoming_votes)" "$(fmt $cp_incoming_certs)" "$(fmt $cp_conflict)" \
            "$(fmt $cps_certs_sent)" "$(fmt $cps_certs_dropped)" "$cps_standstill"
    fi
    printf "│   ├─ Last vote (RPC):  %s (root slot %s)\n" "$(fmt $me_last_vote)" "$(fmt $me_root_slot)"
    # TowerBFT-only rows: vote txs, optimistic confirmation and fork weight do not exist under Votor.
    [ "$votor_active" = false ] && printf "│   ├─ Vote reception:   %s/sample %s\n" "$(fmt $vote_rx)" "$vote_rx_icon"
    printf "│   ├─ Bank frozen:      %s\n" "$(fmt $frozen_slot)"
    if [ "$votor_active" = false ]; then
    printf "│   ├─ Optimistic slot:  %s\n" "$(fmt $optimistic_slot)"
    printf "│   ├─ Fork weight:      %s\n" "$fork_weight"
    printf "│   ├─ Dup confirm:      %sms\n" "$dup_confirm_ms"
    fi
    printf "│   └─ Hi super-maj root:%s (confirmed %s, agg %dms)\n" \
        "$(fmt $hsmr)" "$(fmt $hcs)" "$agg_ms"
    fi
    fi
    echo "│"
    echo "├─ $(sec_tag leader 3)🏛️  Leader / Block Production: $leader_icon $drop_icon"
    if ! is_collapsed leader; then
    if [ "$CLIENT" = firebam ] && [ "$my_next_leader" -le 0 ]; then
        na_row "My next leader"
    else
    printf "│   ├─ My next leader:   %s (cur slot %s → %s away)\n" \
        "$(fmt $my_next_leader)" "$(fmt $processed)" "$leader_distance"
    fi
    if [ "$next_leader_abs" -gt 0 ]; then
        printf "│   ├─ Next leader at:   slot %s in %s — %s / %s\n" \
            "$(fmt $next_leader_abs)" "$(fmt_eta $next_leader_eta_secs)" \
            "$next_leader_at_utc" "$next_leader_at_local"
    fi
    if [ -n "$ls_groups_render" ]; then
        printf "│   ├─ Upcoming groups:  %d remaining this epoch (next %d):\n" "$ls_remaining" "$LEADER_GROUPS_TO_SHOW"
        while IFS=' ' read -r gs ge secs; do
            [ -z "$gs" ] && continue
            n=$((ge - gs + 1))
            printf "│   │     %s-%s (%d slot%s) in %s\n" \
                "$(fmt $gs)" "$(fmt $ge)" "$n" "$([ "$n" -eq 1 ] && echo '' || echo 's')" "$(fmt_eta $secs)"
        done <<< "$ls_groups_render"
    else
        printf "│   ├─ Upcoming groups:  (leader schedule pending — fetched once per epoch)\n"
    fi
    printf "│   ├─ My last leader:   slot %s ; window slots in tail: %d\n" \
        "$(fmt $my_last_leader_slot)" "$my_leader_slots_in_tail"
    if [ "$CLIENT" = firebam ]; then
    na_row "Block build"
    na_row "Last leader chg"
    na_row "Leader changes"
    na_row "Blocks on fork"
    na_row "Dropped blocks"
    printf "│   ├─ Replay tip:       slot %s %s (+%d/cycle)\n" \
        "$(fmt $replay_slot)" "$replay_dicon" "$replay_slot_delta"
    na_row "Last snapshot" last
    else
    if [ "$have_build" = 1 ] && [ "$build_from_history" = 1 ]; then
        # Build recovered from beyond the recent tail — its banking/poh internals
        # aren't in the tail, so report only the build itself with how long ago.
        build_age_secs=$(awk -v a="$build_age" -v d="$slot_dur" 'BEGIN{printf "%d", a*d}')
        printf "│   ├─ Block build:      %s slot %s in %dms (target ≤%dms; last build %s slots / %s ago, beyond tail)\n" \
            "$build_icon" "$(fmt $leader_elapsed_slot)" "$leader_elapsed_ms" "$LEADER_BUILD_MS_WARN" \
            "$(fmt $build_age)" "$(fmt_eta $build_age_secs)"
    elif [ "$have_build" = 1 ]; then
        printf "│   ├─ Block build:      %s slot %s in %dms (target ≤%dms, %s slots ago)\n" \
            "$build_icon" "$(fmt $leader_elapsed_slot)" "$leader_elapsed_ms" "$LEADER_BUILD_MS_WARN" "$(fmt $build_age)"
        printf "│   │     internals:    sched recv=%sus buf=%sus sched=%sus clear=%sus clean=%sus | poh rec=%sus lock=%sus\n" \
            "$bst_recv" "$bst_buffer" "$bst_sched" "$bst_clear" "$bst_clean" "$poh_record_us" "$poh_lock_us"
    else
        printf "│   ├─ Block build:      %s no leader slot recorded in log\n" "$build_icon"
    fi
    printf "│   ├─ Last leader chg:  slot %s leader %s\n" \
        "$(fmt ${last_leader_slot:-0})" "${last_leader_pubkey:-?}"
    printf "│   ├─ Leader changes:   %d in last %d log lines\n" "$leader_change_count" "$LOG_TAIL_LINES"
    printf "│   ├─ Blocks on fork:   %s %s (+%d/cycle)\n" "$(fmt $blocks_on_fork)" "$blocks_dicon" "$blocks_delta"
    printf "│   ├─ Dropped blocks:   %s %s (+%d/cycle, drop_rate %s%%)\n" "$(fmt $dropped_blocks)" "$dropped_dicon" "$dropped_delta" "$drop_rate"
    printf "│   ├─ Replay tip:       slot %s %s (+%d/cycle, %s tx in %dus)\n" \
        "$(fmt $replay_slot)" "$replay_dicon" "$replay_slot_delta" "$(fmt $replay_tx)" "$replay_us"
    printf "│   └─ Last snapshot:    📸 %s at slot %s\n" "$snap_kind" "$(fmt $snap_slot)"
    fi
    fi
    echo "│"
    if [ "$CLIENT" = firebam ]; then
    # FireBAM: only the fee facts of OUR leader slots (firebam-log-view.py); no tx/CU counts.
    echo "├─ $(sec_tag latest 4)📦 Latest Leader Slot (#$([ "$cost_slot" -gt 0 ] && fmt $cost_slot || echo n/a))"
    if ! is_collapsed latest; then
    na_row "Transactions"
    na_row "Block cost"
    na_row "Vote cost"
    if [ "$cost_slot" -gt 0 ]; then
    printf "│   ├─ Total fee:        %s lamports %s\n" "$(fmt $cost_fee)" "$(arrow $cost_fee $prev_cost_fee)"
    printf "│   └─ Priority fee:     %s lamports %s\n" "$(fmt $cost_priority)" "$(arrow $cost_priority $prev_cost_priority)"
    else
    na_row "Total fee"
    na_row "Priority fee" last
    fi
    fi
    else
    echo "├─ $(sec_tag latest 4)📦 Latest Slot (#$(fmt $cost_slot))"
    if ! is_collapsed latest; then
    printf "│   ├─ Transactions:     %s (%s sigs) %s\n" "$(fmt $cost_txns)" "$(fmt $cost_sigs)" "$(arrow $cost_txns $prev_cost_txns)"
    printf "│   ├─ Block cost:       %s CU %s\n" "$(fmt $cost_block)" "$(arrow $cost_block $prev_cost_block)"
    printf "│   ├─ Vote cost:        %s CU\n" "$(fmt $cost_vote)"
    printf "│   ├─ Total fee:        %s lamports %s\n" "$(fmt $cost_fee)" "$(arrow $cost_fee $prev_cost_fee)"
    printf "│   └─ Priority fee:     %s lamports %s\n" "$(fmt $cost_priority)" "$(arrow $cost_priority $prev_cost_priority)"
    fi
    fi
    echo "│"
    if [ -n "$me_present" ]; then
        echo "├─ $(sec_tag vote 5)🗳️  Vote Account: $vote_icon $vote_status"
        if ! is_collapsed vote; then
        printf "│   ├─ Activated stake:  %s SOL (%s%% of %s SOL active)\n" \
            "$(fmt $me_stake_sol)" "$stake_share_pct" "$(fmt $total_stake_sol)"
        printf "│   ├─ Commission:       %s%%\n" "$me_commission"
        printf "│   ├─ Epoch credits:    %s this epoch (prev epoch %s)\n" "$(fmt $me_credits)" "$(fmt $me_prev_credits)"
        if [ "$vote_lag" -gt 0 ]; then
            vl_peers="$peers_as_far_behind of $current_count validators ≥${vote_lag} behind"
        else
            vl_peers="at cluster max"
        fi
        printf "│   ${vl_color}├─ ▶ Vote lag:       %s slots behind cluster max (%s) %s (Δ%+d/cycle, warn>%d crit>%d delinq~128) ◀${vl_reset}\n" \
            "$(fmt $vote_lag)" "$vl_peers" "$vote_lag_dicon" "$vote_lag_delta" "$VOTE_LAG_WARN" "$VOTE_LAG_CRIT"
        if [ "$CLIENT" = firebam ]; then
            if [ "$last_vote_list_refresh" -gt 0 ]; then
                printf "│   ├─ Cluster list:     from %s, %ss old (refreshed every %ss; FireBAM has no local getVoteAccounts)\n" \
                    "$CLUSTER_RPC_LABEL" "$((now_epoch - last_vote_list_refresh))" "$VOTE_LIST_REFRESH"
            else
                printf "│   ├─ Cluster list:     unavailable (FireBAM has no local getVoteAccounts; no CLUSTER_RPC_URL reply)\n"
            fi
        fi
        if _outside_on; then
            # The cluster's own opinion of us — the signal that matters for
            # rewards, and the one our local node can be wrong about.
            if [ "$ext_vote_ts" -gt 0 ]; then
                printf "│   ├─ %s Outside says:   %s (lastVote %s, checked %ss ago) @ %s\n" \
                    "$ext_vote_icon" "$ext_me_state" "$(fmt $ext_me_last_vote)" "$((now_epoch - ext_vote_ts))" "$CLUSTER_RPC_LABEL"
            else
                printf "│   ├─ %s Outside says:   %s @ %s\n" "$ext_vote_icon" "$ext_me_state" "$CLUSTER_RPC_LABEL"
            fi
        fi
        printf "│   └─ Cluster vote acct:%d active / %d delinquent (%s%% stake delinquent)\n" \
            "$current_count" "$delinquent_count" "$delinq_pct"
        fi
    else
        echo "├─ $(sec_tag vote 5)🗳️  Vote Account: $vote_icon $vote_status (VOTE_PUBKEY $VOTE_PUBKEY)"
        if ! is_collapsed vote; then
        printf "│   └─ Cluster vote acct:%d active / %d delinquent (%s%% stake delinquent)\n" \
            "$current_count" "$delinquent_count" "$delinq_pct"
        fi
    fi
    echo "│"
    echo "├─ $(sec_tag perf 6)⚡ Performance (${tps_src:-?} window):"
    if ! is_collapsed perf; then
    printf "│   ├─ TPS:              %s (non-vote %s) | Slots/s: %s\n" "$tps" "$nvtps" "$sps"
    printf "│   ├─ Slot time:        %s ms/slot (target %s, %s)\n" "$slot_ms" "$slot_ms_target" "$slot_ms_src"
    printf "│   └─ Txns in epoch:    %s\n" "$(fmt $epoch_tx_count)"
    fi
    echo "│"
    echo "├─ $(sec_tag shred 7)📡 Shred Reception: $shred_icon"
    if ! is_collapsed shred; then
    if [ "$CLIENT" = firebam ] && [ "$fb_metrics_ok" = 1 ]; then
    # FireBAM shred tile (:7999), per cycle. No per-slot insert latency source.
    printf "│   ├─ Shreds accepted:  %s (FEC sets completed %s) per cycle\n" "$(fmt $fb_sh_acc)" "$(fmt $fb_sh_fec)"
    printf "│   ├─ Repair received:  %s | duplicates %s\n" "$(fmt $fb_sh_repair)" "$(fmt $fb_sh_dup)"
    printf "│   └─ Problems:         rejected %s | parse failed %s | equivocated %s\n" \
        "$(fmt $fb_sh_rej)" "$(fmt $fb_sh_parse)" "$(fmt $fb_sh_equiv)"
    elif [ "$CLIENT" = firebam ]; then
    na_row "Latest slot"
    na_row "Avg latency"
    na_row "Repair/recover" last
    else
    printf "│   ├─ Latest slot:      #%s (%sms, last_index %s)\n" "$(fmt $shred_slot)" "$shred_time_ms" "$shred_last_idx"
    printf "│   ├─ Avg latency:      %sms (last 10 inserts) %s\n" "$shred_avg" "$(arrow $shred_avg $prev_shred_avg)"
    printf "│   └─ Repaired:         %s | Recovered: %s\n" "$shred_repaired" "$shred_recovered"
    fi
    fi
    echo "│"
    if [ "$bam_present" = 1 ]; then
        echo "├─ $(sec_tag bam 8)🔲 BAM (Jito): $bam_icon"
        if ! is_collapsed bam; then
        printf "│   ├─ Bundles recv:     %s\n" "$(fmt $bam_bundles)"
        # The FireBAM metrics row carries no heartbeat_sent column.
        printf "│   ├─ Heartbeats:       recv=%s sent=%s\n" "$(fmt $bam_hb_recv)" "$([ "$CLIENT" = firebam ] && echo n/a || fmt $bam_hb_sent)"
        printf "│   ├─ Fwd failures:     %s | Outbound fail: %s\n" "$(fmt $bam_fwd_fail)" "$(fmt $bam_out_fail)"
        printf "│   └─ Unhealthy count:  %s\n" "$bam_unhealthy"
        fi
        echo "│"
    fi
    if [ "$CLIENT_LABEL" = FireBAM ]; then
        if [ "$fb_metrics_ok" = 1 ]; then
            fb_cert_delta=$(( fb_final_cert - ${prev_fb_final_cert:-$fb_final_cert} ))
            [ "$fb_caught_up" = 1 ] && fb_icon="🟢" || fb_icon="🔴"
            echo "├─ $(sec_tag fd f)🔥 FireBAM metrics (127.0.0.1:7999): $fb_icon"
            if ! is_collapsed fd; then
            printf "│   ├─ Votor:            final cert #%s (+%s/cycle) | wait-to-vote #%s | %s\n" \
                "$(fmt $fb_final_cert)" "$fb_cert_delta" "$(fmt $fb_wait_vote)" "$fb_role"
            printf "│   ├─ Vote history:     %s file writes | pool slots %s used / %s free\n" \
                "$(fmt $fb_vh_writes)" "$fb_pool_used" "$fb_pool_free"
            printf "│   ├─ Replay:           caught up %s | accounts %s / %s (%s%% of max_accounts)\n" \
                "$( [ "$fb_caught_up" = 1 ] && echo yes || echo NO )" "$(fmt $fb_acc_used)" "$(fmt $fb_acc_cap)" \
                "$(awk -v u=$fb_acc_used -v c=$fb_acc_cap 'BEGIN{printf "%.1f", (c?u*100/c:0)}')"
            printf "│   ├─ Gossip peers:     %s staked / %s unstaked\n" "$(fmt $fb_peers_staked)" "$(fmt $fb_peers_unstaked)"
            printf "│   ├─ Busiest tiles:    %s (%s)\n" "${fb_tile_report:-n/a}" "$fb_tile_src"
            printf "│   ├─ Backpressure max: %s%% (%s)\n" "${fb_bp_max:-0}" "${fb_bp_max_tile:-n/a}"
            printf "│   └─ BAM healthy:      %s\n" "$( [ "$fb_bam_healthy" = 1 ] && echo yes || echo no )"
            fi
        else
            echo "├─ $(sec_tag fd f)🔥 FireBAM metrics: 🔴 127.0.0.1:7999 not answering (starting or down)"
        fi
        echo "│"
    fi
    echo "├─ $(sec_tag net 9)🌐 Network: $neterr_icon"
    if ! is_collapsed net; then
    if [ "$CLIENT" = firebam ] && [ "$fb_metrics_ok" = 1 ]; then
    # From :7999: gossip peers and FireBAM's own NIC counters (XDP bypasses the kernel's).
    printf "│   ├─ %s Cluster nodes:  %s (%s staked, gossip CRDS)\n" "$peers_icon" "$(fmt $cluster_nodes)" "$cluster_staked"
    printf "│   ├─ Traffic:          rx %s KiB / tx %s KiB | pkts rx %s / tx %s (FireBAM NIC, per cycle)\n" \
        "$rx_kbps" "$tx_kbps" "$(fmt $rx_pkts_delta)" "$(fmt $tx_pkts_delta)"
    printf "│   └─ Errors (delta):   rx_drops=%s (FireBAM NIC)\n" "$(fmt $rx_drops_delta)"
    elif [ "$CLIENT" = firebam ]; then
    na_row "Cluster nodes"
    na_row "Traffic"
    na_row "Errors (delta)" last
    else
    printf "│   ├─ %s Cluster nodes:  %s (%s staked, %s dead, %s stale)\n" \
        "$peers_icon" "$(fmt $cluster_nodes)" "$cluster_staked" "$cluster_dead" "$cluster_stale"
    printf "│   ├─ Traffic:          rx %s KiB / tx %s KiB | pkts rx %s / tx %s\n" \
        "$rx_kbps" "$tx_kbps" "$(fmt $rx_pkts_delta)" "$(fmt $tx_pkts_delta)"
    printf "│   └─ Errors (delta):   in_err=%s rcvbuf_err=%s rx_drops=%s\n" \
        "$(fmt $in_err_delta)" "$(fmt $rcv_err_delta)" "$(fmt $rx_drops_delta)"
    fi
    fi
    echo "│"
    echo "├─ $(sec_tag dz 0)⚡ DoubleZero: $dz_icon $cached_dz_status"
    if ! is_collapsed dz && [ -n "$cached_dz_tunnels" ]; then
        echo "$cached_dz_tunnels" | while IFS= read -r tline; do
            printf "│   ├─ %s\n" "$tline"
        done
    fi
    echo "│"
    echo "├─ $(sec_tag svc s)⚙️  Services: $svc_icon"
    if ! is_collapsed svc; then
    printf "│   ├─ %-23s%s\n" "$SERVICE_NAME.service:" "$svc_sol"
    printf "│   ├─ %-23s%s\n" "${SHREDSTREAM_UNIT%.service}:" "$svc_shred"
    printf "│   └─ %-23s%s\n" "${DOUBLEZERO_UNIT%.service}:" "$svc_dz"
    fi
    echo "│"
    echo "└─ $(sec_tag sys y)🖥️  System Health:"
    if ! is_collapsed sys; then
    if [ "$CLIENT" = firebam ]; then
    # /proc + sysfs + :7999 (2026-10-26). Accounts cache/data/banks are Agave
    # datapoints; FireBAM's accounts index is in the FireBAM section.
    printf "    ├─ CPU load 1/5/15:  %s / %s / %s (cores=%s, threads=%s) — not a signal on FireBAM\n" \
        "$load1" "$load5" "$load15" "$cpu_num" "$(fmt $threads)"
    printf "    ├─ %s Tile CPU:        busiest %s%% (%s)\n" "$cpu_icon" "${fb_busy_max:-?}" "${fb_busy_max_tile:-n/a}"
    printf "    ├─ %s Memory:          %s%% free / %s%% available (used %s of %s GiB)\n" \
        "$mem_icon" "$mem_free_pct_fmt" "$mem_avail_pct_fmt" \
        "$(awk -v b=$mem_used 'BEGIN{printf "%.1f", b/1073741824}')" \
        "$(awk -v b=$mem_total 'BEGIN{printf "%.1f", b/1073741824}')"
    printf "    ├─ Hugepages:        1 GiB: %s / %s in use | 2 MiB: %s / %s in use (FireBAM workspace)\n" \
        "$fb_giant_used" "$fb_giant_total" "$fb_huge2_used" "$fb_huge2_total"
    printf "    ├─ Accounts cache / data / banks: n/a (Agave datapoints; see the FireBAM section)\n"
    else
    printf "    ├─ %s CPU load 1/5/15: %s / %s / %s (cores=%s, threads=%s, load1=%s%% of cores)\n" \
        "$cpu_icon" "$load1" "$load5" "$load15" "$cpu_num" "$(fmt $threads)" "$load_ratio"
    printf "    ├─ %s Memory:          %s%% free / %s%% available (used %s of %s GiB)\n" \
        "$mem_icon" "$mem_free_pct_fmt" "$mem_avail_pct_fmt" \
        "$(awk -v b=$mem_used 'BEGIN{printf "%.1f", b/1073741824}')" \
        "$(awk -v b=$mem_total 'BEGIN{printf "%.1f", b/1073741824}')"
    printf "    ├─ Accounts cache:   %s (%s accounts, %s slots)\n" \
        "$(human_bytes $cache_size)" "$(fmt $cache_accounts)" "$cache_slots"
    printf "    ├─ Accounts data:    %s\n" "$(human_bytes $accounts_data_len)"
    printf "    ├─ Active banks:     %s\n" "$root_banks"
    fi
    printf "    ├─ Disk (ledger):    %s\n" "${disk_ledger:-?}"
    printf "    ├─ Disk (root):      %s\n" "${disk_root:-?}"
    printf "    └─ %s Log tail (%d lines): %d WARN, %d ERROR (+%d/+%d this cycle)\n" \
        "$logs_icon" "$LOG_TAIL_LINES" "$warn_count" "$error_count" "$warn_delta" "$err_delta"
    fi
    echo ""

    # ---- Epoch progress bar ----
    epoch_pct_int=${epoch_pct%%.*}; epoch_pct_int=${epoch_pct_int:-0}
    bar_width=40
    filled=$((epoch_pct_int * bar_width / 100))
    [ "$filled" -gt "$bar_width" ] && filled=$bar_width
    [ "$filled" -lt 0 ] && filled=0
    empty=$((bar_width - filled))
    bar=$(printf '%*s' "$filled" '' | tr ' ' '#')$(printf '%*s' "$empty" '' | tr ' ' '-')
    printf "⏱️  Epoch %s [%s] %s%%\n" "$epoch" "$bar" "$epoch_pct"
    echo ""

    # ---- Alert banner ----
    issues=0
    [ "$health" != "ok" ] && issues=$((issues+1))
    [ "$cluster_lag" -gt "$PROC_LAG_CRIT" ] && issues=$((issues+1))
    [ "$final_lag" -gt "$FINAL_LAG_CRIT" ] && issues=$((issues+1))
    [ "$root_stall" -gt "$ROOT_STALL_CRIT" ] && issues=$((issues+1))
    [ "$me_delinquent" = "true" ] && issues=$((issues+1))
    [ -n "$me_present" ] && [ "$vote_lag" -gt "$VOTE_LAG_CRIT" ] && issues=$((issues+1))
    { [ "$CLIENT" != firebam ] || [ "$fb_metrics_ok" = 1 ]; } && [ "$cluster_staked" -lt "$MIN_PEERS_STAKED" ] && issues=$((issues+1))
    [ "$CLIENT" = firebam ] && [ "$fb_metrics_ok" = 1 ] && [ "$fb_caught_up" != 1 ] && issues=$((issues+1))
    [ "$svc_sol"   != "active" ] && issues=$((issues+1))
    [ "$svc_shred" != "active" ] && [ "$svc_shred" != "absent" ] && issues=$((issues+1))
    [ "$svc_dz"    != "active" ] && [ "$svc_dz"    != "absent" ] && issues=$((issues+1))
    [ "$cached_dz_status" = "DEGRADED" ] && issues=$((issues+1))
    if _outside_on; then
        [ "$ext_ok" != 1 ] && issues=$((issues+1))
        [ "$ext_ok" = 1 ] && [ "$ext_lag" -gt "$PROC_LAG_CRIT" ] && issues=$((issues+1))
        [ "$ext_me_state" = "delinquent" ] && issues=$((issues+1))
    fi
    [ "$bam_present" = 1 ] && [ "$bam_unhealthy" -gt 0 ] && issues=$((issues+1))

    if [ "$prev_processed" = 0 ] && [ "$RUN_ONCE" != true ]; then
        echo "⏳ Status: Initializing..."
    elif [ "$ext_me_state" = "delinquent" ] && [ "$me_delinquent" != "true" ]; then
        # Outside disagreeing with local is worse than either alone: our node
        # thinks it is voting, the cluster is not counting those votes.
        echo "🚨 ALERT: $CLUSTER_RPC_LABEL reports our vote account DELINQUENT while the local view says active"
    elif [ "$me_delinquent" = "true" ]; then
        echo "🚨 ALERT: vote account is DELINQUENT"
    elif [ -n "$me_present" ] && [ "$vote_lag" -gt "$VOTE_LAG_CRIT" ]; then
        echo "🚨 ALERT: vote_lag ${vote_lag} slots (Δ${vote_lag_delta:+}${vote_lag_delta}/cycle) — going delinquent before ~128-slot cliff"
    elif [ "$svc_sol" != "active" ]; then
        echo "🚨 ALERT: $SERVICE_NAME.service is not active ($svc_sol)"
    elif [ "$health" != "ok" ]; then
        echo "🚨 ALERT: RPC health=$health"
    elif [ "$cluster_lag" -gt "$PROC_LAG_CRIT" ]; then
        echo "🚨 ALERT: processed slot $cluster_lag behind cluster tip"
    elif [ "$root_stall" -gt "$ROOT_STALL_CRIT" ]; then
        echo "🚨 ALERT: no new root for ${root_stall}s"
    elif [ "$votor_active" = true ] && { [ "$ag_standstill_count" -gt 0 ] || [ "$cps_standstill" = "true" ]; }; then
        echo "🚨 ALERT: Alpenglow Standstill (log events=$ag_standstill_count, in_standstill=$cps_standstill)"
    elif [ "$cached_dz_status" = "DEGRADED" ]; then
        echo "🚨 ALERT: DoubleZero tunnel(s) DOWN"
    elif [ $issues -gt 0 ]; then
        echo "⚠️  WARNING: $issues health issue(s) detected"
    elif [ "$RUN_ONCE" = true ]; then
        echo "🟢 HEALTHY — validator is voting"
    elif [ "$proc_delta" -gt 0 ] && [ "$root_delta" -gt 0 ]; then
        echo "🚀 Status: validator healthy and finalizing (proc +$proc_delta, roots +$root_delta)"
    elif [ "$proc_delta" -gt 0 ]; then
        echo "📡 Status: replaying slots (proc +$proc_delta) but no new root this cycle"
    else
        echo "⏸️  Status: idle / no slot progress this cycle"
    fi

    # ---- Save previous values ----
    prev_processed=$processed
    prev_confirmed=$confirmed
    prev_finalized=$finalized
    prev_vote_lag=$vote_lag
    prev_blocks_on_fork=$blocks_on_fork
    prev_dropped_blocks=$dropped_blocks
    prev_new_root_max=$new_root_max
    prev_fb_final_cert=${fb_final_cert:-0}
    prev_replay_slot=$replay_slot
    prev_log_warn_count=$warn_count
    prev_log_error_count=$error_count
    prev_cost_block=$cost_block
    prev_cost_txns=$cost_txns
    prev_cost_fee=$cost_fee
    prev_cost_priority=$cost_priority
    prev_shred_avg=$shred_avg
    prev_ts=$now_epoch

    [ "$RUN_ONCE" = true ] && exit 0
    # Replace sleep with a non-blocking key read: a hotkey toggles a section and
    # redraws immediately; otherwise this times out after SLEEP_SECS like sleep.
    if read -rsn1 -t "$SLEEP_SECS" key 2>/dev/null; then
        handle_key "$key"
    fi
done
