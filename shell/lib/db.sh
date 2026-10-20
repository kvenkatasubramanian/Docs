#!/usr/bin/env bash
# =============================================================================
# db.sh - runbook steps 9 to 12
#
#   phase_plan_db     rladmin recover list -> classify standard vs Active-Active (CRDB),
#                     apply --recovery-path, print the exact commands           (read-only)
#   phase_recover_db  one `rladmin recover db` per database, in this order:
#                     data-bearing CRDBs -> standard DBs -> config-only CRDBs    (MUTATING)
#
# `rladmin recover all` is never used because CRDBs and standard DBs coexist.
# =============================================================================

# print_db_plan <plan.tsv>  - coloured table on stderr (the tsv stays plain)
print_db_plan() {
  local plan="$1"
  local id name kind status action col
  {
    printf '\n  %s%-7s %-24s %-9s %-14s %s%s\n' "$C_BOLD" "DB" "NAME" "KIND" "STATUS" "ACTION" "$C_RESET"
    printf '  %s%s%s\n' "$C_DIM" "$(_repeat $(($(_cols) - 2)) "$S_BAR")" "$C_RESET"
    while IFS="$(printf '\t')" read -r id name kind status action; do
      [ -n "$id" ] || continue
      case "$action" in
        BLOCKED:* | UNDECIDED*) col="$C_RED" ;;
        *only_configuration*)   col="$C_ORANGE" ;;
        *)                      col="$C_GREEN" ;;
      esac
      printf '  %-7s %-24s %-9s %s%-14s%s %s%s%s\n' \
        "$id" "$name" "$kind" "$col" "$status" "$C_RESET" "$col" "$action" "$C_RESET"
    done <"$plan"
    printf '  %splan saved: %s%s\n\n' "$C_DIM" "$plan" "$C_RESET"
  } >&2
}

# Writes $ARTIFACT_DIR/db-plan.tsv:  <db:id> <name> <kind> <status> <action>
# Returns 0 only when every database is ready and every CRDB has a decision.
phase_plan_db() {
  local P=plan-db
  phase_banner "DATABASE PLAN" "Steps 10, 12 - rladmin recover list, standard vs Active-Active classification"

  local plan="$ARTIFACT_DIR/db-plan.tsv"
  : >"$plan"

  # --- Step 10 (optional): map the recovery path on every node ------------------
  if [ -n "$RECOVERY_PATH" ]; then
    if [ "$EXECUTE" = "true" ]; then
      local nid
      for nid in $(rl_status_nodes | cut -d'|' -f1 | sed 's/node://'); do
        if rl node "$nid" recovery_path set "$RECOVERY_PATH" >>"$LOG_FILE" 2>&1; then
          report_add $P "recovery-path-node-$nid" PASS "recovery_path=$RECOVERY_PATH"
        else
          report_add $P "recovery-path-node-$nid" FAIL "rladmin node $nid recovery_path set failed"
          return 1
        fi
      done
    else
      report_add $P recovery-path INFO \
        "would run: rladmin node <id> recovery_path set $RECOVERY_PATH on every node (needs --execute)"
    fi
  fi

  # --- rladmin recover list ------------------------------------------------------
  if ! rl_select_pod; then
    report_add $P rladmin FAIL "no reachable pod"
    return 1
  fi
  local list
  list="$(rl_recover_list)" || return 1
  if [ -z "$list" ]; then
    report_add $P recover-list INFO "No recoverable databases found (nothing in recovery state)"
    return 0
  fi
  printf '%s\n' "$list" >"$ARTIFACT_DIR/recover-list.txt"

  local crdbs
  crdbs="$(crdb_names)"
  if [ -n "$crdbs" ]; then
    report_add $P crdb-inventory INFO "Active-Active DBs on this cluster: $(echo "$crdbs" | tr '\n' ' ')"
  fi

  # --- Classify every database ------------------------------------------------------
  local id name type status kind action missing=0 undecided=""
  while IFS='|' read -r id name type status; do
    [ -n "$id" ] || continue

    if printf '%s\n' "$crdbs" | grep -qx "$name"; then
      kind=crdb
    else
      kind=standard
    fi

    if [ "$status" != "ready" ]; then
      action="BLOCKED:$status"
      missing=1
    elif [ "$kind" = "standard" ]; then
      action="rladmin recover db $name"
    elif csv_contains "$AA_DATA_BEARING" "$name"; then
      action="rladmin recover db $name            # CRDB: WITH data (sole data-bearing instance)"
    elif csv_contains "$AA_CONFIG_ONLY" "$name"; then
      action="rladmin recover db $name only_configuration   # CRDB: config only, data syncs from live peers"
    else
      action="UNDECIDED: pass --aa-data-bearing $name OR --aa-config-only $name"
      undecided="$undecided $name"
    fi

    printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$name" "$kind" "$status" "$action" >>"$plan"
  done <<<"$list"

  print_db_plan "$plan"

  if [ "$missing" -eq 1 ]; then
    report_add $P recover-list FAIL \
      "databases report missing-files. Fix before recovery: (1) recovery path set correctly on ALL nodes (--recovery-path)," \
      "(2) files present under $PERSIST_ROOT/$DB_PERSIST_DIR, (3) owner redislabs:redislabs mode 640, (4) files not corrupted."
  fi
  if [ -n "$undecided" ]; then
    report_add $P active-active FAIL \
      "undecided CRDB(s):$undecided. Rule: if other participating clusters are live -> --aa-config-only;" \
      "if ALL participants are down -> exactly ONE instance across all clusters gets --aa-data-bearing, every other instance config-only."
  fi

  [ "$missing" -eq 0 ] && [ -z "$undecided" ]
}

