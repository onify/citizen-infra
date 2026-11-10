# Onify Citizen Infrastructure

Deploy a new Onify Citizen environment: API, APP, worker, Gateway and Elasticsearch.
APP uses the `citizen/app-root` image.
Both installation guides use `.env` for settings and the `keyfile.json` supplied
by Onify for access to its container images. Choose the guide for your environment.

| Task | Guide |
|---|---|
| Run locally with Docker | [Docker Desktop](docs/docker-desktop.md) |
| Deploy to Kubernetes | [Getting started](#getting-started) below |
| Prepare files for a customer | [Customer package](docs/customer-package.md) |
| Change images, resources or integrations | [Configuration](docs/configuration.md) |
| Update or troubleshoot an installation | [Operations](docs/operations.md) |
| Set up snapshots and verify recovery | [Backups](docs/backups.md) |
| Add optional Kubernetes security hardening | [Kubernetes security](docs/security.md) |
| Understand the repository or run checks | [Development](docs/development.md) |

The [security additions](docs/security.md) are **optional and Kubernetes-only**.
Enable Elasticsearch HTTPS/authentication, non-root containers, or both explicitly
in each installation's Kustomize overlay. They are not enabled by the standard
installation or preparation script. Docker Compose is unchanged.

## Getting started

This Kubernetes guide creates an empty installation. API initializes system data
and an admin account; import the Citizen workspace/customer content separately.
Gateway integrations are disabled.

### Before you start

- A Kubernetes cluster with a default StorageClass (at least 10Gi available),
  a network plugin that enforces NetworkPolicy, and permission to deploy.
  Allow for the [resource profile](docs/configuration.md#resource-sizing) and
  [Elasticsearch host settings](docs/configuration.md#cluster-settings).
- The example uses `nginx` Ingress, cert-manager with a `letsencrypt-prod`
  ClusterIssuer, and APP/API DNS names pointing to the Ingress controller.
  For other cluster settings, see [configuration](docs/configuration.md#cluster-settings).
- Approved API, APP and Gateway image versions, a client license,
  and the `keyfile.json` supplied by Onify with read access to those images.
  Use an APP **app-root** image and API/worker images compatible with Elasticsearch 9.5.
- Bash 3.2+, `kubectl`, `openssl`, [Mike Farah yq v4](https://github.com/mikefarah/yq#install)
  and [jq 1.6+](https://jqlang.org/download/). On macOS: `brew install kubectl yq jq`.
- Docker Compose CLI 2.23.1+ to parse `.env` during preparation; no containers
  are started. The [JSON input format](docs/customer-package.md#alternative-json-customer-package)
  does not require this tool.

Run the commands from this repository's root, in the same terminal.
The commands below use client `acme`, instance `test` and namespace `acme-test`.
Use the directory printed by the script and your configured namespace.

### 1. Prepare .env and keyfile.json

Place the `keyfile.json` supplied by Onify in the repository root. For a new
installation, create `.env` from [.env.example](.env.example). If you have already
prepared `.env` for this installation, keep that file instead of copying again:

```bash
cp .env.example .env
chmod 600 .env keyfile.json
```

Fill in the three image tags, client/instance codes matching the license, license,
admin username/password, APP-token secret and client secret. For each of the
three secrets, use a password manager or run `openssl rand -hex 32` separately.

All `K8S_*` values have [defaults](docs/configuration.md#kubernetes-settings-in-env).
Before preparation for a live cluster, set `K8S_APP_HOST` and `K8S_API_HOST` to
distinct real DNS names pointing to its Ingress controller; the default
`example.com` names cannot provide your TLS certificate. Check the controller,
issuer and StorageClass settings too. Leave `APP_PORT` unchanged; Kubernetes
does not use it.

Keep license/secret values on one line and retain the single quotes shown in the
template so `$`, `#` and spaces stay literal. Escape a literal apostrophe as `\'`.
Shell variables override matching `.env` values. Preparation reads `keyfile.json`
directly; no registry login or Google Cloud CLI is needed.

For JSON input, follow [Customer package](docs/customer-package.md#alternative-json-customer-package)
instead of steps 1–2, then continue at [Select the cluster](#3-select-the-cluster).

### 2. Prepare the installation

```bash
bash scripts/prepare-installation.sh --env-file .env
```

The script reads `keyfile.json` beside `.env`, creates Kubernetes files and
`registryCredentials.json`, and runs offline preflight. Image tags and credentials
are taken from `.env`; all must be filled in for this input format.

It reports `deployments/<client_code>-<client_instance>/` and refuses to overwrite
an existing installation. Save that directory securely. Later `.env` edits do
not update it; edit the generated files and follow [Operations](docs/operations.md#apply-changes).

### 3. Select the cluster

After preparation reports `Installation preflight passed`, run this in your
terminal from the repository root to list the available Kubernetes contexts:

```bash
kubectl config get-contexts
```

In **the same terminal**, run the assignments below. Replace
`REPLACE_WITH_CONTEXT` with the intended context's value from the `NAME` column.
Replace `acme-test` with `metadata.name` from your generated
`deployments/<client>-<instance>/namespace.yaml`:

```bash
ONIFY_CONTEXT=REPLACE_WITH_CONTEXT
ONIFY_NAMESPACE=acme-test
```

These are temporary shell variables used by the `kubectl` commands below.
Do not put them in `.env`; no `export` is needed. Continue in this terminal,
or set them again if you open a new one. `K8S_NAMESPACE` in `.env` is the input
used during preparation; `ONIFY_NAMESPACE` here refers to that prepared namespace.

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

Before storing customer data, complete the [runtime checks](docs/operations.md#before-customer-use)
and configure [backups](docs/backups.md).

## License

The scripts, configuration files and documentation in this repository are
licensed under the [MIT License](LICENSE).
Onify products and the container images referenced here are subject to their
own license terms; this license does not grant rights to those products or images.
