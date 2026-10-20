#!/usr/bin/env bash
# =============================================================================
# cluster.sh - runbook steps 6, 7 and 8
#
#   phase_recover_cluster   patch spec.clusterRecovery=true, wait for Running AND
#                           the flag being cleared by the operator, wait for pods  (MUTATING)
#   phase_validate_cluster  rladmin status, all nodes OK, no running actions
# =============================================================================

phase_recover_cluster() {
  local P=recover-cluster
  phase_banner "RECOVER CLUSTER" \
    "Steps 6-7 - patch clusterRecovery=true, wait for Running + flag cleared, pods Ready  (MUTATING)"
  require_approval "recover-cluster"

  local nodes
  nodes="$(rec_field '.spec.nodes')"
  nodes="${nodes:-3}"

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
  phase_validate_cluster
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
