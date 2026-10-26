#!/usr/bin/env bash
# =============================================================================
# common.sh - shared helpers for rec-recover.sh
#
# Sourced by rec-recover.sh; never executed directly.
# Requires: bash >= 3.2, oc, tar, awk, sed, grep, base64. No jq: cluster objects are read with
# `oc -o jsonpath`, REST JSON is parsed inside the Redis pod. Colour needs a terminal on stderr.
# =============================================================================

# -----------------------------------------------------------------------------
# Defaults (override via rec-recover.env or command-line flags)
# -----------------------------------------------------------------------------
NS="${NS:-}"    # empty = auto-detect from the logged-in cluster (see discover_target)
REC="${REC:-}"  # empty = auto-detect from the logged-in cluster
REDIS_CONTAINER="${REDIS_CONTAINER:-redis-enterprise-node}"
OPERATOR_DEPLOYMENT="${OPERATOR_DEPLOYMENT:-redis-enterprise-operator}"

# Persistence layout inside the Redis Enterprise pod (documented defaults)
PERSIST_ROOT="${PERSIST_ROOT:-/var/opt/redislabs/persist}"
CCS_FILE="${CCS_FILE:-ccs/ccs-redis.rdb}"      # relative to PERSIST_ROOT
DB_PERSIST_DIR="${DB_PERSIST_DIR:-redis}"      # relative to PERSIST_ROOT
RECOVERY_PATH="${RECOVERY_PATH:-}"             # non-default path for rladmin node recovery_path set

# Timeouts (seconds)
RL_TIMEOUT="${RL_TIMEOUT:-30}"                 # rladmin status etc., applied inside the container
RL_RECOVER_TIMEOUT="${RL_RECOVER_TIMEOUT:-3600}" # rladmin recover db
TIMEOUT_REC="${TIMEOUT_REC:-1800}"             # REC -> Running
TIMEOUT_POD="${TIMEOUT_POD:-900}"              # each pod -> Ready
POLL_INTERVAL="${POLL_INTERVAL:-15}"

# Backup
BACKUP_MAX_BYTES="${BACKUP_MAX_BYTES:-21474836480}" # skip per-pod DB archive above 20 GiB

# Customer CA certificate. recover-cluster and all require this file on the workstation (looked up in the
# current directory, then next to rec-recover.sh). After clusterRecovery is patched, its content is appended
# to TRUSTED_CA_PATH in each pod as the pod comes up, and once more on every pod after the rebuild, wherever
# the certificate is not already present. The operator's first-pod recovery needs the certificate there.
CA_CERT_FILE="${CA_CERT_FILE:-O1_G2_Certificate.pem}"
TRUSTED_CA_PATH="${TRUSTED_CA_PATH:-/etc/opt/redislabs/trusted_ca.pem}"
RESTART_AFTER_RESTORE="${RESTART_AFTER_RESTORE:-true}"   # supervisorctl restart all on pods where the certificate was appended after the rebuild
SWITCH_MASTER="${SWITCH_MASTER:-true}"                   # after recovery, move the cluster master to another node (rladmin cluster master set)
NEW_MASTER_NODE="${NEW_MASTER_NODE:-}"                   # node id to promote; empty = lowest healthy node id that is not the current master

# Behaviour
ASSUME_YES="${ASSUME_YES:-false}"              # --yes: no prompts
ALLOW_UNBACKED="${ALLOW_UNBACKED:-false}"      # continue even if the backup step could not archive everything
STRICT_MODULES="${STRICT_MODULES:-false}"      # treat duplicate module versions as blocking
# Active-Active (CRDB) handling in recover-db:
#   interactive runs ask per database; --yes runs use AA_MODE unless the database is listed below.
AA_MODE="${AA_MODE:-config-only}"              # config-only (peers are live) | data (all participants were down)
AA_DATA_BEARING="${AA_DATA_BEARING:-}"         # comma-separated CRDB names always recovered WITH data
AA_CONFIG_ONLY="${AA_CONFIG_ONLY:-}"           # comma-separated CRDB names always recovered configuration-only

# Artifacts
SCRIPT_ROOT="${SCRIPT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
ARTIFACT_ROOT="${ARTIFACT_ROOT:-$SCRIPT_ROOT/artifacts}"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
# Two invocations in the same second must not share an artifact directory.
if [ -d "$ARTIFACT_ROOT/$RUN_ID" ] && [ -z "${ARTIFACT_DIR:-}" ]; then
  RUN_ID="${RUN_ID}-$$"
