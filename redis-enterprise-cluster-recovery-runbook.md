# Redis Enterprise on OpenShift
## Redis Enterprise Cluster Recovery Runbook — Scenarios A and B

> **Scope:** This runbook covers recovery of the Redis Enterprise cluster (REC), persistent volumes, CCS configuration, and databases on OpenShift. Scenario A recovers from existing persistent volumes; Scenario B rebuilds from a CCS backup when the original volumes are unavailable. It does not recover the OpenShift control plane, etcd, worker nodes, or cluster operators.

## 1. Purpose and scope

This runbook describes how to recover a Redis Enterprise cluster managed by the Redis Enterprise Operator on OpenShift when the original cluster configuration is still available on persistent storage.

It covers:

* Quorum loss or simultaneous pod restarts
* Recovery after deletion of the `RedisEnterpriseCluster` resource when PVCs remain
* Recovery after deletion of a PVC when the underlying PV is retained
* Cluster topology and node configuration recovery
* Database definition and configuration recovery
* Database activation in configuration-only mode
* Active-Active (CRDB) database recovery when participating instances use preserved persistent storage
* Recovery validation and troubleshooting

The commands use the OpenShift CLI, `oc`.

### Out of scope

This runbook intentionally excludes:

* OpenShift control-plane or infrastructure recovery
* Restoring database keys or values from AOF/RDB persistence files
* Recovery of databases that depend on incompatible or manually uploaded modules

Database data recovery requires a separate procedure.

## 2. Executive summary

Use Scenario A when the original Redis Enterprise configuration remains on persistent storage. Use Scenario B only when the original volumes are unavailable but a valid off-cluster CCS backup exists.

The recovery flow is:

1. Confirm that the infrastructure, Operator, PVCs, and volumes are healthy.
2. Confirm that the original PVCs are still present and bound.
3. If a retained PV must be reused, re-bind it to the exact original PVC name.
4. Set `spec.clusterRecovery: true` on the `RedisEnterpriseCluster` resource.
5. Allow the Operator to restore the configuration on the first node and rejoin the remaining nodes.
6. For Scenario B, stage the CCS backup on fresh PVCs and create the REC in recovery mode.
7. Activate the recovered databases with `only_configuration` when data recovery is intentionally excluded.

