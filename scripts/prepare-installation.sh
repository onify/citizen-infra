#!/usr/bin/env bash
# Prepare a new installation from .env or a customer package; never apply to a cluster.
# yq expressions must remain literal.
# shellcheck disable=SC2016
set +x
set -euo pipefail
umask 077
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fail() { printf '%s\n' "$*" >&2; exit 1; }
if [[ ${1:-} == --help || ${1:-} == -h ]]; then
    printf '%s\n' 'Usage: bash scripts/prepare-installation.sh --env-file .env' \
        '   or: bash scripts/prepare-installation.sh CUSTOMER_PACKAGE_DIRECTORY' \
        'Creates deployments/<client_code>-<instance_code>. See docs/customer-package.md.'
    exit 0
fi
env_file=
settings_name=customer.json
if [[ $# == 2 && $1 == --env-file && -f $2 ]]; then
    package=$(cd -- "$(dirname -- "$2")" && pwd)
    env_file="$package/$(basename -- "$2")"
    settings_name=.env
elif [[ $# == 1 && -d $1 ]]; then
    package=$(cd -- "$1" && pwd)
else
    fail 'Provide --env-file FILE or a customer package directory; see README.md.'
fi
for tool in jq yq kubectl openssl; do
    command -v "$tool" >/dev/null || fail "Install $tool; see README.md."
done
[[ $(yq --version) == *'github.com/mikefarah/yq/'*'version v4.'* ]] || fail 'Install Mike Farah yq v4.'
if [[ -n $env_file ]]; then
    command -v docker >/dev/null || fail 'Install Docker Compose to read .env; no running Docker engine is needed.'
    [[ -r $env_file ]] || fail 'The .env file is not readable.'
else
    [[ -f $package/customer.json && -r $package/customer.json ]] || fail 'Missing or unreadable package file: customer.json'
fi
[[ -f $package/keyfile.json && -r $package/keyfile.json ]] || fail 'Missing or unreadable package file: keyfile.json'
mkdir -p "$ROOT/deployments"
stage=$(mktemp -d "$ROOT/deployments/.prepare.XXXXXX")
destination=
claimed=false
complete=false
cleanup() {
    rm -rf -- "$stage"
    if $claimed && ! $complete; then rm -rf -- "$destination"; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [[ -n $env_file ]]; then
    # Compose parses .env as data, including quotes, interpolation and shell overrides.
    if ! docker compose --project-directory "$ROOT" --env-file "$env_file" \
        -f "$ROOT/compose.yaml" -f "$ROOT/scripts/kubernetes.compose.yaml" \
        config --format json 2> "$stage/.error" |
        jq '
            # Compose escapes dollar signs in exported config; restore the actual values.
            walk(if type == "string" then gsub("\\$\\$"; "$") else . end) |
            .services["onify-api"].environment as $api |
            def image: capture("^(?<repository>.+):(?<tag>[^:]+)$");
            .["x-kubernetes"] + {
                client_code: $api.ONIFY_client_code, instance_code: $api.ONIFY_client_instance,
                license: $api.ONIFY_initialLicense,
                admin: {username: $api.ONIFY_adminUser_username, password: $api.ONIFY_adminUser_password},
                app_secret: $api.ONIFY_apiTokens_app_secret, client_secret: $api.ONIFY_client_secret,
                images: {api: (.services["onify-api"].image | image),
                    app: (.services["onify-app"].image | image),
                    gateway: (.services["onify-gateway"].image | image)}
            }
        ' > "$stage/.customer.json" 2> "$stage/.error"; then
        fail 'Could not read .env with Docker Compose. Check Compose is installed and fill the shared settings; see README.md.'
    fi
else
    cp "$package/customer.json" "$stage/.customer.json"
fi
cp "$package/keyfile.json" "$stage/.keyfile.json"
for file in .customer.json .keyfile.json; do
    jq -es 'length == 1 and (.[0] | type == "object")' "$stage/$file" >/dev/null 2> "$stage/.error" || fail 'Each package JSON file must contain exactly one valid JSON object.'
done

# Reject misspelled fields and values that cannot be written safely as literal env entries.
jq -e '
    def fields($allowed): type == "object" and ((keys - $allowed) | length == 0);
    def text: type == "string" and test("^[^\\s\\x00-\\x1f\\x7f]+$") and (contains("REPLACE_WITH_") | not);
    def optional_secret: type == "string" and (. == "" or
        (test("\\S") and (test("[\\x00-\\x1f\\x7f]") | not) and (contains("REPLACE_WITH_") | not)));
    def dns_label: text and length <= 63 and test("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$");
    def host: text and length <= 253 and (split(".") | length >= 2 and all(.[]; dns_label));
    def image: fields(["repository", "tag"]) and
        (.repository | text and test("^[a-z0-9.-]+(:[0-9]+)?/[a-z0-9._/-]+$")) and
        (.tag | text and test("^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$"));
    fields(["client_code", "instance_code", "namespace", "license", "admin", "app_secret", "client_secret", "images", "ingress", "storage"]) and
    (.client_code | dns_label) and (.instance_code | dns_label) and (.namespace | dns_label) and
    (.license | optional_secret and length > 0) and
    (.admin | fields(["username", "password"]) and (.username | text) and (.password | optional_secret)) and
    (.app_secret | optional_secret) and (.client_secret | optional_secret) and
    (.images | fields(["api", "app", "gateway"]) and (.api | image) and (.app | image) and (.gateway | image)) and
    (.ingress | fields(["app_host", "api_host", "class_name", "cluster_issuer", "controller_namespace", "controller_labels"]) and
        (.app_host | host) and (.api_host | host) and .app_host != .api_host and
        (.class_name | dns_label) and (.cluster_issuer | dns_label) and (.controller_namespace | dns_label) and
        (.controller_labels | type == "object" and length > 0 and all(to_entries[]; (.key | text) and (.value | text)))) and
    (.storage | fields(["size", "class_name"]) and (.size | text and test("^[1-9][0-9]*(Mi|Gi|Ti)$")) and
        (.class_name == "" or (.class_name | dns_label)))
' "$stage/.customer.json" > /dev/null 2> "$stage/.error" || fail "Invalid $settings_name: fill every field in the template, use distinct DNS hostnames and remove placeholders/unknown fields."
name=$(jq -r '.client_code + "-" + .instance_code' "$stage/.customer.json")
destination="$ROOT/deployments/$name"
[[ ! -e $destination && ! -L $destination ]] || fail "Installation already exists: deployments/$name. Existing files and secrets were not changed."

jq -e '
    .type == "service_account" and
    (.client_email | type == "string" and test("^[^\\s@]+@[^\\s@]+$")) and
    (.private_key | type == "string" and test("\\S"))
' "$stage/.keyfile.json" >/dev/null 2> "$stage/.error" || fail 'keyfile.json must be the original Google service-account JSON from Onify, with type, client_email and private_key; a Docker config is not a keyfile.'
if ! jq -r '.private_key' "$stage/.keyfile.json" |
    openssl pkey -noout -passin pass: > "$stage/.error" 2>&1; then
    fail 'keyfile.json contains an invalid private_key; use the original file supplied by Onify.'
fi
# Never send the Google key to an unrelated image registry.
jq -e 'all(.images[]; .repository | split("/")[0] |
    test("^(gcr\\.io|(us|eu|asia)\\.gcr\\.io|[a-z0-9-]+-docker\\.pkg\\.dev)$"))
' "$stage/.customer.json" >/dev/null 2> "$stage/.error" || fail 'keyfile.json supports only Google Container Registry and Artifact Registry image hosts.'
jq -n --slurpfile config "$stage/.customer.json" --rawfile key "$stage/.keyfile.json" '
    ("_json_key:" + $key | @base64) as $auth |
    {auths: (reduce $config[0].images[] as $image ({};
        .[$image.repository | split("/")[0]] = {auth: $auth}))}
' > "$stage/registryCredentials.json" 2> "$stage/.error" || fail 'Could not generate registry credentials from keyfile.json.'

for file in kustomization.yaml namespace.yaml ingress.yaml storage.yaml resources-patch.yaml network-policy.yaml config.env gateway.env .gitignore; do
    cp "$ROOT/examples/acme/$file" "$stage/$file"
done
# yq reads settings from a file; no input is evaluated as shell or injected into expressions.
export ONIFY_PACKAGE_CONFIG="$stage/.customer.json"
yq -i 'load(strenv(ONIFY_PACKAGE_CONFIG)) as $c |
    .namespace = $c.namespace |
    (.images[] | select(.name == "onify-api-image")) |= (.newName = $c.images.api.repository | .newTag = $c.images.api.tag) |
    (.images[] | select(.name == "onify-app-image")) |= (.newName = $c.images.app.repository | .newTag = $c.images.app.tag) |
    (.images[] | select(.name == "onify-gateway-image")) |= (.newName = $c.images.gateway.repository | .newTag = $c.images.gateway.tag)
' "$stage/kustomization.yaml"
yq -i '.metadata.name = load(strenv(ONIFY_PACKAGE_CONFIG)).namespace' "$stage/namespace.yaml"
yq -i 'load(strenv(ONIFY_PACKAGE_CONFIG)).ingress as $c |
    .spec.ingressClassName = $c.class_name |
    .metadata.annotations."cert-manager.io/cluster-issuer" = $c.cluster_issuer |
    (select(.metadata.name == "onify-app") | .spec) |= (.rules[0].host = $c.app_host | .tls[0].hosts = [$c.app_host]) |
    (select(.metadata.name == "onify-api") | .spec) |= (.rules[0].host = $c.api_host | .tls[0].hosts = [$c.api_host])
' "$stage/ingress.yaml"
yq -i 'load(strenv(ONIFY_PACKAGE_CONFIG)).ingress as $c |
    .spec.ingress[1].from[0].namespaceSelector.matchLabels."kubernetes.io/metadata.name" = $c.controller_namespace |
    .spec.ingress[1].from[0].podSelector.matchLabels = $c.controller_labels
' "$stage/network-policy.yaml"
yq -i '.spec.resources.requests.storage = load(strenv(ONIFY_PACKAGE_CONFIG)).storage.size' "$stage/storage.yaml"
if [[ $(jq -r '.storage.class_name' "$stage/.customer.json") != '' ]]; then
    yq -i '.spec.storageClassName = load(strenv(ONIFY_PACKAGE_CONFIG)).storage.class_name' "$stage/storage.yaml"
fi
jq -Rrs --slurpfile config "$stage/.customer.json" '
    $config[0] as $c |
    {ONIFY_client_code: $c.client_code, ONIFY_client_instance: $c.instance_code,
     ONIFY_adminUser_username: $c.admin.username} as $values |
    split("\n") | map((split("=")[0] // "") as $key | if $values | has($key) then $key + "=" + $values[$key] else . end) | join("\n")
' "$stage/config.env" > "$stage/.config.env"
mv "$stage/.config.env" "$stage/config.env"
{
    jq -r '"ONIFY_initialLicense=" + .license' "$stage/.customer.json"
    for entry in admin.password:ONIFY_adminUser_password app_secret:ONIFY_apiTokens_app_secret client_secret:ONIFY_client_secret; do
        field=${entry%%:*}
        key=${entry#*:}
        value=$(jq -r ".$field" "$stage/.customer.json")
        if [[ -z $value ]]; then value=$(openssl rand -hex 32); fi
        printf '%s=%s\n' "$key" "$value"
    done
} > "$stage/secrets.env"
cp "$ROOT/examples/acme/gateway-secrets.env.example" "$stage/gateway-secrets.env"
chmod 600 "$stage"/* "$stage/.gitignore"
# Verify that rendering preserves both supplied and generated credentials exactly.
if ! kubectl kustomize "$stage" 2> "$stage/.error" |
    yq -o=json '.' 2> "$stage/.error" |
    jq -es --rawfile expected "$stage/secrets.env" '
        ($expected | split("\n") | map(select(length > 0) | capture("^(?<key>[^=]+)=(?<value>.*)$")) | from_entries) as $values |
        [.[] | select(.kind == "Secret" and (.metadata.name | startswith("onify-api-secrets-")))][0].data |
        map_values(gsub("[\r\n]"; "") | @base64d) == $values
    ' >/dev/null 2> "$stage/.error"; then
    fail 'Credential rendering changed an input value; check env-file compatibility.'
fi
bash "$ROOT/tests/check.sh" "$stage"
rm "$stage/.customer.json" "$stage/.keyfile.json" "$stage/.error"
# Claim a new destination so retries/concurrent runs cannot overwrite existing credentials.
mkdir "$destination" || fail 'Destination was created by another process; nothing was overwritten.'
claimed=true
cp -R "$stage/." "$destination/"
complete=true
printf 'Prepared deployments/%s (no cluster access).\n' "$name"
printf 'Admin password and secrets are in deployments/%s/secrets.env; empty inputs were generated and values are not printed.\n' "$name"
printf '%s\n' 'Store the installation securely. Continue with Select the cluster in README.md using this directory and its namespace.'
