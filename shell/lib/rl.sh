#!/usr/bin/env bash
# =============================================================================
# rl.sh - rladmin / REST / crdb-cli wrappers executed inside a Redis Enterprise pod
#
# Every command is wrapped in coreutils `timeout` INSIDE the container so a
# quorum-less cluster cannot hang the automation. Sourced after common.sh.
# =============================================================================

RL_POD="${RL_POD:-}" # pod used for cluster-wide commands; set by rl_select_pod

# -----------------------------------------------------------------------------
# Pod selection and exec wrappers
# -----------------------------------------------------------------------------
rl_select_pod() {
  if [ -n "$RL_POD" ] && pod_exec "$RL_POD" true >/dev/null 2>&1; then
    return 0
  fi
  first_reachable_pod || return 1
  RL_POD="$REACHABLE_POD"
  log "using pod $RL_POD for rladmin/REST commands"
}

# _ct <seconds> <command...>  - run with in-container timeout (no timeout if coreutils is missing)
_ct() {
  local secs="$1"
  shift
  pod_exec "$RL_POD" bash -c \
    'if command -v timeout >/dev/null 2>&1; then exec timeout "$0" "$@"; else shift 0; exec "$@"; fi' \
    "$secs" "$@"
}

# rl <rladmin args...>       (RL_TIMEOUT)
rl() {
  rl_select_pod || return 1
  _ct "$RL_TIMEOUT" rladmin "$@"
}

# rl_long <rladmin args...>  (RL_RECOVER_TIMEOUT, for rladmin recover db)
rl_long() {
  rl_select_pod || return 1
  _ct "$RL_RECOVER_TIMEOUT" rladmin "$@"
}

# -----------------------------------------------------------------------------
# REST API (https://localhost:9443) using the REC admin secret
# -----------------------------------------------------------------------------

# _rec_cred username|password
_rec_cred() {
  ocn get secret "$REC" -o jsonpath="{.data.$1}" 2>/dev/null | base64 -d 2>/dev/null
}

# rest_get </v1/path>  - raw JSON on stdout, non-zero on failure
rest_get() {
  rl_select_pod || return 1
  local u p
  u="$(_rec_cred username)"
  p="$(_rec_cred password)"
  if [ -z "$u" ] || [ -z "$p" ]; then
    log_warn "REC secret $REC has no username/password; REST calls unavailable"
    return 1
  fi
  pod_exec "$RL_POD" env "RL_U=$u" "RL_P=$p" bash -c \
    'command -v timeout >/dev/null 2>&1 && T="timeout 20" || T=""; $T curl -sS -k -f -u "$RL_U:$RL_P" "https://localhost:9443$0"' \
    "$1"
}

# rest_query </v1/path> <jq filter> <python expression>
# Fetches the JSON inside the pod and parses it THERE with whatever is available (jq, then
# python3 / Redis Enterprise's bundled python), so the workstation needs no JSON tool.
# The python expression receives the parsed document as `d` and must evaluate to a list of strings.
# Returns 1 when the pod has no parser; callers fall back to other sources.
rest_query() {
  rl_select_pod || return 1
  local u p
  u="$(_rec_cred username)"
  p="$(_rec_cred password)"
  [ -n "$u" ] && [ -n "$p" ] || return 1
  pod_exec "$RL_POD" env "RL_U=$u" "RL_P=$p" "JQF=$2" "PYE=$3" bash -c '
    command -v timeout >/dev/null 2>&1 && T="timeout 20" || T=""
    doc="$($T curl -sS -k -f -u "$RL_U:$RL_P" "https://localhost:9443$0")" || exit 2
    if command -v jq >/dev/null 2>&1; then
      printf "%s" "$doc" | jq -r "$JQF"
    else
      for py in python3 /opt/redislabs/bin/python3 /opt/redislabs/bin/python python; do
        if command -v "$py" >/dev/null 2>&1 || [ -x "$py" ]; then
          printf "%s" "$doc" | "$py" -c "import sys, json; d = json.load(sys.stdin); [print(x) for x in ($PYE)]"
          exit $?
        fi
      done
      exit 1
    fi' "$1" 2>/dev/null
}

# -----------------------------------------------------------------------------
# Output parsers  (columns are located by header name where it matters)
# -----------------------------------------------------------------------------

