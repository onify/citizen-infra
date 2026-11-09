# Operations

Start with [Getting started](../README.md#getting-started) for a new installation.
Run the commands below from the repository root, with `ONIFY_CONTEXT` and
`ONIFY_NAMESPACE` set for that installation. Replace `deployments/acme-test`
with its actual directory.

## Apply changes

For Elasticsearch version changes, read the [upgrade precautions](#elasticsearch-upgrades)
before applying the new image to an existing data volume.

Keep the installation's existing secret values. Validate and review the changes:

```bash
bash tests/check.sh deployments/acme-test
kubectl --context "$ONIFY_CONTEXT" diff -k deployments/acme-test
kubectl --context "$ONIFY_CONTEXT" apply --dry-run=server -k deployments/acme-test
```

`kubectl diff` exits with code 1 when differences exist. Review the diff before
applying; it can contain Secret data and must stay out of Git and shared logs.
If the server dry run succeeds, apply and wait for the affected workloads as in
[the startup check](../README.md#5-wait-for-startup-and-open-the-app):

```bash
kubectl --context "$ONIFY_CONTEXT" apply -k deployments/acme-test
```

## Elasticsearch upgrades

The Kubernetes base and Docker Compose example use Elasticsearch **9.5.6**.
Do not start it directly against a PVC or Docker volume containing 7.17 data.
Take and verify a [snapshot](backups.md) first, then follow Elastic's
[supported upgrade procedure](https://www.elastic.co/docs/deploy-manage/upgrade/prepare-to-upgrade)
through the latest 8.19.x release. Resolve Upgrade Assistant blockers and reindex
7.x indices that must remain writable before moving to 9.5. Verify the chosen
API/worker images against 9.5 in a test environment before customer deployment.

Keep an existing installation pinned to its current Elasticsearch version until
that migration is prepared. Do not delete its PVC or Docker volume to bypass an
upgrade failure. Downgrading an upgraded data directory is unsupported; recovery
requires the pre-upgrade snapshot and a compatible cluster.

## Troubleshooting

Start with the workload status and recent events:

```bash
kubectl --context "$ONIFY_CONTEXT" -n "$ONIFY_NAMESPACE" get pods,ingress,pvc
kubectl --context "$ONIFY_CONTEXT" -n "$ONIFY_NAMESPACE" get events --sort-by=.metadata.creationTimestamp
```

For a failing pod, use its name from the list:

```bash
ONIFY_POD=REPLACE_WITH_POD_NAME
kubectl --context "$ONIFY_CONTEXT" -n "$ONIFY_NAMESPACE" describe pod "$ONIFY_POD"
kubectl --context "$ONIFY_CONTEXT" -n "$ONIFY_NAMESPACE" logs "$ONIFY_POD" --tail=100
```

| Symptom | Check first |
|---|---|
| `ImagePullBackOff` | Image repository/tag and the `onify-regcred` registry Secret. |
| PVC stays `Pending` | StorageClass, provisioner events and available storage. |
| Pod stays `Pending` | Scheduling events, resource requests and node capacity. |
| Container restarts or is not ready | Container logs, license/configuration and connection to Elasticsearch. |
| APP URL does not load | DNS, Ingress class, TLS certificate and the controller selectors in NetworkPolicy. |
| APP loads but login fails | API logs and the configured admin credentials; browser API requests must reach the APP's internal API proxy. |

## Before customer use

The TCP readiness probes only show that a process is listening. Verify APP
login, browser API requests, a worker task, and an authenticated operation for
each enabled Gateway integration with the actual release images and credentials.
An empty installation has no enabled integrations to exercise yet.

Verify namespace isolation using the cluster's documented network test procedure
and an approved diagnostic image. From a disposable pod in another customer
namespace, connections to `onify-elasticsearch.<installation-namespace>.svc:9200`
and `onify-gateway.<installation-namespace>.svc:8686` must fail. Approved pods
in the installation namespace must connect, and the public APP must still load
through Ingress.

Set up [backups and verify a restore](backups.md) before storing customer data.
Offline checks cannot prove cluster policy enforcement, application compatibility
or recoverability.
