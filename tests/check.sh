#!/usr/bin/env bash
# Check a configured installation, or run offline checks with test inputs.
set +x
set -euo pipefail
umask 077

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
installation=
schema=false
version=1.32.0

fail() { printf '%s\n' "$*" >&2; exit 1; }
usage() {
    printf '%s\n' 'Usage: bash tests/check.sh [installation] [--schema] [--kubernetes-version VERSION]' \
        'Without an installation, run self-checks using temporary test credentials.'
}

while (($#)); do
    case $1 in
        --schema) schema=true ;;
        --kubernetes-version)
            (($# >= 2)) || fail 'Missing value for --kubernetes-version.'
            version=$2; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) fail "Unknown option: $1" ;;
        *) [[ -z $installation ]] || fail 'Specify one installation directory.'; installation=$1 ;;
    esac
    shift
done
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'Use a Kubernetes version such as 1.32.0.'
for tool in kubectl yq jq; do
    command -v "$tool" >/dev/null || fail "Install $tool; see README.md."
done
[[ $(yq --version) == *'github.com/mikefarah/yq/'*'version v4.'* ]] || fail 'Install Mike Farah yq v4; see README.md.'
if $schema; then
    command -v kubeconform >/dev/null || fail 'Install kubeconform to use --schema.'
fi
if [[ -z $installation ]]; then
    exec bash "$ROOT/tests/self-check.sh" "$schema" "$version"
fi
[[ -d $installation ]] || fail "Installation directory not found: $installation"
installation=$(cd -- "$installation" && pwd)
temp=$(mktemp -d "${TMPDIR:-/tmp}/onify-citizen-check.XXXXXX")
trap 'rm -rf -- "$temp"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Read literal KEY=value data; never source customer files or put secrets in arguments.
for file in secrets.env config.env gateway.env gateway-secrets.env; do
    [[ -f $installation/$file ]] || fail "Missing $file; copy and fill in the example first."
    jq -Rs --arg file "$file" '
        reduce (split("\n") | to_entries[]) as $line ({};
            ($line.value | rtrimstr("\r")) as $text |
            if $text | test("^\\s*(#|$)") then .
            elif ($text | test("^[A-Za-z_][A-Za-z0-9_]*=")) | not then
                error("Invalid KEY=value entry in \($file), line \($line.key + 1).")
            else ($text | index("=")) as $offset | $text[:$offset] as $key |
                if has($key) then error("Duplicate key \($key) in \($file).")
                else .[$key] = $text[$offset + 1:] end
            end)
    ' < "$installation/$file" > "$temp/$file.json"
