# Recover a Redis Software cluster on OpenShift

`rec-recover.sh` recovers a Redis Software cluster on OpenShift after it loses quorum or can't heal on its own. It confirms that recovery is needed, backs up the cluster configuration and database files, asks the Redis operator to rebuild the cluster from the existing persistent volumes, and then recovers every database from its persistence files. Active-Active databases and standard databases follow separate paths, so the script never overwrites a data-bearing Active-Active instance by accident.

The script is read-only by default. Any step that changes the cluster needs `--execute` plus an approval token that the precheck prints. Every run writes a timestamped report to `artifacts/`.

## Contents

- [Prerequisites](#prerequisites)
  - [Platforms](#platforms)
- [How it works](#how-it-works)
- [Run a recovery](#run-a-recovery)
- [Subcommands](#subcommands)
- [Options](#options)
  - [Target](#target)
  - [Gates](#gates)
  - [Databases](#databases)
  - [Other](#other)
- [Configuration file](#configuration-file)
- [Output](#output)
- [Safety rules](#safety-rules)
- [Test offline](#test-offline)

## Prerequisites

Cluster:

- A `RedisEnterpriseCluster` (REC) deployed with `persistentSpec.enabled: true`
- The original PVCs still exist and are `Bound`
- The Redis operator deployment is running
- The same Redis Software version as before the failure

Workstation:

- bash 3.2 or later
- `oc`, logged in with access to the REC namespace, nodes, and volumeattachments
- `tar`, `awk`, and `base64` (no `jq`: the script reads cluster objects with `oc -o jsonpath` and parses REST output inside the Redis pod)
- Python 3.11 or later, only if you want the optional log collector

### Platforms

| Platform | Works? | How |
|---|---|---|
| macOS | Yes | Nothing to install beyond `oc`. |
| Linux | Yes | Nothing to install beyond `oc`. |
| Windows, Git Bash | Yes | Open **Git Bash** (comes with Git for Windows: bash, awk, tar, base64, curl). Put `oc.exe` on your PATH. The script disables MSYS path conversion itself so pod paths such as `/var/opt/redislabs/persist` reach `oc exec` unchanged. |
| Windows, WSL | Yes | Behaves like Linux. Install `oc` inside the WSL distribution. |
| Windows PowerShell or cmd | No | The script is bash. Use Git Bash or WSL. |

Run `./rec-recover.sh doctor` first on any new machine. It checks every tool, the `oc` session, and whether a REC is visible, and prints the install command for anything missing. Keep the repository checked out with LF line endings on Windows; the included `.gitattributes` enforces this, but if you copied the files another way and see `$'\r': command not found`, run `dos2unix` on the `.sh` files.

Run the script from an admin workstation or bastion outside the cluster. It talks to the OpenShift API with `oc` and runs `rladmin` inside the Redis pods with `oc exec`. Don't run it inside a Redis pod—recovery recreates those pods.

## How it works

![Recovery flow](docs/recovery-flow.svg)

Green boxes are read-only and safe to run at any time. Orange boxes change the cluster and need `--execute --token`. The two diamonds are gates: the approval token from `precheck`, and an explicit decision for every Active-Active database. `all` runs the chain left to right and stops at the approval token unless you pass `--execute --token`.

When the script patches the REC with `clusterRecovery: true`, the operator recreates the Redis pods, mounts the existing PVCs, restores the cluster configuration store (CCS) from the first pod, joins the remaining pods, and clears the flag. That step restores configuration only. `recover-db` restores database data afterwards with `rladmin recover db`.

## Run a recovery

1. Log in to the OpenShift cluster with `oc login`. The script finds the REC on its own; copy `rec-recover.env.example` to `rec-recover.env` only if you want to change timeouts or pin a specific REC.

2. Check whether recovery is justified:

   ```bash
   ./rec-recover.sh precheck
   ```

   Read the verdict. A single pod or node failure heals on its own and doesn't need recovery. Continue only on `RECOVERY_RECOMMENDED`. Note the approval token.

3. Back up the cluster configuration and database files, then copy `artifacts/<run>/backup` off the cluster:

   ```bash
   ./rec-recover.sh backup
   ```

4. Rebuild the cluster:

   ```bash
   ./rec-recover.sh recover-cluster --execute --token <token>
   ```

   Don't run this twice for the same incident. If the wait times out while the cluster is still initializing, watch `oc get rec` until it shows `Running`, then continue with the next step.

5. Plan the database recovery and settle every Active-Active decision:

   ```bash
   ./rec-recover.sh plan-db
   ```

6. Recover the databases:

   ```bash
   ./rec-recover.sh recover-db --execute --token <token> --aa-config-only crdb-a,crdb-b
   ```

7. Validate manually: databases are `active` in `rladmin status`, apps connect, TLS and authentication work, and every Active-Active peer shows the instance in sync (`crdb-cli crdb get --crdb-guid <guid>` on each participating cluster).

Once you know the Active-Active decisions, you can run the whole chain in two commands:

```bash
./rec-recover.sh all
./rec-recover.sh all --execute --token <token> --aa-config-only crdb-a,crdb-b
```

## Subcommands

Run `./rec-recover.sh <subcommand> [options]`. Without a subcommand, `precheck` runs.

| Subcommand | Changes the cluster | What it does | When to use it |
|---|---|---|---|
| `precheck` | No | Checks that the REC exists with persistence enabled, PVCs are `Bound`, OpenShift nodes are `Ready`, no VolumeAttachment points at a dead node, the operator is running, how many Redis pods are `Ready` versus quorum, whether `rladmin status` answers, which modules are loaded, and which REDB and REAADB resources exist. Saves the REC spec. Prints a verdict and an approval token. | Always first. The verdict is `RECOVERY_NOT_NEEDED`, `RECOVERY_RECOMMENDED`, or `BLOCKED` when a prerequisite is missing. |
| `doctor` | no | Workstation check: bash, oc, tar, awk, base64, sha256, python, `oc` session, REC visibility. Prints install hints. |
| `diagnostics` | No | Downloads and runs the Redis `log_collector.py` in `all` mode into the artifacts folder. Skips with a warning if Python 3.11 isn't available. | Before recovery, when you have or expect a Redis Support case. It never blocks the run. |
| `backup` | No | Archives the CCS directory from the first reachable pod and the database persistence directory from every reachable pod, with a `SHA256SUMS` manifest. | Before any recovery. Recovery reuses the original storage, so keep a copy of what's on it. |
| `recover-cluster` | Yes | Patches the REC with `clusterRecovery: true`, waits until the state is `Running` and the operator has cleared the flag, waits for every pod to be `Ready`, then checks that all nodes are `OK` and no cluster actions are running. | After `precheck` returns `RECOVERY_RECOMMENDED` and `backup` succeeds. Run it once per incident. |
| `plan-db` | No | Runs `rladmin recover list`, marks each database as standard or Active-Active, and prints the exact `rladmin recover` command for each one. Shows `UNDECIDED` for any Active-Active database without an `--aa-*` decision and `BLOCKED` for any database that reports `missing-files`. | After the cluster is `Running` and before you recover databases. Run it as often as you like. |
| `recover-db` | Yes | Rebuilds the plan, stops if anything is `UNDECIDED` or `BLOCKED`, then recovers databases one at a time: data-bearing Active-Active instances first, then every standard database, then config-only Active-Active instances. Confirms that `rladmin recover list` is empty afterwards. | After `plan-db` shows a clean plan. It never uses `rladmin recover all`, which would load data into every Active-Active instance at once. |
| `all` | Gated | Runs `precheck`, `diagnostics`, and `backup`, then stops. With `--execute --token` it continues with `recover-cluster` and `recover-db`. | Use the first form to prepare and the second to run the full recovery. If a phase fails, the run stops there. Finish with the individual subcommands. |

## Options

### Target

| Option | Default | What it does | When to use it |
|---|---|---|---|
| `--ns <namespace>` | auto-detected | OpenShift namespace of the REC. | Only to pin one cluster when several RECs exist, or when you lack permission to list RECs cluster-wide. Can also be `NS=` in `rec-recover.env`. |
| `--rec <name>` | auto-detected | Name of the REC. Pod names derive from it (`<rec>-0`, `<rec>-1`, and so on). | Same as `--ns`. Can also be `REC=` in the env file. |
| `--container <name>` | `redis-enterprise-node` | Container in the Redis pods where `rladmin` runs. | Only if your operator uses a different container name. |
| `--env <file>` | `rec-recover.env` | Load defaults from another env file. | Keep one env file per cluster, such as `prod.env` and `dr.env`. |

How detection works: every run first checks the `oc` session and stops with a clear message if it has expired or you never logged in. It then lists `RedisEnterpriseCluster` resources on the logged-in cluster. Exactly one REC is used automatically and logged as `auto-detected target`. Several RECs give a numbered prompt on a terminal, or an error listing them when the script runs non-interactively. None is an error. If your account cannot list RECs cluster-wide, the current `oc project` is searched instead.

### Gates

| Option | Default | What it does | When to use it |
|---|---|---|---|
| `--execute` | off | Lets `recover-cluster`, `recover-db`, and the second half of `all` change the cluster. | Without it, every command is a dry run. Add it after you've read the precheck findings. |
| `--token <token>` | none | The approval token from the last `precheck`. It encodes the REC UID and the precheck run, and expires after four hours (`TOKEN_TTL`). | Required with `--execute`. It proves that someone reviewed a recent precheck of this cluster. A stale, foreign, or mistyped token stops the run before anything changes. |
| `--force` | off | Allows recovery when the precheck verdict was `RECOVERY_NOT_NEEDED`. | Almost never. Only when you have independent evidence of quorum loss that the precheck couldn't see. |
| `--allow-unbacked` | off | Continues even if the backup phase couldn't archive the CCS or database files. | Only when no pod is reachable and you accept recovering onto storage you have no copy of. Prefer a PVC snapshot from your storage platform first. |
| `--strict-modules` | off | Treats duplicate module versions as `BLOCKED` instead of a warning. | On Redis Software 7.2.4-x, clusters with old or manually uploaded modules can't recover until compatible modules are present. Use it to make the script enforce that. |

### Databases

| Option | Default | What it does | When to use it |
|---|---|---|---|
| `--recovery-path <path>` | unset | Runs `rladmin node <id> recovery_path set <path>` on every node before listing recoverable databases (with `--execute`). Also sets the directory to back up. | When you restored persistence files somewhere other than `/var/opt/redislabs/persist/redis`. Without it, `plan-db` shows `missing-files`. |
| `--aa-data-bearing <db[,db]>` | unset | Active-Active databases on this cluster to recover with their data (`rladmin recover db <name>`). | Only when every participating cluster of that database is down. Exactly one instance across all clusters may carry the data. |
| `--aa-config-only <db[,db]>` | unset | Active-Active databases on this cluster to recover with configuration only (`rladmin recover db <name> only_configuration`). The instance then syncs from live peers. | The normal choice when at least one other participating cluster is healthy. |

A database can't appear in both lists. Every Active-Active database in `rladmin recover list` must appear in one of them, or `recover-db` won't start. Standard databases need no option.

| Peer clusters | Option for the instance on this cluster |
|---|---|
| At least one peer is live | `--aa-config-only <name>` |
| All peers are down and this cluster will carry the data | `--aa-data-bearing <name>`, then recover the peers config-only |
| All peers are down and another cluster will carry the data | `--aa-config-only <name>`, after that cluster recovers its instance with data |
| Unsure | Stop. Check `crdb-cli crdb list` and `crdb-cli crdb get` on each peer first. |

### Other

| Option | Default | What it does | When to use it |
|---|---|---|---|
| `--skip-diagnostics` | off | Skips the log collector in `all`. | When you already have logs or Python 3.11 isn't installed. |
| `--timeout-rec <seconds>` | `1800` | How long `recover-cluster` waits for the REC to reach `Running` with the flag cleared. | Raise it for large clusters or slow image pulls. If it expires while the state is still changing, don't rerun `recover-cluster`. Wait for `oc get rec` to show `Running`, then continue with `plan-db`. |
| `--timeout-pod <seconds>` | `900` | How long to wait for each Redis pod to become `Ready` after the REC is `Running`. | Raise it if nodes attach volumes slowly. |
| `--no-color` | off | Plain-text output. `NO_COLOR=1` does the same. `COLOR=always` forces colour when piping. | For output captured by other tooling. `run.log` and `report.md` are always plain text. |
| `-h`, `--help` | | Prints usage. | |

## Configuration file

Copy `rec-recover.env.example` to `rec-recover.env` and edit it. Command-line options override the file.

| Variable | Default | Purpose |
|---|---|---|
| `NS`, `REC` | unset (auto-detected) | Leave empty to detect the REC from the logged-in cluster. Set them only to pin a specific cluster. |
| `REDIS_CONTAINER`, `OPERATOR_DEPLOYMENT` | `redis-enterprise-node`, `redis-enterprise-operator` | Container where `rladmin` runs, and the operator deployment that the precheck verifies. |
| `PERSIST_ROOT`, `CCS_FILE`, `DB_PERSIST_DIR` | `/var/opt/redislabs/persist`, `ccs/ccs-redis.rdb`, `redis` | Where the CCS and database files live inside the pod. These are the documented defaults. |
| `RECOVERY_PATH` | unset | Same as `--recovery-path`. |
| `RL_TIMEOUT` | `30` | Seconds allowed for ordinary `rladmin` calls. Runs inside the container, so a dead cluster can't hang the script. |
| `RL_RECOVER_TIMEOUT` | `3600` | Seconds allowed for each `rladmin recover db`. Raise it for very large databases. |
| `TIMEOUT_REC`, `TIMEOUT_POD`, `POLL_INTERVAL` | `1800`, `900`, `15` | Wait behaviour of `recover-cluster`. |
| `TOKEN_TTL` | `14400` | Seconds an approval token stays valid. |
| `BACKUP_MAX_BYTES` | `21474836480` | Per-pod size above which the script skips the database file archive (20 GiB). Snapshot larger data with your storage platform. |
| `AA_DATA_BEARING`, `AA_CONFIG_ONLY` | unset | Same as the `--aa-*` options. Useful when the lists are long. |

## Output

Terminal output is colour-coded: green `PASS`, orange `WARN`, red `FAIL`, and cyan `INFO`, with a banner for each phase, a verdict box after the precheck, a colour-coded database plan, and a summary footer.

Each run creates `artifacts/<run-id>/` with:

- `report.md`—every finding as a table
- `report.tsv` and `run.log`
- Raw `rladmin` output, `rec-spec.yaml`, `pods.yaml`, `events.txt`, and `redb.yaml` / `reaadb.yaml` / `rerc.yaml`
- REDB, REAADB, and RERC inventories
- `db-plan.tsv`
- `backup/` with the archives and `SHA256SUMS`

The approval token and verdict live in `artifacts/precheck-state.env` as `KEY=value` lines. To read the token without re-running the precheck: `sed -n 's/^TOKEN=//p' artifacts/precheck-state.env`.

## Safety rules

- Nothing changes without `--execute` and a valid, unexpired token for this REC.
- You can't override a `BLOCKED` verdict. A `RECOVERY_NOT_NEEDED` verdict needs `--force`.
- A failed or skipped backup stops the run unless you pass `--allow-unbacked`.
- The script never runs `rladmin recover all`. Every Active-Active database needs an explicit decision, and any database with `missing-files` stops `recover-db` before the first `rladmin recover`.
- The script never force-deletes pods, never deletes PVCs or VolumeAttachments, and never recreates the REC. If the REC was deleted, recreate it from `artifacts/<run>/rec-spec.json` with the same name, version, storage class, node count, and credentials, then run `precheck` again.