Redis documents this persistent-storage recovery flow for Redis Enterprise on Kubernetes, and the Redis Enterprise Operator supports OpenShift deployments. See [Recover a Redis Enterprise cluster on Kubernetes](https://redis.io/docs/latest/operate/kubernetes/re-clusters/cluster-recovery/).

## 3. Conventions and prerequisites

Replace the following placeholders with values from your environment:

* `<namespace>` — OpenShift namespace
* `<cluster>` — `RedisEnterpriseCluster` resource name
* `<version>` — Redis Enterprise image version tag used by the original cluster
* `<storage-class>` — storage class used by the original cluster
* `<ordinal>` — node ordinal, such as `0`, `1`, or `2`

Run `oc` commands as a cluster administrator unless your environment provides an equivalent role with the required permissions.

### 3.1 Persistence is required

The original cluster must have been deployed with:

```yaml
spec:
  persistentSpec:
    enabled: true
```

When persistence is disabled, the configuration exists only on ephemeral pod storage and is lost when the pod is removed. Confirm this prerequisite before starting recovery.

### 3.2 Version and credential requirements

Use the same Redis Enterprise version and persistence settings as the original cluster. Confirm that the cluster credential secret and administrator credentials remain valid for the recovered cluster.

A version mismatch or invalid credential configuration can prevent recovery from completing. Validate credential behavior against the exact Redis Enterprise and Operator versions deployed in the environment.

### 3.3 Operator and version compatibility

Confirm that:

* The Redis Enterprise Operator is running.
* The Operator supports the Redis Enterprise version being recovered.
* The recovery cluster uses the original `versionTag`.
* The cluster is not affected by a documented module limitation. In particular, some Redis Enterprise versions cannot recover or upgrade clusters containing old or manually uploaded modules.

## 4. When to use this runbook

Use Scenario A when the configuration is still available on the original persistent volumes. Use Scenario B only when the original volumes are unavailable but a valid off-cluster CCS backup exists.

| Situation | Configuration status | Action |
|---|---|---|
| Single pod restart or isolated node failure | Configuration remains on the volume | Allow the Operator to self-heal; intervene only if recovery stalls. |
| Quorum loss or all pods restart together | Configuration remains on the volumes | Recover in place using Section 7. |
| `RedisEnterpriseCluster` resource deleted | PVCs still exist | Recreate the REC with the original settings and enable recovery. |
| PVC deleted with `Retain` reclaim policy | PV and data remain | Re-bind the retained PV, then recover in place. |
| Original PVCs or PVs are permanently lost | Configuration is unavailable, but a valid CCS backup exists | Use Scenario B. |
| Original PVCs or PVs and CCS backup are unavailable | Configuration cannot be restored | This runbook does not apply. |

## 5. Key recovery concepts

### 5.1 `clusterRecovery`

Recovery is triggered by setting the following field on the `RedisEnterpriseCluster` resource:

```yaml
spec:
  clusterRecovery: true
```

When the original persistent volumes are available, the Operator uses this flag to:

1. Start the first node.
2. Read the saved configuration from the node's local recovery storage.
3. Restore the cluster configuration.
4. Bring the remaining nodes back into the cluster.

The RedisEnterpriseCluster API reference states that `clusterRecovery` initiates recovery and is cleared automatically after recovery completes. Verify the resource state after the operation. See the [RedisEnterpriseCluster API Reference](https://redis.io/docs/latest/operate/kubernetes/reference/api/redis_enterprise_cluster_api/).

When the original volumes are unavailable, Scenario B uses the same recovery flag after fresh PVCs have been prepared and the CCS has been staged manually. This is an advanced, non-standard procedure and must be validated for the exact deployment versions.

### 5.2 The Cluster Configuration Store (CCS)

The CCS contains cluster configuration such as:

* Cluster nodes and topology
* Database definitions
* Endpoints and ports
* Users and policies
* Database settings such as memory limits and eviction policies

When persistence is enabled, recovery files are stored on the persistent storage associated with the cluster nodes. Do not assume a fixed CCS path. Always query a healthy running node before performing diagnostics or taking a backup:

```bash
oc exec -n <namespace> <cluster>-0 \
  -c redis-enterprise-node -- \
  /opt/redislabs/bin/ccs-cli CONFIG GET dbfilename
```

Example output:

```text
/opt/persistent/ccs/ccs-redis.rdb
```

The exact path can vary by deployment. Confirm that the reported file is on the PVC-backed persistent storage used by the node.

### 5.3 PVCs, PVs, and reclaim policies

Deleting the `RedisEnterpriseCluster` resource does not necessarily delete its per-node PVCs. Always verify the PVCs before selecting a recovery path:

```bash
oc get pvc -n <namespace>
```

The storage class reclaim policy determines what happens when a PVC is deleted:

| Reclaim policy | Result when the PVC is deleted | Scenario A action |
|---|---|---|
| `Retain` | The underlying PV remains in a `Released` state and its data is preserved. | Re-bind the PV to the original PVC name, then recover. |
| `Delete` | The PV and its data are deleted with the PVC. | This Scenario A runbook no longer applies. |

Check the reclaim policy with:

```bash
oc get storageclass <storage-class> \
  -o jsonpath='{.reclaimPolicy}{"\n"}'
```

### 5.4 Configuration recovery versus data recovery

Cluster recovery restores the cluster and database configuration. After the cluster is recovered, databases may appear in a recovery state and require activation.

In the configuration-only model covered by this runbook, activation creates empty databases with their original configuration. It does not restore keys or values.

## 6. Pre-recovery checklist

Resolve infrastructure problems before attempting recovery. Starting recovery while storage, nodes, or networking remain unstable can create additional failures.

Confirm all of the following:

* The underlying storage, nodes, and network are stable.
* The Redis Enterprise Operator is running:

  ```bash
  oc get pods -n <namespace>
  ```

* The Operator supports the Redis Enterprise version being recovered.
* Persistence was enabled on the original cluster.
* The recovery cluster will use the same Redis Enterprise `versionTag` as the original.
* The original cluster credential secret and administrator credentials are available.
* For Scenario B, a valid CCS backup is available and contains `ccs/ccs-redis.rdb`.
* For Scenario B, the recovery environment is clean and has sufficient storage for all recovery PVCs.
* The original PVCs still exist and are `Bound`.
* No stale `VolumeAttachment` objects prevent the volumes from attaching.
* Old Redis Enterprise pods are fully terminated before replacement pods start.
* If a PVC was deleted, the corresponding PV is retained and can be re-bound.

## 7. Recover in place with existing PVCs

Use this procedure when the original PVCs still exist and contain the Redis Enterprise configuration.

### 7.1 Recognize a stalled recovery

Typical indicators include:

* The `RedisEnterpriseCluster` resource is not in `Running` state, or the resource is missing.
* Pods are not fully ready.
* `rladmin status` shows nodes in `PENDING RECOVERY`.
* The cluster has not recovered automatically after several minutes.
* The original PVCs are still present and contain the configuration.

### 7.2 Enable recovery

If the cluster resource still exists, enable recovery:

```bash
oc patch rec <cluster> -n <namespace> \
  --type merge \
  --patch '{"spec":{"clusterRecovery":true}}'
```

If the cluster resource was deleted, recreate it with:

* The same cluster name
* The same Redis Enterprise version
* Persistence enabled
* The same storage settings
* The same cluster credential configuration
* `clusterRecovery: true`

The Operator should bind to the existing PVCs and restore the configuration from the persistent recovery files.

Monitor the recovery state and pod status:

```bash
watch "oc get rec <cluster> -n <namespace> \
  -o jsonpath='{.status.state}'; echo; \
  oc get pods -n <namespace> | grep <cluster>"
```

Expected progression:

1. `RecoveringFirstPod` — the first node restores the configuration.
2. `Initializing` — the remaining nodes rejoin the cluster.
3. `Running` — the cluster configuration is restored.
4. Databases appear in a recovery state and must be activated in Section 10.

### 7.3 Handle RWO and Multi-Attach conditions

With block or `ReadWriteOnce` storage, avoid deleting all pods simultaneously. A volume may remain attached to the old node while a replacement pod is scheduled on another node, producing a `Multi-Attach` or `volume is still in use` error.

First identify and remove the stale `VolumeAttachment` for the affected volume. Allow the old pod to terminate cleanly before starting the replacement.

Only as a last resort—and only when healthy configuration copies exist on other nodes—consider deleting and recreating the affected secondary node's PVC so that the node can rejoin with fresh storage.

**Never delete the PVC for the node that contains the only surviving configuration copy.**

## 8. Re-bind a retained PV before recovery

Use this procedure when a PVC was deleted but the storage class uses the `Retain` reclaim policy and the original PV still contains the configuration.

1. Find the released PV:

   ```bash
   oc get pv | grep Released | grep <cluster>
   ```

2. Remove the old claim reference:

   ```bash
   oc patch pv <pv-name> -p '{"spec":{"claimRef":null}}'
   ```

3. Recreate the PVC with the exact StatefulSet name and bind it to the retained PV:

   ```yaml
   apiVersion: v1
   kind: PersistentVolumeClaim
   metadata:
     name: redis-enterprise-storage-<cluster>-<ordinal>
     namespace: <namespace>
   spec:
     accessModes:
       - ReadWriteOnce
     resources:
       requests:
         storage: 20Gi
     storageClassName: <storage-class>
     volumeName: <pv-name>
   ```

4. Repeat the process for each released volume, matching every PV to its original PVC name.
5. Confirm that the PVCs are `Bound`.
6. Continue with Section 7.2.

This PV re-binding procedure is an OpenShift/Kubernetes storage operation rather than a Redis-specific recovery command. Test it with the storage platform team before using it in production.

## 9. Scenario B — Rebuild from a CCS backup

> **Advanced, non-standard procedure:** Redis's official Kubernetes recovery workflow is Scenario A, which uses the original persistent recovery storage. This procedure is included for environments where the original volumes are unavailable, but it relies on configuration-file behavior and manual volume preparation that are not described as the standard Redis Kubernetes recovery workflow. Validate it in a lab with the same OpenShift, Operator, and Redis Enterprise versions, and involve Redis Support for critical production recoveries.

Use this scenario only when the original configuration is no longer available on any volume and an off-cluster CCS backup is available.

### 9.1 Additional prerequisites

* A valid CCS backup containing `ccs/ccs-redis.rdb`
* The same Redis Enterprise version as the original cluster
* The same cluster name and compatible cluster credential configuration
* Enough storage for one PVC per recovery node
* A clean starting point with no conflicting REC, PVCs, or pods

### 9.2 Confirm a clean starting point

```bash
oc get rec,pvc,pods -n <namespace>
```

Remove or isolate conflicting resources before continuing. Do not overwrite unrelated PVCs.

### 9.3 Pre-create the PVCs

The StatefulSet expects PVCs named:

```text
redis-enterprise-storage-<cluster>-<ordinal>
```

Create one PVC for each node. The following example creates three PVCs:

```bash
for n in 0 1 2; do
  cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: redis-enterprise-storage-<cluster>-${n}
  namespace: <namespace>
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 20Gi
  storageClassName: <storage-class>
EOF
done
```

Confirm that all PVCs are `Bound` before staging the CCS.

### 9.4 Stage the CCS on each volume

A volume is mounted only when it is used by a pod. Use a short-lived helper pod to mount the recovery PVCs and copy the CCS onto each one.

Use a dedicated service account with a temporary SCC rather than the default service account. Remove the service account and SCC permission after staging is complete.

The CCS must be placed at this relative path on every volume:

```text
ccs/ccs-redis.rdb
```

The file must be readable by the `redislabs` user. The exact UID, GID, and mode are deployment-specific; confirm them for the target Redis Enterprise version before staging the file.

Create the temporary service account:

```bash
oc create sa ccs-stager -n <namespace>
oc adm policy add-scc-to-user anyuid \
  -z ccs-stager -n <namespace>
```

Create a helper pod that mounts the recovery PVCs:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: ccs-stager
  namespace: <namespace>
spec:
  serviceAccountName: ccs-stager
  securityContext:
    runAsUser: 0
  containers:
    - name: stager
      image: registry.access.redhat.com/ubi9/ubi:latest
      command: ["sleep", "3600"]
      volumeMounts:
        - name: v0
          mountPath: /mnt/pvc0
        - name: v1
          mountPath: /mnt/pvc1
        - name: v2
          mountPath: /mnt/pvc2
  volumes:
    - name: v0
      persistentVolumeClaim:
        claimName: redis-enterprise-storage-<cluster>-0
    - name: v1
      persistentVolumeClaim:
        claimName: redis-enterprise-storage-<cluster>-1
    - name: v2
      persistentVolumeClaim:
        claimName: redis-enterprise-storage-<cluster>-2
```

Wait for the helper pod to become ready and copy the backup into it:

```bash
oc wait --for=condition=Ready pod/ccs-stager \
  -n <namespace> --timeout=120s

oc cp ccs-backup-XXXX.tgz \
  <namespace>/ccs-stager:/tmp/backup.tgz
```

Extract and stage the CCS on every volume:

```bash
oc exec -n <namespace> ccs-stager -- bash -c '
  set -e
  mkdir -p /tmp/bk
  tar xzf /tmp/backup.tgz -C /tmp/bk

  for n in 0 1 2; do
    mkdir -p /mnt/pvc${n}/ccs
    cp /tmp/bk/ccs/ccs-redis.rdb \
       /mnt/pvc${n}/ccs/ccs-redis.rdb
    chown -R 1001:1001 /mnt/pvc${n}/ccs
    chmod 0640 /mnt/pvc${n}/ccs/ccs-redis.rdb
  done

  ls -ln /mnt/pvc0/ccs
'
```

Verify the path, ownership, and permissions on every volume according to the target Redis Enterprise version.

### 9.5 Remove the helper and wait for detach

Delete the helper pod gracefully and remove the temporary SCC permission:

```bash
oc delete pod ccs-stager -n <namespace>
oc adm policy remove-scc-from-user anyuid \
  -z ccs-stager -n <namespace>
oc delete sa ccs-stager -n <namespace>
```

Wait until the volumes have detached before creating the REC:

```bash
oc get volumeattachment -o json | \
  python3 -c '
import json, sys
items = json.load(sys.stdin)["items"]
print([
    v["metadata"]["name"]
    for v in items
    if "<cluster>" in str(v["spec"])
])
'
```

Repeat until the command returns:

```text
[]
```

### 9.6 Create the REC in recovery mode

Create the REC with the same Redis Enterprise version, cluster name, persistence settings, and compatible credential configuration as the original cluster:

```yaml
apiVersion: app.redislabs.com/v1
kind: RedisEnterpriseCluster
metadata:
  name: <cluster>
  namespace: <namespace>
spec:
  nodes: 3
  clusterRecovery: true
  redisEnterpriseImageSpec:
    repository: registry.connect.redhat.com/redislabs/redis-enterprise
    versionTag: <version>
  persistentSpec:
    enabled: true
    storageClassName: <storage-class>
    volumeSize: 20Gi
  redisEnterpriseNodeResources:
    requests:
      cpu: "2"
      memory: 4Gi
    limits:
      cpu: "2"
      memory: 4Gi
```

Monitor recovery:

```bash
watch "oc get rec <cluster> -n <namespace> \
  -o jsonpath='{.status.state}'; echo; \
  oc get pods -n <namespace> | grep <cluster>"
```

Expected progression:

1. `RecoveringFirstPod` — the first node reads the staged CCS and restores the configuration.
2. `Initializing` — the remaining nodes join the cluster.
3. `Running` — the recovered cluster configuration is available.

Continue with database activation in Section 10. Active-Active databases require the sequence in Section 11.

## 10. Activate databases in configuration-only mode

After the cluster reaches `Running`, database definitions may still be in a recovery state. In the configuration-only model, activate each database with `only_configuration`.

List databases waiting for activation:

```bash
oc exec -n <namespace> <cluster>-0 \
  -c redis-enterprise-node -- rladmin recover list
```

Activate each database:

```bash
oc exec -n <namespace> <cluster>-0 \
  -c redis-enterprise-node -- \
  rladmin recover db db:<id> only_configuration
```

Repeat the command for every database listed by `rladmin recover list`.

After activation, each database should be active with its original configuration and zero keys.

Do not use `rladmin recover all` for a strictly configuration-only recovery if persistence files are present. Activate databases individually with `only_configuration` instead.

## 11. Active-Active (CRDB) recovery

Use this section after the Redis Enterprise cluster has reached `Running` and the participating Active-Active database instances are visible. This procedure assumes the original persistent recovery files are still available on the relevant nodes.

Redis recommends different actions depending on whether other Active-Active instances remain healthy:

* **Some instances remain live:** Recover only the configuration for the failed instances. The recovered instances should receive their data from the live instances through Active-Active replication.
* **All instances require recovery:** Recover one instance with its data, then recover the remaining instances with configuration only. The empty instances should update from the recovered instance through Active-Active replication.

### 10.1 Identify the recoverable instances

List databases and recovery status from a healthy cluster node:

```bash
oc exec -n <namespace> <cluster>-0 \
  -c redis-enterprise-node -- rladmin recover list
```

Confirm which Active-Active instances are live, which are failed, and whether the required persistence files are available.

### 10.2 Recover failed instances while another instance remains live

For each failed Active-Active instance, recover configuration only:

```bash
oc exec -n <namespace> <cluster>-0 \
  -c redis-enterprise-node -- \
  rladmin recover db db:<id> only_configuration
```

Do not restore an independent data copy into the failed instance when a live Active-Active instance is available to provide the data through replication.

### 10.3 Recover when all instances require recovery

When every participating instance requires recovery:

1. Select one instance for data recovery.
2. Confirm that its database persistence files are available and readable.
3. Recover that instance with data using the version-appropriate `rladmin recover db` command without `only_configuration`.
4. Recover every other instance with configuration only:

   ```bash
   oc exec -n <namespace> <cluster>-0 \
     -c redis-enterprise-node -- \
     rladmin recover db db:<id> only_configuration
   ```

5. Wait for the empty instances to synchronize from the recovered instance.
6. Verify that all instances are active and replication has converged before restoring normal application traffic.

If persistence files are not in the expected recovery location, configure the node recovery path using the Redis Enterprise version-specific `rladmin` documentation before running data recovery.

### 10.4 Validate CRDB recovery and application routing

Confirm the following:

* Each recovered instance is active.
* The Active-Active database is synchronizing successfully.
* The recovered instances are not reporting missing persistence files.
* Application traffic is routed to a healthy database member.

Active-Active databases do not provide built-in failover or failback for application connections. Application, proxy, DNS, or global traffic-management logic must redirect clients to a healthy member during a cluster or regional failure.

See [Recover a failed database](https://redis.io/docs/latest/operate/rs/databases/recover/) and [Disaster recovery strategies for Active-Active databases](https://redis.io/docs/latest/operate/rs/databases/active-active/disaster-recovery/).

## 12. Success checklist

Recovery is complete when all of the following are true:

* `oc get rec` reports the cluster state as `Running`.
* `rladmin status` reports all nodes as healthy.
* Every expected database is present.
* Database configuration matches the original, including name, port, memory, eviction policy, and persistence settings.
* `rladmin recover list` reports no missing files.
* Every database is active after configuration-only activation.
* Applications can connect successfully to the database endpoints.

## 13. Troubleshooting

| Symptom | Likely cause | Recommended action |
|---|---|---|
| Stuck in `RecoveringFirstPod` | The first node cannot bootstrap from the persistent recovery files. | Confirm that the PVC is `Bound`, no stale `VolumeAttachment` exists, the CCS path is correct, credentials are valid, and the Redis Enterprise version matches. Then review node and Operator logs. |
| Cluster recovers with no configuration | The expected recovery file is missing, stale, or inaccessible. | Query `ccs-cli CONFIG GET dbfilename` on a healthy node and verify that the reported path is on the mounted persistent volume. |
| A retained PV will not bind | The old claim reference remains or the recreated PVC name does not match the original. | Clear `claimRef`, recreate the PVC with the exact original name, specify `volumeName`, and verify the PV/PVC pair. |
| Recovery stalls and the node service restarts | Redis Enterprise version or credential configuration mismatch. | Recreate or update the REC with the original supported version and valid cluster credentials. |
| Secondary nodes remain in `ContainerCreating` with `Multi-Attach` or `volume is still in use` | A `ReadWriteOnce` volume remains attached to another node. | Remove the stale `VolumeAttachment`. Only as a last resort, and only when another healthy configuration copy exists, recreate the affected secondary node's PVC. |
| `rladmin recover list` reports missing files or permission errors | Recovery files are in the wrong location or unreadable by the `redislabs` user. | Verify the mounted storage path and permissions, then review node logs. |
| Cluster resource will not delete or PVC remains `Terminating` | Kubernetes finalizers are blocking deletion. | Remove finalizers only after confirming the resource is safe to remove, then delete residual StatefulSets and pods. |

### 13.1 Recovery diagnostics

When recovery stalls, especially in `RecoveringFirstPod`, collect the following information:

```bash
oc get rec <cluster> -n <namespace> \
  -o jsonpath='{.status.state}'; echo

oc describe rec <cluster> -n <namespace>

oc logs -n <namespace> <cluster>-0 \
  -c redis-enterprise-node

oc logs -n <namespace> \
  deploy/redis-enterprise-operator
```

## 14. Documentation alignment

The official Redis Kubernetes recovery documentation supports this runbook's core flow:

* The cluster must use persistent storage.
* Set `spec.clusterRecovery: true` on the `RedisEnterpriseCluster` resource.
* The Operator recreates the cluster, mounts persistent recovery storage, restores the configuration on the first node, and joins the remaining nodes.
* Database configuration recovery and database data recovery are separate steps; use `only_configuration` when data restoration is intentionally excluded.
* For Active-Active databases with live instances, recover configuration for failed instances and let data update from the live instances.
* If all Active-Active instances require recovery, recover one instance with data and the remaining instances with configuration only.

See [Recover a Redis Enterprise cluster on Kubernetes](https://redis.io/docs/latest/operate/kubernetes/re-clusters/cluster-recovery/), [RedisEnterpriseCluster API Reference](https://redis.io/docs/latest/operate/kubernetes/reference/api/redis_enterprise_cluster_api/), [Recover a failed database](https://redis.io/docs/latest/operate/rs/databases/recover/), and [Disaster recovery strategies for Active-Active databases](https://redis.io/docs/latest/operate/rs/databases/active-active/disaster-recovery/).

The retained-PV re-binding procedure is an OpenShift/Kubernetes storage operation and should be validated for the storage class and CSI driver in use.

Scenario B is included as an advanced, non-standard procedure. Redis documentation describes the supported Kubernetes recovery flow using persistent recovery storage; it does not prescribe the manual PVC creation, helper pod, or CCS-staging workflow. Validate Scenario B in a lab and involve Redis Support for critical production recoveries.

## 15. Quick reference

| Action | Command |
|---|---|
| Check PVCs | `oc get pvc -n <namespace>` |
| Check storage reclaim policy | `oc get storageclass <storage-class> -o jsonpath='{.reclaimPolicy}'` |
| Confirm CCS path | `ccs-cli CONFIG GET dbfilename` |
| Start Scenario B recovery | Pre-create PVCs, stage `ccs/ccs-redis.rdb`, then create the REC with `clusterRecovery: true` |
| Enable recovery | `oc patch rec <cluster> -n <namespace> --type merge --patch '{"spec":{"clusterRecovery":true}}'` |
| Check cluster state | `oc get rec <cluster> -n <namespace> -o jsonpath='{.status.state}'` |
| Check cluster and database status | `rladmin status` |
| List recoverable databases | `rladmin recover list` |
| Activate a database without restoring data | `rladmin recover db db:<id> only_configuration` |

## 16. Source

Rewritten from [WellsFargo-Redis-Cluster-Recovery-Guide-OCP](https://docs.google.com/document/d/1BTdZE2th7bDrZBLtQkTA28qxhcizxftdLCh6XVoF6Qk).
