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
- **Resources:** `resources-patch.yaml` sets CPU/memory requests and limits for
  all five workloads. These are starting budgets, not measured customer
  capacity. Keep Elasticsearch's heap (`ES_JAVA_OPTS` in `kustomization.yaml`)
  below its container memory limit; the example uses a 1Gi heap and 2Gi limit.
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
