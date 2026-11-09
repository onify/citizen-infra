# Prepare a customer package

Onify supplies `keyfile.json` for both Docker and Kubernetes installations.
The simplest package is the shared `.env` plus `keyfile.json`. Fill in
[.env.example](../.env.example)'s shared settings and keep the two files together.
All `K8S_*` settings have defaults; set real Kubernetes DNS names in a package
intended for live deployment. The customer can first test Docker and then prepare
Kubernetes with the same image tags, license and credentials:

```bash
bash scripts/prepare-installation.sh --env-file .env
```

For a package in another directory, pass its path, for example
`--env-file customer-packages/acme-test/.env`. Keep the files private and transfer
them through your existing secure file transfer or secret store. Follow the
[Getting started guide](../README.md#getting-started) to deploy. This reuses
settings; it does not copy Docker's database or application data.

## Alternative: JSON customer package

For environments without Docker Compose or packages requiring custom image
repositories/controller label selectors, the original JSON input is supported.
Prepare the following two files and use the directory command below. The
`--env-file` command reads only `.env` settings; it does not merge `customer.json`.

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

Use a new directory, fill in `customer.json` and add the Onify-supplied keyfile
as described below. `customer-packages/` is excluded from Git. Share the completed
package through your existing secure file transfer or secret store; it contains a
license, registry credentials and any passwords/secrets you supply in `customer.json`.

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
| `images.api`, `images.app`, `images.gateway` | Registry/repository and approved version tag for each image. API and worker share the API image. |
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

Use JSON strings for the license and credentials. For example:

```json
{
  "license": "REPLACE_WITH_CLIENT_LICENSE",
  "admin": { "username": "admin", "password": "" },
  "app_secret": "",
  "client_secret": ""
}
```

Empty credential strings are generated independently. Non-empty strings are
used exactly as supplied. Use single-line strings with normal JSON escaping;
preparation checks that the rendered values match the inputs exactly.
`app_secret` is the secret portion of
the APP-token, not an encoded bearer token. The script does not verify the
license with the API.

Gateway's repository is prefilled as `eu.gcr.io/onify-images/halo-gateway`.
Set its approved version in `images.gateway.tag`.

## 3. Add the keyfile supplied by Onify

Copy the original Google service-account JSON supplied by Onify to
`customer-packages/acme-test/keyfile.json`, then restrict its permissions:

```bash
chmod 600 customer-packages/acme-test/keyfile.json
```

The file must contain `type: service_account`, `client_email` and `private_key`.
Do not base64-encode it, rename a Docker config to `keyfile.json`, or create a new
Google account/key yourself. Onify provides a key with read access to the API,
APP and Gateway repositories. The same file is used for
[Docker login](docker-desktop.md#authenticate-to-gcr-with-keyfilejson).

Preparation checks the JSON and private-key format and generates a Docker config
using Google's [`_json_key` authentication](https://docs.cloud.google.com/artifact-registry/docs/docker/authentication#json-key).
It adds an entry for each image registry in `customer.json`. Supported hosts are
`gcr.io`, `eu.gcr.io`, `us.gcr.io`, `asia.gcr.io` and regional
`*-docker.pkg.dev` hosts; other hosts are rejected to avoid exposing the key.
These local checks do not verify Google permissions, key revocation or image tags.

`registryCredentials.json` is now generated output, not a file Onify needs to
supply. Existing prepared installations can keep using their generated Docker
config. Older customer packages need the Onify-supplied `keyfile.json` before
running preparation again; existing installation directories are never overwritten.

## 4. Prepare the installation

With Bash, `jq`, Mike Farah `yq` v4, `kubectl` and `openssl` installed, run:

```bash
bash scripts/prepare-installation.sh customer-packages/acme-test
```

The script creates `deployments/<client_code>-<instance_code>/`, fills in the
manifests and environment files, generates `registryCredentials.json` from
`keyfile.json`, and runs preflight. Each empty password/secret field gets an
independent random value using `openssl rand -hex 32`; supplied values are
preserved. The resulting license, admin password, APP-token secret and client secret are saved in
`secrets.env`; they are not printed.
Files are readable/writable only by their owner, and directories are private.
The generated Docker config contains the key as encoded credentials; protect it
like the original keyfile. The original keyfile stays in the customer package
and is not mounted into application containers. The install guide uses the
generated config to create Kubernetes' [image-pull Secret](https://kubernetes.io/docs/tasks/configure-pod-container/pull-image-private-registry/).

Gateway starts with authentication enabled and no integrations. Its client code
and client secret reference the API configuration automatically.

An existing destination is rejected without changing it. This command prepares
**new installations**; it does not rotate credentials or update an existing one.
Save the generated installation and credentials in your existing secret store
before deploying. For later changes, edit that installation and follow
[Operations](operations.md#apply-changes).

Preparation does not contact a cluster or import customer application data.
The customer continues at [Install](../README.md#4-install) with the generated
directory and namespace. The cluster, storage, Ingress controller, cert-manager
issuer, DNS and NetworkPolicy support must already exist. Live installation and
acceptance testing are separate steps.
