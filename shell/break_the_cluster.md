# Break the cluster: a test manual for `rec-recover.sh`

This manual walks you through deliberately breaking a Redis Enterprise cluster on OpenShift so you can watch
the recovery tooling bring it back. It simulates **total quorum loss while keeping the PVCs intact**, which is
exactly the situation the script is designed for: the pods are gone or cannot agree, but the cluster
configuration and the database files are still on the persistent volumes.

> **Only run this against a cluster you can afford to lose.** Every command below is destructive to the
> running cluster. Double-check the namespace and REC name in step 0 before you run anything else.

| Item | Value used in this manual |
|---|---|
| Namespace | `redis-enterprise` |
| REC (cluster) | `demo-cert-cluster` |
| Database | `demo-db` (TLS enabled) |
| Recovery tool | `ocp-rec-recovery/shell/rec-recover.sh` |
| Time needed | 30 to 60 minutes |

---

## Step 0: Set variables and confirm the target

Open a terminal on the workstation where `oc` is logged in and run everything from the `shell/` folder.

```bash
cd ocp-rec-recovery/shell
export NS=redis-enterprise
export REC=demo-cert-cluster
export DB=demo-db
```

Confirm you are pointed at the right cluster and namespace. Read the output before continuing.

```bash
oc whoami --show-server
oc -n $NS get rec $REC
oc -n $NS get redb
```

Expected: the REC shows `Running` with 3 nodes and `demo-db` is `active`.

You do not need to configure `NS` or `REC` for the script. It detects the RedisEnterpriseCluster from the
cluster you are logged in to. If your cluster hosts more than one REC, answer the numbered prompt the script
shows, or pin one with `NS`/`REC` in `rec-recover.env`.

---

## Step 1: Prepare the test

### 1.1 Confirm the database persists to disk

A database without persistence comes back **empty** after recovery. That is expected Redis behaviour, not a
failure of the tooling, but it makes the test meaningless.

```bash
oc -n $NS get redb $DB -o jsonpath='{.spec.persistence}{"\n"}'
```

If the output is empty or `disabled`, enable append-only persistence and wait for the database to return to
`active`:

```bash
oc -n $NS patch redb $DB --type merge -p '{"spec":{"persistence":"aofEverySecond"}}'
oc -n $NS wait redb/$DB --for=jsonpath='{.status.status}'=active --timeout=300s
```

### 1.2 Seed test data

Write 100 keys so you can prove the data survives. The database uses TLS, so the TLS flags are required.

```bash
PW=$(oc -n $NS get secret redb-$DB -o jsonpath='{.data.password}' | base64 -d)
PORT=$(oc -n $NS get secret redb-$DB -o jsonpath='{.data.port}' | base64 -d)

oc -n $NS exec $REC-0 -c redis-enterprise-node -- bash -c "
  for i in \$(seq 1 100); do
    redis-cli -h $DB-headless -p $PORT --tls --insecure -a '$PW' --no-auth-warning SET key\$i value\$i >/dev/null
  done
  redis-cli -h $DB-headless -p $PORT --tls --insecure -a '$PW' --no-auth-warning DBSIZE"
```

Expected output: `(integer) 100` (or 100 plus whatever was already there). **Write this number down.**

Give the append-only file a few seconds to flush:

```bash
sleep 10
```

### 1.3 Record the healthy baseline

Run the precheck. It is read-only.

```bash
./rec-recover.sh precheck
```

Expected verdict: `RECOVERY_NOT_NEEDED`. This is your "before" picture. Note the artifacts directory it prints;
the report inside is useful for comparison later.

### 1.4 Take a backup

```bash
./rec-recover.sh backup
```

Expected: PASS lines for the CCS archive and for the DB files on each pod, and a path under
`artifacts/<run>/backup`. Copy that folder somewhere outside the cluster, even for a test. It is your safety
net if the test goes wrong.

---

## Step 2: Break the cluster (standard method)

Delete all three Redis Enterprise pods at the same time. The operator recreates them on the same PVCs, but the
nodes come up with new IP addresses and no surviving majority to join, so the cluster cannot reform by itself.

```bash
oc -n $NS delete pod -l redis.io/role=node --wait=false
```

If that label selector matches nothing on your operator version, delete by name instead:

```bash
oc -n $NS delete pod $REC-0 $REC-1 $REC-2 --wait=false
```

### 2.1 Watch the cluster fail

```bash
watch -n 10 "oc -n $NS get rec $REC; echo; oc -n $NS get pods -l redis.io/role=node"
```

Over the next 5 to 10 minutes you should see:

- The REC `STATE` leave `Running` (typically `Error` or stuck in an initialising state).
- Pods that come back but never reach `Ready`, or that restart repeatedly.

Press `Ctrl+C` to stop watching once the cluster is clearly not recovering on its own.

### 2.2 Confirm quorum loss with the precheck

```bash
./rec-recover.sh precheck
```

Expected verdict: **`RECOVERY_RECOMMENDED`**, with the `rladmin-status` check reported as failed or timed out.

If the verdict is still `RECOVERY_NOT_NEEDED` after 10 minutes, the cluster healed itself. Go to step 3.
Otherwise skip to step 4.

---

## Step 3: Break the cluster (stronger method, only if step 2 self-healed)

Sometimes all three pods manage to rejoin. This method stops the operator so nothing can heal the cluster,
scales the Redis StatefulSet to zero, brings it back, and then restarts the operator. The pods return on their
PVCs with no way to bootstrap a quorum.

