# Prepare a customer package

Prepare these two files once. The customer runs one command to create their
installation files and credentials, then follows the install steps in the
[Getting started guide](../README.md#getting-started).

```text
customer-packages/acme-test/
├── customer.json
└── registryCredentials.json
```

## 1. Create the package

From the repository root, copy the template into a new directory:

```bash
mkdir -p customer-packages
mkdir -m 700 customer-packages/acme-test && \
cp examples/customer-package/customer.json customer-packages/acme-test/ && \
cp examples/customer-package/registryCredentials.json.example customer-packages/acme-test/registryCredentials.json && \
chmod 600 customer-packages/acme-test/*
```

Use a new directory, then fill in the files below. `customer-packages/` is
excluded from Git. Share the completed package through your existing secure
file transfer or secret store; it contains a license, registry credentials and
any passwords/secrets you supply in `customer.json`.

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
resource budgets for the first empty installation and adjust the generated
`resources-patch.yaml` for customer capacity later.

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

## 3. Add registry credentials

**registryCredentials.json:** a Docker config containing `auths` with embedded
credentials for every registry used by API, APP and Gateway. Each registry entry
needs `auth` (base64-encoded `username:password`) or `identitytoken`.
Replace the example file with the actual credentials file. A config containing
only `credsStore`/`credHelpers`, or a Google service-account key JSON, is not this
format. See [Kubernetes registry credentials](https://kubernetes.io/docs/tasks/configure-pod-container/pull-image-private-registry/)
for obtaining a Docker config suitable for a Kubernetes pull Secret.

Use image-pull credentials scoped to the required repositories. The local check
verifies format and registry coverage; it does not contact the registries.

## 4. Prepare the installation

With Bash, `jq`, Mike Farah `yq` v4, `kubectl` and `openssl` installed, run:

```bash
bash scripts/prepare-installation.sh customer-packages/acme-test
```

The script creates `deployments/<client_code>-<instance_code>/`, fills in the
manifests and environment files, copies the registry credentials, and runs
preflight. Each empty password/secret field gets an independent random value
using `openssl rand -hex 32`; supplied values are preserved. The resulting
license, admin password, APP-token secret and client secret are saved in
`secrets.env`; they are not printed.
Files are readable/writable only by their owner, and directories are private.

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
