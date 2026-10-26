#!/usr/bin/env bash
# =============================================================================
# db.sh - runbook steps 9 to 13
#
#   phase_recover_db  rladmin recover list -> show what will be recovered -> confirm
#                     -> rladmin recover all (every "[... recovery] Initiated/Completed" line rladmin prints
#                        is logged per database, for later investigation)
#                     -> wait until nothing is left in recovery state
#                     -> rladmin status databases: one row per recovered database, every one must be active
#
# Active-Active note: `rladmin recover all` recovers every instance WITH its data. The Redis docs
# recommend configuration-only recovery for an Active-Active instance whose peer clusters are still
# live (`rladmin recover db <name> only_configuration`, the data then syncs back from the peers).
# If that applies to you, recover those databases by hand first and re-run this command for the rest.
# =============================================================================

# _print_recover_list <plan.tsv>  - coloured table on stderr (the tsv stays plain)
_print_recover_list() {
  local plan="$1" id name kind status col
  {
    printf '\n  %s%-7s %-24s %-14s %s%s\n' "$C_BOLD" "DB" "NAME" "KIND" "STATUS" "$C_RESET"
    printf '  %s%s%s\n' "$C_DIM" "$(_repeat $(($(_cols) - 2)) "$S_BAR")" "$C_RESET"
    while IFS="$(printf '\t')" read -r id name kind status; do
      [ -n "$id" ] || continue
      case "$status" in
        ready) col="$C_GREEN" ;;
        *)     col="$C_RED" ;;
      esac
      printf '  %-7s %-24s %-14s %s%s%s\n' "$id" "$name" "$kind" "$col" "$status" "$C_RESET"
    done <"$plan"
    printf '  %slist saved: %s%s\n\n' "$C_DIM" "$plan" "$C_RESET"
  } >&2
}

RECOVER_DB_NAMES=""   # names from `rladmin recover list`, for the per-database status rows afterwards

# _wait_databases_active  - poll until `rladmin recover list` is empty and every database in
# `rladmin status databases` is active, or RL_RECOVER_TIMEOUT runs out. Then one row per recovered
# database with its final status, and a summary.
_wait_databases_active() {
  local P=recover-db deadline remaining statuses bad total start name st
  start="$(date +%s)"
  deadline=$((start + RL_RECOVER_TIMEOUT))
  while :; do
    remaining="$(rl_recover_list 2>/dev/null || true)"
    statuses="$(rl_status_databases)"
    bad="$(printf '%s\n' "$statuses" | awk -F'|' 'NF >= 4 && $4 != "active" { print $2 "=" $4 }')"
    if [ -z "$remaining" ] && [ -n "$statuses" ] && [ -z "$bad" ]; then
      break
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      break
    fi
    log "waiting: $(printf '%s\n' "$remaining" | grep -c . | tr -d ' ') database(s) still in recovery state, not active: ${bad:-none}"
    sleep "$POLL_INTERVAL"
  done

  printf '%s\n' "$statuses" >"$ARTIFACT_DIR/post-db-status.txt"
  rl status databases >"$ARTIFACT_DIR/post-rladmin-status-databases.txt" 2>&1 || true

  local rc=0
  if [ -z "$remaining" ]; then
    report_add $P recover-list PASS "nothing left in recovery state ($(( $(date +%s) - start ))s)"
  else
    report_add $P recover-list FAIL "still in recovery state after ${RL_RECOVER_TIMEOUT}s: $(printf '%s' "$remaining" | cut -d'|' -f2 | tr '\n' ' ')"
    rc=1
  fi
  # one row per database that was in recovery state
  for name in $RECOVER_DB_NAMES; do
    st="$(printf '%s\n' "$statuses" | awk -F'|' -v n="$name" '$2 == n { print $4; exit }')"
    case "$st" in
      active) report_add $P "db-$name" PASS "active" ;;
      "")     report_add $P "db-$name" FAIL "not listed by rladmin status databases"; rc=1 ;;
      *)      report_add $P "db-$name" FAIL "status $st"; rc=1 ;;
    esac
  done
  total="$(printf '%s\n' "$statuses" | grep -c . | tr -d ' ')"
  if [ -z "$statuses" ]; then
    report_add $P db-status FAIL "rladmin status databases returned nothing; check the cluster by hand"
    rc=1
  elif [ -n "$bad" ]; then
    report_add $P db-status FAIL "databases not active: $(printf '%s' "$bad" | tr '\n' ' ')"
    rc=1
  else
    report_add $P db-status PASS "all $total database(s) active: $(printf '%s\n' "$statuses" | cut -d'|' -f2 | tr '\n' ' ')"
  fi
  return $rc
}

