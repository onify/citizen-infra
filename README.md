# Citizen Hub Infrastructure

The script generates Kubernetes manifests from templates.
It has some parameters documented below. It will create a namespace and all resources needed to run onify-citizen in that namespace.

# Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `--namespace` | Kubernetes namespace where resources will be created | `onify-citizen` |
| `--clientInstance` | Instance identifier for the client | `test` |
| `--clientCode` | Code identifier for the client | `acme` |
| `--initialLicense` | Initial license key for the installation | `SOMELICENSE` |
| `--adminPassword` | Password for the admin user | `password1#AAA` |
| `--keyfile` | Path to the container registry credentials file | `keyfile.json` |
| `--domain` | Domain name for the ingress | `onify.net` |
| `--output` | Directory where YAML files will be generated | `.` (current directory) |

The script will automatically generate:
- `clientSecret`: (ONIFY_client_secret) A random 45-character string for client authentication
- `appSecret`: (ONIFY_apiTokens_app_secret) A random 50-character string for application authentication

# Examples:

The manifests in `examples/acme` were created by running the script with the following parameters:

```
./onify-citizen.sh --namespace=onify-citizen-test --clientInstance=test --clientCode=acme --adminPassword="Sup3rS3cretP@ssw#rd" --keyfile=mykeyfile.json --output=./examples/acme --domain=acme.org
```

# How to provision onify-citizen using this repository

1. Run the script to template manifests by running:

```
./onify-citizen.sh --namespace=onify-citizen-test --clientInstance=test --clientCode=acme --adminPassword="Sup3rS3cretP@ssw#rd" --keyfile=mykeyfile.json --output=./examples/acme --domain=acme.org
```

2. Start with creating the namespace by running:

```
kubectl apply -f examples/acme/namespace.yaml
```

3. Apply the rest of the resources with:

```
kubectl apply -f examples/acme
```

## Delete

Run:
```
kubectl delete -f examples/acme
```

## Container registry

To download images, a secret is created containing the contents of the file specified by --keyfile.
Example keyfile.json:

```
{
  "auths": {
    "eu.gcr.io": {
      "auth": "X2pzb25fa2V5OnsNCiAgInR5cGUiOiAic2VydmljZV9hY2NvdW50IiwNCiAgInByb2plY3RfaWQiOiAiYWdvb2dsZWNsb3VkcHJvamVjdCIsDQogICJwcml2YXRlX2tleV9pZCI6ICJzb21lbnVtYmVyIiwNCiAgInByaXZhdGVfa2V5IjogImFwcml2YXRla2V5IiwNCiAgImNsaWVudF9lbWFpbCI6ICJ1c2VybmFtZUBwcm9qZWN0LmlhbS5nc2VydmljZWFjY291bnQuY29tIiwNCiAgImNsaWVudF9pZCI6ICIxMjEyMTIiLA0KICAiYXV0aF91cmkiOiAiaHR0cHM6Ly9hY2NvdW50cy5nb29nbGUuY29tL28vb2F1dGgyL2F1dGgiLA0KICAidG9rZW5fdXJpIjogImh0dHBzOi8vb2F1dGgyLmdvb2dsZWFwaXMuY29tL3Rva2VuIiwNCiAgImF1dGhfcHJvdmlkZXJfeDUwOV9jZXJ0X3VybCI6ICJodHRwczovL3d3dy5nb29nbGVhcGlzLmNvbS9vYXV0aDIvdjEvY2VydHMiLA0KICAiY2xpZW50X3g1MDlfY2VydF91cmwiOiAiaHR0cHM6Ly93d3cuZ29vZ2xlYXBpcy5jb20iDQogICJ1bml2ZXJzZV9kb21haW4iOiAiZ29vZ2xlYXBpcy5jb20iDQp9DQo="
    },
    "ghcr.io": {
      "auth": "c29tZXRoaW5nOnBlcnNvbmFsYWNjZXNzdG9rZW5zb21ldGhpbmcK"
    }
  }
}
```

# Access / Ingress

## APP (and Helix)

The script will create an ingress manifest for onify-citizen with the following address:
```
https://$namespace.$domain
```

### Routes

* `/helix` > `helix`
* `/` > `hub-app`

## API

An ingress for the API is also created with the address:
```
https://$namespace-api.$domain
```

# Cert and TLS

## Lets encrypt
This script does not create annotations for certificates. Here´s an example if certmanager is used in you cluster
```
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
  name: kar-dev-hub-agent
  namespace: kar-dev
spec:
  ingressClassName: nginx
  rules:
    - host: onify-citizen-test.myspecialdomain.org
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
        - onify-citizen-test.myspecialdomain.org
      secretName: tls-secret-app-prod
```

## Custom certificate

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
    - host: onify-citizen.example.com
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
        - onify-citizen.example.com
      secretName: custom-tls-secret

```

Note: The certificate and key in the example above are just placeholders. Replace them with your actual base64 encoded certificate and private key.

# Onify agent
Onify agent is not provisioned default by using this script. To get the script so create those manifests aswell uncomment this line:
```
#onify_agent
```
Remember to add this environmental variables to api and worker if you need agent:
ONIFY_websockets_agent_url = ws://onify-agent:8080/hub

# Elasticsearch

## Persistent disk and backup
This script does not create any PVC or persistent disk so if that needed you need to create a PVC and change the manifests by your own. 
It also does not create backup manifests.

In the examples/elasticsearch/pvc_and_backup_example.yaml theres a example of a PVC and a statefulset using PVC and also an additional volume dedicated for backups.
To then enable backups this needs to be run against the elastic cluster:
```
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
This could be executed from the elastic pod


