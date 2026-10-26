#!/usr/bin/env bash
# =============================================================================
# rec-recover.sh - Redis Enterprise cluster recovery on OpenShift
#
# Rebuilds a Redis Enterprise cluster whose pods are gone or cannot form a quorum, using the
# cluster configuration and database files that survived on the persistent volumes.
#
#   ./rec-recover.sh precheck          read-only health check and verdict
#   ./rec-recover.sh backup            archive CCS + database files from the pods
#   ./rec-recover.sh recover-cluster   operator rebuilds the cluster      (asks for confirmation)
#   ./rec-recover.sh recover-db        recover every database, standard and Active-Active
#   ./rec-recover.sh all               all of the above in order
#
# Target cluster is detected from your `oc login` session. Nothing changes on the
# cluster until you type the cluster name at the confirmation prompt (or pass --yes).
# Requires on the workstation: bash >= 3.2, oc (logged in), tar, awk, sed, grep, base64.
# recover-cluster and all also require the customer CA certificate O1_G2_Certificate.pem in the
# current directory or next to this script; it is appended to /etc/opt/redislabs/trusted_ca.pem in
# every pod. Both commands stop at once if the file is missing.
# =============================================================================
set -euo pipefail

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_ROOT

# Git Bash / MSYS2 / Cygwin rewrite arguments that look like POSIX paths (for example
# /var/opt/redislabs/persist) into Windows paths before oc receives them. Disable that.
case "$(uname -s 2>/dev/null)" in
  MINGW* | MSYS* | CYGWIN*)
    export MSYS_NO_PATHCONV=1
    export MSYS2_ARG_CONV_EXCL='*'
    ;;
esac

# Optional settings file (timeouts, pinning a specific REC, Active-Active defaults).
ENV_FILE="${ENV_FILE:-$SCRIPT_ROOT/rec-recover.env}"
# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

ASSUME_YES="${ASSUME_YES:-false}"
SUBCMD=""

usage() {
  cat <<USAGE
Usage: $0 <command> [--yes]

Commands:
  precheck          Check the cluster and print a verdict. Read-only.
  backup            Archive the cluster configuration (CCS) and database files from every reachable pod.
  recover-cluster   Re-run the precheck, ask for confirmation, then let the operator rebuild the cluster.
                    Appends O1_G2_Certificate.pem (from the current directory or next to the script) to
                    /etc/opt/redislabs/trusted_ca.pem in every pod before, during and after the rebuild.
  recover-db        Recover every database that is in recovery state: standard databases with their data,
                    Active-Active databases with data or configuration-only (you are asked per database).
  all               precheck -> backup -> confirmation -> recover-cluster -> recover-db

Options:
  --yes             Do not prompt. Accepts the confirmation and uses the Active-Active default
                    (AA_MODE in rec-recover.env, default: configuration-only). For unattended runs only.
  -h, --help        This text.

The target namespace and cluster are detected from the cluster you are logged in to with 'oc login'.
Settings such as timeouts live in rec-recover.env (see rec-recover.env.example).
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    precheck | backup | recover-cluster | recover-db | all) SUBCMD="$1" ;;
    --yes | -y) ASSUME_YES=true ;;
    -h | --help) usage; exit 0 ;;
    *)
      echo "unknown argument: $1" >&2
      usage
      exit 2 ;;
  esac
  shift
done
[ -n "$SUBCMD" ] || { usage; exit 2; }
export ASSUME_YES

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
# Preflight: tools, oc session, target cluster
# -----------------------------------------------------------------------------
require_cmd oc tar awk sed grep base64
init_artifacts
check_login      # dies if there is no oc session or it has expired
discover_target  # fills NS/REC from the cluster unless pinned in rec-recover.env
case "$SUBCMD" in
  recover-cluster | all) require_ca_cert_file ;;   # dies if O1_G2_Certificate.pem is not on the workstation
esac

printf '%s\n' "${C_BOLD}Redis Enterprise cluster recovery${C_RESET}  \
${C_DIM}command=${C_RESET}${C_BOLD}$SUBCMD${C_RESET}  \
${C_DIM}namespace=${C_RESET}$NS  ${C_DIM}cluster=${C_RESET}$REC" >&2
printf '%s [INFO ] command=%s ns=%s rec=%s\n' "$(_ts)" "$SUBCMD" "$NS" "$REC" >>"$LOG_FILE"

# -----------------------------------------------------------------------------
# Dispatch
# -----------------------------------------------------------------------------
rc=0
case "$SUBCMD" in
  precheck)        phase_precheck || rc=$? ;;
  backup)          phase_backup || rc=$? ;;
  recover-cluster) phase_recover_cluster || rc=$? ;;
  recover-db)      phase_recover_db || rc=$? ;;
  all)
    if ! phase_precheck; then
      finalize_report "BLOCKED"
      exit 1
    fi
    if ! phase_backup; then
      finalize_report "STOPPED_AT_BACKUP"
      exit 1
    fi
    phase_recover_cluster skip-precheck || { finalize_report "FAILED_CLUSTER_RECOVERY"; exit 1; }
    phase_recover_db                    || { finalize_report "FAILED_DB_RECOVERY"; exit 1; }
    log "Recovery complete. Validate databases and application connectivity manually."
    ;;
esac

if [ "$rc" -eq 0 ]; then
  finalize_report "COMPLETED"
else
  finalize_report "COMPLETED_WITH_FINDINGS"
fi
exit "$rc"
