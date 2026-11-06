# Onify Citizen Infrastructure

Deploy a new Onify Citizen environment on Kubernetes: API, APP, worker, Gateway
and Elasticsearch.

## Getting started

This guide creates an empty installation: no imported customer data and no
enabled Gateway integrations. The API initializes its own system data and admin
account on first start. Keep the default Gateway settings for this first setup.

### Before you start

- A Kubernetes cluster with a default StorageClass (at least 10Gi available),
  a network plugin that enforces NetworkPolicy, and permission to deploy.
- The example uses `nginx` Ingress, cert-manager with a `letsencrypt-prod`
  ClusterIssuer, and APP/API DNS names pointing to the Ingress controller.
  For other cluster settings, see [configuration](docs/configuration.md#cluster-settings).
- Approved API, APP and Gateway image versions, a client license,
  and a Docker registry credentials JSON file covering those images.
- Bash 3.2+, `kubectl`, [Mike Farah yq v4](https://github.com/mikefarah/yq#install)
  and [jq 1.6+](https://jqlang.org/download/). On macOS: `brew install kubectl yq jq`.

Run the commands from this repository's root, in the same terminal.
The guide uses the namespace `onify-citizen-test`; it must be unused by another
installation. To choose another name, change it in both `namespace.yaml` and
`kustomization.yaml` in your copy.

### 1. Copy the example

```bash
mkdir -p deployments
cp -R examples/acme deployments/acme-test
cp deployments/acme-test/secrets.env.example deployments/acme-test/secrets.env
cp deployments/acme-test/gateway-secrets.env.example deployments/acme-test/gateway-secrets.env
chmod 600 deployments/acme-test/secrets.env deployments/acme-test/gateway-secrets.env
```

Use a new destination directory. Your local installation and secret files are
excluded from Git.

### 2. Fill in the installation values

Edit these files in `deployments/acme-test/`:

| File | What to set |
|---|---|
| `kustomization.yaml` | Set the API, APP and Gateway images and version tags. Replace all `REPLACE_WITH_…` placeholders. |
| `config.env` | Set `ONIFY_client_code` to the licensed client, `ONIFY_client_instance`, and the admin username/email. Keep the internal URLs and other defaults. |
| `secrets.env` | Fill in all four values: license, admin password, APP-token secret and client secret. |
| `ingress.yaml` | Replace the APP/API hostnames in **both** `rules` and `tls`. |
| `network-policy.yaml` | Confirm the Ingress controller namespace and pod labels match your cluster. |

Generate each of the APP-token and client secrets with `openssl rand -hex 32`.
Save the values in `secrets.env` and keep them for later deployments. Use literal
`KEY=value` lines without shell quotes.

Leave `gateway.env` unchanged and `gateway-secrets.env` without credentials.
The example's storage and resource settings are starting values for this empty
environment. See [configuration](docs/configuration.md) for adjustments.

### 3. Check the configuration

```bash
bash tests/check.sh deployments/acme-test
kubectl config get-contexts
```

The check must report `Installation preflight passed`. Select the intended
context from the list and set the namespace to match your files:

```bash
ONIFY_CONTEXT=REPLACE_WITH_CONTEXT
ONIFY_NAMESPACE=onify-citizen-test
```

### 4. Install

Set the path to your Docker registry credentials JSON, then create the namespace
and image-pull Secret:

```bash
ONIFY_REGISTRY_FILE=/secure/path/registryCredentials.json
kubectl --context "$ONIFY_CONTEXT" apply -f deployments/acme-test/namespace.yaml
kubectl --context "$ONIFY_CONTEXT" -n "$ONIFY_NAMESPACE" create secret generic onify-regcred \
  --type=kubernetes.io/dockerconfigjson \
  --from-file=".dockerconfigjson=$ONIFY_REGISTRY_FILE" \
  --dry-run=client -o yaml | kubectl --context "$ONIFY_CONTEXT" apply -f -
```

Check the manifests against the cluster. If that succeeds, apply them:

```bash
kubectl --context "$ONIFY_CONTEXT" apply --dry-run=server -k deployments/acme-test && \
kubectl --context "$ONIFY_CONTEXT" apply -k deployments/acme-test
```

### 5. Wait for startup and open the APP

```bash
for workload in statefulset/onify-elasticsearch statefulset/onify-api \
  statefulset/onify-worker statefulset/onify-app deployment/onify-gateway; do
  kubectl --context "$ONIFY_CONTEXT" -n "$ONIFY_NAMESPACE" rollout status "$workload" --timeout=5m || break
done
kubectl --context "$ONIFY_CONTEXT" -n "$ONIFY_NAMESPACE" get pods,ingress,pvc
```

All five workloads should finish rolling out, pods should be `Running` and ready,
and the Elasticsearch PVC should be `Bound`. Open `https://<your-app-host>/`
using the hostname you set in `ingress.yaml`. Sign in with the admin username
from `config.env` and password from `secrets.env`.

Confirm that the APP loads and login works. This is the starting environment;
customer content and integrations can be added afterwards. If startup or login
fails, start with [troubleshooting](docs/operations.md#troubleshooting).

## Next steps

- [Configuration](docs/configuration.md): images, cluster settings, variables and integrations.
- [Operations](docs/operations.md): updates, troubleshooting and checks before customer use.
- [Backups](docs/backups.md): snapshots, retention and restore verification.
- [Development](docs/development.md): repository structure, Kustomize and local tests.
