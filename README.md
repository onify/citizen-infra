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
- Bash 3.2+, `kubectl`, `openssl`, [Mike Farah yq v4](https://github.com/mikefarah/yq#install)
  and [jq 1.6+](https://jqlang.org/download/). On macOS: `brew install kubectl yq jq`.

Run the commands from this repository's root, in the same terminal.
The commands below use the example package's `acme-test` directory and namespace.
Use the directory printed by the script and the namespace from your package.

### 1. Get your customer package

Place the prepared package in `customer-packages/acme-test/`. It must contain
`customer.json` (including the license) and `registryCredentials.json`.
If you are preparing it for a customer, follow the
[package checklist and template](docs/customer-package.md).

### 2. Prepare the installation

```bash
bash scripts/prepare-installation.sh customer-packages/acme-test
```

The script fills in the installation files, generates any empty password/secret
fields, preserves supplied values, and runs preflight. It reports the resulting
directory and refuses to overwrite an existing installation. Save `secrets.env` securely;
reuse these credentials for later deployments.

### 3. Select the cluster

```bash
kubectl config get-contexts
```

After preparation reports `Installation preflight passed`, select the intended
context from the list and set the namespace from `customer.json`:

```bash
ONIFY_CONTEXT=REPLACE_WITH_CONTEXT
ONIFY_NAMESPACE=acme-test
```

### 4. Install

Use the registry credentials copied into the installation to create the namespace
and image-pull Secret:

```bash
ONIFY_REGISTRY_FILE=deployments/acme-test/registryCredentials.json
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

- [Customer package](docs/customer-package.md): the files and settings to prepare for a customer.
- [Configuration](docs/configuration.md): images, cluster settings, variables and integrations.
- [Operations](docs/operations.md): updates, troubleshooting and checks before customer use.
- [Backups](docs/backups.md): snapshots, retention and restore verification.
- [Development](docs/development.md): repository structure, Kustomize and local tests.