phase_recover_db() {
  local P=recover-db
  phase_banner "RECOVER DATABASES" \
    "Steps 11-12 - per-database rladmin recover (data-bearing CRDBs -> standard -> config-only CRDBs)  (MUTATING)"
  require_approval "recover-db"

  phase_plan_db || die "database plan is not executable; see findings above."

  local plan="$ARTIFACT_DIR/db-plan.tsv"
  if [ ! -s "$plan" ]; then
    report_add $P recover INFO "nothing to recover"
    return 0
  fi

  local n_crdb
  n_crdb="$(awk -F'\t' '$3 == "crdb"' "$plan" | wc -l | tr -d ' ')"
  if [ "$n_crdb" -gt 0 ]; then
    report_add $P policy INFO "CRDBs present: 'rladmin recover all' will NOT be used; recovering per database."
  fi

  # --- Recover in three passes --------------------------------------------------------
  local pass id name kind status action out rc=0
  for pass in data-crdb standard config-crdb; do
    while IFS="$(printf '\t')" read -r id name kind status action; do
      case "$pass" in
        data-crdb)   { [ "$kind" = "crdb" ] && csv_contains "$AA_DATA_BEARING" "$name"; } || continue ;;
        standard)    [ "$kind" = "standard" ] || continue ;;
        config-crdb) { [ "$kind" = "crdb" ] && csv_contains "$AA_CONFIG_ONLY" "$name"; } || continue ;;
      esac

      log "recovering $name ($id, $kind, pass=$pass)"
      if [ "$pass" = "config-crdb" ]; then
        out="$(rl_long recover db "$name" only_configuration 2>&1)"
      else
        out="$(rl_long recover db "$name" 2>&1)"
      fi
      printf '%s\n' "$out" >>"$ARTIFACT_DIR/recover-output.txt"

      if printf '%s' "$out" | grep -q 'Completed successfully' \
           && ! printf '%s' "$out" | grep -qE '\| [1-9][0-9]* failed'; then
        report_add $P "db-$name" PASS "recovered ($pass)"
      else
        report_add $P "db-$name" FAIL "recovery failed: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"
        rc=1
      fi
    done <"$plan"
  done

  # --- Nothing should remain in recovery state ----------------------------------------
  local remaining
  remaining="$(rl_recover_list || true)"
  if [ -z "$remaining" ]; then
    report_add $P recover-list PASS "No recoverable databases remain in recovery state"
  else
    report_add $P recover-list WARN "still in recovery state: $(printf '%s' "$remaining" | tr '\n' ' ')"
    rc=1
  fi

  return $rc
}
