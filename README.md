# Onify Citizen Infrastructure

Deploy a new Onify Citizen environment: API, APP, worker, Gateway and Elasticsearch.
Onify supplies a `keyfile.json` for access to its container images, whether you
install with Docker or Kubernetes.

**Quick local setup:** use the [Docker Desktop guide](docs/docker-desktop.md).
Fill in `.env`, authenticate Docker with the supplied `keyfile.json`, and start
all five services with the root [compose.yaml](compose.yaml).
Already configured? See [start again or update images](docs/docker-desktop.md#start-again-update-or-stop).
For Kubernetes, reuse the same `.env` and `keyfile.json` with the guide below.

## CI/CD and GitOps

This repository provides initial deployment boilerplate to help you get started.
Before production use, review and extend the CI/CD workflow to suit your
environment, including automated validation, controlled deployments and rollback.

We recommend GitOps for Kubernetes deployments, using Flux, Argo CD or a similar
tool to keep the cluster aligned with version-controlled configuration. Terraform
or equivalent infrastructure-as-code tooling can complement this by managing the
underlying infrastructure. Choose the tools that fit your team's requirements
and existing platform.

## Getting started

This guide creates an empty installation: no imported customer data and no
enabled Gateway integrations. The API initializes its own system data and admin
account on first start. Keep the default Gateway settings for this first setup.
Reusing `.env` carries over configuration and credentials; it does not migrate
the Docker volume, users or application data to Kubernetes.

### Before you start

- A Kubernetes cluster with a default StorageClass (at least 10Gi available),
  a network plugin that enforces NetworkPolicy, and permission to deploy.
- The example uses `nginx` Ingress, cert-manager with a `letsencrypt-prod`
  ClusterIssuer, and APP/API DNS names pointing to the Ingress controller.
  For other cluster settings, see [configuration](docs/configuration.md#cluster-settings).
- Approved API, APP and Gateway image versions, a client license,
  and the `keyfile.json` supplied by Onify with read access to those images.
- Bash 3.2+, `kubectl`, `openssl`, [Mike Farah yq v4](https://github.com/mikefarah/yq#install)
  and [jq 1.6+](https://jqlang.org/download/). On macOS: `brew install kubectl yq jq`.
- Docker Compose 2.23.1+ to read the shared `.env` with Docker's own syntax.
  No running Docker engine is needed for preparation.

Run the commands from this repository's root, in the same terminal.
The commands below use client `acme`, instance `test` and namespace `acme-test`.
Use the directory printed by the script and your configured namespace.

### 1. Reuse your .env and keyfile.json

Keep the `.env` and Onify-supplied `keyfile.json` you used for Docker beside
`compose.yaml`. For a fresh installation, copy [.env.example](.env.example) to
`.env` and fill in its shared settings: the three image tags, client/instance
codes, license, admin username/password, APP-token secret and client secret.

Every `K8S_*` setting has a default, even if missing or empty. An older Docker
`.env` works without adding a Kubernetes section. For client `acme` and instance
`test`, the defaults are namespace `acme-test`, APP host `acme-test.example.com`
and API host `api-acme-test.example.com`, nginx Ingress, `letsencrypt-prod`,
10Gi storage and the cluster's default StorageClass.

These are preparation defaults. Before deploying to a live cluster, set
`K8S_APP_HOST` and `K8S_API_HOST` to real DNS names pointing to its Ingress
controller; `example.com` is an example domain and cannot provide your live TLS
certificate. Check the [Kubernetes settings](docs/configuration.md#kubernetes-settings-in-env)
if your cluster uses another controller, issuer or StorageClass. `APP_PORT` only
affects Docker; Kubernetes uses HTTPS hostnames.

Keep single quotes around license/secret values, as in the Docker guide. Use
single-line values. Shell variables override matching `.env` values in both
flows. Protect `.env` and `keyfile.json` with `chmod 600 .env keyfile.json`.
No Docker login or Google Cloud CLI is needed for Kubernetes preparation.

The [JSON customer-package flow](docs/customer-package.md#alternative-json-customer-package)
is still supported for installations prepared without Docker Compose.

### 2. Prepare the installation

```bash
bash scripts/prepare-installation.sh --env-file .env
```

The script uses the same image tags and credentials as Docker, fills in the
Kubernetes installation files, converts `keyfile.json` into
`registryCredentials.json`, and runs preflight. All shared credentials must be
filled in; this path does not generate replacement passwords. The keyfile is
read from the directory containing your `.env`.

It reports `deployments/<client_code>-<client_instance>/` and refuses to overwrite
an existing installation. Save that directory securely. Preparation creates a
new installation; later `.env` edits are not automatically applied to it. Follow
[Operations](docs/operations.md#apply-changes) for later changes.

### 3. Select the cluster

```bash
kubectl config get-contexts
```

After preparation reports `Installation preflight passed`, select the intended
context from the list and set the namespace from the generated `namespace.yaml`:

```bash
ONIFY_CONTEXT=REPLACE_WITH_CONTEXT
ONIFY_NAMESPACE=acme-test
```

### 4. Install

Use the `registryCredentials.json` generated from your keyfile to create the
namespace and image-pull Secret. Keep this generated file private; it contains
the key. The original `keyfile.json` cannot be used directly as `.dockerconfigjson`.

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

- [Docker Desktop](docs/docker-desktop.md): a complete local Compose example.
- [Customer package](docs/customer-package.md): the files and settings to prepare for a customer.
- [Configuration](docs/configuration.md): images, cluster settings, variables and integrations.
- [Operations](docs/operations.md): updates, troubleshooting and checks before customer use.
- [Backups](docs/backups.md): snapshots, retention and restore verification.
- [Development](docs/development.md): repository structure, Kustomize and local tests.
