# Onify Citizen Infrastructure

Kubernetes manifests for installing Onify Citizen on an existing cluster.
[Kustomize](https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/)
is built into `kubectl`; it combines a shared base with installation-specific
configuration. The [Onify Citizen Terraform module](https://github.com/onify/terraform/tree/a5bab28a5aa8ca09e35d2de3d1c31d60de2b4ffc/modules/onify-citizen)
is the reference for the components, ports and frontend proxy settings.

## How Kustomize works

The **base** in `kubernetes/` contains the shared Kubernetes resources.
An **overlay** is an installation directory such as `examples/acme/`: its
`kustomization.yaml` selects the base, images, namespace and configuration.
Kustomize combines these files locally into ordinary Kubernetes manifests.

Use `kubectl apply -k` to render and apply an overlay in one command. If you
need a standalone YAML file for another deployment tool, render it first:

```sh
kubectl kustomize deployments/acme-prod > rendered.yaml
```

The rendered file contains the installation's Secret data. The normal
installation flow below uses the overlay directly, without a generated file.

## Components

| Component | Workload | Internal address | Purpose |
|---|---|---|---|
| API | StatefulSet | `http://onify-api:8181` | Onify API |
| App | StatefulSet | `http://onify-app:4000` | Single Citizen frontend, served at `/` |
| Worker | StatefulSet | Background process | API image started with `worker` |
| Gateway | Deployment | `http://onify-gateway:8686` | Internal gateway |
| Elasticsearch | StatefulSet | `http://onify-elasticsearch:9200` | Customer data on a persistent volume |

The app's NGINX proxy receives `ONIFY_API_URL_INTERNAL=http://onify-api:8181`.
Browser API requests use the same origin. The app receives no API admin token.
Gateway and Elasticsearch have internal ClusterIP Services.

## Repository layout

- `kubernetes/`: shared workloads and Services.
- `examples/acme/`: namespace, hostnames, TLS, images, configuration and storage.
- `tests/check.py`: offline rendering and configuration checks.
- `.github/workflows/validate.yaml`: the same checks plus strict Kubernetes
  schema validation on pushes and pull requests.

The example keeps the previous `onify-citizen-test` namespace and existing API,
worker, app and Elasticsearch names. For a new installation, choose a namespace
such as `acme-prod`. Each installation needs its own configuration and secrets.

## Requirements

- `kubectl` with Kustomize support, access to the target Kubernetes cluster.
- Python 3 for the local preflight check.
- An Ingress controller and a StorageClass suitable for Elasticsearch.
- Approved API, root-path Citizen app and Gateway images, with registry access.
- Client code, instance code, license and initial administrator credentials.
- For the example TLS configuration: cert-manager and a `letsencrypt-prod`
  ClusterIssuer, plus DNS records pointing to the Ingress controller.

The example uses the `nginx` Ingress class to match the existing configuration.
Adapt the class and controller-specific annotations to your cluster. For a
custom TLS certificate, create a `kubernetes.io/tls` Secret in the installation
namespace, set its name in `ingress.yaml`, and remove the cert-manager annotation.

## Configure an installation

Create a local installation at the same directory depth as the example, so the base's relative path
continues to work:

```sh
mkdir -p deployments
cp -R examples/acme deployments/acme-prod
cp deployments/acme-prod/secrets.env.example deployments/acme-prod/secrets.env
chmod 600 deployments/acme-prod/secrets.env
```

Edit these files before applying:

| File | Values to set |
|---|---|
| `kustomization.yaml` | Namespace, full image repositories and approved version tags; Elasticsearch heap size |
| `namespace.yaml` | Same namespace |
| `config.env` | Client code, instance, index prefix and API/worker settings |
| `secrets.env` | License, administrator password, app-token secret and client secret |
| `ingress.yaml` | App/API hostnames, TLS hosts, certificate Secrets and Ingress class |
| `storage.yaml` | Disk size and, if needed, `storageClassName` |

Image tags and the Gateway image repository are explicit placeholders because
the reference module requires them as inputs. The app image must be built to
serve `/`; the previous image built for `/helix` is not a drop-in replacement.
API and worker use the same image. Additional app or Gateway environment
settings can be supplied with a Kustomize patch to their container's `env`.

Environment files contain literal `KEY=value` lines, with no shell expansion.
Keep secret values on a single line and do not wrap them in shell quotes.
For a new installation, generate the app-token and client secrets once, for
example with `openssl rand -hex 32`, and save them in `secrets.env`.
Reuse these values on later deployments.

Kustomize generates ConfigMaps and a Kubernetes Secret with content hashes.
Rendering unchanged inputs produces unchanged names; changing configuration or
secrets updates the pod references and rolls out the affected workloads.
Local installation directories, secret files and registry credentials are
excluded from Git.

## Install

The preflight check needs Python 3 and validates that required
credentials, image selections and namespace settings are filled in, then checks the rendered
resources:

```sh
python3 tests/check.py deployments/acme-prod
```

Set the intended Kubernetes context and namespace explicitly. They must match
the installation you configured. Create the namespace and image-pull Secret
using your Docker-compatible registry credentials file:

```sh
ONIFY_CONTEXT=REPLACE_WITH_CONTEXT
ONIFY_NAMESPACE=acme-prod
kubectl --context "$ONIFY_CONTEXT" apply -f deployments/acme-prod/namespace.yaml
kubectl --context "$ONIFY_CONTEXT" -n "$ONIFY_NAMESPACE" create secret generic onify-regcred \
  --type=kubernetes.io/dockerconfigjson \
  --from-file=.dockerconfigjson=/secure/path/registryCredentials.json \
  --dry-run=client -o yaml | kubectl --context "$ONIFY_CONTEXT" apply -f -
```

For obtaining that file, see Kubernetes' [private registry authentication guide](https://kubernetes.io/docs/tasks/configure-pod-container/pull-image-private-registry/).
It must cover every registry used by your selected images.

Review and install:

```sh
kubectl --context "$ONIFY_CONTEXT" diff -k deployments/acme-prod
kubectl --context "$ONIFY_CONTEXT" apply --dry-run=server -k deployments/acme-prod
kubectl --context "$ONIFY_CONTEXT" apply -k deployments/acme-prod
```

`kubectl diff` exits with code 1 when differences exist. Rendered manifests and
diffs can contain Secret data; keep them out of Git and shared logs.

The example exposes the frontend at `https://onify-citizen-test.acme.org/`
and the API at `https://onify-citizen-test-api.acme.org/`.
Remove the API Ingress document if direct external API access is unnecessary.
Gateway has no public Ingress.

## Verify the running installation

Check that storage binds and the workloads become ready:

```sh
kubectl --context "$ONIFY_CONTEXT" -n "$ONIFY_NAMESPACE" get pods,services,ingress,pvc
kubectl --context "$ONIFY_CONTEXT" -n "$ONIFY_NAMESPACE" rollout status statefulset/onify-elasticsearch --timeout=5m
kubectl --context "$ONIFY_CONTEXT" -n "$ONIFY_NAMESPACE" rollout status statefulset/onify-api --timeout=5m
kubectl --context "$ONIFY_CONTEXT" -n "$ONIFY_NAMESPACE" rollout status statefulset/onify-worker --timeout=5m
kubectl --context "$ONIFY_CONTEXT" -n "$ONIFY_NAMESPACE" rollout status statefulset/onify-app --timeout=5m
kubectl --context "$ONIFY_CONTEXT" -n "$ONIFY_NAMESPACE" rollout status deployment/onify-gateway --timeout=5m
```

The TCP readiness probes check that a process is listening. Verify app login,
browser API requests, a worker task and a Gateway operation as well; readiness
alone does not prove application compatibility. For backups, take a snapshot
and test restoring it. These checks need the real images and installation
credentials.

When pods do not become ready, start with `kubectl describe pod` and container
logs in the installation namespace. `ImagePullBackOff` points to the image
reference or registry credentials; a Pending PVC points to storage provisioning.

## Storage and backups

The shared Elasticsearch workload mounts the claim declared in `storage.yaml`.
The default claim requests 10Gi from the cluster's default StorageClass.
Elasticsearch stays single-node; adjust heap, pod resources and disk size for
the installation.

An independently declared PVC survives deletion of the StatefulSet. Deleting
the PVC or namespace can still delete data, depending on the volume reclaim
policy. Avoid `kubectl delete -k` for an installation whose data must be kept.

For filesystem snapshots, attach a separate backup PVC and add
`path.repo=/usr/share/elasticsearch/backup` to Elasticsearch. The optional
[backup manifests](examples/elasticsearch/) provide the PVC and workload patch.
Copy them into the installation:

```sh
cp examples/elasticsearch/backup-*.yaml deployments/acme-prod/
```

Add these entries to the installation's `kustomization.yaml`:

```yaml
resources:
  # Keep the existing resources, then add:
  - backup-storage.yaml
patches:
  - path: backup-patch.yaml
```

Set the backup PVC's storage size/class for your cluster. After applying,
register the repository from the Elasticsearch pod:

```sh
kubectl --context "$ONIFY_CONTEXT" -n "$ONIFY_NAMESPACE" exec onify-elasticsearch-0 -- curl --fail \
  -X PUT http://localhost:9200/_snapshot/backup_repo \
  -H 'Content-Type: application/json' \
  -d '{"type":"fs","settings":{"location":"/usr/share/elasticsearch/backup"}}'
```

Registering the repository does not create or schedule snapshots. Configure
Elasticsearch Snapshot Lifecycle Management for scheduled backups and verify
that a snapshot can be restored.

## Migrate an existing installation

Plan a cutover before applying these manifests to a running installation.

1. Preserve the namespace, `ONIFY_client_code`, `ONIFY_client_instance`,
   `ONIFY_db_indexPrefix`, license and all existing authentication values.
   Copy the installation's other API/worker settings into `config.env` or
   `secrets.env` as appropriate.
2. Take an Elasticsearch snapshot and verify the data restore procedure.
   The old generator did not mount persistent storage by default. Mounting a
   new empty PVC does **not** move data from an existing pod. For ephemeral
   data, snapshot before any Elasticsearch restart, restore to a separate
   persistent Elasticsearch instance, and validate it before cutover.
   For an existing persistent installation, reuse its actual PVC via a
   workload patch and remove `storage.yaml` from the resource list if that
   claim is managed elsewhere. Keep its image version during the migration.
3. Stop the old worker during cutover. Replace the old frontend route:
   remove the `onify-helix` Ingress before enabling the new app Ingress for
   the same hostname. The new app serves `/` on port 4000.
4. Review `kubectl diff -k` and perform the server dry run. Keep any
   previously used node placement, resource settings and required mounts
   through workload patches. Apply only after the data migration is ready.
5. After the new app, API, worker and Gateway work, remove the obsolete
   `onify-helix`, `hub-functions` and `onify-agent` workloads and their
   Services/Ingresses, where present. Update callers of the old endpoints.

`kubectl apply -k` does not remove resources omitted from the new manifests.
StatefulSet selectors and `serviceName` keep their existing values in the base;
check these against the running installation. Other immutable fields require
a planned replacement. Preserve customer storage and the namespace throughout.

## Verify changes locally

```sh
python3 tests/check.py
```

This renders a temporary installation with test credentials, checks all five
workloads, Services, routes and persistent storage, verifies deterministic
rendering, configuration-change and secret-change rollouts, validates required
inputs and consistent namespaces, and checks the optional backup patch.
It does not connect to a cluster.

For strict validation of the rendered resources against Kubernetes JSON schemas,
install [kubeconform](https://github.com/yannh/kubeconform#installation) and run:

```sh
python3 tests/check.py --schema
python3 tests/check.py deployments/acme-prod --schema --kubernetes-version 1.32.0
```

The default schema version is 1.32.0; select the target cluster's version when
checking an installation. Schema files are downloaded from the public Kubernetes
schema registry. CI uses pinned, checksum-verified kubectl and kubeconform
releases and validates both the standard installation and backup variant.
No cluster credentials or production secrets are used by CI.

Schema validation does not cover all server-side rules, installed controllers
or admission policies; the server dry run checks the actual cluster.
Actual image availability, application
compatibility and cluster admission require the installation checks above.
