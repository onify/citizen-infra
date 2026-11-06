#!/usr/bin/env bash
# Test customer-package preparation with fake credentials and no cluster access.
# shellcheck disable=SC2016
set -euo pipefail
umask 077
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
temp=$(mktemp -d "${TMPDIR:-/tmp}/onify-package-check.XXXXXX")
trap 'rm -rf -- "$temp"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$temp/repo/scripts" "$temp/repo/tests" "$temp/customer package"
cp "$ROOT/scripts/prepare-installation.sh" "$temp/repo/scripts/"
cp "$ROOT/tests/check.sh" "$temp/repo/tests/"
cp -R "$ROOT/kubernetes" "$temp/repo/"
mkdir -p "$temp/repo/examples/acme"
for file in kustomization.yaml namespace.yaml ingress.yaml storage.yaml resources-patch.yaml network-policy.yaml config.env gateway.env gateway-secrets.env.example .gitignore; do
    cp "$ROOT/examples/acme/$file" "$temp/repo/examples/acme/"
done
package="$temp/customer package"
destination="$temp/repo/deployments/acme-test"
prepare() { bash "$temp/repo/scripts/prepare-installation.sh" "$package" > "$temp/result.log" 2>&1; }
reject() {
    if prepare; then printf 'Expected rejection (%s): %s\n' "${scenario:-existing}" "$1" >&2; exit 1; fi
    grep -Fq "$1" "$temp/result.log" || { cat "$temp/result.log" >&2; exit 1; }
}
assert_json() { jq -e "$@" >/dev/null || { printf 'Assertion failed at line %s.\n' "${BASH_LINENO[0]}" >&2; exit 1; }; }
reset_package() {
    cp "$temp/customer.json" "$package/customer.json"
    cp "$temp/registryCredentials.json" "$package/registryCredentials.json"
}
jq '.license = "test-license#!=$()`false`" |
    .images.api.tag = "1.0.0" | .images.app.tag = "1.0.0" |
    .images.gateway = {repository: "registry.example.invalid/onify/gateway", tag: "1.0.0"} |
    .ingress.app_host = "citizen.example.invalid" | .ingress.api_host = "api.example.invalid" |
    .ingress.class_name = "customer-nginx" | .ingress.cluster_issuer = "customer-issuer" |
    .ingress.controller_namespace = "customer-ingress" |
    .ingress.controller_labels = {component: "controller", release: "customer"} |
    .storage = {size: "20Gi", class_name: "customer-storage"}
' "$ROOT/examples/customer-package/customer.json" > "$temp/customer.json"
jq -n '{auths: {"eu.gcr.io": {auth: ("test-user:test-password" | @base64)},
    "registry.example.invalid": {identitytoken: "test-only-token"}}}' > "$temp/registryCredentials.json"
reset_package
prepare || { cat "$temp/result.log" >&2; exit 1; }
cp "$destination/secrets.env" "$temp/original-secrets.env"
cmp "$package/registryCredentials.json" "$destination/registryCredentials.json"
grep -Fxq 'ONIFY_client_code=acme' "$destination/config.env"
grep -Fxq 'ONIFY_client_instance=test' "$destination/config.env"
if grep -q '^ONIFY_adminUser_email=' "$destination/config.env"; then exit 1; fi
grep -Fxq 'ONIFY_initialLicense=test-license#!=$()`false`' "$destination/secrets.env"
[[ $(grep -Ec '^ONIFY_(adminUser_password|apiTokens_app_secret|client_secret)=[0-9a-f]{64}$' "$destination/secrets.env") == 3 ]]
[[ $(tail -n 3 "$destination/secrets.env" | cut -d= -f2 | sort -u | wc -l | tr -d ' ') == 3 ]]
if grep -Fq 'test-license' "$temp/result.log" || grep -Fq 'test-password' "$temp/result.log"; then
    printf '%s\n' 'Preparation must not print credentials.' >&2; exit 1
fi
for value in $(tail -n 3 "$destination/secrets.env" | cut -d= -f2); do
    if grep -Fq "$value" "$temp/result.log"; then exit 1; fi
done
[[ -z $(find "$destination" -type f ! -perm 600 -print) ]]
[[ -z $(find "$destination" -type d ! -perm 700 -print) ]]
[[ ! -e $destination/.customer.json && ! -e $destination/license.txt ]]
kubectl kustomize "$destination" | yq -o=json '.' | jq -s '.' > "$temp/rendered.json"
assert_json '
    all(.[]; .kind == "Namespace" or .metadata.namespace == "acme-test") and
    any(.[]; .kind == "Namespace" and .metadata.name == "acme-test") and
    any(.[]; .kind == "PersistentVolumeClaim" and .spec.storageClassName == "customer-storage" and .spec.resources.requests.storage == "20Gi") and
    all(.[] | select(.kind == "Ingress"); .spec.ingressClassName == "customer-nginx" and
        .metadata.annotations["cert-manager.io/cluster-issuer"] == "customer-issuer" and .spec.rules[0].host == .spec.tls[0].hosts[0]) and
    any(.[]; .kind == "NetworkPolicy" and .spec.ingress[1].from == [{
        namespaceSelector: {matchLabels: {"kubernetes.io/metadata.name": "customer-ingress"}},
        podSelector: {matchLabels: {component: "controller", release: "customer"}}}])
