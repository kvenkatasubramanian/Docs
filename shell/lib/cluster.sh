#!/usr/bin/env bash
# =============================================================================
# cluster.sh - runbook steps 6, 7 and 8
#
#   preserve_pod_files      save PRESERVE_FILES (e.g. /etc/opt/redislabs/trusted_ca.pem) from every
#                           reachable pod before the rebuild
#   phase_recover_cluster   patch spec.clusterRecovery=true, wait for Running AND the flag being
#                           cleared by the operator, wait for pods (MUTATING). While waiting, puts the
#                           preserved files into any pod that comes up, because the first-pod recovery
#                           needs trusted_ca.pem and otherwise stalls in RecoveringFirstPod.
#   phase_validate_cluster  rladmin status, all nodes OK, no running actions
#   restore_pod_files       put the preserved files back where the rebuild changed them, then
#                           `supervisorctl restart all` and verify the other nodes picked them up
#   switch_master           rladmin cluster master set <another node>
# =============================================================================

# -----------------------------------------------------------------------------
# Files that the rebuild overwrites (default: /etc/opt/redislabs/trusted_ca.pem)
# -----------------------------------------------------------------------------
PRESERVE_DIR="${PRESERVE_DIR:-$ARTIFACT_DIR/preserved}"

# _pod_file_exists <pod> <path>
_pod_file_exists() {
  pod_exec "$1" sh -c 'test -f "$0"' "$2" >/dev/null 2>&1
}

# _pod_file_sha <pod> <path>  -> sha256 of the file inside the pod, empty if missing
_pod_file_sha() {
  pod_exec "$1" sh -c 'test -f "$0" && sha256sum "$0" | cut -d" " -f1' "$2" 2>/dev/null || true
}

# _preserve_targets  -> pods to save from / restore to, according to PRESERVE_SCOPE
#   master: the current master pod (falls back to the first reachable pod when the cluster cannot say)
#   all:    every reachable pod
_preserve_targets() {
  local m
  if [ "$PRESERVE_SCOPE" = "all" ]; then
    reachable_pods
    return
  fi
  RL_POD=""
  m="$(master_pod 2>/dev/null || true)"
  if [ -n "$m" ]; then
    echo "$m"
  else
    reachable_pods | head -1
  fi
}

# preserve_pod_files  - for every PRESERVE_FILES entry on the target pod(s):
#   1. check whether the file exists; 2. if it does, save it (content, owner, group, mode, checksum)
#   to $PRESERVE_DIR/<pod>/<path>. Files that do not exist are noted and skipped.
preserve_pod_files() {
  local P=preserve
  [ -n "$PRESERVE_FILES" ] || return 0
  local pods pod f dest meta n=0
  pods="$(_preserve_targets)"
  if [ -z "$pods" ]; then
    report_add $P targets WARN "no reachable pod to preserve files from"
    return 0
  fi
  if [ "$PRESERVE_SCOPE" = "all" ]; then
    report_add $P targets INFO "scope=all: saving from $(echo "$pods" | tr '\n' ' ')"
  elif [ -n "$(rl_master_node_id 2>/dev/null)" ]; then
    report_add $P targets INFO "scope=master: saving from the master node's pod $pods"
  else
    report_add $P targets WARN "scope=master but the cluster cannot report its master (expected when quorum is lost); saving from $pods"
  fi

  for pod in $pods; do
    for f in $PRESERVE_FILES; do
      dest="$PRESERVE_DIR/$pod$f"
      if ! _pod_file_exists "$pod" "$f"; then
        report_add $P "$pod$f" INFO "does not exist on $pod before the rebuild; nothing to preserve"
        continue
      fi
      mkdir -p "$(dirname "$dest")"
      if pod_exec "$pod" sh -c 'cat "$0"' "$f" >"$dest" 2>/dev/null && [ -s "$dest" ]; then
        meta="$(pod_exec "$pod" sh -c 'stat -c "%a %U %G" "$0"' "$f" 2>/dev/null || echo "644 redislabs redislabs")"
        printf '%s\n' "$meta" >"$dest.meta"
        _pod_file_sha "$pod" "$f" >"$dest.sha256"
        n=$((n + 1))
        report_add $P "$pod$f" PASS "exists; saved ($(wc -c <"$dest" | tr -d ' ') bytes, $meta)"
      else
        rm -f "$dest"
        report_add $P "$pod$f" WARN "exists on $pod but could not be read; it will not be restored"
      fi
    done
  done
  [ "$n" -gt 0 ] && report_add $P summary INFO "$n file(s) saved under $PRESERVE_DIR"
  return 0
}

