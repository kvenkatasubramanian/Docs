#!/usr/bin/env bash
# =============================================================================
# precheck.sh - runbook steps 1, 2 and 4 (read-only)
#
# Produces a verdict (also stored in PRECHECK_VERDICT for the other phases):
#   RECOVERY_NOT_NEEDED   cluster healthy; do not trigger clusterRecovery
#   RECOVERY_RECOMMENDED  quorum loss / unhealthy cluster
#   BLOCKED               a prerequisite is missing; fix before any recovery
#
# All cluster objects are read with `oc -o jsonpath`; no jq on the workstation.
PRECHECK_VERDICT="${PRECHECK_VERDICT:-}"
# =============================================================================

phase_precheck() {
  local P=precheck
  local blocked=0 recommend=0
  phase_banner "PRECHECK" \
    "Steps 1, 2, 4 - REC, persistence, PVCs, nodes, operator, pods, rladmin, modules, Active-Active inventory (read-only)"

  # --- REC exists --------------------------------------------------------------
  if ! ocn get rec "$REC" >/dev/null 2>&1; then
    report_add $P rec-exists FAIL \
      "REC $REC not found in $NS. Recreate it from the original manifest (same name, version, persistence," \
      "storageClass, nodes, credentials) BEFORE patching clusterRecovery. This script will not recreate it."
    PRECHECK_VERDICT=BLOCKED
    return 1
  fi

  # Reference manifest for manual recreation: yaml with status and managedFields removed
  # (oc prints top-level keys alphabetically, so `status:` is the last block).
  ocn get rec "$REC" -o yaml 2>/dev/null \
    | awk '
        /^status:/ { exit }
        /^  managedFields:/ { skip = 1; next }
        skip && /^  [^ ]/ { skip = 0 }
        skip { next }
        /^  (resourceVersion|uid|generation|creationTimestamp):/ { next }
        { print }' >"$ARTIFACT_DIR/rec-spec.yaml"
  report_add $P rec-manifest INFO "REC spec saved to $ARTIFACT_DIR/rec-spec.yaml (use if REC must be recreated)"

  # --- REC facts ---------------------------------------------------------------
  local rec_uid state nodes version persist sc cr_flag
  rec_uid="$(rec_field .metadata.uid)"
  state="$(rec_field .status.state)";                          state="${state:-unknown}"
  nodes="$(rec_field .spec.nodes)";                            nodes="${nodes:-3}"
  version="$(rec_field .spec.redisEnterpriseImageSpec.versionTag)"; version="${version:-default}"
  persist="$(rec_field .spec.persistentSpec.enabled)";         persist="${persist:-false}"
  sc="$(rec_field .spec.persistentSpec.storageClassName)";     sc="${sc:-(default)}"
  cr_flag="$(rec_field .spec.clusterRecovery)";                cr_flag="${cr_flag:-false}"

  report_add $P rec-state INFO \
    "status.state=$state nodes=$nodes versionTag=$version storageClass=$sc clusterRecovery=$cr_flag"

  if [ "$persist" = "true" ]; then
    report_add $P persistence PASS "spec.persistentSpec.enabled=true"
  else
    report_add $P persistence FAIL "spec.persistentSpec.enabled is not true. Cluster recovery is impossible without persistence."
    blocked=1
  fi
  if [ "$cr_flag" = "true" ]; then
    report_add $P recovery-flag WARN "spec.clusterRecovery is already true; a recovery may be in progress."
  fi
  [ "$state" = "Running" ] || recommend=1

  # --- PVCs  (name <TAB> phase <TAB> volumeName) ----------------------------------
  local pvcs pvc_count notbound
  pvcs="$(ocn get pvc -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\t"}{.spec.volumeName}{"\n"}{end}' 2>/dev/null \
    | awk -F'\t' -v r="$REC" 'index($1, r) > 0')"
  pvc_count="$(printf '%s\n' "$pvcs" | sed '/^$/d' | wc -l | tr -d ' ')"
  notbound="$(printf '%s\n' "$pvcs" | awk -F'\t' 'NF && $2 != "Bound" { print $1 }')"

  if [ "$pvc_count" -eq 0 ]; then
    report_add $P pvc FAIL "no PVCs matching $REC found; this recovery needs the original persistent volumes."
    blocked=1
  elif [ -n "$notbound" ]; then
    report_add $P pvc FAIL "PVCs not Bound: $(echo "$notbound" | tr '\n' ' ')"
    blocked=1
  else
    report_add $P pvc PASS "$pvc_count PVC(s) Bound"
  fi
  if [ "$pvc_count" -gt 0 ] && [ "$pvc_count" -lt "$nodes" ]; then
    report_add $P pvc WARN "only $pvc_count PVC(s) for $nodes nodes"
  fi

  # --- OpenShift nodes (name <TAB> Ready status) and VolumeAttachments ---------------
  local notready_nodes
  notready_nodes="$(oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null \
    | awk -F'\t' 'NF && $2 != "True" { print $1 }')"

  if [ -n "$notready_nodes" ]; then
    report_add $P ocp-nodes WARN "NotReady nodes: $(echo "$notready_nodes" | tr '\n' ' ')"
  else
    report_add $P ocp-nodes PASS "all OpenShift nodes Ready"
  fi

  local pv_names stale_va=""
  pv_names="$(printf '%s\n' "$pvcs" | awk -F'\t' 'NF && $3 != "" { print $3 }')"
  if [ -n "$pv_names" ] && [ -n "$notready_nodes" ]; then
    # VolumeAttachments: name <TAB> node <TAB> pv ; keep those on a NotReady node for one of our PVs
    stale_va="$(oc get volumeattachment -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.nodeName}{"\t"}{.spec.source.persistentVolumeName}{"\n"}{end}' 2>/dev/null \
      | awk -F'\t' -v pvs="$pv_names" -v nodes="$notready_nodes" '
          BEGIN { n = split(pvs, a, "\n"); for (i = 1; i <= n; i++) P[a[i]] = 1
                  n = split(nodes, b, "\n"); for (i = 1; i <= n; i++) N[b[i]] = 1 }
          NF && ($3 in P) && ($2 in N) { print $1 "@" $2 }')"
  fi

  if [ -n "$stale_va" ]; then
    report_add $P volumeattachment WARN \
      "VolumeAttachments to NotReady nodes may block PVC re-attach: $(echo "$stale_va" | tr '\n' ' ')." \
      "Do not delete blindly; let CSI detach or follow your storage vendor runbook."
  else
    report_add $P volumeattachment PASS "no VolumeAttachment pinned to a NotReady node"
  fi

  # --- Operator ----------------------------------------------------------------
  local op_avail
  op_avail="$(ocn get deploy "$OPERATOR_DEPLOYMENT" -o jsonpath='{.status.availableReplicas}' 2>/dev/null)"
  if [ "${op_avail:-0}" -ge 1 ]; then
    report_add $P operator PASS "deployment/$OPERATOR_DEPLOYMENT available=$op_avail"
  else
    report_add $P operator FAIL "deployment/$OPERATOR_DEPLOYMENT not available; the operator performs the recovery."
    blocked=1
  fi

  # --- Pods  (name <TAB> phase <TAB> ready <TAB> deletionTimestamp) ------------------
  local pods total_pods ready_pods terminating
  pods="$(rec_pods_table)"
  total_pods="$(printf '%s\n' "$pods" | sed '/^$/d' | wc -l | tr -d ' ')"
  ready_pods="$(printf '%s\n' "$pods" | awk -F'\t' 'NF && $2 == "Running" && $3 == "True" { n++ } END { print n + 0 }')"
  terminating="$(printf '%s\n' "$pods" | awk -F'\t' 'NF && $4 != "" { print $1 }')"

  report_add $P pods INFO "REC pods: total=$total_pods ready=$ready_pods quorum_needed=$(quorum_of "$nodes")"
  if [ -n "$terminating" ]; then
    report_add $P pods WARN \
      "pods stuck Terminating: $(echo "$terminating" | tr '\n' ' '). Do NOT force-delete; let the operator reconcile."
  fi
  [ "$ready_pods" -lt "$(quorum_of "$nodes")" ] && recommend=1

  ocn get pods -o yaml >"$ARTIFACT_DIR/pods.yaml" 2>/dev/null || true
  ocn get events --sort-by=.lastTimestamp >"$ARTIFACT_DIR/events.txt" 2>/dev/null || true

  # --- rladmin status (timeout-wrapped; failure counts as evidence FOR recovery) --
  local st bad_nodes
  rl_select_pod || true # select in the parent shell so RL_POD is visible below
  if st="$(rl status 2>&1)"; then
    printf '%s\n' "$st" >"$ARTIFACT_DIR/rladmin-status.txt"
    bad_nodes="$(rl_status_nodes | awk -F'|' '$4 != "OK" { print $1 "=" $4 }')"
    if [ -n "$bad_nodes" ]; then
      report_add $P rladmin-status WARN "rladmin reachable but nodes not OK: $(echo "$bad_nodes" | tr '\n' ' ')"
      recommend=1
    else
      report_add $P rladmin-status PASS "rladmin status OK on $RL_POD"
    fi
    rl status extra all >"$ARTIFACT_DIR/rladmin-status-extra.txt" 2>&1 || true
  else
    report_add $P rladmin-status WARN \
      "rladmin status failed or timed out on all pods (consistent with quorum loss): $(printf '%s' "$st" | tail -1)"
    recommend=1
  fi

  # --- Databases / Active-Active inventory ---------------------------------------
  local kind n_redb n_reaadb reaadb_names
  for kind in redb reaadb rerc; do
    ocn get "$kind" -o yaml >"$ARTIFACT_DIR/$kind.yaml" 2>/dev/null || : >"$ARTIFACT_DIR/$kind.yaml"
  done
  n_redb="$(ocn get redb -o name 2>/dev/null | sed '/^$/d' | wc -l | tr -d ' ')"
  reaadb_names="$(ocn get reaadb -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)"
  n_reaadb="$(printf '%s\n' "$reaadb_names" | tr ' ' '\n' | sed '/^$/d' | wc -l | tr -d ' ')"

  report_add $P db-inventory INFO "REDB=$n_redb REAADB=$n_reaadb (saved to artifacts)"
  if [ "$n_reaadb" -gt 0 ]; then
    report_add $P active-active WARN \
      "Active-Active databases present: $reaadb_names." \
      "'recover-db' runs 'rladmin recover all', which recovers them WITH their data. If their peer clusters are live," \
      "recover those by hand first with 'rladmin recover db <name> only_configuration'."
  fi

  # --- Modules (7.2.4-x limitation on old / manually uploaded modules) -----------
  # Parsed inside the pod (jq or python there); nothing needed on the workstation.
  local dup
  if dup="$(module_duplicates)"; then
    if [ -z "$dup" ]; then
      report_add $P modules PASS "no duplicate module versions detected"
    elif [ "$STRICT_MODULES" = "true" ]; then
      report_add $P modules FAIL "multiple versions of a module loaded (7.2.4 recovery limitation): $(echo "$dup" | tr '\n' ';')"
      blocked=1
    else
      report_add $P modules WARN \
        "multiple module versions loaded; verify none are manually uploaded/old before recovery (7.2.4-x limitation): $(echo "$dup" | tr '\n' ';')"
    fi
  else
    report_add $P modules WARN \
      "could not list modules via REST (cluster down, or no jq/python inside the pod). Review spec.modulesList in $ARTIFACT_DIR/redb.yaml manually."
  fi

  # --- Verdict -------------------------------------------------------------------
  local verdict
  if [ "$blocked" -eq 1 ]; then
    verdict=BLOCKED
  elif [ "$recommend" -eq 1 ]; then
    verdict=RECOVERY_RECOMMENDED
  else
    verdict=RECOVERY_NOT_NEEDED
  fi
  PRECHECK_VERDICT="$verdict"
  report_add $P verdict INFO "VERDICT=$verdict"

  case "$verdict" in
    BLOCKED)
      verdict_box "$verdict" \
        "${C_RED}Resolve the FAIL findings above before any recovery.${C_RESET}"
      ;;
    RECOVERY_NOT_NEEDED)
      verdict_box "$verdict" \
        "${C_GREEN}Cluster appears healthy.${C_RESET} Do not trigger a cluster recovery for single-pod or node faults." \
        "Let the operator reconcile and re-run ${C_BOLD}$0 precheck${C_RESET} in a few minutes."
      ;;
    RECOVERY_RECOMMENDED)
      verdict_box "$verdict" \
        "${C_ORANGE}Quorum loss / unhealthy cluster detected.${C_RESET} Next:" \
        "  ${C_BOLD}$0 backup${C_RESET}            archive CCS + database files, copy them off the cluster" \
        "  ${C_BOLD}$0 recover-cluster${C_RESET}   operator rebuilds the cluster (asks for confirmation)" \
        "  ${C_BOLD}$0 recover-db${C_RESET}        recover every database" \
        "${C_DIM}or run all of them with: $0 all${C_RESET}"
      ;;
  esac

  [ "$verdict" != "BLOCKED" ]
}
