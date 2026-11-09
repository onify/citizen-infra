# Development

[Getting started](../README.md#getting-started) is the installation guide.
This page explains the repository and checks for changes to it.

## Repository structure

| Path | Purpose |
|---|---|
| [compose.yaml](../compose.yaml), [.env.example](../.env.example) | Docker Desktop example and shared input for Kubernetes preparation. |
| [kubernetes/](../kubernetes/) | Shared workloads and Services. |
| [examples/acme/](../examples/acme/) | Installation template: namespace, images, configuration, ingress, storage and resource/network patches. |
| [examples/customer-package/](../examples/customer-package/) | Customer settings/license template; add the `keyfile.json` supplied by Onify. |
| [scripts/prepare-installation.sh](../scripts/prepare-installation.sh) | Prepares a new installation from `.env` or a JSON customer package. |
| [scripts/kubernetes.compose.yaml](../scripts/kubernetes.compose.yaml) | Kubernetes metadata merged with Compose when reading `.env`; never deployed. |
| [examples/elasticsearch/](../examples/elasticsearch/) | Optional backup volume, snapshot schedule and retention. |
| [tests/check.sh](../tests/check.sh) | Installation preflight; runs `self-check.sh` when called without a directory. |
| `deployments/`, `customer-packages/` | Private generated installations and inputs; ignored by Git. |

Edit shared workloads in `kubernetes/` and installation defaults in
`examples/acme/`. Preparation copies those defaults into `deployments/`; it
does not update existing installations. Keep templates free of customer secrets.

## How Kustomize works

[Kustomize](https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/)
is built into `kubectl`. It combines the shared **base** in `kubernetes/` with an
installation **overlay** such as `deployments/acme-test/`. The overlay's
`kustomization.yaml` selects its base, namespace, images and configuration.

API and worker use `envFrom` to load the generated ConfigMap and Secret. Every
key in `config.env` and `secrets.env` becomes an environment variable. Generated
resource names have content hashes: unchanged inputs produce identical manifests,
while changed inputs roll out the workloads that reference them.

| Component | Workload | Internal address |
|---|---|---|
| API | StatefulSet | `http://onify-api:8181` |
| APP | StatefulSet | `http://onify-app:4000` |
| Worker | StatefulSet, API image with `worker` argument | Background process |
| Gateway | Deployment | `http://onify-gateway:8686` |
| Elasticsearch | StatefulSet | `http://onify-elasticsearch:9200` |

The APP serves `/` and proxies browser API requests to the internal API on the
same origin. Gateway and Elasticsearch remain internal ClusterIP Services.
Elasticsearch stores data on the installation's persistent volume.

The normal flow uses `kubectl apply -k`. To export for another deployment tool:

```bash
umask 077
kubectl kustomize deployments/acme-test > rendered.yaml
```

The output contains Secret data. Keep it out of Git and shared logs and remove
it when finished.

## Run checks

Use the tools listed in [Getting started](../README.md#before-you-start), including
Docker Compose. Run all three checks after changing shared templates:

```bash
bash tests/check.sh
bash tests/prepare-installation.sh
bash tests/compose.sh
```

| Check | Coverage |
|---|---|
| `check.sh` | Kubernetes rendering, workloads, resources, routes, storage/backups, isolation, secret rollouts and authentication. With an installation path, validates that installation instead. |
| `prepare-installation.sh` | JSON/`.env` inputs, defaults, literal credentials, keyfile conversion, private permissions and overwrite protection. |
| `compose.sh` | Docker wiring, credentials, disabled integrations, startup dependencies, loopback port, persistent volume isolation and pull policy. |

These use private temporary files and synthetic credentials, with no Docker
engine, cluster, real license or registry access. They check invalid inputs,
quoting and secret handling; environment files are never executed as shell code.
They do not verify image compatibility or application startup.

For strict Kubernetes JSON schema validation, install
[kubeconform](https://github.com/yannh/kubeconform#installation):

```bash
bash tests/check.sh --schema
bash tests/check.sh deployments/acme-test --schema --kubernetes-version 1.32.0
```

The default schema version, 1.32.0, is a validation baseline, not a recommended
cluster version. Pass your target cluster version explicitly. Schemas are
downloaded from the public registry.

Schema checks do not cover every server-side rule or installed admission policy.
Use the installation guide's server dry run and [runtime checks](operations.md#before-customer-use)
to verify the actual cluster and application images.

## Deployment automation

This repository includes local checks, not a CI/CD pipeline. Add validation,
deployment approval and rollback to your team's existing pipeline before
production. For GitOps, use the [versioned customer configuration](configuration.md#version-customer-configuration)
with your cluster's deployment tool; supply secrets from your secret store.
