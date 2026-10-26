#!/usr/bin/env bash
# =============================================================================
# backup.sh - runbook step 5
#
#   phase_backup  CCS archive + DB persistence files from every reachable pod,
#                 sha256 manifest under $ARTIFACT_DIR/backup. Read-only against the cluster.
# =============================================================================

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
      report_add $P reachability WARN "no reachable pods; proceeding WITHOUT backup because ALLOW_UNBACKED=true"
      return 0
    fi
    report_add $P reachability FAIL \
      "no reachable REC pods; cannot back up CCS/DB files. Set ALLOW_UNBACKED=true in rec-recover.env to accept the risk."
    return 1
  fi
  report_add $P reachability INFO "reachable pods: $(echo "$pods" | tr '\n' ' ')"

  # --- Space estimate before writing anything ---------------------------------------------
  # Sizes are uncompressed (du) and therefore an upper bound; archives are gzip-compressed.
  local p0_est dbdir_est sz ccs_sz total=0 oversized="" line
  p0_est="$(echo "$pods" | head -1)"
  dbdir_est="$PERSIST_ROOT/$DB_PERSIST_DIR"
  [ -n "$RECOVERY_PATH" ] && dbdir_est="$RECOVERY_PATH"
  ccs_sz="$(pod_exec "$p0_est" sh -c 'du -sb "$(dirname "$0")" 2>/dev/null | cut -f1' "$PERSIST_ROOT/$CCS_FILE" 2>/dev/null || echo 0)"
  ccs_sz="${ccs_sz:-0}"
  total=$((total + ccs_sz))
  {
    printf '\n  %sBACKUP SIZE ESTIMATE%s  (uncompressed, upper bound)\n' "$C_BOLD" "$C_RESET"
    printf '  %-28s %12s\n' "CCS ($p0_est)" "$(human_size "$ccs_sz")"
  } >&2
  for line in $pods; do
    sz="$(pod_exec "$line" sh -c 'test -d "$0" && du -sb "$0" | cut -f1' "$dbdir_est" 2>/dev/null || echo 0)"
    sz="${sz:-0}"
    total=$((total + sz))
    if [ "$sz" -gt "$BACKUP_MAX_BYTES" ]; then
      oversized="$oversized $line"
      printf '  %-28s %12s  %s(exceeds BACKUP_MAX_BYTES, will be skipped)%s\n' "DB files ($line)" "$(human_size "$sz")" "$C_ORANGE" "$C_RESET" >&2
    else
      printf '  %-28s %12s\n' "DB files ($line)" "$(human_size "$sz")" >&2
    fi
  done
  local free
  free="$(free_bytes "$bdir")"
  {
    printf '  %s%s%s\n' "$C_DIM" "$(_repeat 42 "$S_BAR")" "$C_RESET"
    printf '  %-28s %12s\n' "Total required (max)" "$(human_size "$total")"
    printf '  %-28s %12s   %s\n\n' "Free where artifacts live" "$(human_size "$free")" "${C_DIM}$ARTIFACT_ROOT${C_RESET}"
  } >&2
  report_add $P space-estimate INFO "backup needs up to $(human_size "$total"); $(human_size "$free") free under $ARTIFACT_ROOT"
  if [ -n "$oversized" ]; then
    report_add $P space-estimate WARN \
      "DB files on$oversized exceed BACKUP_MAX_BYTES ($(human_size "$BACKUP_MAX_BYTES")) and will be skipped; snapshot those PVCs with your storage platform."
  fi
  if [ "$total" -gt "$free" ]; then
    report_add $P space-estimate FAIL \
      "not enough free space: need up to $(human_size "$total"), have $(human_size "$free"). Free space, or point ARTIFACT_ROOT (rec-recover.env) at a bigger disk."
    return 1
  elif [ "$total" -gt $((free * 8 / 10)) ]; then
    report_add $P space-estimate WARN "backup would use more than 80% of the free space under $ARTIFACT_ROOT"
  fi

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
      "one or more DB persistence backups failed/skipped. Set ALLOW_UNBACKED=true in rec-recover.env to proceed anyway."
    return 1
  fi

  report_add $P manifest INFO "sha256 manifest: $manifest. Copy $bdir to storage OUTSIDE the OpenShift cluster now."
}
