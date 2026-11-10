# Prepare a customer package

Choose one input format and keep it beside the `keyfile.json` supplied by Onify:

| Input | Use when | Credentials |
|---|---|---|
| [.env.example](../.env.example) → `.env` | Preparing a Kubernetes installation from environment settings. Requires Compose CLI to parse the file. | Fill in every secret. |
| [customer.json](../examples/customer-package/customer.json) | Preparing Kubernetes without Compose, or selecting custom Google image repositories/controller labels. | Empty password/secret strings are generated. License is always required. |

For the `.env` format, follow [Getting started](../README.md#getting-started)
and prepare with:

```bash
bash scripts/prepare-installation.sh --env-file .env
```

The path can be outside the repository, for example
`--env-file customer-packages/acme-test/.env`. The script does not merge JSON
settings into this input. Keep packages private and transfer them through your
existing secure file transfer or secret store.

## Alternative: JSON customer package

Prepare these files, then follow the four steps below:

```text
customer-packages/acme-test/
├── customer.json
└── keyfile.json
```

## 1. Create the package

From the repository root, copy the template into a new directory:

```bash
mkdir -p customer-packages
mkdir -m 700 customer-packages/acme-test && \
cp examples/customer-package/customer.json customer-packages/acme-test/ && \
chmod 600 customer-packages/acme-test/*
```

`customer-packages/` is excluded from Git. Fill in `customer.json` and add the
keyfile as described below.

## 2. Fill in customer.json

The [JSON template](../examples/customer-package/customer.json) includes every
supported field. Keep all fields, replace every `REPLACE_WITH_…` value and confirm
the prefilled settings with the cluster administrator.

| Setting | What you provide |
|---|---|
| `client_code` | The client code matching the license. |
| `instance_code` | Instance code, such as `test` or `prod`. |
| `namespace` | An unused Kubernetes namespace for this installation. |
| `license` | The actual client license as a JSON string. Required; it is not generated. |
| `admin.username` | Initial administrator username. |
| `admin.password` | Initial administrator password, or `""` to generate one. |
| `app_secret` | APP-token secret, or `""` to generate one. The APP-token also provides administrative API access. |
| `client_secret` | Client secret, or `""` to generate one. Gateway references the same value. |
| `images.api`, `images.app`, `images.gateway` | Registry/repository and approved version tag for each image. API and worker share the API image; APP uses the `citizen/app-root` image. |
| `ingress.app_host`, `ingress.api_host` | Two different DNS names pointing to the cluster's Ingress controller. |
| `ingress.class_name`, `ingress.cluster_issuer` | Existing Ingress class and cert-manager ClusterIssuer. Defaults: `nginx` and `letsencrypt-prod`. |
| `ingress.controller_namespace`, `ingress.controller_labels` | The controller's actual namespace and pod labels, used by NetworkPolicy. |
| `storage.size`, `storage.class_name` | Elasticsearch disk size (for example `10Gi`) and StorageClass. Use `""` for the cluster's default class. |

Client code, instance code, namespace and the class/issuer names use lowercase
letters, digits and internal hyphens, up to 63 characters. Image repositories
include their registry hostname; supply tags separately. Use the example's
[starting resource profile](configuration.md#resource-sizing) for the first empty
installation. Adjust the generated resource and heap settings for customer
capacity and cluster policy before production.

Use single-line JSON strings for credentials. Non-empty strings are preserved
exactly; empty password/secret strings get independent random values from
`openssl rand -hex 32`. `app_secret` is the secret portion of the APP-token,
not an encoded bearer token. The license is not verified with the API.

## 3. Add the keyfile supplied by Onify

Copy the original Google service-account JSON supplied by Onify to
`customer-packages/acme-test/keyfile.json`, then restrict its permissions:

```bash
chmod 600 customer-packages/acme-test/keyfile.json
```

The file must contain `type: service_account`, `client_email` and `private_key`.
Use the original file without base64 conversion. Onify provides the key with
read access to the API, APP and Gateway repositories; no new Google account or
key needs to be created.

Preparation checks the JSON and private-key format and generates registry credentials
using Google's [`_json_key` authentication](https://docs.cloud.google.com/artifact-registry/docs/docker/authentication#json-key).
It adds an entry for each image registry in `customer.json`. Supported hosts are
`gcr.io`, `eu.gcr.io`, `us.gcr.io`, `asia.gcr.io` and regional
`*-docker.pkg.dev` hosts; other hosts are rejected to avoid exposing the key.
These local checks do not verify Google permissions, key revocation or image tags.

`registryCredentials.json` is generated output for Kubernetes' image-pull Secret;
do not use it as the input `keyfile.json`.

## 4. Prepare the installation

With Bash, `jq`, Mike Farah `yq` v4, `kubectl` and `openssl` installed, run:

```bash
bash scripts/prepare-installation.sh customer-packages/acme-test
```

The script creates `deployments/<client_code>-<instance_code>/`, fills in the
manifests and environment files, generates `registryCredentials.json` from
`keyfile.json`, and runs preflight. The resulting license and credentials are
saved in `secrets.env`; they are not printed.
Files are readable/writable only by their owner, and directories are private.
The generated registry credentials contain the encoded key; protect the file
like the original keyfile. The original stays in the package and is not mounted
into application containers.

Gateway starts with authentication enabled and no integrations. Its client code
and client secret reference the API configuration automatically.

An existing destination is rejected without changing it. This command prepares
**new installations**; it does not rotate credentials or update an existing one.
Save the generated installation and credentials in your existing secret store
before deploying. For later changes, edit that installation and follow
[Operations](operations.md#apply-changes).

Preparation does not contact a cluster or import application data. Continue at
[Select the cluster](../README.md#3-select-the-cluster), then install and verify
startup. The [cluster prerequisites](../README.md#before-you-start) must already
be in place.
