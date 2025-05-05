# citizen-infra
Citizen Hub infrastructure

To apply onify-citizen using kubectl run the script:
````
onify-citizen.sh
````
The script has some parametes documented below. It will create a namespace with all resources in needed to onify-citizen in that namespace.


# Examples:

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


# Dry-run
This will only output all the yaml without applying it. It will use --dry-run=client so it will not verify manifest against server.

```./onify-citizen.sh --keyfile=keyfile.json --namespace=onify-citizen-acme --dry-run=true --client_instance=test --adminPassword="somePasswordWithDigits@SpecialChars" --domain=example.org --initialLicense="SOMELICENSE"```

# Apply

```./onify-citizen.sh --keyfile=keyfile.json --namespace=onify-citizen-acme --client_instance=test --adminPassword="somePasswordWithDigits@SpecialChars" --domain=example.org --initialLicense="SOMELICENSE"```

# Delete
This will delete the namespace and therefore all the other resources so it will give some errors about resources not found

```./onify-citizen.sh --keyfile=keyfile.json --namespace=onify-citizen-acme --action=delete```

# Templating
Instead of applying the manifests directly to the cluster, you can generate YAML files for each component. This is useful for:
- Version control of your Kubernetes manifests
- Manual review before applying
- Using with other deployment tools

The script will create separate YAML files for each component in the specified output directory:

```./onify-citizen.sh --template --output=./k8s-manifests --keyfile=keyfile.json --namespace=onify-citizen-acme --client_instance=test --adminPassword="somePasswordWithDigits@SpecialChars" --domain=example.org --initialLicense="SOMELICENSE"```

This will generate the following files in the `./k8s-manifests` directory:
- namespace.yaml
- secrets.yaml
- api.yaml
- app.yaml
- helix.yaml
- agent.yaml
- functions.yaml
- worker.yaml
- elasticsearch.yaml

# Access
The script will create a ingress for onify-citizen with the following address:
```https://$namespace.$domain```


TODO:
- autogenerate client secrets
