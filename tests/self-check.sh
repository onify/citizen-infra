#!/usr/bin/env bash
# Invoked by check.sh after dependency checks; all fixtures use test credentials.
# jq expressions and shell-syntax fixtures must remain literal.
# shellcheck disable=SC2016
set +x
set -euo pipefail
umask 077
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
schema=${1:-false}
version=${2:-1.32.0}
temp=$(mktemp -d "${TMPDIR:-/tmp}/onify-citizen-self-check.XXXXXX")
trap 'rm -rf -- "$temp"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
overlay="$temp/examples/test installation"
mkdir -p "$overlay"
cp -R "$ROOT/kubernetes" "$temp/kubernetes"
for file in "$ROOT/examples/acme/"*; do
    case ${file##*/} in secrets.env|gateway-secrets.env) continue ;; esac
    cp "$file" "$overlay/"
done
cp "$overlay/secrets.env.example" "$overlay/secrets.env"
cp "$overlay/gateway-secrets.env.example" "$overlay/gateway-secrets.env"

check() { bash "$ROOT/tests/check.sh" "$overlay" > "$temp/check.log" 2>&1; }
rejected() {
    if check; then printf 'Expected rejection: %s\n' "$1" >&2; exit 1; fi
    grep -Fq "$1" "$temp/check.log" || { cat "$temp/check.log" >&2; exit 1; }
}
accepted() { check || { cat "$temp/check.log" >&2; exit 1; }; }
replace() {
    sed "$2" "$1" > "$temp/edited"
    mv "$temp/edited" "$1"
}
render() {
    kubectl kustomize "$overlay" | yq eval -o=json '.' | jq -sS 'map({key: (.kind + "/" + .metadata.name), value: .}) | from_entries' > "$1"
}
assert_json() { jq -e "$@" >/dev/null || { printf 'Self-check assertion failed at line %s.\n' "${BASH_LINENO[0]}" >&2; exit 1; }; }
schema_check() {
    if [[ $schema == true ]]; then
        kubectl kustomize "$overlay" | kubeconform -strict -summary -kubernetes-version "$version"
    fi
}
rollout_check() {
    assert_json --slurpfile before "$1" --slurpfile after "$2" -n '
        all(["StatefulSet/onify-api", "StatefulSet/onify-worker", "Deployment/onify-gateway"][];
            $before[0][.] != $after[0][.]) and
        $before[0]["StatefulSet/onify-app"] == $after[0]["StatefulSet/onify-app"]'
}

rejected 'Fill in ONIFY_initialLicense'
for key in ONIFY_initialLicense ONIFY_adminUser_password ONIFY_apiTokens_app_secret ONIFY_client_secret; do
    printf '%s=test-only-%s#!=$()\n' "$key" "$key"
done > "$overlay/secrets.env"
rejected 'Select all image'
replace "$overlay/kustomization.yaml" 's/REPLACE_WITH_[A-Za-z0-9_]*/selfcheck/g'
accepted
render "$temp/original.json"
render "$temp/repeated.json"
cmp "$temp/original.json" "$temp/repeated.json"
schema_check
assert_json '
    .["StatefulSet/onify-api"].spec.template.spec.containers[0] as $api |
    .["StatefulSet/onify-worker"].spec.template.spec.containers[0] as $worker |
    .["Deployment/onify-gateway"].spec.template.spec.containers[0] as $gateway |
    .["NetworkPolicy/onify-citizen"].spec as $policy |
    $gateway.env[] | select(.name == "GATEWAY_HALO_API_CLIENT_SECRET") | .valueFrom.secretKeyRef as $ref |
    $api.image == $worker.image and $worker.args == ["worker"] and
    $ref.key == "ONIFY_client_secret" and
    all($gateway.env[]; [.name] - ["ONIFY_initialLicense", "ONIFY_adminUser_password", "ONIFY_apiTokens_app_secret", "ONIFY_client_secret"] | length == 1) and
    all($gateway.envFrom[]; (.secretRef.name // "") | startswith("onify-api-secrets-") | not) and
    $policy.podSelector == {} and $policy.policyTypes == ["Ingress"] and
    $policy.ingress[0] == {from: [{podSelector: {}}]} and
    ($policy.ingress[1].from | length) == 1 and
    ($policy.ingress[1].from[0] | keys) == ["namespaceSelector", "podSelector"] and
    ($policy.ingress[1].ports | map(.port) | sort) == [4000, 8181]
' "$temp/original.json"
assert_json '
    [.[] | select(.kind == "Secret" and (.metadata.name | startswith("onify-api-secrets-")))][0] |
    (.data.ONIFY_client_secret | @base64d) == "test-only-ONIFY_client_secret#!=$()"
' "$temp/original.json"

# Exercise literal shell syntax, CRLF, no final newline, and malformed/duplicate keys.
cp "$overlay/gateway-secrets.env" "$temp/saved.env"
printf 'PROVIDER_SECRET=$(touch %s/should-not-exist)`touch %s/should-not-exist` #!="quoted"\\backslash\r\n' "$temp" "$temp" >> "$overlay/gateway-secrets.env"
printf 'LAST_KEY=literal' >> "$overlay/gateway-secrets.env"
accepted
[[ ! -e $temp/should-not-exist ]]
render "$temp/literal.json"
assert_json --rawfile expected "$overlay/gateway-secrets.env" '
    [.[] | select(.kind == "Secret" and (.metadata.name | startswith("onify-gateway-secrets-")))][0].data |
    (.PROVIDER_SECRET | gsub("[\r\n]"; "") | @base64d) == ($expected | split("\n")[] | select(startswith("PROVIDER_SECRET=")) | rtrimstr("\r") | sub("^PROVIDER_SECRET="; "")) and
    (.LAST_KEY | @base64d) == "literal"
' "$temp/literal.json"
printf '\nLAST_KEY=duplicate\n' >> "$overlay/gateway-secrets.env"
rejected 'Duplicate key LAST_KEY'
printf 'not a key=private-value\n' > "$overlay/gateway-secrets.env"
rejected 'Invalid KEY=value entry'
if grep -Fq 'private-value' "$temp/check.log"; then
    printf '%s\n' 'Validation errors must not disclose secret values.' >&2
    exit 1
fi
cp "$temp/saved.env" "$overlay/gateway-secrets.env"

for scenario in image budgets auth fake; do
    cp "$overlay/kustomization.yaml" "$temp/saved.yaml"
    cp "$overlay/gateway.env" "$temp/saved.env"
    case $scenario in
        image) replace "$overlay/kustomization.yaml" 's|citizen/app-root|citizen/app|'; rejected 'Select an APP image' ;;
        budgets) replace "$overlay/kustomization.yaml" '/  - path: resources-patch.yaml/d'; rejected 'Set CPU/memory' ;;
        auth) replace "$overlay/gateway.env" 's/GATEWAY_AUTH=onify-halo-api/GATEWAY_AUTH=none/'; rejected 'Live Gateway requires authentication' ;;
        fake) replace "$overlay/gateway.env" 's/GATEWAY_FAKE_MODE=false/GATEWAY_FAKE_MODE=true/'; rejected 'Production Gateway must use live data' ;;
    esac
    cp "$temp/saved.yaml" "$overlay/kustomization.yaml"
    cp "$temp/saved.env" "$overlay/gateway.env"
