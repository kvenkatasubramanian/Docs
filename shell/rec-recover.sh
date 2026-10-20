#!/usr/bin/env bash
# =============================================================================
# rec-recover.sh - Redis Enterprise cluster recovery on OpenShift
#                  (Method A: persistence enabled, original PVCs intact)
#
# Read-only by default. Mutating subcommands need --execute --token <token>,
# where the token is printed by `precheck`.
#
# Usage:  ./rec-recover.sh [subcommand] [flags]      (see --help)
# Requires on the workstation: bash >= 3.2, oc (logged in), tar, awk, sed, grep, base64. No jq needed.
# =============================================================================
set -euo pipefail

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_ROOT

# Git Bash / MSYS2 / Cygwin rewrite arguments that look like POSIX paths (for example
# /var/opt/redislabs/persist or /v1/bdbs) into Windows paths before oc receives them.
# Those arguments are meant for the Redis pod, so disable the conversion.
case "$(uname -s 2>/dev/null)" in
  MINGW* | MSYS* | CYGWIN*)
    export MSYS_NO_PATHCONV=1
    export MSYS2_ARG_CONV_EXCL='*'
    ;;
esac

ENV_FILE="${ENV_FILE:-$SCRIPT_ROOT/rec-recover.env}"
# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

FORCE="${FORCE:-false}"
SUBCMD=""

# -----------------------------------------------------------------------------
# Usage
# -----------------------------------------------------------------------------
usage() {
  cat <<USAGE
Usage: $0 <subcommand> [flags]

Subcommands (read-only unless marked MUTATES):
  precheck          Steps 1,2,4: health, persistence, PVCs, nodes, operator, modules, AA inventory.
                    Prints verdict + approval token.                                           [default]
  diagnostics       Step 3:     run log_collector.py (best effort).
  backup            Step 5:     archive CCS + DB persistence files from every reachable pod.
  recover-cluster   Steps 6-8:  patch clusterRecovery=true, wait Running + flag cleared,
                    pods Ready, cluster validation.                                             MUTATES
  plan-db           Steps 10,12: rladmin recover list, classify standard vs CRDB, print commands.
  recover-db        Steps 11,12: recover databases per plan (never 'recover all' with CRDBs).  MUTATES
  all               precheck -> diagnostics -> backup, then (only with --execute --token)
                    recover-cluster -> recover-db. Step 13 (validation) is manual.
  doctor            Check this workstation: bash, oc, tar, awk, sed, grep, base64, oc login, REC detection.

Target (optional - auto-detected from the logged-in cluster when omitted):
  --ns <ns>  --rec <name>                       Namespace and REC name. If exactly one REC exists it is used;
                                                several -> numbered prompt (or error when not interactive).
  --container <name>                            Redis container name (default: ${REDIS_CONTAINER:-redis-enterprise-node})
  --env <file>                                  Alternate env file (default: rec-recover.env)

Gates:
  --execute                                     Allow mutating actions
  --token <token>                               Approval token from the latest precheck
  --force                                       Allow recovery when precheck said RECOVERY_NOT_NEEDED
  --allow-unbacked                              Continue even if backup failed/skipped
  --strict-modules                              Treat duplicate module versions as BLOCKED

Databases:
  --recovery-path <path>                        Non-default DB persistence path (rladmin node <id> recovery_path set)
  --aa-data-bearing <db[,db]>                   CRDB instance(s) to recover WITH data (sole data-bearing instance)
  --aa-config-only  <db[,db]>                   CRDB instance(s) to recover only_configuration (peers are live)

Other:
  --skip-diagnostics                            Skip log_collector.py
  --timeout-rec <s>  --timeout-pod <s>          Defaults 1800 / 900
  --no-color                                    Plain output (NO_COLOR env also works; COLOR=always forces colour)
  -h | --help
USAGE
}

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    precheck | diagnostics | backup | recover-cluster | plan-db | recover-db | all | doctor)
      SUBCMD="$1" ;;
    --ns)               NS="$2"; shift ;;
    --rec)              REC="$2"; shift ;;
    --container)        REDIS_CONTAINER="$2"; shift ;;
    --env)
      ENV_FILE="$2"; shift
      # shellcheck disable=SC1090
      [ -f "$ENV_FILE" ] && . "$ENV_FILE" ;;
    --execute)          EXECUTE=true ;;
    --token)            TOKEN="$2"; shift ;;
    --force)            FORCE=true ;;
    --allow-unbacked)   ALLOW_UNBACKED=true ;;
    --strict-modules)   STRICT_MODULES=true ;;
    --recovery-path)    RECOVERY_PATH="$2"; shift ;;
    --aa-data-bearing)  AA_DATA_BEARING="$2"; shift ;;
    --aa-config-only)   AA_CONFIG_ONLY="$2"; shift ;;
    --skip-diagnostics) SKIP_DIAGNOSTICS=true ;;
    --timeout-rec)      TIMEOUT_REC="$2"; shift ;;
    --timeout-pod)      TIMEOUT_POD="$2"; shift ;;
    --no-color)         COLOR=never ;;
    -h | --help)        usage; exit 0 ;;
    *)
      echo "unknown argument: $1" >&2
      usage
      exit 2 ;;
  esac
  shift
