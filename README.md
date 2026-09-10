# solana-validator-scripts

Operational scripts from running the [Trillium](https://trillium.so) Solana
validator — Jito/BAM tooling, DoubleZero revenue and tunnel management, leader
slot monitoring, and CPU tuning for Firedancer and Agave.

These are the working versions, not cleaned-up demos. They are shared because
most of them took a while to get right and there is not much published in this
area.

## Setup

Several scripts read RPC endpoints and validator identity from a shared config
file rather than taking flags:

```bash
mkdir -p ~/.config/validator
cp validator-rpc.conf.example ~/.config/validator/rpc.conf
chmod 600 ~/.config/validator/rpc.conf
$EDITOR ~/.config/validator/rpc.conf
```

`dz-claim.sh` uses its own secrets file; see `dz-claim.secrets.env.example`.

> **On RPC URLs as credentials.** A paid endpoint from QuickNode, Helius,
> Alchemy, or Triton carries its API key *inside the URL path*. The whole URL is
> therefore a secret. Keep any file holding one at mode `600` and out of version
> control — the `.gitignore` here is set up for that. This repo learned the
> lesson the expensive way.

## Jito / BAM

| Script | What it does |
|---|---|
| `set-bam-node.sh` | Switch the BAM endpoint at runtime, without restarting the validator |
| `check-jito-null-commission.sh` | Detect a validator running null MEV commission |
| `check-jito-tip-distribution.sh` | Inspect the tip distribution account for an epoch |
| `init_tip_distribution.py` | Initialise a tip distribution account |
| `claim-jito-bam-boost-public.sh` | Claim BAM boost rewards and sweep them to a wallet |
| `jito-shredstream-check-logs.sh` | Health-check the Jito shredstream proxy from its logs |
| `get_jito_slot_durations.py` | Pull per-slot durations for timing analysis |

## DoubleZero

| Script | What it does |
|---|---|
| `dz-claim.sh` | Monitor and settle DoubleZero publisher rewards |
| `dz_tunnel_guard.sh` | Watchdog for the DoubleZero tunnel |
| `dz-location-scoring.sh` | Score candidate locations |
| `dz_recency_weighted_fees.sh` | Recency-weighted fee calculation over recent blocks |

DoubleZero distributes on a rolling ~8-epoch lag, so `dz-claim.sh` only
configures an epoch once it reports `ready`. Seeing "0 distributed" for a recent
epoch is normal, not a fault.

## Leader slots and monitoring

| Script | What it does |
|---|---|
| `validator-monitor.sh` | Live terminal dashboard for an Agave/Jito node — vote reception, CPU and memory, network errors, shred latency, block build time, DoubleZero and shredstream health |
| `my-leader-slots.sh` | List your leader slots for the current epoch |
| `show-my-next-leader-slot.sh` | Time until your next leader slot |
| `validator-monitor-credits.sh` | Track vote credits and flag shortfalls |
| `sfdp_version_monitor.sh` | Watch client versions against SFDP requirements |
| `collect-identity-balance.sh` | Record identity account balance over time |
| `pubkey-to-name.sh` | Resolve a vote account to a validator name via the Trillium API |
| `epoch-run-once.sh` | Run a set of jobs once per epoch, at the boundary |

`validator-monitor.sh` reads the validator's own JSON-RPC endpoint, its log, and
local sources (filesystem, the `doublezerod` socket, systemd). It shells out to
no `solana` CLI and depends on no public RPC.

**Log source.** Not everyone runs with `--log`; plenty of operators let the
validator write to stdout and read it back with `journalctl`. Both work:

```bash
LOG_SOURCE=auto     # default — see below
LOG_SOURCE=file     LOG_FILE=/mnt/ledger/logs/validator.log
LOG_SOURCE=journal  LOG_UNIT=sol.service
```

On `auto` it derives the path from the `--log` flag in your validator start
script and uses that file if it is readable; otherwise it falls back to
journald. Deriving beats assuming — a host logging to
`/mnt/ledger/logs/validator.log` may match the historical `/home/sol/logs`
default only because the latter is a symlink to it, and a rebuild silently
breaks that. When a `--log` file does exist it is preferred over journald,
since journald may be rate-limiting and dropping the very datapoint lines this
monitor counts.

**Everything else is an environment variable**, with defaults in the config
block at the top:

| Variable | Default | |
|---|---|---|
| `RPC_URL` | `http://127.0.0.1:8899` | the validator's own RPC |
| `VOTE_PUBKEY` | from `rpc.conf` | required |
| `SERVICE_NAME` | `sol` | validator unit |
| `LOG_SOURCE` / `LOG_FILE` / `LOG_UNIT` | `auto` | see above |
| `VALIDATOR_START_SCRIPT` | `~/validator.sh` | scanned for `--log` |
| `LEDGER_DIR` | `/mnt/ledger` | |
| `SNAPSHOT_DIR` | `/mnt/accounts1/snapshots` | |
| `SHREDSTREAM_UNIT` | `dz-shred-forward.service` | set to `jito-shredstream.service` if you still take shreds from Jito rather than the DoubleZero multicast |
| `DOUBLEZERO_UNIT` | `doublezerod.service` | |
| `DZ_SOCKET` | `/run/doublezerod/doublezerod.sock` | |

The Jito and DoubleZero units are optional. If they are not installed they
report `absent` and are not counted as faults, so a plain Agave node does not
sit permanently red. (`systemctl is-active` reports a nonexistent unit as
`inactive`, identical to one that is installed and stopped — the script checks
for existence separately to tell the two apart.)

Its warning thresholds — especially `VOTE_RX_WARN` — were calibrated on specific
hardware and stake. The comments explain the method; recalibrate on your own
nodes instead of adopting the numbers as-is. Vote reception in particular is a
useful *leading* indicator: it drops the moment a host returns degraded, hours
before that host is next leader and under-packs, while every ordinary liveness
check stays green.

## CPU and performance

| Script | What it does |
|---|---|
| `fd-cpu-isolate.sh` | Isolate CPU cores for Firedancer |
| `fd-cpu-restore.sh` | Undo the isolation |
| `set-cpu-perf-min.sh` | Pin the CPU governor to performance, with amd-pstate settling |

## Dashboards

`grafana-bundles-firedancer.json` — Grafana dashboard for Firedancer bundle
metrics. Import it and point it at your Prometheus source.

## Other

`sui-weighted-gas-prices.py` — weighted reference gas price calculation for Sui.
Unrelated to Solana; it lives here because it shares the same tooling.

## Notes

Paths default to `/home/sol/...`, the usual Solana validator convention. Most are
overridable by environment variable — check the top of each script.

No warranty. Read anything before you run it against a live validator, and
understand what `fd-cpu-isolate.sh` and `set-bam-node.sh` will do to a running
node before you find out in production.

## License

MIT