fi
ARTIFACT_DIR="${ARTIFACT_DIR:-$ARTIFACT_ROOT/$RUN_ID}"
REPORT_TSV="$ARTIFACT_DIR/report.tsv"           # ts <TAB> phase <TAB> check <TAB> status <TAB> message
REPORT_MD="$ARTIFACT_DIR/report.md"
LOG_FILE="$ARTIFACT_DIR/run.log"

# -----------------------------------------------------------------------------
# Colours and symbols
#   COLOR=auto|always|never (--no-color sets never). NO_COLOR also disables.
#   The log file is always plain text.
# -----------------------------------------------------------------------------
COLOR="${COLOR:-auto}"

setup_colors() {
  local want=0
  case "$COLOR" in
    always) want=1 ;;
    never)  want=0 ;;
    *)      if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then want=1; fi ;;
  esac

  if [ "$want" -eq 1 ]; then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
    C_GREEN=$'\033[32m'
    C_RED=$'\033[31m'
    C_CYAN=$'\033[36m'
    C_BLUE=$'\033[34m'
    # Orange needs 256 colours; fall back to yellow.
    if [ "$(tput colors 2>/dev/null || echo 8)" -ge 256 ]; then
      C_ORANGE=$'\033[38;5;208m'
    else
      C_ORANGE=$'\033[33m'
    fi
  else
    C_RESET="" C_BOLD="" C_DIM="" C_GREEN="" C_RED="" C_CYAN="" C_BLUE="" C_ORANGE=""
  fi

  case "${LC_ALL:-}${LC_CTYPE:-}${LANG:-}" in
    *UTF-8* | *utf8* | *UTF8*)
      S_OK="✔" S_FAIL="✖" S_WARN="⚠" S_INFO="●" S_SKIP="○" S_BAR="━" ;;
    *)
      S_OK="+" S_FAIL="x" S_WARN="!" S_INFO="*" S_SKIP="-" S_BAR="=" ;;
  esac
}
setup_colors

# _repeat <count> <string>
_repeat() {
  local n="$1" ch="$2" out=""
  while [ "$n" -gt 0 ]; do
    out="$out$ch"
    n=$((n - 1))
  done
  printf '%s' "$out"
}

# Terminal width capped at 110 columns.
_cols() {
  local c
  c="$(tput cols 2>/dev/null || echo 100)"
  [ "$c" -gt 110 ] && c=110
  echo "$c"
}

# -----------------------------------------------------------------------------
# Logging (terminal gets colour, run.log gets plain text)
# -----------------------------------------------------------------------------
_ts()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
_hms() { date -u +%H:%M:%S; }

# _emit <plain line for log file> <coloured line for terminal>
_emit() {
  printf '%s\n' "$1" >>"$LOG_FILE"
  printf '%s\n' "$2" >&2
}

log() {
  _emit "$(_ts) [INFO ] $*" \
        "${C_DIM}$(_hms)${C_RESET}  ${C_CYAN}${S_INFO}${C_RESET}  $*"
}

log_warn() {
  _emit "$(_ts) [WARN ] $*" \
        "${C_DIM}$(_hms)${C_RESET}  ${C_ORANGE}${S_WARN} $*${C_RESET}"
}

log_err() {
  _emit "$(_ts) [ERROR] $*" \
        "${C_DIM}$(_hms)${C_RESET}  ${C_RED}${C_BOLD}${S_FAIL} $*${C_RESET}"
}

die() {
  log_err "$*"
  finalize_report "FAILED"
  exit 1
}

# phase_banner <TITLE> [subtitle]
phase_banner() {
  local title="$1" sub="${2:-}" width line
  width="$(_cols)"
  line="$(_repeat $((width - ${#title} - 6)) "$S_BAR")"
  printf '\n' >&2
  _emit "===== $title ===== $sub" \
        "${C_BOLD}${C_BLUE}${S_BAR}${S_BAR}${S_BAR} ${title} ${line}${C_RESET}"
  if [ -n "$sub" ]; then
    printf '%s\n' "${C_DIM}    $sub${C_RESET}" >&2
  fi
}