# rl_recover_list  -> lines "<db:id>|<name>|<type>|<status>"  (status: ready|missing-files)
# Empty output with rc 0 means "No recoverable databases found" (rladmin exits 1 for that).
rl_recover_list() {
  local out rc=0
  out="$(rl recover list 2>&1)" || rc=$?
  out="$(printf '%s\n' "$out" | grep -v '^command terminated with exit code')"

  if printf '%s' "$out" | grep -qi 'No recoverable databases found'; then
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    log_warn "rladmin recover list failed: $(printf '%s' "$out" | tail -1)"
    return 1
  fi

  printf '%s\n' "$out" | awk '
    /^DATABASES IN RECOVERY STATE/ { next }
    $1 == "DB:ID" { hdr = 1; for (i = 1; i <= NF; i++) col[$i] = i; next }
    hdr && $1 ~ /^db:[0-9]+$/ {
      status = ("STATUS" in col) ? $(col["STATUS"]) : $NF
      printf "%s|%s|%s|%s\n", $1, $2, $3, status
    }'
}

# rl_status_nodes  -> lines "<node:id>|<role>|<address>|<status>"  (STATUS is the last column;
# the leading * on a row means "this is the node rladmin runs on", not the master, so it is stripped)
rl_status_nodes() {
  rl status nodes 2>/dev/null | awk '
    /^NODE:ID/ { hdr = 1; next }
    hdr && $1 ~ /^\*?node:[0-9]+$/ {
      id = $1; sub(/^\*/, "", id)
      printf "%s|%s|%s|%s\n", id, $2, $3, $NF
    }'
}

# rl_master_node_id  -> numeric id of the current master node, empty if unknown.
# Uses the ROLE column (master|slave). The leading * only marks the node rladmin is running on.
rl_master_node_id() {
  rl_status_nodes | awk -F'|' '$2 == "master" { sub(/^node:/, "", $1); print $1; exit }'
}

# rl_node_address <id>  -> internal address of a node
rl_node_address() {
  rl_status_nodes | awk -F'|' -v id="node:$1" '$1 == id { print $3; exit }'
}

# pod_for_node <id>  -> pod whose podIP matches the node's address, empty if not found
pod_for_node() {
  local addr
  addr="$(rl_node_address "$1")"
  [ -n "$addr" ] || return 1
  ocn get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.podIP}{"\n"}{end}' 2>/dev/null \
    | awk -F'\t' -v a="$addr" -v re="^${REC}-[0-9]+$" '$2 == a && $1 ~ re { print $1; exit }'
}

# master_pod  -> pod name of the current master node, empty if the cluster cannot tell us
master_pod() {
  local id
  id="$(rl_master_node_id)"
  [ -n "$id" ] || return 1
  pod_for_node "$id"
}

# rl_status_databases  -> lines "<db:id>|<name>|<type>|<status>"
# Newer versions insert a MODULE column before STATUS, so STATUS is found by header.
rl_status_databases() {
  rl status databases 2>/dev/null | awk '
    $1 == "DB:ID" { hdr = 1; for (i = 1; i <= NF; i++) col[$i] = i; next }
    hdr && $1 ~ /^db:[0-9]+$/ {
      status = ("STATUS" in col) ? $(col["STATUS"]) : $4
      printf "%s|%s|%s|%s\n", $1, $2, $3, status
    }'
}

# crdb_names  -> Active-Active database names on this cluster (best effort, three sources)
#   1. REST /v1/bdbs with crdt == true (parsed inside the pod)
#   2. crdb-cli crdb list
#   3. REAADB custom resources
crdb_names() {
  local names=""

  names="$(rest_query /v1/bdbs \
             '.[] | select(.crdt==true) | .name' \
             '[b["name"] for b in d if b.get("crdt")]' 2>/dev/null || true)"
  if [ -z "$names" ] && rl_select_pod; then
    names="$(_ct 20 crdb-cli crdb list 2>/dev/null | awk 'NR > 1 && NF >= 2 { print $2 }')"
  fi
  if [ -z "$names" ]; then
    names="$(ocn get reaadb -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n')"
  fi

  printf '%s\n' "$names" | sed '/^$/d' | sort -u
}

# module_duplicates  -> lines "<module>: <v1>,<v2>" for modules loaded in more than one version
# (parsed inside the pod). Returns 1 when REST or the in-pod parser is unavailable.
module_duplicates() {
  rest_query /v1/modules \
    'group_by(.module_name) | map(select(length > 1)) | .[] | "\(.[0].module_name): \([.[].semantic_version] | join(","))"' \
    '["%s: %s" % (n, ",".join(m["semantic_version"] for m in d if m["module_name"] == n)) for n in sorted({m["module_name"] for m in d}) if sum(1 for m in d if m["module_name"] == n) > 1]'
}
