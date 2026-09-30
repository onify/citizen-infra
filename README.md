# Onify Citizen Infrastructure

Kubernetes manifests for installing Onify Citizen.
[Kustomize](https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/)
is built into `kubectl`; it combines a shared base with installation-specific
configuration.

## How Kustomize works

The **base** in `kubernetes/` contains the shared Kubernetes resources.
An **overlay** is an installation directory such as `examples/acme/`: its
`kustomization.yaml` selects the base, images, namespace and configuration.
Kustomize combines these files locally into ordinary Kubernetes manifests.

Start with `kubernetes/onify-citizen.yaml` to see the workloads, Services and
container settings. API and worker load their environment variables through
`envFrom`: every key in the referenced ConfigMap and Secret becomes a container
environment variable. The values come from the installation's `config.env` and
`secrets.env` files.

`examples/acme/` is an input template with sample client settings and hostnames,
plus placeholders for images and credentials. Copy and complete it for your
installation. The combined output contains the workloads, Services, Ingresses,
storage claims, ConfigMaps and Secret for that installation.

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

The ACME example uses the `onify-citizen-test` namespace. Set the namespace,
configuration and secrets for each installation, for example `acme-prod`.

## Requirements

- `kubectl` with Kustomize support, access to the target Kubernetes cluster.
- Python 3 for the local preflight check.
- An Ingress controller and a StorageClass suitable for Elasticsearch.
- Approved API, root-path Citizen app and Gateway images, with registry access.
- Client code, instance code, license and initial administrator credentials.
- For the example TLS configuration: cert-manager and a `letsencrypt-prod`
  ClusterIssuer, plus DNS records pointing to the Ingress controller.

The example uses the `nginx` Ingress class.
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

Replace the image placeholders in `kustomization.yaml` with approved
repositories and version tags. The Citizen app image must serve `/` on port 4000.
API and worker use the same image. Additional app or Gateway environment
settings can be supplied with a Kustomize patch to their container's `env`.

Environment files contain literal `KEY=value` lines, with no shell expansion.
Keep secret values on a single line and do not wrap them in shell quotes.
Generate the app-token and client secrets once, for
example with `openssl rand -hex 32`, and save them in `secrets.env`.
Reuse these values on later deployments.

Kustomize generates ConfigMaps and a Kubernetes Secret with content hashes.
Rendering unchanged inputs produces unchanged names; changing configuration or
secrets updates the pod references and rolls out the affected workloads.
Local installation directories, secret files and registry credentials are
excluded from Git.

## Environment variables

API and worker both receive these 15 variables from `config.env`. The values
shown are the installation template's defaults or examples; set the client and
administrator details for your installation.

| Variable | Default or example value |
|---|---|
| `NODE_ENV` | `production` |
| `ENV_PREFIX` | `ONIFY_` |
| `INTERPRET_CHAR_AS_DOT` | `_` |
| `ONIFY_client_code` | `acme` |
| `ONIFY_client_instance` | `test` |
| `ONIFY_db_indexPrefix` | `onify` |
| `ONIFY_db_elasticsearch_host` | `http://onify-elasticsearch:9200` |
| `ONIFY_adminUser_username` | `admin` |
| `ONIFY_adminUser_email` | `admin@onify.local` |
| `ONIFY_autoinstall` | `true` |
| `ONIFY_resources_baseDir` | `/usr/share/onify/resources` |
| `ONIFY_resources_tempDir` | `/usr/share/onify/temp_resources` |
| `ONIFY_logging_elasticFlushInterval` | `500` |
| `ONIFY_logging_log` | `stdout,elastic` |
| `ONIFY_worker_cleanupInterval` | `300` |

They also receive these four variables from `secrets.env`, giving each container
19 configured environment variables. Fill in all four values.

| Variable | Value to supply |
|---|---|
| `ONIFY_initialLicense` | Client license |
| `ONIFY_adminUser_password` | Initial administrator password |
| `ONIFY_apiTokens_app_secret` | App-token secret |
| `ONIFY_client_secret` | Client secret |

Additional API/worker variables can be added to the corresponding environment
file; `envFrom` includes every key. Keep credentials in `secrets.env`.

The other containers have the following environment settings:

| Container | Variable | Value | Configured in |
|---|---|---|---|
| App | `ONIFY_API_URL_INTERNAL` | `http://onify-api:8181` | `kubernetes/onify-citizen.yaml` |
| Gateway | `NODE_ENV` | `development` | `kubernetes/onify-citizen.yaml` |
| Gateway | `GATEWAY_TENANCY` | `single` | `kubernetes/onify-citizen.yaml` |
| Gateway | `GATEWAY_FAKE_MODE` | `true` | `kubernetes/onify-citizen.yaml` |
| Gateway | `GATEWAY_AUTH` | `none` | `kubernetes/onify-citizen.yaml` |
| Gateway | `PORT` | `8686` | `kubernetes/onify-citizen.yaml` |
| Elasticsearch | `discovery.type` | `single-node` | `kubernetes/onify-citizen.yaml` |
| Elasticsearch | `cluster.name` | `onify-elasticsearch` | `kubernetes/onify-citizen.yaml` |
| Elasticsearch | `ES_JAVA_OPTS` | `-Xms1024m -Xmx1024m` | Installation's `kustomization.yaml` |

Gateway's values are defaults in the shared base. Override them per environment
in the installation's `kustomization.yaml`. For example:

```yaml
patches:
  - patch: |-
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: onify-gateway
      spec:
        template:
          spec:
            containers:
              - name: gateway
                env:
                  - name: NODE_ENV
                    value: production
                  - name: GATEWAY_FAKE_MODE
                    value: "false"
```

Use the same format to override `GATEWAY_TENANCY` and `GATEWAY_AUTH`.
Kubernetes environment values are strings, so quote boolean values such as
`"true"` and `"false"`.

The optional backup patch adds `path.repo=/usr/share/elasticsearch/backup` to
Elasticsearch. See [Storage and backups](#storage-and-backups).

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

Add the backup manifest and patch to the installation's `kustomization.yaml`:

```yaml
resources:
  # Additional resource:
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
