#!/usr/bin/env bash
# Render only synthetic credentials; no Docker daemon or private images needed.
set +x
set -euo pipefail
umask 077
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
temp=$(mktemp -d "${TMPDIR:-/tmp}/onify-compose-check.XXXXXX")
trap 'rm -rf -- "$temp"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
cp "$ROOT/compose.yaml" "$ROOT/.env.example" "$temp/"
cd "$temp"

# Ignore user shell values and never load the real installation's .env.
while IFS='=' read -r key _; do
    case $key in ''|'#'*) continue ;; esac
    unset "$key"
done < .env.example
unset COMPOSE_PROJECT_NAME
compose() { docker compose --project-directory "$temp" --env-file "$temp/.env" -f "$temp/compose.yaml" config "$@"; }
sed "s/^\([^=]*\)=''\$/\1='test-only-\1-\$literal # secret'/; s/=\$/=test-only/" .env.example > .env
compose --format json > rendered.json
# Compose versions may escape literal dollars when exporting reusable config.
jq -e '
    .services as $s |
    $s["onify-api"] as $api |
    $s["onify-worker"] as $worker |
    $s["onify-gateway"].environment as $gateway |
    ($s | length) == 5 and
    all($s[]; .pull_policy == "always") and
    .name == "onify-test-only_test-only" and
    .volumes["elasticsearch-data"].name == "onify-test-only_test-only_elasticsearch-data" and
    ([$s[].volumes[]? | select(.source == "elasticsearch-data")] | length) == 1 and
    $s["onify-elasticsearch"].image == "docker.elastic.co/elasticsearch/elasticsearch:9.5.6" and
    $s["onify-elasticsearch"].environment["xpack.security.enabled"] == "false" and
    $api.image == $worker.image and $worker.command == ["worker"] and
    $api.environment == $worker.environment and
    $api.environment.ONIFY_websockets_agent_url == "" and
    ($api.environment.ONIFY_initialLicense | gsub("\\$\\$"; "$")) == "test-only-ONIFY_initialLicense-$literal # secret" and
    $gateway.GATEWAY_HALO_API_CLIENT_CODE == $api.environment.ONIFY_client_code and
    $gateway.GATEWAY_HALO_API_CLIENT_SECRET == $api.environment.ONIFY_client_secret and
    all(["ACTORSMARTBOOK_ASSOCIATIONS", "BYGGR_CASES", "SSBTGO_ORGANIZATIONS"][];
        $gateway["GATEWAY_INTEGRATION_" + . + "_ENABLED"] == "false") and
    ($gateway | has("ONIFY_adminUser_password") or has("ONIFY_apiTokens_app_secret") | not) and
    ($s["onify-app"].environment | keys) == ["ONIFY_API_URL_INTERNAL"] and
    $s["onify-app"].environment.ONIFY_API_URL_INTERNAL == "http://onify-api:8181" and
    $api.environment.ONIFY_db_elasticsearch_host == "http://onify-elasticsearch:9200" and
    all($s[].ports[]?; .host_ip == "127.0.0.1") and
    ([$s[].ports[]?] | length) == 1 and
    $s["onify-app"].ports[0].published == "80" and
    ($s["onify-api"].ports // [] | length) == 0 and
    .configs["app-nginx-redirects"].content == "absolute_redirect off;\n" and
    any($s["onify-app"].configs[]; .source == "app-nginx-redirects" and .target == "/etc/nginx/conf.d/00-local-redirects.conf") and
    ($s["onify-elasticsearch"].ports // [] | length) == 0 and
    ($s["onify-gateway"].ports // [] | length) == 0 and
    $api.depends_on["onify-elasticsearch"].condition == "service_healthy" and
    all(["onify-worker", "onify-app", "onify-gateway"][]; $s[.].depends_on["onify-api"].condition == "service_healthy") and
    any($s["onify-elasticsearch"].volumes[]; .type == "volume" and .source == "elasticsearch-data" and .target == "/usr/share/elasticsearch/data")
' rendered.json > /dev/null || { printf '%s\n' 'Compose wiring assertion failed.' >&2; exit 1; }

cp .env complete.env
# A different client or instance gets its own data; a restart keeps the same name.
compose --format json > repeated.json
jq -e --slurpfile before rendered.json '.volumes == $before[0].volumes' repeated.json > /dev/null
for key in ONIFY_client_code ONIFY_client_instance; do
    sed "s/^$key=.*/$key=another/; s/^APP_PORT=.*/APP_PORT=4001/" complete.env > .env
    compose --format json > separate.json
    jq -e --slurpfile before rendered.json '
        .name != $before[0].name and
        .volumes["elasticsearch-data"].name != $before[0].volumes["elasticsearch-data"].name and
        .services["onify-app"].ports[0].published == "4001" and
        .services["onify-app"].ports[0].target == 4000 and
        (.services["onify-api"].ports // [] | length) == 0
    ' separate.json > /dev/null
done
for key in API_TAG APP_TAG GATEWAY_TAG ONIFY_client_code ONIFY_client_instance ONIFY_initialLicense \
    ONIFY_adminUser_password ONIFY_apiTokens_app_secret ONIFY_client_secret; do
    sed "s/^$key=.*/$key=/" complete.env > .env
    if compose --quiet > check.log 2>&1; then
        printf 'Expected rejection of empty %s\n' "$key" >&2
        exit 1
    fi
    grep -Fq "Set $key in .env" check.log
done
printf '%s\n' 'Compose checks passed (no containers started).'
