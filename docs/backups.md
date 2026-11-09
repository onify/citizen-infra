# Backups

Set up backups before storing customer data. For the initial empty environment,
start with [Getting started](../README.md#getting-started).
Run commands from the repository root with `ONIFY_CONTEXT` and
`ONIFY_NAMESPACE` set for your installation. Replace `deployments/acme-test`
with its actual directory.

## Storage

The shared Elasticsearch workload mounts the claim declared in `storage.yaml`.
The default claim requests 10Gi from the cluster's default StorageClass.
Elasticsearch stays single-node; adjust heap, pod resources and disk size for
the installation.

An independently declared PVC survives deletion of the StatefulSet. Deleting
the PVC or namespace can still delete data, depending on the volume reclaim
policy. Avoid `kubectl delete -k` for an installation whose data must be kept.

## Enable snapshots

For filesystem snapshots, attach a separate backup PVC and add
`path.repo=/usr/share/elasticsearch/backup` to Elasticsearch. The optional
[backup manifests](../examples/elasticsearch/) provide the PVC and workload patch.
Copy them into the installation:

```bash
cp examples/elasticsearch/backup-*.yaml deployments/acme-test/
cp examples/elasticsearch/*.json deployments/acme-test/
```

Append the backup manifest and patch to the existing lists in the installation's
`kustomization.yaml` (keep the resource patch and all existing resources):

```yaml
resources:
  # Additional resource:
  - backup-storage.yaml
patches:
  - path: backup-patch.yaml
```

Set the backup PVC's storage size/class and the JSON policy for your cluster.
The default schedule is daily at 01:30 UTC, with 30-day retention, at least five
snapshots and at most fifty. This backs up application indices, not cluster
settings or feature states. Keep installation configuration and secrets in their
separate stores. A backup PVC on the same storage system does not protect against
loss of that system; arrange an independent copy for disaster recovery.

Validate and apply the backup configuration, then wait for Elasticsearch to
restart with the backup mount:

```bash
bash tests/check.sh deployments/acme-test
kubectl --context "$ONIFY_CONTEXT" apply --dry-run=server -k deployments/acme-test && \
kubectl --context "$ONIFY_CONTEXT" apply -k deployments/acme-test
kubectl --context "$ONIFY_CONTEXT" -n "$ONIFY_NAMESPACE" rollout status statefulset/onify-elasticsearch --timeout=5m
```

## Register the repository and schedule

Register and verify the repository, then create the schedule:

```bash
kubectl --context "$ONIFY_CONTEXT" -n "$ONIFY_NAMESPACE" exec -i onify-elasticsearch-0 -- curl --fail --silent --show-error \
  -X PUT http://localhost:9200/_snapshot/backup_repo \
  -H 'Content-Type: application/json' --data-binary @- < deployments/acme-test/snapshot-repository.json
kubectl --context "$ONIFY_CONTEXT" -n "$ONIFY_NAMESPACE" exec onify-elasticsearch-0 -- curl --fail --silent --show-error \
  -X POST http://localhost:9200/_snapshot/backup_repo/_verify
kubectl --context "$ONIFY_CONTEXT" -n "$ONIFY_NAMESPACE" exec -i onify-elasticsearch-0 -- curl --fail --silent --show-error \
  -X PUT http://localhost:9200/_slm/policy/daily-snapshot \
  -H 'Content-Type: application/json' --data-binary @- < deployments/acme-test/daily-snapshot-policy.json
kubectl --context "$ONIFY_CONTEXT" -n "$ONIFY_NAMESPACE" exec onify-elasticsearch-0 -- curl --fail --silent --show-error \
  http://localhost:9200/_slm/status
kubectl --context "$ONIFY_CONTEXT" -n "$ONIFY_NAMESPACE" exec onify-elasticsearch-0 -- curl --fail --silent --show-error \
  -X POST http://localhost:9200/_slm/policy/daily-snapshot/_execute
```

Repository/policy writes must return `acknowledged: true`; repository verification
must list the node and SLM status must be `RUNNING`. The execute call returns a
snapshot name, not a completed backup. Set that name and inspect it until its
state is `SUCCESS`; investigate `FAILED` or `PARTIAL` before accepting backups:

```bash
ONIFY_SNAPSHOT=REPLACE_WITH_RETURNED_SNAPSHOT_NAME
kubectl --context "$ONIFY_CONTEXT" -n "$ONIFY_NAMESPACE" exec onify-elasticsearch-0 -- curl --fail --silent --show-error \
  "http://localhost:9200/_snapshot/backup_repo/$ONIFY_SNAPSHOT"
```

## Verify a restore

Choose one application index from the successful snapshot. Ensure sufficient disk
space and that the `restore-check-` target does not already exist. Create a local
`restore-check.json`, replacing the index placeholder:

```json
{
  "indices": "REPLACE_WITH_ONE_APPLICATION_INDEX",
  "include_global_state": false,
  "feature_states": ["none"],
  "include_aliases": false,
  "rename_pattern": "(.+)",
  "rename_replacement": "restore-check-$1"
}
```

Restore into the new name, leaving the application's active index untouched:

```bash
kubectl --context "$ONIFY_CONTEXT" -n "$ONIFY_NAMESPACE" exec -i onify-elasticsearch-0 -- curl --fail --silent --show-error \
  -X POST "http://localhost:9200/_snapshot/backup_repo/$ONIFY_SNAPSHOT/_restore?wait_for_completion=true" \
  -H 'Content-Type: application/json' --data-binary @- < restore-check.json
ONIFY_RESTORED_INDEX=REPLACE_WITH_RESTORE_CHECK_INDEX_NAME
kubectl --context "$ONIFY_CONTEXT" -n "$ONIFY_NAMESPACE" exec onify-elasticsearch-0 -- curl --fail --silent --show-error \
  "http://localhost:9200/$ONIFY_RESTORED_INDEX/_count"
```

Require zero failed restore shards and verify known records/counts from the
snapshot. A changing live index may have a different current count. Remove the
temporary index after acceptance using its exact reviewed name, never a wildcard.
This single-index check is not a full disaster-recovery exercise; perform a full
restore in an isolated installation to verify disaster recovery.
See Elastic's [SLM policy contract](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-slm-put-lifecycle)
and [restore procedure](https://www.elastic.co/docs/deploy-manage/tools/snapshot-and-restore/restore-snapshot).
