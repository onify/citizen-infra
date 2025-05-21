# Citizen Hub Infrastructure

The script generates Kubernetes manifests from templates.
It has some parameters documented below. It will create a namespace and all resources needed to run Onify Citizen Hub in that namespace.

> For more information about requirements, see [requirements](https://support.onify.co/docs/requirements).

> For more informatoon about installation, see [installation](https://github.com/onify/install). 

## Prerequisites

* Client code
* Instance code
* License
* Access to images (gcr/ghcr)

## Container images

The following container images are used by Citizen Hub. Image versions may vary depending on your deployment requirements:

* `eu.gcr.io/onify-images/hub/api:*`
* `eu.gcr.io/onify-images/hub/app:*`
* `eu.gcr.io/onify-images/hub/agent-server:*` (optional, used if Onify Agent is enabled)
* `ghcr.io/onify/helix-app:*` (default Helix image; replace with your custom image for production)
* `ghcr.io/onify/citizen-functions:*`
* `docker.elastic.co/elasticsearch/elasticsearch:*`

## Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `--namespace` | Kubernetes namespace where resources will be created | `onify-citizen` |
| `--clientInstance` | Instance identifier for the client | `test` |
| `--clientCode` | Code identifier for the client | `acme` |
| `--initialLicense` | Initial license key for the installation | `SOMELICENSE` |
| `--adminPassword` | Password for the admin user. Needs to be a complext password with capital and lowercase letters, numbers and special characters  | `P@33w0rd543On1f7` |
| `--registryCredentials` | Path to the container registry credentials file | `registryCredentials.json` |
| `--domain` | Domain name for the ingress | `onify.net` |
| `--output` | Directory where YAML files will be generated | `.` (current directory) |

The script will automatically generate:
- `clientSecret`: (ONIFY_client_secret) A random 45-character string for client authentication
- `appSecret`: (ONIFY_apiTokens_app_secret) A random 50-character string for application authentication

## Examples

The manifests in `examples/acme` were created by running the script with the following parameters:

```bash
./onify-citizen.sh --namespace=onify-citizen-test --clientInstance=test --clientCode=acme --adminPassword="Sup3rS3cretP@ssw#rd" --registryCredentials=registryCredentials.json --output=./examples/acme --domain=acme.org
```

## Provisioning

Onify Citizen Hub is based on several (micro)services; `api`, `worker`, `app`, `helix`, `functions` and `elasticsearch`. 
Here is how you can create Kubernetes manifest for these services;

> NOTE: For provisioning Onify Helix (helix), please see section below for more details.

1. Run the script to template manifests by running:

```bash
./onify-citizen.sh --namespace=onify-citizen-prod --clientInstance=prod --clientCode=ace --adminPassword="Sup3rS3cretP@ssw#rd" --registryCredentials=registryCredentials.json --output=./prod --domain=acme.com
```

2. Start with creating the namespace by running:

```bash
kubectl apply -f prod/namespace.yaml
```

3. Apply the rest of the resources with:

```bash
kubectl apply -f prod/
```

### Delete

To delete and start over, run:

```bash
kubectl delete -f examples/acme
```

### Container registry

To download images, a secret is created containing the contents of the file specified by --registryCredentials.

The credential is basically built on this structure:
registryCredentials.json is an example.

```json
{
  "auths": {
    "eu.gcr.io": {
      "auth": "BASE64 ENCODED GCR.IO KEYFILE"
    },
    "ghcr.io": {
      "auth": "BASE64 ENCODED > githubuser:PAT"
    }
  }
}
```

### Access / Ingress

#### APP (and Helix)

The script will create an ingress manifest for onify-citizen with the following address:

```
https://$namespace.$domain
```

*Routes*

* `/helix` > `helix`
* `/` > `hub-app`

#### API

An ingress for the API is also created with the address:

```
https://$namespace-api.$domain
```

## Cert and TLS

### Let's Encrypt

We recommend certmanager for automating TLS certificates from letsencrypt.
When certmanager is installed (using helm or similar). These manifests needs to be applied:

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    #change to your email
    email: hello@onify.io
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - http01:
        ingress:
          ingressClassName: nginx
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    #change to your email
    email: hello@onify.io
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-staging
    solvers:
    - http01:
        ingress:
          ingressClassName: nginx
}
```


This script does not create annotations for certificates. Here´s an annotation xample if certmanager is used in you cluster.

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod  ## -< this is the annotation for certmanager
  name: onify-citizen-ingress
  namespace: onify-citizen-test
spec:
  ingressClassName: nginx
  rules:
    - host: onify-citizen-test.acme.org
      http:
        paths:
          - backend:
              service:
                name: onify-app
                port:
                  number: 3000
            path: /
            pathType: Prefix
          - backend:
              service:
                name: onify-helix
                port:
                  number: 4000
            path: /helix
            pathType: Prefix

  tls:
    - hosts:
        - onify-citizen-test.acme.org
      secretName: tls-secret-app-prod
```

### Custom certificate

Create a secret with your custom certificate. Here's an example:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: custom-tls-secret
  namespace: onify-citizen
type: kubernetes.io/tls
data:
  # The base64 encoded certificate
  tls.crt: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSUZhekNDQTFPZ0F3SUJBZ0lVZXhhbXBsZWNlcnRpZmljYXRlYmFzZTY0ZGF0YQotLS0tLUVORCBDRVJUSUZJQ0FURS0tLS0t
  # The base64 encoded private key
  tls.key: LS0tLS1CRUdJTiBQUklWQVRFIEtFWS0tLS0tCk1JSUpRd0lCQURBTkJna3Foa2lHOXcwQkFRRUZBQVNDQ1Mwd2dna3BBZ0VBQW9JQ0FRQzlYWkFBCi0tLS0tRU5EIFBSSVZBVEUgS0VZLS0tLS0=
```

And here's an example of an Ingress using the custom certificate:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: onify-citizen-ingress
  namespace: onify-citizen
spec:
  ingressClassName: nginx
  rules:
    - host: onify-citizen.acme.org
      http:
        paths:
          - backend:
              service:
                name: onify-app
                port:
                  number: 3000
            path: /
            pathType: Prefix
          - backend:
              service:
                name: onify-helix
                port:
                  number: 4000
            path: /helix
            pathType: Prefix
  tls:
    - hosts:
        - onify-citizen.acme.org
      secretName: custom-tls-secret

```

Note: The certificate and key in the example above are just placeholders. Replace them with your actual base64 encoded certificate and private key.

## Onify agent

Onify agent is not provisioned default by using this script. To get the script so create those manifests aswell uncomment this line:

```
#onify_agent
```

Remember to add this environmental variables to api and worker if you need agent:

```
ONIFY_websockets_agent_url = ws://onify-agent:8080/hub
```

## Elasticsearch

### Persistent disk and backup

This script does not create any PVC or persistent disk so if that needed you need to create a PVC and change the manifests by your own. 
It also does not create backup manifests.

In the `examples/elasticsearch/pvc_and_backup_example.yaml` theres a example of a PVC and a statefulset using PVC and also an additional volume dedicated for backups.
To then enable backups this needs to be run against the elastic cluster:

```bash
curl -s \
 -X PUT \
 "http://elasticsearch.namespace.svc.cluster.local:9200/_snapshot/backup_repo" \
 -H "Content-Type: application/json" -d '{
    "type": "fs",
    "settings": {
      "location": "/usr/share/elasticsearch/backup"
    }
  }'
```

This could be executed from the elastic pod.

## Onify Helix

Onify Helix is a custom image unlike the rest of the other services (api, app, functions, elasticsearch). This requires it´s own Git repo, container registry and CI/CD pipeline.
We recommend using GitHub. We have ready made GitHub Action Workflows for Onify Helix. But you can also run your own...

Here is an example how to build latest in GitHub and use GitHub as container registry:

```yaml
name: Build latest

on:
  push:
    branches: [main]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      #CHECKOUT ACTION CLONES THE REPOSITORY
      - uses: actions/checkout@v3

      #SETUP VARIABLES
      - name: Setup variables
        id: variables
        run: |-
          echo "repo=${{ github.repository }}" | tr '[:upper:]' '[:lower:]' >> $GITHUB_OUTPUT

      #LOGIN TO GHCR REGISTRY SO WE CAN PUSH THE IMAGE. USES THE DEFAULT GITHUB_TOKEN VARIABLE THAT WORKFLOW ALWAYS HAVE ACCESS TO
      - name: Log in to the Container registry
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      #BUILD AND PUSH THE LATEST IMAGE
      - name: Build and push latest
        uses: docker/build-push-action@v5
        with:
          context: .
          push: true
          tags: |
            ghcr.io/${{ steps.variables.outputs.repo }}:latest
          build-args: ONIFY_GITHUB_ACCESS_TOKEN=${{ secrets.ONIFY_GITHUB_ACCESS_TOKEN }}
```

> NOTE: The `ONIFY_GITHUB_ACCESS_TOKEN` is something you will get from Onify.

You need to replace the image (eg. `ghcr.io/onify/helix-app-lab:latest`) in `helix.yaml` with your own image and make sure you have access to that. 