done
base="$temp/kubernetes/onify-citizen.yaml"
cp "$base" "$temp/saved-base.yaml"
replace "$base" 's/key: ONIFY_client_secret/key: missing_client_secret/'
rejected 'Missing key missing_client_secret'
cp "$temp/saved-base.yaml" "$base"

replace "$overlay/config.env" 's/ONIFY_client_code=acme/ONIFY_client_code=another-client/'
accepted
render "$temp/reconfigured.json"
rollout_check "$temp/original.json" "$temp/reconfigured.json"
replace "$overlay/secrets.env" 's/test-only-ONIFY_client_secret/changed-secret/'
accepted
render "$temp/rotated.json"
rollout_check "$temp/reconfigured.json" "$temp/rotated.json"
printf 'GATEWAY_API_KEY=test-only-key\n' > "$overlay/gateway-secrets.env"
accepted
render "$temp/provider.json"
assert_json --slurpfile before "$temp/rotated.json" --slurpfile after "$temp/provider.json" -n '
    $before[0]["Deployment/onify-gateway"] != $after[0]["Deployment/onify-gateway"] and
    all(["StatefulSet/onify-api", "StatefulSet/onify-worker", "StatefulSet/onify-app"][]; $before[0][.] == $after[0][.])'
cp "$overlay/gateway.env" "$temp/saved.env"
replace "$overlay/gateway.env" 's/GATEWAY_AUTH=onify-halo-api/GATEWAY_AUTH=api-key/'
accepted
: > "$overlay/gateway-secrets.env"
rejected 'requires GATEWAY_API_KEY from a Secret'
printf '\nGATEWAY_API_KEY=unsafe-literal-key\n' >> "$overlay/gateway.env"
rejected 'requires GATEWAY_API_KEY from a Secret'
printf 'GATEWAY_API_KEY=test-only-key\n' > "$overlay/gateway-secrets.env"
# Explicit env literals override envFrom Secrets and must lose Secret provenance.
cp "$base" "$temp/saved-base.yaml"
yq -i '(select(.kind == "Deployment") | .spec.template.spec.containers[0].env) += [{"name": "GATEWAY_API_KEY", "value": "unsafe-literal-key"}]' "$base"
rejected 'requires GATEWAY_API_KEY from a Secret'
cp "$temp/saved-base.yaml" "$base"
: > "$overlay/gateway-secrets.env"
cp "$temp/saved.env" "$overlay/gateway.env"
replace "$overlay/gateway.env" 's/NODE_ENV=production/NODE_ENV=development/;s/GATEWAY_AUTH=onify-halo-api/GATEWAY_AUTH=none/;s/GATEWAY_FAKE_MODE=false/GATEWAY_FAKE_MODE=true/'
accepted
cp "$temp/saved.env" "$overlay/gateway.env"

