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
cp "$ROOT/scripts/prepare-installation.sh" "$ROOT/scripts/kubernetes.compose.yaml" "$temp/repo/scripts/"
cp "$ROOT/compose.yaml" "$temp/repo/"
cp "$ROOT/tests/check.sh" "$temp/repo/tests/"
cp -R "$ROOT/kubernetes" "$temp/repo/"
mkdir -p "$temp/repo/examples/acme"
for file in kustomization.yaml namespace.yaml ingress.yaml storage.yaml resources-patch.yaml network-policy.yaml config.env gateway.env gateway-secrets.env.example .gitignore; do
    cp "$ROOT/examples/acme/$file" "$temp/repo/examples/acme/"
done
package="$temp/customer package"
destination="$temp/repo/deployments/acme-test"
prepare_args=("$package")
prepare() { bash "$temp/repo/scripts/prepare-installation.sh" "${prepare_args[@]}" > "$temp/result.log" 2>&1; }
reject() {
    if prepare; then printf 'Expected rejection (%s): %s\n' "${scenario:-existing}" "$1" >&2; exit 1; fi
    grep -Fq "$1" "$temp/result.log" || { cat "$temp/result.log" >&2; exit 1; }
}
assert_json() { jq -e "$@" >/dev/null || { printf 'Assertion failed at line %s.\n' "${BASH_LINENO[0]}" >&2; exit 1; }; }
reset_package() {
    cp "$temp/customer.json" "$package/customer.json"
    cp "$temp/keyfile.json" "$package/keyfile.json"
}
jq '.license = "test-license#!=$()`false`" |
    .images.api.tag = "1.0.0" | .images.app.tag = "1.0.0" |
    .images.gateway = {repository: "europe-north1-docker.pkg.dev/onify-images/gateway/halo-gateway", tag: "1.0.0"} |
    .ingress.app_host = "citizen.example.invalid" | .ingress.api_host = "api.example.invalid" |
    .ingress.class_name = "customer-nginx" | .ingress.cluster_issuer = "customer-issuer" |
    .ingress.controller_namespace = "customer-ingress" |
    .ingress.controller_labels = {component: "controller", release: "customer"} |
    .storage = {size: "20Gi", class_name: "customer-storage"}
' "$ROOT/examples/customer-package/customer.json" > "$temp/customer.json"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$temp/test-key.pem" 2>/dev/null
openssl pkey -in "$temp/test-key.pem" -aes-256-cbc -passout pass:test-only-passphrase -out "$temp/encrypted-key.pem"
jq -n --rawfile key "$temp/test-key.pem" '{type: "service_account",
    client_email: "test-only@example.invalid", private_key: $key}' > "$temp/keyfile.json"
reset_package
prepare || { cat "$temp/result.log" >&2; exit 1; }
cp "$destination/secrets.env" "$temp/original-secrets.env"
assert_json --rawfile key "$package/keyfile.json" '
    (.auths | keys) == ["eu.gcr.io", "europe-north1-docker.pkg.dev"] and
    all(.auths[]; (.auth | @base64d) == "_json_key:" + $key)
' "$destination/registryCredentials.json"
kubectl create secret generic onify-regcred --namespace=acme-test \
    --type=kubernetes.io/dockerconfigjson \
    --from-file=".dockerconfigjson=$destination/registryCredentials.json" \
    --dry-run=client -o json > "$temp/pull-secret.json"
assert_json --slurpfile registry "$destination/registryCredentials.json" '
    .metadata.name == "onify-regcred" and .metadata.namespace == "acme-test" and
    .type == "kubernetes.io/dockerconfigjson" and
    (.data[".dockerconfigjson"] | @base64d | fromjson) == $registry[0]