# _saved_copy <file>  -> path of any saved copy of <file> (whichever pod it came from), empty if none
_saved_copy() {
  ls "$PRESERVE_DIR"/*"$1" 2>/dev/null | grep -v '\.after-rebuild$' | head -1 || true
}

# restore_pod_files  - after the rebuild, for every preserved file on the target pod(s):
#   1. check whether the file exists now and compare it with the saved copy
#   2. exists and identical  -> leave it alone
#      exists but different  -> keep the rebuilt version as <path>.after-rebuild, write the saved copy back
#      missing               -> write the saved copy back
#   3. supervisorctl restart all on each node where something was written (one node at a time)
#   4. scope=master: wait for the other pods to pick the file up and report whether they did
restore_pod_files() {
  local P=restore
  [ -n "$PRESERVE_FILES" ] || return 0
  [ -d "$PRESERVE_DIR" ] || { report_add $P skip INFO "nothing was preserved before the rebuild"; return 0; }

  local pods pod f src meta mode owner group now_sha saved_sha changed restored_any=0 reason
  RL_POD=""
  pods="$(_preserve_targets)"
  [ "$PRESERVE_SCOPE" = "all" ] || report_add $P targets INFO "scope=master: restoring on the current master pod $pods; other nodes sync from it"

  for pod in $pods; do
    changed=0
    for f in $PRESERVE_FILES; do
      src="$(_saved_copy "$f")"
      if [ ! -s "$src" ]; then
        report_add $P "$pod$f" INFO "did not exist before the rebuild; not created"
        continue
      fi

      if _pod_file_exists "$pod" "$f"; then
        now_sha="$(_pod_file_sha "$pod" "$f")"
        saved_sha="$(cat "$src.sha256" 2>/dev/null || true)"
        if [ -n "$saved_sha" ] && [ "$now_sha" = "$saved_sha" ]; then
          report_add $P "$pod$f" PASS "exists and is unchanged by the rebuild"
          continue
        fi
        reason="exists but the content changed; rebuilt version kept as $(basename "$f").after-rebuild"
        mkdir -p "$PRESERVE_DIR/$pod$(dirname "$f")"
        pod_exec "$pod" sh -c 'cat "$0"' "$f" >"$PRESERVE_DIR/$pod$f.after-rebuild" 2>/dev/null || true
      else
        reason="missing after the rebuild"
      fi

      meta="$(cat "$src.meta" 2>/dev/null || echo "644 redislabs redislabs")"
      mode="${meta%% *}"; owner="$(echo "$meta" | awk '{print $2}')"; group="$(echo "$meta" | awk '{print $3}')"
      if pod_exec "$pod" sh -c 'mkdir -p "$(dirname "$0")" && cat >"$0" && chmod "$1" "$0" && chown "$2:$3" "$0"' \
           "$f" "$mode" "$owner" "$group" <"$src" >>"$LOG_FILE" 2>&1; then
        report_add $P "$pod$f" PASS "restored on $pod ($reason)"
        changed=1
      else
        report_add $P "$pod$f" FAIL "could not write $f on $pod (see $LOG_FILE)"
      fi
    done

    if [ "$changed" -eq 1 ] && [ "$RESTART_AFTER_RESTORE" = "true" ]; then
      restored_any=1
      log "restarting Redis Enterprise services on $pod (supervisorctl restart all)"
      if pod_exec "$pod" supervisorctl restart all >>"$LOG_FILE" 2>&1; then
        _wait_node_ok "$pod" \
          && report_add $P "$pod-restart" PASS "services restarted, node OK" \
          || report_add $P "$pod-restart" WARN "services restarted but node not OK within ${TIMEOUT_POD}s; check rladmin status"
      else
        report_add $P "$pod-restart" FAIL "supervisorctl restart all failed on $pod"
      fi
    fi
  done

  if [ "$restored_any" -eq 0 ]; then
    report_add $P summary INFO "no restart needed; preserved files were intact after the rebuild"
  elif [ "$PRESERVE_SCOPE" != "all" ]; then
    _verify_file_sync "$pods"
  fi
  return 0
}

# _verify_file_sync <master pod>  - wait until every other pod has the same file content as the saved copy
_verify_file_sync() {
  local P=restore master="$1" f src saved_sha deadline pod pending
  for f in $PRESERVE_FILES; do
    src="$(_saved_copy "$f")"
    [ -s "$src" ] || continue
    saved_sha="$(cat "$src.sha256" 2>/dev/null || true)"
    [ -n "$saved_sha" ] || continue
    deadline=$(($(date +%s) + TIMEOUT_POD))
    while :; do
      pending=""
      for pod in $(rec_pod_names); do
        [ "$pod" = "$master" ] && continue
        [ "$(_pod_file_sha "$pod" "$f")" = "$saved_sha" ] || pending="$pending $pod"
      done
      [ -z "$pending" ] && break
      [ "$(date +%s)" -lt "$deadline" ] || break
      sleep "$POLL_INTERVAL"
    done
    if [ -z "$pending" ]; then
      report_add $P "sync$f" PASS "all pods now carry the preserved $f"
    else
      report_add $P "sync$f" WARN \
        "$f did not reach:$pending within ${TIMEOUT_POD}s. If it should be identical on every node, re-run with PRESERVE_SCOPE=all in rec-recover.env."
    fi
  done
}

# switch_master  - move the cluster master away from the current node (rladmin cluster master set <id>)
switch_master() {
  local P=master
  [ "$SWITCH_MASTER" = "true" ] || { report_add $P skip INFO "SWITCH_MASTER=false; master left as is"; return 0; }
  RL_POD=""
  local current target ids
  current="$(rl_master_node_id)"
  if [ -z "$current" ]; then
    report_add $P current WARN "cannot determine the current master node; master not switched"
    return 0
  fi
  if [ -n "$NEW_MASTER_NODE" ]; then
    target="$NEW_MASTER_NODE"
  else
    # lowest healthy node id that is not the current master
    target="$(rl_status_nodes | awk -F'|' -v cur="node:$current" '$4 == "OK" && $1 != cur { sub(/^node:/, "", $1); print $1 }' | sort -n | head -1)"
  fi
  if [ -z "$target" ] || [ "$target" = "$current" ]; then
    report_add $P target WARN "no other healthy node to promote (current master node:$current); master not switched"
    return 0
  fi
  log "switching cluster master from node:$current to node:$target (rladmin cluster master set $target)"
  if ! rl cluster master set "$target" >>"$LOG_FILE" 2>&1; then
    report_add $P set FAIL "rladmin cluster master set $target failed (see $LOG_FILE)"
    return 1
  fi
  local deadline now
  deadline=$(($(date +%s) + 120))
  while :; do
    now="$(rl_master_node_id)"
    [ "$now" = "$target" ] && break
    [ "$(date +%s)" -lt "$deadline" ] || break
    sleep "$POLL_INTERVAL"
  done
  if [ "$now" = "$target" ]; then
    report_add $P set PASS "cluster master is now node:$target (pod $(pod_for_node "$target" || echo '?')), was node:$current"
  else
    report_add $P set WARN "requested master node:$target but rladmin still reports node:${now:-?}; check 'rladmin status nodes'"
  fi
}

# _place_files_during_rebuild  - called on every poll while the REC is not yet Running.
# The operator recovers the first pod with `rladmin cluster recover`, which needs trusted_ca.pem in
# place; without it the REC sits in RecoveringFirstPod. So as soon as a pod can be exec'd, compare the
# preserved file with what is there and write it back if missing or different. No service restart here:
# the operator is driving the rebuild. Pods may be recreated several times, hence the re-check each poll.
_place_files_during_rebuild() {
  local P=recover-cluster pod f src saved_sha now_sha meta mode owner group
  [ -n "$PRESERVE_FILES" ] && [ -d "$PRESERVE_DIR" ] || return 0
  for pod in $(rec_pod_names); do
    pod_exec "$pod" true >/dev/null 2>&1 || continue
    for f in $PRESERVE_FILES; do
      src="$(_saved_copy "$f")"
      [ -s "$src" ] || continue
      saved_sha="$(cat "$src.sha256" 2>/dev/null || true)"
      now_sha="$(_pod_file_sha "$pod" "$f")"
      [ -n "$saved_sha" ] && [ "$now_sha" = "$saved_sha" ] && continue
      meta="$(cat "$src.meta" 2>/dev/null || echo "644 redislabs redislabs")"
      mode="${meta%% *}"; owner="$(echo "$meta" | awk '{print $2}')"; group="$(echo "$meta" | awk '{print $3}')"
      if pod_exec "$pod" sh -c 'mkdir -p "$(dirname "$0")" && cat >"$0" && chmod "$1" "$0" && chown "$2:$3" "$0"' \
           "$f" "$mode" "$owner" "$group" <"$src" >>"$LOG_FILE" 2>&1; then
        report_add $P "$pod$f" PASS \
          "placed during the rebuild ($([ -z "$now_sha" ] && echo 'file was missing' || echo 'content differed')) so the operator can continue"
      else
        report_add $P "$pod$f" WARN "could not place $f on $pod during the rebuild (pod may be restarting); will retry on the next poll"
      fi
    done
  done
}

# _wait_node_ok <pod>  - wait until rladmin status shows every node OK again (after a service restart)
_wait_node_ok() {
  local deadline bad
  deadline=$(($(date +%s) + TIMEOUT_POD))
  RL_POD=""
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if rl_select_pod >/dev/null 2>&1; then
      bad="$(rl_status_nodes | awk -F'|' '$4 != "OK"')"
      [ -z "$bad" ] && [ -n "$(rl_status_nodes)" ] && return 0
    fi
    sleep "$POLL_INTERVAL"
  done
  return 1
}

# phase_recover_cluster [skip-precheck]
#   Re-runs the precheck (unless 'all' just did), then asks for confirmation before patching.
phase_recover_cluster() {
  local P=recover-cluster

  if [ "${1:-}" != "skip-precheck" ]; then
    phase_precheck || die "precheck is BLOCKED; cluster recovery refused."
  fi

  phase_banner "RECOVER CLUSTER" \
    "Steps 6-7 - patch clusterRecovery=true, wait for Running + flag cleared, pods Ready  (CHANGES THE CLUSTER)"

  case "$PRECHECK_VERDICT" in
    RECOVERY_RECOMMENDED)
      confirm "rebuild cluster $REC in namespace $NS" \
        "Precheck verdict: ${C_ORANGE}${C_BOLD}RECOVERY_RECOMMENDED${C_RESET}" \
        "The operator will recreate the Redis Enterprise pods and restore the cluster from the CCS on the PVCs." \
        "Make sure the backup from '$0 backup' has been copied off the cluster." ;;
    RECOVERY_NOT_NEEDED)
      confirm "rebuild cluster $REC in namespace $NS although the precheck says it is HEALTHY" \
        "Precheck verdict: ${C_GREEN}${C_BOLD}RECOVERY_NOT_NEEDED${C_RESET}" \
        "${C_RED}A recovery on a healthy cluster causes an unnecessary outage.${C_RESET}" \
        "Continue only if you are certain quorum is lost and the operator cannot heal it." ;;
    *)
      die "precheck verdict is $PRECHECK_VERDICT; cluster recovery refused." ;;
  esac

  local nodes
  nodes="$(rec_field '.spec.nodes')"
  nodes="${nodes:-3}"

  # --- Save files the rebuild is known to overwrite -------------------------------------
  preserve_pod_files

  # --- Step 6: patch -----------------------------------------------------------
  log "patching rec/$REC spec.clusterRecovery=true"
  if ocn patch rec "$REC" --type merge --patch '{"spec":{"clusterRecovery":true}}' >>"$LOG_FILE" 2>&1; then
    report_add $P patch PASS "spec.clusterRecovery=true applied at $(_ts)"
  else
    report_add $P patch FAIL "oc patch failed (see $LOG_FILE)"
    return 1
  fi

  # --- Step 7a: REC state -> Running and flag cleared -------------------------------
  local deadline state flag last="" seen=""
  deadline=$(($(date +%s) + TIMEOUT_REC))

  while :; do
    state="$(rec_field '.status.state')"
    flag="$(rec_field '.spec.clusterRecovery')"
    state="${state:-unknown}"
    flag="${flag:-false}"

    if [ "$state|$flag" != "$last" ]; then
      log "REC state=$state clusterRecovery=$flag"
      last="$state|$flag"
      case " $seen " in
        *" $state "*) ;;
        *) seen="$seen $state" ;;
      esac
    fi

    if [ "$state" = "Running" ] && [ "$flag" != "true" ]; then
      break
    fi
    _place_files_during_rebuild
    if [ "$(date +%s)" -ge "$deadline" ]; then
      report_add $P rec-state FAIL \
        "timed out after ${TIMEOUT_REC}s; last state=$state flag=$flag; states seen:$seen"
      return 1
    fi
    sleep "$POLL_INTERVAL"
  done
  report_add $P rec-state PASS "REC Running and clusterRecovery cleared; states seen:$seen"

  # --- Step 7b: pods Ready -------------------------------------------------------
  local i=0 pod
  while [ "$i" -lt "$nodes" ]; do
    pod="${REC}-${i}"
    if ocn wait "pod/$pod" --for=condition=Ready --timeout="${TIMEOUT_POD}s" >>"$LOG_FILE" 2>&1; then
      report_add $P "pod-$pod" PASS "Ready"
    else
      report_add $P "pod-$pod" FAIL "not Ready within ${TIMEOUT_POD}s"
      return 1
    fi
    i=$((i + 1))
  done

  RL_POD="" # pods were recreated; re-select
  phase_validate_cluster || return 1

  # --- Put preserved files back and restart services where needed ----------------------
  restore_pod_files

  # --- Move the cluster master to another node -------------------------------------------
  switch_master
}

# Step 8
phase_validate_cluster() {
  local P=validate-cluster ok=0
  phase_banner "VALIDATE CLUSTER" "Step 8 - rladmin status, nodes OK, running actions"

  if ! rl_select_pod; then
    report_add $P rladmin FAIL "no reachable pod after recovery"
    return 1
  fi
  if ! rl status >"$ARTIFACT_DIR/post-rladmin-status.txt" 2>&1; then
    report_add $P rladmin FAIL "rladmin status failed after recovery"
    return 1
  fi
  rl status extra all >"$ARTIFACT_DIR/post-rladmin-status-extra.txt" 2>&1 || true

  local bad
  bad="$(rl_status_nodes | awk -F'|' '$4 != "OK" { print $1 "=" $4 }')"
  if [ -n "$bad" ]; then
    report_add $P nodes FAIL "nodes not OK: $(echo "$bad" | tr '\n' ' ')"
    ok=1
  else
    report_add $P nodes PASS "all cluster nodes OK: $(rl_status_nodes | cut -d'|' -f1 | tr '\n' ' ')"
  fi

  local ra
  ra="$(rl cluster running_actions 2>&1 || true)"
  printf '%s\n' "$ra" >"$ARTIFACT_DIR/post-running-actions.txt"
  if printf '%s' "$ra" | grep -qiE 'no running actions|^\s*$'; then
    report_add $P running-actions PASS "no unresolved cluster actions"
  else
    report_add $P running-actions WARN \
      "cluster actions in progress: $(printf '%s' "$ra" | tr '\n' ' ' | cut -c1-200)"
  fi

  return $ok
}
