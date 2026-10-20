#!/usr/bin/env bash
# =============================================================================
# backup.sh - runbook steps 3 and 5
#
#   phase_diagnostics  log_collector.py (best effort, needs python3 >= 3.11)
#   phase_backup       CCS archive + DB persistence files from every reachable pod,
#                      sha256 manifest under $ARTIFACT_DIR/backup
#
# Both phases are read-only against the cluster.
# =============================================================================

phase_diagnostics() {
  local P=diagnostics
  phase_banner "DIAGNOSTICS" "Step 3 - log_collector.py (best effort)"

  if [ "$SKIP_DIAGNOSTICS" = "true" ]; then
    report_add $P log-collector SKIP "--skip-diagnostics"
    return 0
  fi

  local py pyv
  py="$(python_bin || echo python3)"
  pyv="$("$py" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || echo 0)"
  if [ "$(printf '%s\n' "3.11" "$pyv" | sort -V | head -1)" != "3.11" ]; then
    report_add $P log-collector WARN \
      "python3 >= 3.11 not found (have $pyv); skipping log_collector.py." \
      "Run it manually per https://redis.io/docs/latest/operate/kubernetes/logs/collect-logs/"
    return 0
  fi

  local lc="$ARTIFACT_DIR/log_collector.py"
  if [ -f "$SCRIPT_ROOT/log_collector.py" ]; then
    cp "$SCRIPT_ROOT/log_collector.py" "$lc"
  elif ! curl -sSfL "$LOG_COLLECTOR_URL" -o "$lc" 2>/dev/null; then
    report_add $P log-collector WARN \
      "could not download log_collector.py; place a copy at $SCRIPT_ROOT/log_collector.py to enable"
    return 0
  fi

  mkdir -p "$ARTIFACT_DIR/logs"
  if "$py" -I "$lc" -m all -n "$NS" --k8s_cli oc -o "$ARTIFACT_DIR/logs" \
       >"$ARTIFACT_DIR/log_collector.out" 2>&1; then
    report_add $P log-collector PASS "logs collected to $ARTIFACT_DIR/logs"
  else
    report_add $P log-collector WARN "log_collector.py failed (see $ARTIFACT_DIR/log_collector.out); continuing"
  fi
}

phase_backup() {
  local P=backup
  phase_banner "BACKUP" "Step 5 - CCS archive + DB persistence files from every reachable pod"

  local bdir="$ARTIFACT_DIR/backup"
  local manifest="$bdir/SHA256SUMS"
  mkdir -p "$bdir"
  : >"$manifest"

  # --- Reachability ------------------------------------------------------------
  local pods
  pods="$(reachable_pods)"
  if [ -z "$pods" ]; then
    if [ "$ALLOW_UNBACKED" = "true" ]; then
      report_add $P reachability WARN "no reachable pods; proceeding WITHOUT backup because --allow-unbacked was set"
      return 0
    fi
    report_add $P reachability FAIL \
      "no reachable REC pods; cannot back up CCS/DB files. Re-run with --allow-unbacked to accept the risk."
    return 1
  fi
  report_add $P reachability INFO "reachable pods: $(echo "$pods" | tr '\n' ' ')"

  # --- CCS (once, from the first reachable pod) ---------------------------------
  local p0 ccs_path disc
  p0="$(echo "$pods" | head -1)"
  ccs_path="$PERSIST_ROOT/$CCS_FILE"

  if ! pod_exec "$p0" test -f "$ccs_path" 2>/dev/null; then
    # Fallback: ask ccs-cli where the file is (undocumented tool; best effort).
    disc="$(pod_exec "$p0" bash -c \
      'command -v /opt/redislabs/bin/ccs-cli >/dev/null && /opt/redislabs/bin/ccs-cli CONFIG GET dbfilename | tail -1 | tr -d "\r"' \
      2>/dev/null || true)"
    if [ -n "$disc" ] && pod_exec "$p0" test -f "$disc" 2>/dev/null; then
      ccs_path="$disc"
      report_add $P ccs-path WARN "CCS not at documented path; discovered via ccs-cli: $ccs_path"
    else
      report_add $P ccs FAIL "CCS file not found at $PERSIST_ROOT/$CCS_FILE on $p0"
      return 1
    fi
  fi

  # Best-effort flush; the cluster flushes CCS continuously anyway.
  if pod_exec "$p0" bash -c 'command -v /opt/redislabs/bin/ccs-cli >/dev/null && timeout 20 /opt/redislabs/bin/ccs-cli SAVE' \
       >/dev/null 2>&1; then
    report_add $P ccs-save INFO "ccs-cli SAVE issued on $p0"
  else
    report_add $P ccs-save WARN "ccs-cli SAVE skipped/failed (non-fatal; CCS is flushed continuously by the cluster)"
  fi

  local ccs_dir ccs_parent ccs_tar
  ccs_dir="$(dirname "$ccs_path")"
  ccs_parent="$(dirname "$ccs_dir")"
  ccs_tar="$bdir/ccs-${p0}.tgz"

  if pod_exec "$p0" tar czf - -C "$ccs_parent" "$(basename "$ccs_dir")" >"$ccs_tar" 2>/dev/null \
       && tar tzf "$ccs_tar" 2>/dev/null | grep 'ccs-redis.rdb' >/dev/null; then
    echo "$(sha256_file "$ccs_tar")  $(basename "$ccs_tar")" >>"$manifest"
    report_add $P ccs PASS "CCS archived: $ccs_tar ($(du -h "$ccs_tar" | cut -f1))"
  else
    report_add $P ccs FAIL "CCS archive failed or does not contain ccs-redis.rdb"
    return 1
  fi

  # --- DB persistence files (one archive per reachable pod) ---------------------
  local dbdir p size tarf failed=0
  dbdir="$PERSIST_ROOT/$DB_PERSIST_DIR"
  [ -n "$RECOVERY_PATH" ] && dbdir="$RECOVERY_PATH"

  for p in $pods; do
    if ! pod_exec "$p" test -d "$dbdir" 2>/dev/null; then
      report_add $P "db-files-$p" WARN "$dbdir not present on $p"
      continue
    fi

    size="$(pod_exec "$p" du -sb "$dbdir" 2>/dev/null | awk '{print $1}')"
    size="${size:-0}"
    if [ "$size" -gt "$BACKUP_MAX_BYTES" ]; then
      report_add $P "db-files-$p" WARN \
        "$dbdir on $p is $size bytes (> BACKUP_MAX_BYTES); skipped. Use your backup platform for DB files."
      failed=1
      continue
    fi

    tarf="$bdir/dbfiles-${p}.tgz"
    if pod_exec "$p" tar czf - -C "$(dirname "$dbdir")" "$(basename "$dbdir")" >"$tarf" 2>/dev/null \
         && tar tzf "$tarf" >/dev/null 2>&1; then
      echo "$(sha256_file "$tarf")  $(basename "$tarf")" >>"$manifest"
      report_add $P "db-files-$p" PASS "archived $dbdir from $p -> $tarf ($(du -h "$tarf" | cut -f1))"
    else
      report_add $P "db-files-$p" WARN "archive of $dbdir from $p failed"
      failed=1
    fi
  done

  if [ "$failed" -eq 1 ] && [ "$ALLOW_UNBACKED" != "true" ]; then
    report_add $P db-files FAIL \
      "one or more DB persistence backups failed/skipped. Re-run with --allow-unbacked to proceed anyway."
    return 1
  fi

  report_add $P manifest INFO "sha256 manifest: $manifest. Copy $bdir to storage OUTSIDE the OpenShift cluster now."
}
