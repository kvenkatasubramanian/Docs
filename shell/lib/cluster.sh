#!/usr/bin/env bash
# =============================================================================
# cluster.sh - runbook steps 6, 7 and 8
#
#   require_ca_cert_file    recover-cluster / all: the customer CA certificate (O1_G2_Certificate.pem) must be
#                           on the workstation before anything runs
#   ensure_trusted_ca       append the certificate to /etc/opt/redislabs/trusted_ca.pem in the pods where it
#                           is not already present: on every poll while the REC rebuilds, as the pods come
#                           up (the first-pod recovery needs the certificate and otherwise sits in
#                           RecoveringFirstPod), and once more after the rebuild on every pod
#   phase_recover_cluster   patch spec.clusterRecovery=true, wait for Running AND the flag being
#                           cleared by the operator, wait for pods (MUTATING)
#   phase_validate_cluster  rladmin status, all nodes OK, no running actions
#   (every append is followed at once by `supervisorctl restart all` on that pod)
#   switch_master           rladmin cluster master set <another node>
# =============================================================================

# -----------------------------------------------------------------------------
# Customer CA certificate -> appended to TRUSTED_CA_PATH in every pod
# -----------------------------------------------------------------------------
TRUSTED_CA_DIR="${TRUSTED_CA_DIR:-$ARTIFACT_DIR/trusted_ca}"
CA_CERT_PATH=""              # resolved by require_ca_cert_file
CA_CERT_BODY=""              # the certificate with CR/LF removed; used for the "already present" test
TRUSTED_CA_CHANGED_PODS=""   # pods where the certificate was appended (and services restarted)
TRUSTED_CA_MISSING_PODS=""   # pods still without trusted_ca.pem during the rebuild (for the timeout message)

# _pod_file_exists <pod> <path>
_pod_file_exists() {
  pod_exec "$1" sh -c 'test -f "$0"' "$2" >/dev/null 2>&1
}