done
SUBCMD="${SUBCMD:-precheck}"

export NS REC REDIS_CONTAINER EXECUTE TOKEN FORCE ALLOW_UNBACKED RECOVERY_PATH \
       AA_DATA_BEARING AA_CONFIG_ONLY STRICT_MODULES SKIP_DIAGNOSTICS TIMEOUT_REC TIMEOUT_POD COLOR

# -----------------------------------------------------------------------------
# Libraries
# -----------------------------------------------------------------------------
# shellcheck source=lib/common.sh
. "$SCRIPT_ROOT/lib/common.sh"
# shellcheck source=lib/rl.sh
. "$SCRIPT_ROOT/lib/rl.sh"
# shellcheck source=lib/precheck.sh
. "$SCRIPT_ROOT/lib/precheck.sh"
# shellcheck source=lib/backup.sh
. "$SCRIPT_ROOT/lib/backup.sh"
# shellcheck source=lib/cluster.sh
. "$SCRIPT_ROOT/lib/cluster.sh"
# shellcheck source=lib/db.sh
. "$SCRIPT_ROOT/lib/db.sh"

# -----------------------------------------------------------------------------
# Preflight
# -----------------------------------------------------------------------------
if [ "$SUBCMD" = "doctor" ]; then
  run_doctor
  exit $?
fi

require_cmd oc tar awk sed grep base64
init_artifacts
check_login      # dies if there is no oc session or it has expired
discover_target  # fills NS/REC from the cluster unless given by flag or env file

printf '%s\n' "${C_BOLD}Redis Enterprise REC recovery (Method A)${C_RESET}  \
${C_DIM}subcommand=${C_RESET}${C_BOLD}$SUBCMD${C_RESET}  \
${C_DIM}ns=${C_RESET}$NS  ${C_DIM}rec=${C_RESET}$REC  ${C_DIM}execute=${C_RESET}$EXECUTE" >&2
printf '%s [INFO ] subcommand=%s ns=%s rec=%s execute=%s\n' "$(_ts)" "$SUBCMD" "$NS" "$REC" "$EXECUTE" >>"$LOG_FILE"

# A CRDB cannot be in both Active-Active lists.
if [ -n "$AA_DATA_BEARING" ] && [ -n "$AA_CONFIG_ONLY" ]; then
  IFS=',' read -r -a _dbs <<<"$AA_DATA_BEARING"
  for _d in "${_dbs[@]}"; do
    if csv_contains "$AA_CONFIG_ONLY" "$_d"; then
      die "database '$_d' is listed in both --aa-data-bearing and --aa-config-only"
    fi
  done
fi

# -----------------------------------------------------------------------------
# Dispatch
# -----------------------------------------------------------------------------
rc=0
case "$SUBCMD" in
  precheck)        phase_precheck || rc=$? ;;
  diagnostics)     phase_diagnostics || rc=$? ;;
  backup)          phase_backup || rc=$? ;;
  recover-cluster) phase_recover_cluster || rc=$? ;;
  plan-db)         phase_plan_db || rc=$? ;;
  recover-db)      phase_recover_db || rc=$? ;;
  all)
    phase_precheck || rc=$?
    if [ "$rc" -ne 0 ]; then
      finalize_report "BLOCKED"
      exit "$rc"
    fi

    phase_diagnostics || true

    phase_backup || rc=$?
    if [ "$rc" -ne 0 ]; then
      finalize_report "STOPPED_AT_BACKUP"
      exit "$rc"
    fi

    if [ "$EXECUTE" != "true" ]; then
      log "Prechecks and backup completed. Re-run 'all --execute --token <token>' to perform recovery."
      finalize_report "PRECHECK_ONLY"
      exit 0
    fi

    phase_recover_cluster || { finalize_report "FAILED_CLUSTER_RECOVERY"; exit 1; }
    phase_recover_db      || { finalize_report "FAILED_DB_RECOVERY"; exit 1; }
    log "Recovery complete. Validate databases and application connectivity manually (runbook step 13)."
    ;;
esac

if [ "$rc" -eq 0 ]; then
  finalize_report "COMPLETED"
else
  finalize_report "COMPLETED_WITH_FINDINGS"
fi
exit "$rc"