' "$temp/rendered.json"
reject 'Installation already exists'
cmp "$temp/original-secrets.env" "$destination/secrets.env"
rm -rf "$destination"

for scenario in missing json placeholder unknown namespace empty_license multiline_license null_secret multiline_secret registry_helper registry_coverage legacy_image multiple_json; do
    reset_package
    case $scenario in
        missing) rm "$package/customer.json"; reject 'Missing or unreadable package file: customer.json' ;;
        json) printf '{malformed-secret-value' > "$package/customer.json"; reject 'exactly one valid JSON object' ;;
        placeholder) cp "$ROOT/examples/customer-package/customer.json" "$package/customer.json"; reject 'Invalid customer.json' ;;
        unknown) jq '.misspelled = true' "$temp/customer.json" > "$package/customer.json"; reject 'Invalid customer.json' ;;
        namespace) jq '.namespace = "../../escape"' "$temp/customer.json" > "$package/customer.json"; reject 'Invalid customer.json' ;;
        empty_license) jq '.license = ""' "$temp/customer.json" > "$package/customer.json"; reject 'Invalid customer.json' ;;
        multiline_license) jq '.license = "first-line\nprivate-value"' "$temp/customer.json" > "$package/customer.json"; reject 'Invalid customer.json' ;;
        null_secret) jq '.app_secret = null' "$temp/customer.json" > "$package/customer.json"; reject 'Invalid customer.json' ;;
        multiline_secret) jq '.admin.password = "first-line\nprivate-value"' "$temp/customer.json" > "$package/customer.json"; reject 'Invalid customer.json' ;;
        registry_helper) printf '{"credsStore":"desktop"}\n' > "$package/registryCredentials.json"; reject 'embedded auth/identitytoken' ;;
        registry_coverage) jq 'del(.auths["registry.example.invalid"])' "$temp/registryCredentials.json" > "$package/registryCredentials.json"; reject 'must cover' ;;
        legacy_image) jq '.images.app.repository = "eu.gcr.io/onify-images/citizen/app"' "$temp/customer.json" > "$package/customer.json"; reject 'Select an APP image' ;;
        multiple_json) cat "$temp/customer.json" >> "$package/customer.json"; reject 'exactly one valid JSON object' ;;
    esac
    [[ ! -e $destination ]]
    [[ -z $(find "$temp/repo/deployments" -mindepth 1 -maxdepth 1 -print) ]]
    if grep -Eq 'private-value|malformed-secret-value' "$temp/result.log"; then exit 1; fi
done
reset_package
# Provided credentials survive exactly, including spaces, quotes and shell syntax.
jq '.admin.password = " supplied password #!=$()`false` " |
    .app_secret = "supplied-app-#!=$()\\path" | .client_secret = "\"supplied-client-#!=$()\""
' "$temp/customer.json" > "$package/customer.json"
prepare || { cat "$temp/result.log" >&2; exit 1; }
jq -r '"ONIFY_adminUser_password=" + .admin.password,
    "ONIFY_apiTokens_app_secret=" + .app_secret, "ONIFY_client_secret=" + .client_secret
' "$package/customer.json" > "$temp/expected.env"
while IFS= read -r line; do grep -Fxq "$line" "$destination/secrets.env"; done < "$temp/expected.env"
if grep -Eq 'supplied-password|supplied password|supplied-app|supplied-client' "$temp/result.log"; then exit 1; fi
cp "$destination/secrets.env" "$temp/supplied.env"
reset_package
reject 'Installation already exists'
cmp "$temp/supplied.env" "$destination/secrets.env"
rm -rf "$destination"
# Empty fields generate independently; non-empty fields keep their supplied values.
jq '.admin.password = "supplied-password" | .client_secret = "supplied-client"' "$temp/customer.json" > "$package/customer.json"
prepare || { cat "$temp/result.log" >&2; exit 1; }
grep -Fxq 'ONIFY_adminUser_password=supplied-password' "$destination/secrets.env"
grep -Fxq 'ONIFY_client_secret=supplied-client' "$destination/secrets.env"
grep -Eq '^ONIFY_apiTokens_app_secret=[0-9a-f]{64}$' "$destination/secrets.env"
rm -rf "$destination"
reset_package
jq '.namespace = "customer-second" | .instance_code = "second" | .storage.class_name = ""' "$temp/customer.json" > "$package/customer.json"
prepare || { cat "$temp/result.log" >&2; exit 1; }
second="$temp/repo/deployments/acme-second"
[[ $(yq '.metadata.name' "$second/namespace.yaml") == customer-second ]]
[[ $(yq '.spec | has("storageClassName")' "$second/storage.yaml") == false ]]
if cmp -s "$temp/original-secrets.env" "$second/secrets.env"; then exit 1; fi
printf '%s\n' 'Customer package checks passed (no cluster access).'