cp "$ROOT"/examples/elasticsearch/backup-*.yaml "$overlay/"
yq -i '.resources += ["backup-storage.yaml"] | .patches += [{"path": "backup-patch.yaml"}]' "$overlay/kustomization.yaml"
accepted
schema_check
render "$temp/backup.json"
assert_json --slurpfile repository "$ROOT/examples/elasticsearch/snapshot-repository.json" \
    --slurpfile policy "$ROOT/examples/elasticsearch/daily-snapshot-policy.json" '
    .["StatefulSet/onify-elasticsearch"].spec.template.spec as $pod |
    ($pod.volumes | map(.persistentVolumeClaim.claimName) | sort) == ["onify-elasticsearch-backup", "onify-elasticsearch-data"] and
    any($pod.containers[0].env[]; .name == "path.repo" and .value == "/usr/share/elasticsearch/backup" and .value == $repository[0].settings.location) and
    $policy[0].repository == "backup_repo" and $policy[0].retention.max_count >= $policy[0].retention.min_count and
    $policy[0].config.include_global_state == false and $policy[0].config.feature_states == ["none"]
' "$temp/backup.json"
replace "$overlay/kustomization.yaml" 's/namespace: onify-citizen-test/namespace: another-installation/'
rejected 'Set the same namespace'
replace "$overlay/namespace.yaml" 's/onify-citizen-test/another-installation/'
accepted
printf '%s\n' 'Kustomize checks passed (no cluster access).'