init_artifacts() {
  mkdir -p "$ARTIFACT_DIR"
  : >>"$LOG_FILE"
  : >>"$REPORT_TSV"
  log "run id: $RUN_ID  artifacts: $ARTIFACT_DIR"
}

# Human-readable OS name used in messages and install hints.
os_name() {
  case "$(uname -s 2>/dev/null)" in
    Darwin)                  echo macOS ;;
    Linux)                   echo Linux ;;
    MINGW* | MSYS* | CYGWIN*) echo "Windows (Git Bash)" ;;
    *)                       uname -s 2>/dev/null || echo unknown ;;
  esac
}

# install_hint <command>  - one line per OS on how to get a missing tool
install_hint() {
  case "$(os_name)" in
    macOS)   echo "brew install $1" ;;
    Linux)   echo "sudo apt-get install $1   # or: sudo dnf install $1" ;;
    Windows*) case "$1" in
                oc) echo "download from the OpenShift console > ? > Command line tools, put oc.exe on PATH" ;;
                *)  echo "comes with Git for Windows; reinstall Git for Windows if missing" ;;
              esac ;;
    *)       echo "install $1 with your package manager" ;;
  esac
}

require_cmd() {
  local c missing=""
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
  done
  [ -z "$missing" ] && return 0
  printf '%s\n' "${C_RED}${C_BOLD}${S_FAIL} missing required command(s) on this $(os_name) workstation:${missing}${C_RESET}" >&2
  for c in $missing; do
    printf '    %-8s %s\n' "$c" "$(install_hint "$c")" >&2
  done
  exit 2
}

# -----------------------------------------------------------------------------
# Findings and report
# -----------------------------------------------------------------------------

# report_add <phase> <check> <PASS|WARN|FAIL|INFO|SKIP> <message...>
report_add() {
  local phase="$1" check="$2" status="$3"
  shift 3
  local msg="$*"

  # tabs/newlines inside the message would break the TSV
  local flat
  flat="$(printf '%s' "$msg" | tr '\t\n\r' '   ')"
  printf '%s\t%s\t%s\t%s\t%s\n' "$(_ts)" "$phase" "$check" "$status" "$flat" >>"$REPORT_TSV"

  local col sym
  case "$status" in
    PASS) col="$C_GREEN"  sym="$S_OK" ;;
    WARN) col="$C_ORANGE" sym="$S_WARN" ;;
    FAIL) col="$C_RED"    sym="$S_FAIL" ;;
    SKIP) col="$C_DIM"    sym="$S_SKIP" ;;
    *)    col="$C_CYAN"   sym="$S_INFO" ;;
  esac

  local line
  line="$(printf '%s  %s%s %-4s%s  %s%-22s%s %s' \
    "${C_DIM}$(_hms)${C_RESET}" "${col}${C_BOLD}" "$sym" "$status" "$C_RESET" \
    "$C_BOLD" "$check" "$C_RESET" "${col}${msg}${C_RESET}")"
  _emit "$(_ts) [$status] [$phase/$check] $msg" "$line"
}

# report_count <status>
report_count() {
  awk -F'\t' -v s="$1" '$4 == s { n++ } END { print n + 0 }' "$REPORT_TSV" 2>/dev/null || echo 0
}