phase_recover_db() {
  local P=recover-db
  phase_banner "RECOVER DATABASES" \
    "Steps 9-13 - rladmin recover list, rladmin recover all, wait, rladmin status databases  (CHANGES THE CLUSTER)"

  # --- Step 10 (optional): map the recovery path on every node ------------------
  if [ -n "$RECOVERY_PATH" ]; then
    local nid
    for nid in $(rl_status_nodes | cut -d'|' -f1 | sed 's/node://'); do
      if rl node "$nid" recovery_path set "$RECOVERY_PATH" >>"$LOG_FILE" 2>&1; then
        report_add $P "recovery-path-node-$nid" PASS "recovery_path=$RECOVERY_PATH"
      else
        report_add $P "recovery-path-node-$nid" FAIL "rladmin node $nid recovery_path set failed"
        return 1
      fi
    done
  fi

  # --- rladmin recover list ------------------------------------------------------
  if ! rl_select_pod; then
    report_add $P rladmin FAIL "no reachable pod"
    return 1
  fi
  local list
  list="$(rl_recover_list)" || return 1
  if [ -z "$list" ]; then
    report_add $P recover-list INFO "No recoverable databases found (nothing in recovery state); checking database status only"
    _wait_databases_active
    return
  fi
  printf '%s\n' "$list" >"$ARTIFACT_DIR/recover-list.txt"

  local crdbs
  crdbs="$(crdb_names)"

  # --- Show what will be recovered -------------------------------------------------------
  local plan="$ARTIFACT_DIR/db-plan.tsv" id name type status kind missing=0 n_total n_crdb=0
  : >"$plan"
  while IFS='|' read -r id name type status; do
    [ -n "$id" ] || continue
    if printf '%s\n' "$crdbs" | grep -qx "$name"; then kind=active-active; n_crdb=$((n_crdb + 1)); else kind=standard; fi
    [ "$status" = "ready" ] || missing=1
    printf '%s\t%s\t%s\t%s\n' "$id" "$name" "$kind" "$status" >>"$plan"
    RECOVER_DB_NAMES="$RECOVER_DB_NAMES $name"
  done <<<"$list"
  n_total="$(grep -c . "$plan")"
  _print_recover_list "$plan"

  if [ "$missing" -eq 1 ]; then
    report_add $P recover-list FAIL \
      "databases report missing-files. Fix before recovery: (1) files present under $PERSIST_ROOT/$DB_PERSIST_DIR on the nodes," \
      "(2) owner redislabs:redislabs mode 640, (3) files not corrupted, (4) set RECOVERY_PATH in rec-recover.env if they live elsewhere."
    return 1
  fi
  if [ "$n_crdb" -gt 0 ]; then
    report_add $P active-active WARN \
      "$n_crdb Active-Active database(s) will be recovered WITH their data by 'rladmin recover all'." \
      "If the other participating clusters of one of them are live, stop here, recover it by hand with" \
      "'rladmin recover db <name> only_configuration', then re-run this command for the rest."
  fi

  # --- Confirm, then rladmin recover all -----------------------------------------------
  confirm "recover $n_total database(s) on $REC with 'rladmin recover all'" \
    "Every database listed above is recovered from its persistence files in one command." \
    "The script then waits until nothing is left in recovery state and every database is active."

  local out rc=0
  log "running rladmin recover all"
  out="$(rl_long recover all 2>&1)" || true
  printf '%s\n' "$out" >"$ARTIFACT_DIR/recover-output.txt"

  # Log every per-database line rladmin printed ("[<name> (db:<id>) recovery] Initiated." / "... Completed ...")
  # so the run log shows which database did what. Full output is in recover-output.txt.
  local line
  while IFS= read -r line; do
    case "$line" in
      *recovery\]*|*\[db:*|*recover*) report_add $P recover-all-output INFO "$(printf '%s' "$line" | sed 's/^ *//')" ;;
    esac
  done <<<"$out"

  if printf '%s' "$out" | grep -q 'Completed successfully' \
       && ! printf '%s' "$out" | grep -qE '\| [1-9][0-9]* failed'; then
    report_add $P recover-all PASS "rladmin recover all: $(printf '%s' "$out" | grep 'Completed' | tail -1 | sed 's/^ *//')"
  else
    report_add $P recover-all FAIL "rladmin recover all did not complete cleanly: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"
    rc=1
  fi

  # --- Wait for the databases, then check their status -------------------------------
  _wait_databases_active || rc=1
  return $rc
}