done
jq -en --slurpfile secrets "$temp/secrets.env.json" --slurpfile config "$temp/config.env.json" '
    ["ONIFY_initialLicense", "ONIFY_adminUser_password", "ONIFY_apiTokens_app_secret", "ONIFY_client_secret"] as $keys |
    reduce $keys[] as $key (true;
        if $config[0] | has($key) then error("Keep authentication values in secrets.env, not config.env.")
        elif ($secrets[0][$key] // "" | test("\\S")) | not then error("Fill in \($key) in secrets.env.")
        elif $secrets[0][$key] | test("^\\s*REPLACE_WITH_") then error("Replace the placeholder for \($key) in secrets.env.")
        else . end) |
    reduce ["ONIFY_client_code", "ONIFY_client_instance", "ONIFY_db_indexPrefix"][] as $key (.;
        if $config[0][$key] // "" | test("\\S") then . else error("Fill in \($key) in config.env.") end)
' >/dev/null

# Tool errors can contain input lines, so keep rendered credentials and diagnostics private.
kubectl kustomize "$installation" > "$temp/rendered.yaml" 2> "$temp/render-error" || fail 'Kustomize rendering failed; check overlay files and references.'
if grep -q 'REPLACE_WITH_' "$temp/rendered.yaml"; then
    fail 'Select all image repositories and tags; replace configuration placeholders.'
fi
yq eval -o=json '.' "$temp/rendered.yaml" > "$temp/resources.json" 2> "$temp/yaml-error" || fail 'Invalid rendered YAML.'
yq eval -o=json '.' "$installation/namespace.yaml" > "$temp/namespace.json" 2> "$temp/yaml-error" || fail 'Check namespace.yaml.'

jq -es --slurpfile namespace "$temp/namespace.json" '
    def require(condition; message): if condition then . else error("CHECK: " + message) end;
    def nonempty: type == "string" and test("\\S");
    def object($kind; $name):
        .[$kind + "/" + $name] // error("CHECK: Include the referenced \($kind)/\($name) in the overlay.");
    def container($name):
        (if $name == "onify-gateway" then "Deployment" else "StatefulSet" end) as $kind |
        object($kind; $name).spec.template.spec.containers[0];
    def data($kind; $name):
        object($kind; $name) | (.data // {}) |
        if $kind == "Secret" then with_entries(.value |= (
            gsub("[\r\n]"; "") | . as $encoded | @base64d |
            require((@base64) == $encoded; "Invalid base64 Secret data."))) else . end;
    def environment($container):
        . as $objects |
        reduce ($container.envFrom // [])[] as $source ({};
            ($source | has("secretRef")) as $secret |
            ($source.secretRef // $source.configMapRef) as $ref |
            ($objects | data(if $secret then "Secret" else "ConfigMap" end; $ref.name)) as $values |
            reduce ($values | to_entries[]) as $entry (.;
                .[($source.prefix // "") + $entry.key] = {value: $entry.value, secret: $secret})) |
        reduce ($container.env // [])[] as $entry (.;
            if $entry | has("value") then .[$entry.name] = {value: $entry.value, secret: false}
            else ($entry.valueFrom | has("secretKeyRef")) as $secret |
                ($entry.valueFrom.secretKeyRef // $entry.valueFrom.configMapKeyRef) as $ref |
                require($ref != null; "Use a literal or generated key reference for \($entry.name).") |
                ($objects | data(if $secret then "Secret" else "ConfigMap" end; $ref.name)) as $values |
                require($values | has($ref.key); "Missing key \($ref.key) in \($ref.name).") |
                .[$entry.name] = {value: $values[$ref.key], secret: $secret}
            end) |
        require(all(.[]; .value | type == "string"); "Environment values must be strings.");

    try (
        map(select(. != null)) |
        require(length == (unique_by([.kind, .metadata.name]) | length); "Duplicate rendered resource.") |
        map({key: (.kind + "/" + .metadata.name), value: .}) | from_entries |
        [.[] | select(.kind == "Namespace") | .metadata.name] as $namespaces |
        require($namespaces | length == 1; "Declare one installation namespace.") |
        require(any($namespace[]; .kind == "Namespace" and .metadata.name == $namespaces[0]);
            "Set the same namespace in namespace.yaml and kustomization.yaml.") |
        require(all(.[]; .kind == "Namespace" or .metadata.namespace == $namespaces[0]);
            "All resources must use the installation namespace.") |
        ["StatefulSet/onify-api", "StatefulSet/onify-worker", "StatefulSet/onify-app",
         "StatefulSet/onify-elasticsearch", "Deployment/onify-gateway"] as $workloads |
        require(([.[] | select(.kind == "StatefulSet" or .kind == "Deployment") | .kind + "/" + .metadata.name] | sort)
            == ($workloads | sort); "Expected API, worker, APP, Elasticsearch and Gateway workloads.") |
        reduce $workloads[] as $workload (.;
            .[$workload].spec.template.spec.containers[0] as $container |
            require($container.image | test("^onify-(api|app|gateway)-image$") | not;
                "Set image replacements for API, APP and Gateway in kustomization.yaml.") |
            require(all($container.resources.requests.cpu, $container.resources.requests.memory,
                $container.resources.limits.memory; nonempty); "Set CPU/memory requests and a memory limit for \($workload).") |
            require(($container.resources.limits | has("cpu") | not) or
                ($container.resources.limits.cpu | nonempty); "Set a non-empty CPU limit or omit it for \($workload).") |
            (environment($container)) as $env |
            require(all($env[]; .value | test("^\\s*REPLACE_WITH_") | not); "Replace environment placeholders for \($workload).")) |
        ["ONIFY_initialLicense", "ONIFY_adminUser_password", "ONIFY_apiTokens_app_secret", "ONIFY_client_secret"] as $keys |
        ([.[] | select(.kind == "Secret" and (.metadata.name | startswith("onify-api-secrets-")))][0].metadata.name) as $secret |
        require($secret != null; "Keep the generated onify-api-secrets Secret and its content hash.") |
        environment(container("onify-api")) as $api |
        reduce ["onify-api", "onify-worker"][] as $name (.;
            container($name) as $container |
            require(any($container.envFrom[]; . == {secretRef: {name: $secret}}); "\($name) must reference the generated Secret.") |
            environment($container) as $env |
            require(all($keys[]; $env[.].secret == true); "\($name) credentials must come from a Secret.") |
            require(all($keys[]; $env[.].value | nonempty); "\($name) requires non-empty credentials.") |
            require(($env | map_values(.value)) == ($api | map_values(.value)); "API and worker must use the same environment.")) |
        container("onify-app") as $app |
        require($app.image | test("/(citizen/app|hub/app)([:@]|$)") | not;
            "Select an APP image that serves / and proxies requests to the internal API.") |
        environment($app) as $app_env |
        require($app_env.ONIFY_API_URL_INTERNAL.value == "http://onify-api:8181"; "APP must proxy browser API requests to the internal API.") |
        require(all($app_env[]; .secret == false) and all($keys[]; . as $key | $app_env | has($key) | not); "API credentials must not be passed to the APP.") |
        require(all(object("Ingress"; "onify-app").spec.rules[]; .http.paths | length == 1 and
            .[0].path == "/" and .[0].backend.service == {name: "onify-app", port: {number: 4000}}); "APP Ingress must serve / on port 4000.") |
        require(all(.[] | select(.kind == "Ingress") | .spec.rules[].http.paths[];
            .backend.service.name != "onify-gateway" and .backend.service.name != "onify-elasticsearch"); "Gateway and Elasticsearch must stay internal.") |
        require(all(.[] | select(.kind == "Service"); (.spec.type // "ClusterIP") == "ClusterIP"); "Services must use ClusterIP.") |
        environment(container("onify-gateway")) as $gateway |
        ($gateway | map_values(.value)) as $env |
        require($env.PORT == "8686" and object("Service"; "onify-gateway").spec.ports[0].port == 8686; "Gateway must use port 8686.") |
        require($env.GATEWAY_HOST == "0.0.0.0" or $env.GATEWAY_HOST == "::"; "Gateway must listen on the pod network.") |
        require($env.GATEWAY_TENANCY == "single" or $env.GATEWAY_TENANCY == "multi"; "Select Gateway tenancy.") |
        require($env.GATEWAY_FAKE_MODE == "true" or $env.GATEWAY_FAKE_MODE == "false"; "Set GATEWAY_FAKE_MODE to true or false.") |
        require(["onify-halo-api", "api-key", "none"] | index($env.GATEWAY_AUTH); "Select Gateway authentication.") |
        require($env.GATEWAY_AUTH != "none" or $env.GATEWAY_FAKE_MODE == "true"; "Live Gateway requires authentication; none only works with fake data.") |
        require($env.NODE_ENV != "production" or $env.GATEWAY_FAKE_MODE == "false"; "Production Gateway must use live data.") |
        require($env.GATEWAY_AUTH != "onify-halo-api" or
            ($gateway.GATEWAY_HALO_API_CLIENT_SECRET.secret == true and $env.GATEWAY_HALO_API_CLIENT_SECRET == $api.ONIFY_client_secret.value
             and $env.GATEWAY_HALO_API_CLIENT_CODE == $api.ONIFY_client_code.value);
            "Gateway JWT authentication must reference the API client code and client Secret.") |
        require($env.GATEWAY_AUTH != "api-key" or
            ($gateway.GATEWAY_API_KEY.secret == true and ($env.GATEWAY_API_KEY | nonempty));
            "Gateway API-key authentication requires GATEWAY_API_KEY from a Secret.") |
        object("StatefulSet"; "onify-elasticsearch").spec.template.spec as $pod |
        environment(container("onify-elasticsearch")) as $elastic |
        (if $elastic["xpack.security.enabled"].value == "true" then
            require($elastic["xpack.security.http.ssl.enabled"].value == "true";
                "Authenticated Elasticsearch requires HTTPS.") |
            require($elastic.ELASTIC_PASSWORD.secret == true and ($elastic.ELASTIC_PASSWORD.value | nonempty);
                "Elasticsearch bootstrap password must come from a Secret.") |
            reduce ["onify-api", "onify-worker"][] as $name (.;
                environment(container($name)) as $env |
                require($env.ONIFY_db_elasticsearch_host.value == "https://onify-elasticsearch:9200";
                    "API and worker must use the Elasticsearch HTTPS endpoint.") |
                require(all(["ONIFY_db.elasticsearch.auth.username", "ONIFY_db.elasticsearch.auth.password"][];
                    $env[.].secret == true and ($env[.].value | nonempty));
                    "Elasticsearch client credentials require dotted environment names and Secret references.") |
                require($env.NODE_EXTRA_CA_CERTS.value == "/etc/onify/ca/ca.crt" and
                    any(container($name).volumeMounts[]?; .name == "elasticsearch-ca" and .mountPath == "/etc/onify/ca" and .readOnly == true);
                    "Mount the Elasticsearch CA read-only for API and worker.") |
                require($env.NODE_TLS_REJECT_UNAUTHORIZED.value != "0" and
                    $env["ONIFY_db.elasticsearch.tls.rejectUnauthorized"].value != "false" and
                    $env.ONIFY_db_elasticsearch_tls_rejectUnauthorized.value != "false";
                    "Do not disable Elasticsearch certificate verification."))
         else . end) |
        require(any($pod.volumes[]; .name == "data" and (.persistentVolumeClaim.claimName | nonempty)) and
            any($pod.containers[0].volumeMounts[]; . == {name: "data", mountPath: "/usr/share/elasticsearch/data"});
            "Elasticsearch must mount persistent customer data.") |
        true
    ) catch (if startswith("CHECK: ") then error(ltrimstr("CHECK: ")) else error("Invalid manifest structure or environment data.") end)
' "$temp/resources.json" >/dev/null

if $schema; then
    kubeconform -strict -summary -kubernetes-version "$version" "$temp/rendered.yaml"
fi
printf '%s\n' 'Installation preflight passed (no cluster access).'