```bash
oc -n $NS scale deploy redis-enterprise-operator --replicas=0
oc -n $NS scale sts $REC --replicas=0
oc -n $NS wait pod -l redis.io/role=node --for=delete --timeout=300s
oc -n $NS scale sts $REC --replicas=3
oc -n $NS scale deploy redis-enterprise-operator --replicas=1
```

Wait 3 to 5 minutes, then confirm the operator is back and re-run the precheck:

```bash
oc -n $NS get deploy redis-enterprise-operator
./rec-recover.sh precheck
```

The operator **must** show `1/1` available before you continue, because the operator performs the recovery.
Expected verdict: `RECOVERY_RECOMMENDED`.

---

## Step 4: Recover the cluster

Run the full recovery. Run it inside `tmux` or `screen`; the cluster rebuild can take 10 to 20 minutes.

```bash
./rec-recover.sh all
```

What you will see, in order:

1. **PRECHECK** runs again and prints the verdict.
2. **BACKUP** archives CCS and DB files again from any reachable pod.
3. **CONFIRMATION REQUIRED**: the script shows the verdict and asks you to type the cluster name
   (`demo-cert-cluster`). Nothing has changed on the cluster up to this point.
4. **RECOVER CLUSTER** patches `clusterRecovery: true`, then polls until the REC is `Running` and the operator
   has cleared the flag. Each state change is logged.
5. **VALIDATE CLUSTER** checks every node is `OK` and no cluster actions are pending.
6. **RECOVER DATABASES** lists `demo-db` as `ready`, kind `standard`, asks you to confirm once more, then runs
   `rladmin recover db demo-db` and confirms nothing remains in recovery state. This cluster has no
   Active-Active databases, so no Active-Active question is asked.

Expected final summary: `COMPLETED` with 0 failed. The report path is printed on the last line.

If the run stops early, read the red FAIL line, fix the cause, and run `./rec-recover.sh all` again. The
precheck inside it decides whether the cluster still needs recovery.

---

## Step 5: Verify the result manually

Recovery brings the cluster and database back. You still need to confirm the data is intact and clients can
connect. These checks are deliberately manual.

### 5.1 Cluster and database state

```bash
oc -n $NS get rec $REC
oc -n $NS get pods -l redis.io/role=node
oc -n $NS get redb $DB
oc -n $NS exec $REC-0 -c redis-enterprise-node -- rladmin status
```

Expected: REC `Running`, three pods `Ready`, `demo-db` `active`, every node `OK` in `rladmin status`.

### 5.2 Data survived

```bash
PW=$(oc -n $NS get secret redb-$DB -o jsonpath='{.data.password}' | base64 -d)
PORT=$(oc -n $NS get secret redb-$DB -o jsonpath='{.data.port}' | base64 -d)
oc -n $NS exec $REC-0 -c redis-enterprise-node -- \
  redis-cli -h $DB-headless -p $PORT --tls --insecure -a "$PW" --no-auth-warning DBSIZE
oc -n $NS exec $REC-0 -c redis-enterprise-node -- \
  redis-cli -h $DB-headless -p $PORT --tls --insecure -a "$PW" --no-auth-warning GET key42
```

Expected: the same key count you wrote down in step 1.2, and `"value42"`.

### 5.3 Review the report

```bash
ls -t artifacts/ | head -1
```

Open `artifacts/<latest>/report.md`. Every row should be PASS or INFO, with WARN only on events or modules.

---

## Step 6: Clean up after the test

Remove the seeded keys if the database is shared with other testing:

```bash
oc -n $NS exec $REC-0 -c redis-enterprise-node -- bash -c "
  for i in \$(seq 1 100); do
    redis-cli -h $DB-headless -p $PORT --tls --insecure -a '$PW' --no-auth-warning DEL key\$i >/dev/null
  done"
```

Delete old artifact directories once you have saved the reports you want to keep:

```bash
ls artifacts/
rm -rf artifacts/<run-id-you-no-longer-need>
```

---

## What not to do during this test

| Do not | Why |
|---|---|
| Delete PVCs | That is a different recovery scenario (restore from external backup). This tooling does not cover it and your data is gone. |
| Force-delete pods with `--grace-period=0` | Leaves VolumeAttachments pinned to nodes and makes the test unrepresentative of a real failure. |
| Run `rladmin cluster reset` inside a pod | Wipes the cluster configuration store that the operator rebuilds from. |
| Test a cluster that participates in Active-Active with production peers | Recovering it can disturb replication on the production side. |
| Patch `clusterRecovery: true` by hand while the precheck says `RECOVERY_NOT_NEEDED` | Recovery on a healthy cluster causes an unnecessary outage. Let the precheck decide; the script warns loudly before letting you override it. |

## If something goes badly wrong

1. Do not delete anything else. The PVCs still hold the CCS and the AOF files.
2. Collect logs for Redis Support with `log_collector.py` (see https://redis.io/docs/latest/operate/kubernetes/logs/collect-logs/).
3. Check the REC and events: `oc -n $NS describe rec $REC` and `oc -n $NS get events --sort-by=.lastTimestamp`.
4. Your step 1.4 backup contains the cluster configuration and the database files. Keep it until the cluster
   is confirmed healthy.
5. Open a Redis Support case with the diagnostics archive if the REC does not return to `Running`.

## A note on realism

Redis does not publish an official failure-injection procedure for Kubernetes. Deleting all pods at once is the
method most commonly used to trigger operator-driven recovery, and the stronger method in step 3 exists because
a healthy cluster can occasionally survive it. Neither method damages persistent storage, so both reproduce the
scenario the recovery tooling targets: cluster gone, data intact.
