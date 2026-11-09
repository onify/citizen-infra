# Configuration

[Getting started](../README.md#getting-started) covers the first empty installation.
Use this reference when adapting it for a customer. Paths below are relative to
the installation directory, for example `deployments/acme-test/`.
The [package preparation script](customer-package.md) fills these files in for
a new installation; edit the generated files for later adjustments.

## Images and environment files

Set the API, APP and Gateway images and approved version tags in
`kustomization.yaml`. API and worker share the same API image.

Kubernetes and Docker Compose default to Elasticsearch **9.5.6**. Both use the
internal HTTP endpoint with `xpack.security.enabled=false`, matching the API's
connection settings. Keep Elasticsearch isolated using the supplied NetworkPolicy
or private Compose network. Select API/worker images compatible with Elasticsearch
9.5 and follow the [upgrade precautions](operations.md#elasticsearch-upgrades)
before reusing existing data.

| File | Purpose |
|---|---|
| [config.env](../examples/acme/config.env) | API/worker settings: client identity, admin identity, internal URLs, logging and initialization. |
| [secrets.env.example](../examples/acme/secrets.env.example) → `secrets.env` | License, initial admin password, APP-token secret and client secret; all four are required. |
| [gateway.env](../examples/acme/gateway.env) | Gateway mode and non-secret integration settings. |
| [gateway-secrets.env.example](../examples/acme/gateway-secrets.env.example) → `gateway-secrets.env` | Credentials for enabled integrations; may contain only comments for an empty installation. |

Use literal `KEY=value` lines, with one value per line and no shell quotes or
shell expansion. Additional API/worker variables can be added to the matching
file; both containers load every key. Keep credentials in the secret files.
Additional APP settings can be supplied with a Kustomize patch to its container's
`env`.

Kustomize generates ConfigMaps and Secrets with content hashes. Changing a file
changes the pod references and rolls out the affected workloads. Keep generated
credentials stable across deployments. The APP receives only the internal API
URL (`http://onify-api:8181`); it does not receive API credentials.

## Kubernetes settings in .env

Use the same [.env.example](../.env.example) as Docker. Preparation reads it with
Docker Compose, then creates the literal `config.env` and `secrets.env` files
used by Kustomize. Do not copy the quoted `.env` directly into those files.
Images and shared credentials come from the root Compose configuration; the
following settings only affect Kubernetes preparation. All have defaults when
omitted or empty; no `K8S_*` values need to be filled in to prepare an installation:

| Variable | Purpose/default |
|---|---|
| `K8S_APP_HOST` | `<client_code>-<client_instance>.example.com`. |
| `K8S_API_HOST` | `api-<client_code>-<client_instance>.example.com`. |
| `K8S_NAMESPACE` | Empty uses `<ONIFY_client_code>-<ONIFY_client_instance>`. |
| `K8S_INGRESS_CLASS` | Ingress class; default `nginx`. |
| `K8S_CLUSTER_ISSUER` | Existing cert-manager ClusterIssuer; default `letsencrypt-prod`. |
| `K8S_INGRESS_CONTROLLER_NAMESPACE` | Controller namespace; default `ingress-nginx`. |
| `K8S_INGRESS_CONTROLLER_NAME` | Controller's `app.kubernetes.io/name` pod label; default `ingress-nginx`. |
| `K8S_STORAGE_SIZE` | Elasticsearch volume size; default `10Gi`. |
| `K8S_STORAGE_CLASS` | Empty uses the cluster's default StorageClass. |

Replace the example hostnames with real, distinct DNS names pointing to your
Ingress controller before live deployment. Default hostnames are only examples;
they do not configure DNS or issue working TLS certificates.

For a controller with other pod label keys, adjust `network-policy.yaml` in the
prepared installation before applying it, or use the JSON customer package.
Review resource budgets in `resources-patch.yaml` for the target cluster.

`.env` is an input for a **new** installation. It does not update an existing
deployment or transfer Docker's data. `APP_PORT` and `COMPOSE_PROJECT_NAME` only
control the local Docker installation. Shell overrides follow
[Docker Compose's precedence](https://docs.docker.com/compose/how-tos/environment-variables/variable-interpolation/#ways-to-set-variables-with-interpolation).
Keep license/password/secret values on one line; quote literal values with single
quotes as in the template. Unknown extra `.env` variables are not passed to the
Kubernetes workloads automatically.

## Cluster settings

- **Namespace:** use the same name in `namespace.yaml` and `kustomization.yaml`.
- **Ingress and TLS:** set hosts in both `rules` and `tls` in `ingress.yaml`.
  Change `ingressClassName` and controller-specific annotations to match your
  cluster. For an existing TLS certificate, create its `kubernetes.io/tls`
  Secret in the installation namespace, set its name, and remove the
  cert-manager annotation. Remove the API Ingress document if direct external
  API access is unnecessary; keep the APP Ingress for browser access.
- **Storage:** `storage.yaml` requests 10Gi from the default StorageClass.
  Set `storageClassName` if needed and size the disk for the installation.
- **Resources:** `resources-patch.yaml` sets CPU/memory requests and memory limits
  for all five workloads. Review the [starting profile](#resource-sizing) and
  adjust it for the customer's workload and cluster policy before production.
- **Elasticsearch host:** configure `vm.max_map_count=1048576` on the Linux nodes
  that run Elasticsearch; see [Elastic's host requirements](https://www.elastic.co/docs/deploy-manage/deploy/self-managed/install-elasticsearch-docker-prod).
- **Network:** set both Ingress controller selectors in `network-policy.yaml`
  to match the actual namespace and pod labels. The policy allows traffic within
  the installation namespace and controller access to APP/API ports 4000/8181.
  Outbound traffic is unchanged. NetworkPolicies are additive, so another broad
  allow policy can still permit access. If central policies provide the same
  isolation, verify them before removing the example policy.

Onify supplies `keyfile.json` for image access. [Package preparation](customer-package.md#3-add-the-keyfile-supplied-by-onify)
generates `registryCredentials.json` for each Google registry used by the selected
images; the [installation guide](../README.md#4-install) uses it to create
`onify-regcred`. The service account must have read access to all selected image
repositories. If you later change registry hosts, update the Docker config and
reapply the pull Secret; editing image names alone does not update credentials.

## Resource sizing

These are starting values for one replica of each service, not measured customer
capacity. Onify maintains the starting profile; the customer's operations team
must validate it with representative traffic, concurrent jobs and data volumes
before production, then monitor memory peaks, restarts and CPU contention.

| Container | CPU request | Memory request | Memory limit |
|---|---:|---:|---:|
| API (Node.js) | `1000m` | `2Gi` | `4Gi` |
| Worker (Node.js) | `1000m` | `2Gi` | `4Gi` |
| Gateway (Node.js) | `250m` | `512Mi` | `1Gi` |
| APP (Nginx) | `100m` | `64Mi` | `256Mi` |
| Elasticsearch | `1000m` | `4Gi` | `4Gi` |

CPU limits are omitted so services can use spare CPU during bursts. Keep requests
and memory limits; add CPU limits in `resources-patch.yaml` if the customer's
policy requires them. A namespace LimitRange can inject defaults, and quotas
can require explicit limits. Check the admitted Pods as well as the rendered
manifests. See [Kubernetes resource management](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/).

With one replica each, requests total **3.35 CPU and 8.5625 GiB memory**; memory
limits total **13.25 GiB**. Requests are scheduling budgets, not usage caps.
Allow capacity for simultaneous peaks, system services, other workloads and
rollouts; summing requests alone does not cover peak memory demand.

API and worker share `NODE_OPTIONS=--max-old-space-size=3072` in `config.env`.
Gateway uses `--max-old-space-size=640` in `gateway.env`. These values limit V8's
old space, not total process memory. Buffers, native allocations, other heap
regions and additional processes need headroom inside the container limit.
Revisit both settings together when changing memory budgets; see
[Node.js heap sizing](https://nodejs.org/api/cli.html#--max-old-space-sizesize-in-mib).

Elasticsearch uses a 2 GiB heap (`-Xms2g -Xmx2g` in `kustomization.yaml`) with
4 GiB requested and limited memory. Keep manual heap sizing at no more than
half the container's available memory to leave room for off-heap allocations
and filesystem cache. Elastic recommends automatic heap sizing for most
production deployments; when overriding it in production, use a JVM options
file rather than the example's `ES_JAVA_OPTS` environment variable. See
[Elasticsearch JVM settings](https://www.elastic.co/docs/reference/elasticsearch/jvm-settings).

New installations prepared from either `.env` or a customer package inherit this
profile. Existing installation directories keep their settings: update their
`resources-patch.yaml`, `config.env`, `gateway.env` and Elasticsearch heap setting
together, then follow the [update procedure](operations.md#apply-changes).
The local Docker Desktop example has its own development resource settings.

## Gateway integrations

The default is live mode with Halo API JWT authentication. Gateway reads the
API client code and client secret through individual references; it does not
receive the admin password or APP token. Changes to client identity or its
secret roll out API, worker and Gateway together. Callers must forward a valid
Halo API user JWT; the static APP token is not a Gateway JWT.

No integrations are enabled by the template. The three standard connections
are explicitly disabled so the empty installation needs no provider credentials.
Choose integrations using the documentation for the pinned Gateway release:
[configuration](https://github.com/onify/gateway/blob/main/docs/configuration.md)
and [connection variables](https://github.com/onify/gateway/blob/main/.env.example).
The links open `main`; select the version matching your image.

For example, enable only Actor Smartbook in `gateway.env`:

```dotenv
GATEWAY_INTEGRATION_ACTORSMARTBOOK_ASSOCIATIONS_ENABLED=true
GATEWAY_INTEGRATION_ACTORSMARTBOOK_ASSOCIATIONS_BASE_URL=REPLACE_WITH_PROVIDER_URL
```

Put `GATEWAY_INTEGRATION_ACTORSMARTBOOK_ASSOCIATIONS_API_KEY` in
`gateway-secrets.env`. Keep the other integrations disabled. After applying,
make an authenticated call to the enabled integration to check connectivity
and mappings; preflight only verifies configuration wiring.

Other supported configurations:

- **API-key authentication:** set `GATEWAY_AUTH=api-key`, put `GATEWAY_API_KEY`
  in `gateway-secrets.env`, and configure callers to send `x-api-key`.
- **Isolated demo with fake data:** set `NODE_ENV=development`,
  `GATEWAY_FAKE_MODE=true` and `GATEWAY_AUTH=none` together. Preflight rejects
  unauthenticated live mode and fake data in production mode.
- **Customer JSON configuration:** mount the reviewed JSON through a generated
  ConfigMap, set `GATEWAY_CONFIG` to its container path, and remove the three
  `GATEWAY_INTEGRATION_*_ENABLED` switches when the manifest owns activation.
- **Halo API resource/configuration sync:** enable separately with the documented
  URL/token settings. JWT validation settings alone do not enable sync.

## Version customer configuration

Keep non-secret installation files in the customer's private deployment
repository, including `.gitignore`, configuration, patches and backup policy
JSON. Keep both secret files and registry credentials in your existing secret
store, restoring them with restricted permissions when deploying.

In a separate repository, replace `../../kubernetes` in `kustomization.yaml`
with a reviewed, published commit:

```yaml
resources:
  - https://github.com/onify/citizen-infra//kubernetes?ref=REPLACE_WITH_FULL_COMMIT_SHA
  - namespace.yaml
  - ingress.yaml
  - storage.yaml
  - network-policy.yaml
```

Git must have read access; keep credentials out of the URL. Alternatively, use
a local checkout at a recorded commit. Pin images to immutable release
identifiers or digests and record the last accepted deployment revision.
Shared-base changes reach an installation only when its pinned revision changes.