' "$temp/pull-secret.json"
grep -Fxq 'ONIFY_client_code=acme' "$destination/config.env"
grep -Fxq 'ONIFY_client_instance=test' "$destination/config.env"
if grep -q '^ONIFY_adminUser_email=' "$destination/config.env"; then exit 1; fi
grep -Fxq 'ONIFY_initialLicense=test-license#!=$()`false`' "$destination/secrets.env"
[[ $(grep -Ec '^ONIFY_(adminUser_password|apiTokens_app_secret|client_secret)=[0-9a-f]{64}$' "$destination/secrets.env") == 3 ]]
[[ $(tail -n 3 "$destination/secrets.env" | cut -d= -f2 | sort -u | wc -l | tr -d ' ') == 3 ]]
if grep -Fq 'test-license' "$temp/result.log" || grep -Fq 'PRIVATE KEY' "$temp/result.log" ||
    grep -Fq -f "$temp/test-key.pem" "$temp/result.log"; then
    printf '%s\n' 'Preparation must not print credentials.' >&2; exit 1
fi
for value in $(tail -n 3 "$destination/secrets.env" | cut -d= -f2); do
    if grep -Fq "$value" "$temp/result.log"; then exit 1; fi
done
[[ -z $(find "$destination" -type f ! -perm 600 -print) ]]
[[ -z $(find "$destination" -type d ! -perm 700 -print) ]]
[[ ! -e $destination/.customer.json && ! -e $destination/license.txt &&
   ! -e $destination/.keyfile.json && ! -e $destination/keyfile.json ]]
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

for scenario in missing json placeholder unknown namespace empty_license multiline_license null_secret multiline_secret missing_key key_json key_multiple_json key_type key_email key_empty key_invalid key_encrypted docker_config registry_host registry_lookalike registry_port legacy_image multiple_json; do
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
        missing_key) rm "$package/keyfile.json"; reject 'Missing or unreadable package file: keyfile.json' ;;
        key_json) printf '{malformed-secret-value' > "$package/keyfile.json"; reject 'exactly one valid JSON object' ;;
        key_multiple_json) cat "$temp/keyfile.json" >> "$package/keyfile.json"; reject 'exactly one valid JSON object' ;;
        key_type) jq '.type = "authorized_user"' "$temp/keyfile.json" > "$package/keyfile.json"; reject 'original Google service-account JSON' ;;
        key_email) jq '.client_email = null' "$temp/keyfile.json" > "$package/keyfile.json"; reject 'original Google service-account JSON' ;;
        key_empty) jq '.private_key = ""' "$temp/keyfile.json" > "$package/keyfile.json"; reject 'original Google service-account JSON' ;;
        key_invalid) jq '.private_key = "private-value"' "$temp/keyfile.json" > "$package/keyfile.json"; reject 'invalid private_key' ;;
        key_encrypted) jq --rawfile key "$temp/encrypted-key.pem" '.private_key = $key' "$temp/keyfile.json" > "$package/keyfile.json"; reject 'invalid private_key' ;;
        docker_config) printf '{"auths":{"eu.gcr.io":{"auth":"dXNlcjpwYXNz"}}}\n' > "$package/keyfile.json"; reject 'original Google service-account JSON' ;;
        registry_host) jq '.images.gateway.repository = "registry.example.invalid/onify/gateway"' "$temp/customer.json" > "$package/customer.json"; reject 'only Google' ;;
        registry_lookalike) jq '.images.gateway.repository = "eu.gcr.io.example.invalid/onify/gateway"' "$temp/customer.json" > "$package/customer.json"; reject 'only Google' ;;
        registry_port) jq '.images.gateway.repository = "eu.gcr.io:5000/onify/gateway"' "$temp/customer.json" > "$package/customer.json"; reject 'only Google' ;;
        legacy_image) jq '.images.app.repository = "eu.gcr.io/onify-images/citizen/app"' "$temp/customer.json" > "$package/customer.json"; reject 'Select an APP image' ;;
        multiple_json) cat "$temp/customer.json" >> "$package/customer.json"; reject 'exactly one valid JSON object' ;;
    esac
    [[ ! -e $destination ]]
    [[ -z $(find "$temp/repo/deployments" -mindepth 1 -maxdepth 1 -print) ]]
    if grep -Eq 'private-value|malformed-secret-value' "$temp/result.log" ||
        grep -Fq -f "$temp/test-key.pem" "$temp/result.log"; then exit 1; fi
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

