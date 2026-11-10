#!/usr/bin/env bash
# Offline security wiring checks. No real credentials, images or cluster needed.
set +x
set -euo pipefail
umask 077
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
temp=$(mktemp -d "${TMPDIR:-/tmp}/onify-security-check.XXXXXX")
trap 'rm -rf -- "$temp"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
overlay="$temp/examples/acme"
mkdir -p "$overlay"
cp -R "$ROOT/kubernetes" "$temp/kubernetes"
for file in kustomization.yaml namespace.yaml ingress.yaml storage.yaml resources-patch.yaml network-policy.yaml config.env gateway.env; do
    cp "$ROOT/examples/acme/$file" "$overlay/"
done
cp "$ROOT/examples/security/"*-patch.yaml "$overlay/"
cp "$ROOT/examples/acme/gateway-secrets.env.example" "$overlay/gateway-secrets.env"
sed 's/REPLACE_WITH_[A-Za-z0-9_]*/selfcheck/g' "$overlay/kustomization.yaml" > "$temp/kustomization.yaml"
mv "$temp/kustomization.yaml" "$overlay/kustomization.yaml"
for key in ONIFY_initialLicense ONIFY_adminUser_password ONIFY_apiTokens_app_secret ONIFY_client_secret; do
    printf '%s=test-only\n' "$key"
done > "$overlay/secrets.env"
printf 'username=onify\npassword=test-only-client-$literal # secret\n' > "$overlay/elasticsearch-client.env"
printf 'password=test-only-bootstrap\n' > "$overlay/elasticsearch-bootstrap.env"
# Rendering checks only; real certificate validation belongs to the runtime test.
printf 'test-only-public-ca\n' > "$overlay/ca.crt"
printf 'test-only-public-certificate\n' > "$overlay/tls.crt"
printf 'test-only-private-key\n' > "$overlay/tls.key"
yq -i '
    .patches += [{"path": "elasticsearch-patch.yaml"}, {"path": "non-root-patch.yaml"}] |
    .configMapGenerator += [{"name": "onify-elasticsearch-ca", "files": ["ca.crt"]}] |
    .secretGenerator += [
        {"name": "onify-elasticsearch-tls", "type": "kubernetes.io/tls", "files": ["tls.crt", "tls.key"]},
        {"name": "onify-elasticsearch-bootstrap", "envs": ["elasticsearch-bootstrap.env"]},
        {"name": "onify-elasticsearch-client", "envs": ["elasticsearch-client.env"]}]
' "$overlay/kustomization.yaml"
check() { bash "$ROOT/tests/check.sh" "$overlay" > "$temp/check.log" 2>&1; }
check || { cat "$temp/check.log" >&2; exit 1; }
kubectl kustomize "$overlay" | yq -o=json '.' | jq -s 'map(select(. != null))' > "$temp/rendered.json"
jq -e '
    . as $objects |
    all(.[] | select(.kind == "StatefulSet" and (.metadata.name | IN("onify-api", "onify-worker", "onify-app")));
        .spec.template.spec as $pod |
        (if .metadata.name == "onify-app" then 101 else 1000 end) as $uid |
        $pod.securityContext.runAsUser == $uid and $pod.securityContext.runAsGroup == $uid and
        $pod.securityContext.fsGroup == $uid and $pod.securityContext.runAsNonRoot == true and
        $pod.securityContext.seccompProfile.type == "RuntimeDefault" and
        $pod.containers[0].securityContext == {
            allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: ["ALL"]}}) and
    all(.[] | select(.kind == "StatefulSet") | .spec.template.spec.volumes[]? | select(.secret);
        .secret.secretName as $name | any($objects[]; .kind == "Secret" and .metadata.name == $name)) and
    all(.[] | select(.kind == "StatefulSet" and (.metadata.name | IN("onify-api", "onify-worker"))) | .spec.template.spec;
        all(.volumes[]; has("secret") | not) and
        any(.volumes[]; .configMap.name // "" | startswith("onify-elasticsearch-ca-"))) and
    any(.[]; .kind == "Secret" and (.metadata.name | startswith("onify-elasticsearch-client-")) and
        (.data.password | @base64d) == "test-only-client-$literal # secret")
' "$temp/rendered.json" >/dev/null
# Credential rotation must restart both database clients, without sharing their
# new credential with Elasticsearch itself, Gateway or the app.
printf 'username=onify\npassword=test-only-rotated\n' > "$overlay/elasticsearch-client.env"
kubectl kustomize "$overlay" | yq -o=json '.' | jq -s 'map(select(. != null))' > "$temp/rotated.json"
jq -e --slurpfile before "$temp/rendered.json" '
    def workloads: map(select(.kind == "StatefulSet" or .kind == "Deployment")) |
        map({key: .metadata.name, value: .}) | from_entries;
    ($before[0] | workloads) as $old | workloads as $new |
    all(["onify-api", "onify-worker"][]; . as $name | $old[$name] != $new[$name]) and
    all(["onify-elasticsearch", "onify-gateway", "onify-app"][]; . as $name | $old[$name] == $new[$name])
' "$temp/rotated.json" >/dev/null
cp "$overlay/elasticsearch-patch.yaml" "$temp/original-patch.yaml"
for scenario in http literal bypass; do
    cp "$temp/original-patch.yaml" "$overlay/elasticsearch-patch.yaml"
    case $scenario in
        http)
            yq -i '(select(.metadata.name == "onify-elasticsearch") | .spec.template.spec.containers[0].env[] | select(.name == "xpack.security.http.ssl.enabled")).value = "false"' "$overlay/elasticsearch-patch.yaml"
            expected='Authenticated Elasticsearch requires HTTPS' ;;
        literal)
            yq -i '(select(.metadata.name != "onify-elasticsearch") | .spec.template.spec.containers[0].env[] | select(.name == "ONIFY_db.elasticsearch.auth.password")) |= (del(.valueFrom) | .value = "unsafe-literal")' "$overlay/elasticsearch-patch.yaml"
            expected='Elasticsearch client credentials require dotted environment names and Secret references' ;;
        bypass)
            yq -i '(select(.metadata.name != "onify-elasticsearch") | .spec.template.spec.containers[0].env) += [{"name": "NODE_TLS_REJECT_UNAUTHORIZED", "value": "0"}]' "$overlay/elasticsearch-patch.yaml"
            expected='Do not disable Elasticsearch certificate verification' ;;
    esac
    if check; then printf 'Expected rejection: %s\n' "$scenario" >&2; exit 1; fi
    grep -Fq "$expected" "$temp/check.log" || { cat "$temp/check.log" >&2; exit 1; }
done
printf '%s\n' 'Security manifest checks passed (no cluster access).'
