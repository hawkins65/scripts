# lib-env.sh — sourceable detection helpers for the bam-leader-activity repo.
#
# Source this from any bash script that needs to discover validator
# environment details. Sourcing alone does nothing — call the functions.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib-env.sh"
#   LEDGER_DIR=$(detect_ledger_dir)
#
# Functions:
#   detect_ledger_dir — prints the --ledger value of the running
#                       agave-validator process. Falls back to grepping
#                       ~/validator.sh, then /mnt/ledger.

# Print the ledger directory the running validator was started with.
# Network-agnostic (mainnet/testnet) and role-agnostic (primary/standby).
detect_ledger_dir() {
    local _pid _dir=""
    _pid=$(pgrep -x agave-validator 2>/dev/null | head -1)
    if [[ -n "$_pid" && -r "/proc/$_pid/cmdline" ]]; then
        _dir=$(tr '\0' ' ' < "/proc/$_pid/cmdline" \
            | grep -oP '(?<=--ledger )\S+' | head -1)
    fi
    if [[ -z "$_dir" && -f "$HOME/validator.sh" ]]; then
        _dir=$(grep -oP '(?<=--ledger )\S+' "$HOME/validator.sh" | head -1)
    fi
    echo "${_dir:-/mnt/ledger}"
}