# require_ca_cert_file  - find CA_CERT_FILE in the current directory, then next to the script. Dies if absent.
require_ca_cert_file() {
  local f="$CA_CERT_FILE" candidate
  case "$f" in
    /*) [ -f "$f" ] && CA_CERT_PATH="$f" ;;
    *)
      for candidate in "$PWD/$f" "$SCRIPT_ROOT/$f"; do
        if [ -f "$candidate" ]; then CA_CERT_PATH="$candidate"; break; fi
      done ;;
  esac
  if [ -z "$CA_CERT_PATH" ]; then
    die "$f not found in $PWD or next to the script in $SCRIPT_ROOT. recover-cluster and all need the customer CA certificate to complete $TRUSTED_CA_PATH in the pods. Place the file there and retry."
  fi
  if ! grep -q -- '-----BEGIN CERTIFICATE-----' "$CA_CERT_PATH"; then
    die "$CA_CERT_PATH does not look like a PEM certificate (no BEGIN CERTIFICATE line)."
  fi
  mkdir -p "$TRUSTED_CA_DIR"
  CA_CERT_BODY="$TRUSTED_CA_DIR/cert.body"
  tr -d '\r\n' <"$CA_CERT_PATH" >"$CA_CERT_BODY"
  log "customer CA certificate: $CA_CERT_PATH ($(wc -c <"$CA_CERT_PATH" | tr -d ' ') bytes); appended to $TRUSTED_CA_PATH in every pod where it is not already present"
}

# _pod_has_cert <pod>  -> 0 if the pod's trusted_ca.pem already contains the certificate (line endings ignored)
_pod_has_cert() {
  pod_exec_stdin "$1" sh -c 'body=$(cat); test -f "$0" && tr -d "\r\n" <"$0" | grep -qF -- "$body"' \
    "$TRUSTED_CA_PATH" <"$CA_CERT_BODY" >/dev/null 2>&1
}

# _append_cert_to_pod <pod> <phase-label> <mode>
#   Keeps a copy of the file as it was (trusted_ca/<pod>.before.<mode>), appends the certificate at the
#   bottom (adding a newline first if the file lacks one), keeps owner and mode, verifies the result.
_append_cert_to_pod() {
  local pod="$1" P="$2" mode="$3" meta fmode owner group
  pod_exec "$pod" sh -c 'cat "$0"' "$TRUSTED_CA_PATH" >"$TRUSTED_CA_DIR/$pod.before.$mode" 2>/dev/null || true
  meta="$(pod_exec "$pod" sh -c 'stat -c "%a %U %G" "$0"' "$TRUSTED_CA_PATH" 2>/dev/null || echo "644 redislabs redislabs")"
  fmode="${meta%% *}"; owner="$(echo "$meta" | awk '{print $2}')"; group="$(echo "$meta" | awk '{print $3}')"
  if pod_exec_stdin "$pod" sh -c '[ -z "$(tail -c1 "$0")" ] || echo >>"$0"; cat >>"$0" && { [ -z "$(tail -c1 "$0")" ] || echo >>"$0"; } && chmod "$1" "$0" && chown "$2:$3" "$0"' \
       "$TRUSTED_CA_PATH" "$fmode" "$owner" "$group" <"$CA_CERT_PATH" >>"$LOG_FILE" 2>&1 \
     && _pod_has_cert "$pod"; then
    pod_exec "$pod" sh -c 'cat "$0"' "$TRUSTED_CA_PATH" >"$TRUSTED_CA_DIR/$pod.after.$mode" 2>/dev/null || true
    case "$mode" in
      during) report_add "$P" "$pod" PASS "$(basename "$CA_CERT_PATH") appended to $TRUSTED_CA_PATH during the rebuild so the operator can continue" ;;
      *)      report_add "$P" "$pod" PASS "$(basename "$CA_CERT_PATH") appended to $TRUSTED_CA_PATH" ;;
    esac
    TRUSTED_CA_CHANGED_PODS="$TRUSTED_CA_CHANGED_PODS $pod"
    _restart_pod_services "$pod" "$P" "$mode"
    return 0
  fi
  if [ "$mode" = during ]; then
    report_add "$P" "$pod" WARN "could not append the certificate on $pod during the rebuild (pod may be restarting); retrying on the next poll"
  else
    report_add "$P" "$pod" FAIL "could not append the certificate to $TRUSTED_CA_PATH on $pod (see $LOG_FILE)"
  fi
  return 1
}

# ensure_trusted_ca <during|post>  - for every pod of the REC:
#   pod unreachable          during: skip (not up yet)                               post: FAIL
#   trusted_ca.pem missing   during: skip, retry next poll (operator has not written it)  post: FAIL (nothing to append to; the script stops)
#   certificate present      during: silent                                          post: PASS
#   otherwise                append the certificate, then `supervisorctl restart all` on that pod
# Returns 1 when anything failed in post. During the rebuild nothing is fatal.
ensure_trusted_ca() {
  local mode="$1" P pod rc=0 appended=0 present=0
  case "$mode" in
    during) P=recover-cluster ;;
    post)   P=trusted-ca-after ;;
  esac
  TRUSTED_CA_MISSING_PODS=""
  [ "$mode" = post ] && TRUSTED_CA_CHANGED_PODS=""

  for pod in $(rec_pod_names); do
    if ! pod_exec "$pod" true >/dev/null 2>&1; then
      [ "$mode" = post ] && { report_add $P "$pod" FAIL "not reachable after the rebuild"; rc=1; }
      continue
    fi
    if ! _pod_file_exists "$pod" "$TRUSTED_CA_PATH"; then
      if [ "$mode" = during ]; then
        TRUSTED_CA_MISSING_PODS="$TRUSTED_CA_MISSING_PODS $pod"
      else
        report_add $P "$pod" FAIL "$TRUSTED_CA_PATH is missing on $pod; there is nothing to append the certificate to. Restore the file in the pod and re-run."
        rc=1
      fi
      continue
    fi
    if _pod_has_cert "$pod"; then
      [ "$mode" = during ] || report_add $P "$pod" PASS "$TRUSTED_CA_PATH already contains the certificate"
      present=$((present + 1))
      continue
    fi
    if _append_cert_to_pod "$pod" "$P" "$mode"; then
      appended=$((appended + 1))
    else
      [ "$mode" = during ] || rc=1
    fi
  done

  if [ "$mode" != during ]; then
    if [ "$appended" -gt 0 ]; then
      report_add $P summary INFO "certificate appended and services restarted on $appended pod(s), already present on $present; copies under $TRUSTED_CA_DIR"
    else
      report_add $P summary INFO "every pod already carries the certificate; no restart needed"
    fi
  fi
  return $rc
}

# _restart_pod_services <pod> <phase-label> <mode>  - `supervisorctl restart all` right after the certificate
# was appended on that pod, so the services load the new trusted_ca.pem at once. After the rebuild (post) the
# script also waits until every node reports OK again before moving on; during the rebuild it does not wait,
# because the cluster is not formed yet and the operator keeps driving the recovery.
_restart_pod_services() {
  local pod="$1" P="$2" mode="$3"
  if [ "$RESTART_AFTER_RESTORE" != "true" ]; then
    report_add "$P" "$pod-restart" WARN "RESTART_AFTER_RESTORE=false; services on $pod not restarted. The new certificate is picked up at the next restart."
    return 0
  fi
  log "restarting Redis Enterprise services on $pod (supervisorctl restart all)"
  if ! pod_exec "$pod" supervisorctl restart all >>"$LOG_FILE" 2>&1; then
    report_add "$P" "$pod-restart" FAIL "supervisorctl restart all failed on $pod (see $LOG_FILE)"
    return 1
  fi
  if [ "$mode" = during ]; then
    report_add "$P" "$pod-restart" PASS "services restarted on $pod right after the append"
  elif _wait_node_ok "$pod"; then
    report_add "$P" "$pod-restart" PASS "services restarted on $pod, all nodes OK"
  else
    report_add "$P" "$pod-restart" WARN "services restarted on $pod but nodes not all OK within ${TIMEOUT_POD}s; check rladmin status"
  fi
  return 0
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
    "Steps 6-7 - patch clusterRecovery=true, append the certificate to trusted_ca.pem as pods come up, wait for Running + flag cleared, pods Ready  (CHANGES THE CLUSTER)"

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
    ensure_trusted_ca during
    if [ "$(date +%s)" -ge "$deadline" ]; then
      report_add $P rec-state FAIL \
        "timed out after ${TIMEOUT_REC}s; last state=$state flag=$flag; states seen:$seen${TRUSTED_CA_MISSING_PODS:+; $TRUSTED_CA_PATH never appeared on:$TRUSTED_CA_MISSING_PODS}"
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

  # --- Certificate into trusted_ca.pem on every pod after the rebuild (append + restart where missing) ---
  ensure_trusted_ca post || return 1

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