# finalize_report <overall label>  - writes report.md and prints the summary footer
finalize_report() {
  local overall="${1:-COMPLETED}"
  [ -f "$REPORT_TSV" ] || return 0

  local np nw nf
  np="$(report_count PASS)"
  nw="$(report_count WARN)"
  nf="$(report_count FAIL)"

  {
    echo "# REC recovery run report"
    echo
    echo "- Run id: \`$RUN_ID\`"
    echo "- Namespace / REC: \`$NS\` / \`$REC\`"
    echo "- Overall: **$overall**"
    echo "- PASS: $np  WARN: $nw  FAIL: $nf"
    echo
    echo "| Time (UTC) | Phase | Check | Status | Message |"
    echo "|---|---|---|---|---|"
    awk -F'\t' '{ gsub(/\|/, "\\|", $5); printf "| %s | %s | %s | %s | %s |\n", $1, $2, $3, $4, $5 }' "$REPORT_TSV"
  } >"$REPORT_MD"

  local ocol
  case "$overall" in
    COMPLETED | PRECHECK_ONLY)                 ocol="$C_GREEN" ;;
    COMPLETED_WITH_FINDINGS | STOPPED_AT_BACKUP) ocol="$C_ORANGE" ;;
    *)                                         ocol="$C_RED" ;;
  esac

  {
    printf '\n%s\n' "${C_DIM}$(_repeat "$(_cols)" "$S_BAR")${C_RESET}"
    printf '  %sSUMMARY%s  %s%s%s   %s%s %s passed%s   %s%s %s warnings%s   %s%s %s failed%s\n' \
      "$C_BOLD" "$C_RESET" "${ocol}${C_BOLD}" "$overall" "$C_RESET" \
      "$C_GREEN" "$S_OK" "$np" "$C_RESET" \
      "$C_ORANGE" "$S_WARN" "$nw" "$C_RESET" \
      "$C_RED" "$S_FAIL" "$nf" "$C_RESET"
    printf '  %sreport%s   %s\n' "$C_DIM" "$C_RESET" "$REPORT_MD"
    printf '%s\n' "${C_DIM}$(_repeat "$(_cols)" "$S_BAR")${C_RESET}"
  } >&2
  printf '%s [INFO ] report written: %s\n' "$(_ts)" "$REPORT_MD" >>"$LOG_FILE"
}

# verdict_box <VERDICT> <line...>  - coloured box for the precheck verdict
verdict_box() {
  local verdict="$1"
  shift

  local col width
  case "$verdict" in
    RECOVERY_NOT_NEEDED)  col="$C_GREEN" ;;
    RECOVERY_RECOMMENDED) col="$C_ORANGE" ;;
    *)                    col="$C_RED" ;;
  esac
  width="$(_cols)"

  {
    printf '\n%s%s%s\n' "$col" "$(_repeat "$width" "$S_BAR")" "$C_RESET"
    printf '  %sPRECHECK VERDICT%s   %s%s%s%s\n' "$C_BOLD" "$C_RESET" "$col" "$C_BOLD" "$verdict" "$C_RESET"
    printf '\n'
    local l
    for l in "$@"; do
      printf '  %s\n' "$l"
    done
    printf '%s%s%s\n\n' "$col" "$(_repeat "$width" "$S_BAR")" "$C_RESET"
  } >&2
  printf '%s [INFO ] VERDICT=%s\n' "$(_ts)" "$verdict" >>"$LOG_FILE"
}

# -----------------------------------------------------------------------------
# oc wrappers
# -----------------------------------------------------------------------------
ocn() { oc -n "$NS" "$@"; }

# -----------------------------------------------------------------------------
# Login check and target discovery
# -----------------------------------------------------------------------------

# Dies with a clear message when there is no oc session or it has expired.
check_login() {
  local server user
  server="$(oc whoami --show-server 2>/dev/null || echo "unknown server")"
  if ! user="$(oc whoami 2>/dev/null)"; then
    die "not logged in to OpenShift ($server), or the session has expired. Run 'oc login' and retry."
  fi
  log "logged in to $server as $user"
}

# _list_recs [namespace]  -> lines "<namespace>\t<rec>\t<state>\t<nodes>"
_list_recs() {
  local ns="${1:-}" jp
  jp='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.status.state}{"\t"}{.spec.nodes}{"\n"}{end}'
  if [ -n "$ns" ]; then
    oc -n "$ns" get rec -o jsonpath="$jp" 2>/dev/null
  else
    oc get rec -A -o jsonpath="$jp" 2>/dev/null
  fi | awk -F'\t' 'NF >= 2 { printf "%s\t%s\t%s\t%s\n", $1, $2, ($3 == "" ? "unknown" : $3), ($4 == "" ? "?" : $4) }'
}

