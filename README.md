# citizen-infra
Citizen Hub infrastructure

The script templates manifests. 
It has some parametes documented below. It will create a namespace with all resources in needed to onify-citizen in that namespace.

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
- `clientSecret`: (ONIFY_client_secret ) A random 45-character string for client authentication
- `appSecret`: (ONIFY_apiTokens_app_secret) A random 50-character string for application authentication

# Examples:

The examples/acme manifests was created by running the script with the following parameters:

```
./onify-citizen.sh --namespace=onify-citizen-test --clientInstance=test --clientCode=acme --adminPassword="Sup3rS3cretP@ssw#rd" --keyfile=mykeyfile.json --output=./examples/acme --domain=acme.org
```

## container registry
To be able to download images a secret is created containing the content of what you specify as --keyfile.
example keyfile.json
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
The script will create a ingress manifest for onify-citizen with the following address:
```https://$namespace.$domain```
