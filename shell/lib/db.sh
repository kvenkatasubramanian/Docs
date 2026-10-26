#!/usr/bin/env bash
# =============================================================================
# db.sh - runbook steps 9 to 12
#
#   phase_recover_db  rladmin recover list -> classify standard vs Active-Active (CRDB)
#                     -> decide per CRDB (data or configuration-only) -> confirm
#                     -> one `rladmin recover db` per database, in this order:
#                        data-bearing CRDBs, standard DBs, configuration-only CRDBs
#
# `rladmin recover all` is never used because CRDBs and standard DBs coexist.
# Active-Active rule (Redis docs): if other participating clusters are live, recover the
# local instance configuration-only and let it sync; if ALL participants were down, exactly
# one instance in the whole deployment is recovered with data, every other one config-only.
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
        BLOCKED:*)             col="$C_RED" ;;
        *only_configuration*)  col="$C_ORANGE" ;;
        *)                     col="$C_GREEN" ;;
      esac
      printf '  %-7s %-24s %-9s %s%-14s%s %s%s%s\n' \
        "$id" "$name" "$kind" "$col" "$status" "$C_RESET" "$col" "$action" "$C_RESET"
    done <"$plan"
    printf '  %splan saved: %s%s\n\n' "$C_DIM" "$plan" "$C_RESET"
  } >&2
}

# decide_crdb <name>  -> prints "data" or "config-only"
#   1. explicit lists in rec-recover.env (AA_DATA_BEARING / AA_CONFIG_ONLY)
#   2. --yes: AA_MODE default
#   3. interactive question
decide_crdb() {
  local name="$1"
  if csv_contains "$AA_DATA_BEARING" "$name"; then echo data; return; fi
  if csv_contains "$AA_CONFIG_ONLY" "$name"; then echo config-only; return; fi
  if [ "$ASSUME_YES" = "true" ]; then
    case "$AA_MODE" in
      data) echo data ;;
      *)    echo config-only ;;
    esac
    return
  fi
  {
    printf '\n  %sActive-Active database %s%s%s\n' "$C_BOLD" "$C_ORANGE" "$name" "$C_RESET"
    printf '  Are the OTHER participating clusters of this database up and serving right now?\n'
    printf '  %syes%s -> recover configuration only here; data syncs back from the live peers (recommended).\n' "$C_BOLD" "$C_RESET"
    printf '  %sno%s  -> ALL participants were down; recover THIS instance with its data. Do this on ONE cluster only.\n' "$C_BOLD" "$C_RESET"
  } >&2
  if ask_yes_no "peers live for $name?"; then echo config-only; else echo data; fi
}

phase_recover_db() {
  local P=recover-db
  phase_banner "RECOVER DATABASES" \
    "Steps 9-12 - rladmin recover list, per-database decisions, one rladmin recover db each  (CHANGES THE CLUSTER)"

  local plan="$ARTIFACT_DIR/db-plan.tsv"
  : >"$plan"

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
    report_add $P recover-list INFO "No recoverable databases found (nothing in recovery state)"
    return 0
  fi
  printf '%s\n' "$list" >"$ARTIFACT_DIR/recover-list.txt"

  local crdbs
  crdbs="$(crdb_names)"
  if [ -n "$crdbs" ]; then
    report_add $P crdb-inventory INFO "Active-Active DBs on this cluster: $(echo "$crdbs" | tr '\n' ' ')"
  fi

  # --- Classify and decide ------------------------------------------------------------
  local id name type status kind action missing=0 decision
  while IFS='|' read -r id name type status; do
    [ -n "$id" ] || continue

    if printf '%s\n' "$crdbs" | grep -qx "$name"; then kind=crdb; else kind=standard; fi

    if [ "$status" != "ready" ]; then
      action="BLOCKED:$status"
      missing=1
    elif [ "$kind" = "standard" ]; then
      action="rladmin recover db $name"
    else
      decision="$(decide_crdb "$name")"
      if [ "$decision" = "data" ]; then
        action="rladmin recover db $name            # Active-Active: WITH data (the one data-bearing instance)"
      else
        action="rladmin recover db $name only_configuration   # Active-Active: config only, data syncs from peers"
      fi
      [ "$ASSUME_YES" = "true" ] && ! csv_contains "$AA_DATA_BEARING$AA_CONFIG_ONLY" "$name" \
        && report_add $P "aa-$name" WARN "Active-Active decision taken from AA_MODE=$AA_MODE (--yes, no explicit list)"
    fi

    printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$name" "$kind" "$status" "$action" >>"$plan"
  done <<<"$list"

  print_db_plan "$plan"

  if [ "$missing" -eq 1 ]; then
    report_add $P recover-list FAIL \
      "databases report missing-files. Fix before recovery: (1) files present under $PERSIST_ROOT/$DB_PERSIST_DIR on the nodes," \
      "(2) owner redislabs:redislabs mode 640, (3) files not corrupted, (4) set RECOVERY_PATH in rec-recover.env if they live elsewhere."
    return 1
  fi

  # --- Confirm, then recover in three passes -----------------------------------------
  local n_total n_crdb
  n_total="$(grep -c . "$plan")"
  n_crdb="$(awk -F'\t' '$3 == "crdb"' "$plan" | wc -l | tr -d ' ')"
  confirm "recover $n_total database(s) on $REC ($n_crdb Active-Active)" \
    "Each database is recovered with its own 'rladmin recover db' in the order shown above:" \
    "data-bearing Active-Active first, then standard databases, then configuration-only Active-Active."

  local pass out rc=0
  for pass in data-crdb standard config-crdb; do
    while IFS="$(printf '\t')" read -r id name kind status action; do
      case "$pass" in
        data-crdb)   { [ "$kind" = "crdb" ] && [[ "$action" != *only_configuration* ]]; } || continue ;;
        standard)    [ "$kind" = "standard" ] || continue ;;
        config-crdb) { [ "$kind" = "crdb" ] && [[ "$action" == *only_configuration* ]]; } || continue ;;
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