# Fills NS and REC from the logged-in cluster when they were not given by flag or env file.
#   exactly one REC  -> used automatically
#   several RECs     -> numbered prompt on a terminal, otherwise an error listing them
#   none             -> error
discover_target() {
  if [ -n "$NS" ] && [ -n "$REC" ]; then
    return 0
  fi

  local recs cur
  if [ -n "$NS" ]; then
    recs="$(_list_recs "$NS")"
  else
    recs="$(_list_recs)"
    if [ -z "$recs" ]; then
      # No cluster-wide list permission (or nothing found): try the current project.
      cur="$(oc project -q 2>/dev/null || true)"
      [ -n "$cur" ] && recs="$(_list_recs "$cur")"
    fi
  fi
  if [ -n "$REC" ]; then
    recs="$(printf '%s\n' "$recs" | awk -F'\t' -v r="$REC" '$2 == r')"
  fi
  recs="$(printf '%s\n' "$recs" | sed '/^$/d')"

  local count
  count="$(printf '%s\n' "$recs" | sed '/^$/d' | wc -l | tr -d ' ')"
  case "$count" in
    0)
      die "no RedisEnterpriseCluster found${NS:+ in namespace $NS}${REC:+ named $REC} on this cluster." \
          "Check 'oc get rec -A', or pass --ns/--rec (or set NS/REC in rec-recover.env)."
      ;;
    1)
      NS="$(printf '%s' "$recs" | cut -f1)"
      REC="$(printf '%s' "$recs" | cut -f2)"
      log "auto-detected target: ns=$NS rec=$REC (state=$(printf '%s' "$recs" | cut -f3), nodes=$(printf '%s' "$recs" | cut -f4))"
      ;;
    *)
      if [ -t 0 ]; then
        _choose_rec "$recs"
      else
        die "$count RedisEnterpriseClusters found; pass --ns/--rec to choose one:" \
            "$(printf '%s\n' "$recs" | awk -F'\t' '{printf " [%s/%s state=%s]", $1, $2, $3}')"
      fi
      ;;
  esac
}

# _choose_rec "<tab-separated rows>"  - interactive numbered selection
_choose_rec() {
  local rows="$1" i=1 line choice
  {
    printf '\n  %sSeveral Redis Enterprise clusters found. Choose the one to work on:%s\n\n' "$C_BOLD" "$C_RESET"
    printf '  %s   %-28s %-28s %-10s %s%s\n' "$C_BOLD" "NAMESPACE" "REC" "STATE" "NODES" "$C_RESET"
    while IFS="$(printf '\t')" read -r ns rec state nodes; do
      printf '  %s%d.%s %-28s %-28s %-10s %s\n' "$C_BOLD" "$i" "$C_RESET" "$ns" "$rec" "$state" "$nodes"
      i=$((i + 1))
    done <<<"$rows"
    printf '\n'
  } >&2
  while :; do
    printf '  Enter number (1-%d) or q to quit: ' "$((i - 1))" >&2
    read -r choice
    case "$choice" in
      q | Q) die "no target selected." ;;
      '' | *[!0-9]*) ;;
      *)
        if [ "$choice" -ge 1 ] && [ "$choice" -lt "$i" ]; then
          line="$(printf '%s\n' "$rows" | sed -n "${choice}p")"
          NS="$(printf '%s' "$line" | cut -f1)"
          REC="$(printf '%s' "$line" | cut -f2)"
          log "selected target: ns=$NS rec=$REC"
          return 0
        fi
        ;;
    esac
  done
}

rec_json() { ocn get rec "$REC" -o json 2>/dev/null; }

# rec_field '.spec.nodes'  - one REC field via jsonpath (empty when missing)
rec_field() {
  ocn get rec "$REC" -o jsonpath="{$1}" 2>/dev/null
}

# StatefulSet pods are named <rec>-<ordinal>; select by name so labels do not matter.
# Output: one line per pod "<name>\t<phase>\t<ready True|False|>\t<deletionTimestamp|>"
rec_pods_table() {
  ocn get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\t"}{.metadata.deletionTimestamp}{"\n"}{end}' 2>/dev/null \
    | awk -F'\t' -v re="^${REC}-[0-9]+$" '$1 ~ re'
}

rec_pod_names() {
  local names
  names="$(rec_pods_table | cut -f1)"
  if [ -n "$names" ]; then
    echo "$names"
    return
  fi
  # Fallback to StatefulSet naming when no pods exist yet.
  local count i
  count="$(rec_field '.spec.nodes')"
  count="${count:-3}"
  i=0
  while [ "$i" -lt "$count" ]; do
    echo "${REC}-${i}"
    i=$((i + 1))
  done
}

# pod_exec <pod> <command...>  - exec in the Redis Enterprise container
pod_exec() {
  local pod="$1"
  shift
  ocn exec "$pod" -c "$REDIS_CONTAINER" --request-timeout=60s -- "$@"
}

