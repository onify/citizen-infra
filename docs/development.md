# Development

[Getting started](../README.md#getting-started) is the installation guide.
This page explains the repository and checks for changes to it.

## Repository structure

| Path | Purpose |
|---|---|
| [compose.yaml](../compose.yaml), [.env.example](../.env.example) | Standalone Docker Desktop example; see the [quick start](docker-desktop.md). |
| [kubernetes/](../kubernetes/) | Shared workloads and Services. |
| [examples/acme/](../examples/acme/) | Installation template: namespace, images, configuration, ingress, storage and resource/network patches. |
| [examples/customer-package/](../examples/customer-package/) | Customer package template: settings, license and registry credentials. |
| [scripts/prepare-installation.sh](../scripts/prepare-installation.sh) | Prepares a new installation and generates its credentials. |
| [examples/elasticsearch/](../examples/elasticsearch/) | Optional backup volume, snapshot schedule and retention. |
| [tests/check.sh](../tests/check.sh) | Installation preflight; runs `self-check.sh` when called without a directory. |
| [.github/workflows/validate.yaml](../.github/workflows/validate.yaml) | Rendering and strict schema validation on pushes and pull requests. |

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

Use the tools listed in [Getting started](../README.md#before-you-start):

```bash
bash tests/check.sh
bash tests/prepare-installation.sh
```

For the Docker Desktop example, with Docker Compose and jq installed:

```bash
bash tests/compose.sh
```

This renders synthetic inputs and checks required values, shared credentials,
startup dependencies, the single loopback port, persistent Elasticsearch storage,
separate volumes for different client/instance pairs and an always-pull policy
for every service.
It needs no Docker daemon, registry credentials or license. It does not verify
image compatibility or application startup; follow the [local guide](docker-desktop.md)
to check startup and login with approved images. CI runs this check too.

The self-check uses temporary test credentials and covers rendering, all five
workloads, Services, routes, storage, resource budgets, isolation rules, input
validation and the backup patch. It also checks configuration/secret rollouts,
Gateway authentication, literal secret values, duplicate keys and Windows line
endings. Environment files are read as data, never executed. Temporary files
are private and removed on exit; no cluster connection is made.
The package checks cover generated settings/credentials, file permissions,
invalid input, registry coverage, cleanup and protection against overwriting an
existing installation. They also verify that supplied credentials are preserved
and empty fields are generated independently. CI runs both suites.

For strict Kubernetes JSON schema validation, install
[kubeconform](https://github.com/yannh/kubeconform#installation):

```bash
bash tests/check.sh --schema
bash tests/check.sh deployments/acme-test --schema --kubernetes-version 1.32.0
```

The default schema version is 1.32.0; select the target cluster version when
checking an installation. Schemas are downloaded from the public registry.
CI uses pinned, checksum-verified kubectl, yq and kubeconform releases and the
runner's jq. It validates the standard and backup variants with test inputs.

Schema checks do not cover every server-side rule or installed admission policy.
Use the installation guide's server dry run and [runtime checks](operations.md#before-customer-use)
to verify the actual cluster and application images.