# Reuse Docker's .env parser and values without starting containers or executing file contents.
while IFS='=' read -r key _; do
    case $key in ''|'#'*) continue ;; esac
    unset "$key"
done < "$ROOT/.env.example"
unset COMPOSE_PROJECT_NAME
cat > "$package/.env" <<'ENV'
API_TAG=1.2.3
APP_TAG=4.5.6
GATEWAY_TAG=7.8.9
ONIFY_client_code=acme
ONIFY_client_instance=test
ONIFY_adminUser_username=admin
APP_PORT=4001
ONIFY_initialLicense='test-license-${literal}'
ONIFY_adminUser_password=' supplied $password $$literal # = \\path \' quote `touch should-not-exist` $(touch should-not-exist) '
ONIFY_apiTokens_app_secret="quoted-\"secret\""
ONIFY_client_secret='client-$secret-$$literal'
ENV
cp "$package/.env" "$temp/complete.env"
prepare_args=(--env-file "$package/.env")
prepare || { cat "$temp/result.log" >&2; exit 1; }
cmp "$package/.env" "$temp/complete.env"
sed 's/<SPACE>$/ /' > "$temp/expected.env" <<'ENV'
ONIFY_initialLicense=test-license-${literal}
ONIFY_adminUser_password= supplied $password $$literal # = \\path ' quote `touch should-not-exist` $(touch should-not-exist)<SPACE>
ONIFY_apiTokens_app_secret=quoted-"secret"
ONIFY_client_secret=client-$secret-$$literal
ENV
while IFS= read -r line; do grep -Fxq "$line" "$destination/secrets.env"; done < "$temp/expected.env"
[[ ! -e should-not-exist && ! -e $temp/repo/should-not-exist && ! -e $package/should-not-exist ]]
[[ ! -e $destination/.env && ! -e $destination/.customer.json ]]
[[ -z $(find "$destination" -type f ! -perm 600 -print) ]]
if grep -Eq 'test-license|supplied|quoted-|client-\$secret' "$temp/result.log"; then exit 1; fi
[[ $(yq '.metadata.name' "$destination/namespace.yaml") == acme-test ]]
[[ $(yq '.spec | has("storageClassName")' "$destination/storage.yaml") == false ]]
[[ $(yq '.spec.resources.requests.storage' "$destination/storage.yaml") == 10Gi ]]
yq -o=json '.' "$destination/ingress.yaml" | jq -es '
    any(.[]; .metadata.name == "onify-app" and .spec.rules[0].host == "acme-test.example.com") and
    any(.[]; .metadata.name == "onify-api" and .spec.rules[0].host == "api-acme-test.example.com") and
    all(.[]; .spec.ingressClassName == "nginx" and .metadata.annotations["cert-manager.io/cluster-issuer"] == "letsencrypt-prod")
' >/dev/null
yq -o=json '.' "$destination/kustomization.yaml" > "$temp/env-kustomization.json"
assert_json '.images == [
    {name: "onify-api-image", newName: "eu.gcr.io/onify-images/hub/api", newTag: "1.2.3"},
    {name: "onify-app-image", newName: "eu.gcr.io/onify-images/citizen/app-root", newTag: "4.5.6"},
    {name: "onify-gateway-image", newName: "eu.gcr.io/onify-images/halo-gateway", newTag: "7.8.9"}
]' "$temp/env-kustomization.json"
reject 'Installation already exists'
rm -rf "$destination"
for scenario in missing_env_value same_host multiline_env invalid_env; do
    cp "$temp/complete.env" "$package/.env"
    case $scenario in
        missing_env_value) printf '\nONIFY_client_secret=\n' >> "$package/.env"; reject 'Could not read .env' ;;
        same_host) printf '\nK8S_API_HOST=acme-test.example.com\n' >> "$package/.env"; reject 'Invalid .env' ;;
        multiline_env) printf '\nONIFY_client_secret="private-value\\nsecond-line"\n' >> "$package/.env"; reject 'Invalid .env' ;;
        invalid_env) printf '\nONIFY_client_secret="private-value\n' >> "$package/.env"; reject 'Could not read .env' ;;
    esac
    [[ ! -e $destination ]]
    [[ -z $(find "$temp/repo/deployments" -name '.prepare.*' -print) ]]
    if grep -Eq 'private-value|test-license|supplied' "$temp/result.log"; then exit 1; fi
