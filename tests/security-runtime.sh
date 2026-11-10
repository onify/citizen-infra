#!/usr/bin/env bash
# Disposable local proof using existing images; no pulls, host ports or customer data.
set +x
set -euo pipefail
umask 077
[[ $# == 2 ]] || { printf '%s\n' 'Usage: bash tests/security-runtime.sh API_IMAGE APP_ROOT_IMAGE' >&2; exit 1; }
api_image=$1
app_image=$2
temp=$(mktemp -d "${TMPDIR:-/tmp}/onify-security-runtime.XXXXXX")
name="onify-security-${temp##*.}"
name=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
cleanup() {
    docker rm -f "$name-es" >/dev/null 2>&1 || true
    docker network rm "$name" >/dev/null 2>&1 || true
    rm -rf -- "$temp"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir "$temp/tls"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=onify-test-ca \
    -keyout "$temp/ca.key" -out "$temp/tls/ca.crt" > "$temp/openssl.log" 2>&1
openssl req -newkey rsa:2048 -nodes -subj /CN=onify-elasticsearch \
    -keyout "$temp/tls/tls.key" -out "$temp/server.csr" >> "$temp/openssl.log" 2>&1
printf 'subjectAltName=DNS:onify-elasticsearch\nextendedKeyUsage=serverAuth\n' > "$temp/extensions"
openssl x509 -req -days 1 -in "$temp/server.csr" -CA "$temp/tls/ca.crt" -CAkey "$temp/ca.key" \
    -CAcreateserial -extfile "$temp/extensions" -out "$temp/tls/tls.crt" >> "$temp/openssl.log" 2>&1
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=untrusted-test-ca \
    -keyout "$temp/wrong-ca.key" -out "$temp/wrong-ca.crt" >> "$temp/openssl.log" 2>&1
# Disposable test key only; the runtime UID must read the host bind mount.
chmod 755 "$temp/tls"
chmod 644 "$temp/tls/"*
chmod 644 "$temp/wrong-ca.crt"
docker network create --internal "$name" >/dev/null
docker run --detach --pull never --name "$name-es" --network "$name" \
    --network-alias onify-elasticsearch --network-alias wrong-name --memory 2g \
    --tmpfs /usr/share/elasticsearch/data:uid=1000,gid=0 \
    --mount "type=bind,source=$temp/tls,target=/usr/share/elasticsearch/config/tls,readonly" \
    -e discovery.type=single-node -e ES_JAVA_OPTS=-Xms512m\ -Xmx512m \
    -e xpack.security.enabled=true -e xpack.security.http.ssl.enabled=true \
    -e xpack.security.http.ssl.certificate=tls/tls.crt -e xpack.security.http.ssl.key=tls/tls.key \
    -e ELASTIC_PASSWORD=test-only-bootstrap \
    docker.elastic.co/elasticsearch/elasticsearch:9.5.6 >/dev/null
ready=false
for ((attempt=0; attempt<120; attempt++)); do
    if docker exec "$name-es" curl --fail --silent --cacert config/tls/ca.crt \
        -u elastic:test-only-bootstrap 'https://onify-elasticsearch:9200/_cluster/health?wait_for_status=yellow&timeout=1s' \
        > "$temp/health.json" 2>/dev/null; then ready=true; break; fi
    sleep 1
done
if ! $ready; then docker logs --tail 40 "$name-es" >&2; exit 1; fi
# Prove a separate application user, without giving it the bootstrap password.
docker exec "$name-es" curl --fail --silent --cacert config/tls/ca.crt -u elastic:test-only-bootstrap \
    -H 'Content-Type: application/json' -X PUT https://onify-elasticsearch:9200/_security/role/onify_test \
    -d '{"cluster":["monitor"],"indices":[{"names":["onify-*"],"privileges":["all"]}]}' >/dev/null
docker exec "$name-es" curl --fail --silent --cacert config/tls/ca.crt -u elastic:test-only-bootstrap \
    -H 'Content-Type: application/json' -X PUT https://onify-elasticsearch:9200/_security/user/onify_test \
    -d '{"password":"test-only-client","roles":["onify_test"]}' >/dev/null
cat > "$temp/check.js" <<'JS'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const https = require('node:https');
const config = require('/usr/app/node_modules/exp-config');
const client = require('/usr/app/src/lib/elasticsearchClient')();
async function request(options) {
  return new Promise((resolve, reject) => {
    const req = https.get({ hostname: 'onify-elasticsearch', port: 9200, agent: false, ...options }, res => {
      res.resume(); res.on('end', () => resolve(res.statusCode));
    });
    req.on('error', reject);
  });
}
(async () => {
  assert.equal(process.getuid(), 1000);
  assert.equal(config.db.elasticsearch.auth.username, 'onify_test');
  for (const path of [config.resources.baseDir, config.resources.tempDir, '/tmp']) {
    fs.mkdirSync(`${path}/check`, { recursive: true });
    fs.writeFileSync(`${path}/check/file`, 'ok');
  }
  assert.equal((await client.info()).version.number, '9.5.6');
  await client.cluster.health();
  await client.index({ index: 'onify-security-check', id: '1', document: { ok: true } });
  assert.equal((await client.get({ index: 'onify-security-check', id: '1' }))._source.ok, true);
  await client.indices.delete({ index: 'onify-security-check' });
  assert.equal(await request({}), 401);
  assert.equal(await request({ auth: 'onify_test:wrong-password' }), 401);
  assert.equal(await request({ auth: 'onify_test:test-only-client', path: '/_security/user' }), 403);
  await assert.rejects(request({ hostname: 'wrong-name' }), { code: 'ERR_TLS_CERT_ALTNAME_INVALID' });
  await assert.rejects(request({ ca: fs.readFileSync('/wrong-ca.crt') }), e => /CERT|VERIFY/.test(e.code));
  await client.close();
  console.log('API/worker UID, writable paths, HTTPS, dedicated-user CRUD and negative authentication/TLS checks passed.');
})().catch(error => { console.error(error); process.exit(1); });
JS
chmod 644 "$temp/check.js"
docker run --rm --pull never --platform linux/amd64 --network "$name" --user 1000:1000 \
    --read-only --cap-drop ALL --security-opt no-new-privileges \
    --tmpfs /usr/share/onify/resources:uid=1000,gid=1000,mode=0700 \
    --tmpfs /usr/share/onify/temp_resources:uid=1000,gid=1000,mode=0700 \
    --tmpfs /tmp:uid=1000,gid=1000,mode=0700 \
    --mount "type=bind,source=$temp/tls/ca.crt,target=/etc/onify/ca/ca.crt,readonly" \
    --mount "type=bind,source=$temp/check.js,target=/check.js,readonly" \
    --mount "type=bind,source=$temp/wrong-ca.crt,target=/wrong-ca.crt,readonly" \
    -e NODE_ENV=production -e ENV_PREFIX=ONIFY_ -e INTERPRET_CHAR_AS_DOT=_ \
    -e ONIFY_resources_baseDir=/usr/share/onify/resources -e ONIFY_resources_tempDir=/usr/share/onify/temp_resources \
    -e ONIFY_db_elasticsearch_host=https://onify-elasticsearch:9200 \
    -e ONIFY_db.elasticsearch.auth.username=onify_test -e ONIFY_db.elasticsearch.auth.password=test-only-client \
    -e NODE_EXTRA_CA_CERTS=/etc/onify/ca/ca.crt --entrypoint node "$api_image" /check.js
docker run --rm --pull never --platform linux/amd64 --network none --user 101:101 \
    --read-only --cap-drop ALL --security-opt no-new-privileges \
    --tmpfs /etc/nginx/conf.d:uid=101,gid=101,mode=0700 \
    --tmpfs /var/cache/nginx:uid=101,gid=101,mode=0700 --tmpfs /run:uid=101,gid=101,mode=0700 \
    -e ONIFY_API_URL_INTERNAL=http://127.0.0.1:8181 --entrypoint sh "$app_image" -ec '
        /docker-entrypoint.sh nginx -g "daemon off;" >/dev/null 2>&1 & p=$!
        trap "kill $p 2>/dev/null || true" EXIT
        for i in 1 2 3 4 5; do
            if wget -q -O /dev/null http://127.0.0.1:4000/ 2>/dev/null; then
                test "$(id -u)" = 101
                echo "APP UID 101 and HTTP startup with read-only root filesystem passed."
                exit 0
            fi
            sleep 1
        done
        exit 1'