# pod_exec_stdin <pod> <command...>  - same, forwarding our stdin to the command (oc exec -i);
# used to send file content into the pod.
pod_exec_stdin() {
  local pod="$1"
  shift
  ocn exec -i "$pod" -c "$REDIS_CONTAINER" --request-timeout=60s -- "$@"
}

# Sets REACHABLE_POD to the first pod where exec works; returns 1 if none.
first_reachable_pod() {
  local p
  REACHABLE_POD=""
  for p in $(rec_pod_names); do
    if pod_exec "$p" true >/dev/null 2>&1; then
      REACHABLE_POD="$p"
      return 0
    fi
  done
  return 1
}

reachable_pods() {
  local p
  for p in $(rec_pod_names); do
    pod_exec "$p" true >/dev/null 2>&1 && echo "$p"
  done
}

# -----------------------------------------------------------------------------
# Confirmation gate (the only thing standing between you and a cluster change)
# -----------------------------------------------------------------------------

# confirm <what> [line...]  - prints the lines, then requires the cluster name to be typed.
# --yes (ASSUME_YES=true) skips the prompt. Without a terminal and without --yes, it dies.
confirm() {
  local what="$1"
  shift
  {
    printf '\n%s%s%s\n' "$C_ORANGE" "$(_repeat "$(_cols)" "$S_BAR")" "$C_RESET"
    printf '  %s%sCONFIRMATION REQUIRED: %s%s\n' "$C_ORANGE" "$C_BOLD" "$what" "$C_RESET"
    local l
    for l in "$@"; do printf '  %s\n' "$l"; done
    printf '%s%s%s\n' "$C_ORANGE" "$(_repeat "$(_cols)" "$S_BAR")" "$C_RESET"
  } >&2
  if [ "$ASSUME_YES" = "true" ]; then
    log "confirmation skipped with --yes: $what"
    return 0
  fi
  if [ ! -t 0 ]; then
    die "$what needs a confirmation. Run from a terminal, or pass --yes for unattended runs."
  fi
  local answer
  printf '  Type the cluster name (%s%s%s) to continue, anything else to abort: ' "$C_BOLD" "$REC" "$C_RESET" >&2
  read -r answer
  if [ "$answer" != "$REC" ]; then
    die "aborted by user at confirmation: $what"
  fi
  log "confirmed by user: $what"
}

# ask_yes_no <question>  - returns 0 for yes, 1 for no. Dies without a terminal (callers handle --yes first).
ask_yes_no() {
  local answer
  [ -t 0 ] || die "a decision is needed for: $1  (run from a terminal, or set AA_MODE / AA_DATA_BEARING / AA_CONFIG_ONLY in rec-recover.env and use --yes)"
  while :; do
    printf '  %s [y/n]: ' "$1" >&2
    read -r answer
    case "$answer" in
      y | Y | yes | YES) return 0 ;;
      n | N | no | NO)   return 1 ;;
    esac
  done
}

# -----------------------------------------------------------------------------
# Misc
# -----------------------------------------------------------------------------

# csv_contains "<a,b,c>" "<item>"
csv_contains() {
  local IFS=','
  local x
  for x in $1; do
    [ "$x" = "$2" ] && return 0
  done
  return 1
}

quorum_of() { echo $(($1 / 2 + 1)); }

# human_size <bytes>  -> e.g. 1.5 GiB (integer maths only, bash 3.2 safe)
human_size() {
  local b="${1:-0}" unit=B
  local units="KiB MiB GiB TiB"
  local whole="$b" frac=0
  for unit2 in $units; do
    [ "$whole" -ge 1024 ] || break
    frac=$(( (whole % 1024) * 10 / 1024 ))
    whole=$((whole / 1024))
    unit="$unit2"
  done
  if [ "$unit" = "B" ]; then printf '%d B' "$whole"; else printf '%d.%d %s' "$whole" "$frac" "$unit"; fi
}

# free_bytes <directory>  -> free space on the filesystem holding <directory>
free_bytes() {
  local kb
  kb="$(df -Pk "$1" 2>/dev/null | awk 'NR == 2 { print $4 }')"
  echo $(( ${kb:-0} * 1024 ))
}