done
# Explicitly empty K8S settings select the same defaults as an older Docker-only .env.
cp "$temp/complete.env" "$package/.env"
sed -n 's/^\(K8S_[A-Z_]*\)=.*/\1=/p' "$ROOT/.env.example" >> "$package/.env"
prepare || { cat "$temp/result.log" >&2; exit 1; }
kubectl kustomize "$destination" > "$temp/defaults.yaml"
rm -rf "$destination"
cp "$temp/complete.env" "$package/.env"
prepare || { cat "$temp/result.log" >&2; exit 1; }
kubectl kustomize "$destination" > "$temp/omitted.yaml"
cmp "$temp/defaults.yaml" "$temp/omitted.yaml"
rm -rf "$destination"
cp "$temp/complete.env" "$package/.env"
sed -n '/^K8S_/p' "$ROOT/.env.example" >> "$package/.env"
prepare || { cat "$temp/result.log" >&2; exit 1; }
kubectl kustomize "$destination" > "$temp/template-defaults.yaml"
cmp "$temp/defaults.yaml" "$temp/template-defaults.yaml"
rm -rf "$destination"
# Windows line endings, cluster overrides and shell precedence match the Docker path.
sed 's/$/\r/' "$temp/complete.env" > "$package/.env"
cat >> "$package/.env" <<'ENV'
K8S_NAMESPACE=customer-k8s
K8S_APP_HOST=citizen.example.invalid
K8S_API_HOST=api.example.invalid
K8S_INGRESS_CLASS=customer-nginx
K8S_CLUSTER_ISSUER=customer-issuer
K8S_INGRESS_CONTROLLER_NAMESPACE=customer-ingress
K8S_INGRESS_CONTROLLER_NAME=customer-controller
K8S_STORAGE_SIZE=20Gi
K8S_STORAGE_CLASS=customer-storage
ENV
API_TAG=9.9.9 ONIFY_client_secret='override-$secret-$$literal' prepare || { cat "$temp/result.log" >&2; exit 1; }
[[ $(yq '.metadata.name' "$destination/namespace.yaml") == customer-k8s ]]
[[ $(yq '.images[0].newTag' "$destination/kustomization.yaml") == 9.9.9 ]]
[[ $(yq '.spec.storageClassName' "$destination/storage.yaml") == customer-storage ]]
[[ $(yq '.spec.resources.requests.storage' "$destination/storage.yaml") == 20Gi ]]
[[ $(yq '.spec.ingress[1].from[0].podSelector.matchLabels."app.kubernetes.io/name"' "$destination/network-policy.yaml") == customer-controller ]]
[[ $(yq '.spec.ingress[1].from[0].namespaceSelector.matchLabels."kubernetes.io/metadata.name"' "$destination/network-policy.yaml") == customer-ingress ]]
yq -o=json '.' "$destination/ingress.yaml" | jq -es '
    any(.[]; .metadata.name == "onify-app" and .spec.rules[0].host == "citizen.example.invalid") and
    any(.[]; .metadata.name == "onify-api" and .spec.rules[0].host == "api.example.invalid") and
    all(.[]; .spec.ingressClassName == "customer-nginx" and .metadata.annotations["cert-manager.io/cluster-issuer"] == "customer-issuer")
' >/dev/null
grep -Fxq 'ONIFY_client_secret=override-$secret-$$literal' "$destination/secrets.env"
printf '%s\n' 'Customer package checks passed (no cluster access).'
