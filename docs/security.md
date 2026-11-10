# Optional Kubernetes security

**These additions are optional and apply to Kubernetes installations only.**
Neither the standard installation nor `prepare-installation.sh` enables them.
Choose the Elasticsearch HTTPS/authentication patch, the non-root patch, or both,
and explicitly add the chosen patches to the installation's Kustomize overlay
after completing their prerequisites. Docker Compose is unchanged.

The default installation encrypts public Ingress traffic only. Its internal
HTTP traffic and Elasticsearch are unauthenticated at the database layer.
NetworkPolicy limits reachability; it does not encrypt traffic or authenticate
database users.

The opt-in examples below implement Elasticsearch HTTPS and username/password
wiring, and non-root API, worker and app containers. They do not enable TLS for
the remaining services, provision a service mesh, create Elasticsearch users,
or change an existing installation automatically. TLS for all container traffic
is a separate Kubernetes design choice described below, not an enabled feature.

## Internal traffic and TLS choices

| Connection | Current transport | Required change |
|---|---|---|
| Ingress → app:4000 / API:8181 | HTTP after public TLS termination | Include the Ingress controller in mTLS, or configure verified HTTPS to native TLS listeners. |
| app → API:8181 | Nginx HTTP proxy | Mesh mTLS, or API TLS plus Nginx CA trust, SNI and `proxy_ssl_verify on`. Changing the URL alone does not enable certificate verification. |
| API / worker → Elasticsearch:9200 | HTTP, security disabled | The Elasticsearch patch below enables authenticated HTTPS with CA validation. |
| API / worker workflows → Gateway:8686 | HTTP where configured in customer resources | Mesh mTLS, or Gateway TLS and HTTPS URLs/trust in the calling workflows. |
| Gateway → API | Optional configuration/resource sync and logging | Include these connections when enabled; JWT validation alone does not make an API network call. |
| Elasticsearch nodes:9300 | Single-node, no inter-node traffic | A future multi-node deployment needs native transport TLS and a separate cluster design. |

External integrations and image registry connections need their own transport
review; an internal mesh does not
automatically secure traffic beyond its boundary.

**If the customer's Kubernetes platform already operates a service mesh**, use
its supported mTLS and workload authorization policies for all five workloads
and the Ingress controller. Require strict mTLS, deny plaintext bypass, and test
both Service and direct Pod access. For example, Istio's
[PeerAuthentication](https://istio.io/latest/docs/reference/config/security/peer_authentication/)
supports `STRICT`; its default permissive mode is insufficient. Assign distinct
workload service accounts for authorization instead of sharing the default
identity. Keep `automountServiceAccountToken: false` for application credentials;
mesh identity/token handling is a separate platform responsibility.

Mesh encryption protects traffic between mesh proxies. The local hop to
the application may remain HTTP. If the customer's requirement is TLS terminated
by each application process, choose native TLS instead and document that boundary.

**Without an existing mesh**, native TLS avoids introducing a new cluster-wide
platform solely for this installation. It requires changes to the API's Hapi
listener (`hub-api-2/src/manifest.js`), Gateway startup (`gateway/src/server.ts`),
app-root Nginx listener/proxy and Ingress upstream configuration. Those changes
belong in their image repositories; the current images do not expose a complete
server-TLS configuration contract. Use the customer's internal CA and cert-manager
or existing certificate automation for DNS SANs, distribution, renewal and reload.
Public Ingress certificates do not automatically cover Kubernetes service names.
Nginx requires explicit [upstream certificate verification](https://nginx.org/en/docs/http/ngx_http_proxy_module.html#proxy_ssl_verify).

The platform owner must select the TLS boundary and certificate owner before
rolling out the remaining links. No mesh-specific policy is applied by this repo.

## Elasticsearch HTTPS and credentials

Use [elasticsearch-patch.yaml](../examples/security/elasticsearch-patch.yaml) with
Elasticsearch 9.5.6 and compatible API/worker images. The API client already
supports Basic authentication. In the tested image, `exp-config` does **not** map
new underscore-separated auth fields absent from `production.json`; the patch
therefore uses the supported dotted environment names:

```text
ONIFY_db.elasticsearch.auth.username
ONIFY_db.elasticsearch.auth.password
```

Keep the password in a Kubernetes Secret, never in the connection URL, ConfigMap
or app container. API and worker receive only the application account. The
Elasticsearch bootstrap Secret is separate and never mounted into those clients.
The public CA is a ConfigMap; the server's private key is mounted only into
Elasticsearch. `NODE_EXTRA_CA_CERTS` loads the PEM CA at Node startup and retains
certificate/hostname verification; it also trusts this CA for other Node TLS
clients. Use a dedicated internal CA where possible. See
[Node's CA configuration](https://nodejs.org/download/release/v24.20.0/docs/api/cli.html#node_extra_ca_certsfile).

### Prepare an installation revision

Copy the patch into the prepared installation directory:

```bash
cp examples/security/elasticsearch-patch.yaml deployments/acme-test/
```

Place these files there using the existing secret store and PKI. Restrict the
directory to the operator and files to mode `600`; do not commit the private key
or password files. Add `elasticsearch-*.env`, `tls.key` and any private issuance
material to the installation's `.gitignore` before creating them.

| File | Contents |
|---|---|
| `ca.crt` | Trusted root/intermediate CA PEM bundle, without private keys. |
| `tls.crt` | Server certificate plus intermediate chain, PEM. DNS SAN must contain `onify-elasticsearch`; include any additional DNS name actually used by clients. |
| `tls.key` | Matching unencrypted PEM private key, supplied as a restricted Kubernetes Secret. |
| `elasticsearch-bootstrap.env` | `password=<bootstrap password for elastic>` on one literal line. |
| `elasticsearch-client.env` | `username=<existing application user>` and `password=<its password>` on separate literal lines. |

The application user must exist in Elasticsearch before API/worker start. These
files configure clients; they do not create a database user. The built-in `elastic`
account is for initial administration, not the application's ongoing identity.
Keep its bootstrap password separate from the application password.

Append to the existing lists in `kustomization.yaml`, retaining existing entries:

```yaml
patches:
  - path: elasticsearch-patch.yaml
configMapGenerator:
  - name: onify-elasticsearch-ca
    files: [ca.crt]
secretGenerator:
  - name: onify-elasticsearch-tls
    type: kubernetes.io/tls
    files: [tls.crt, tls.key]
  - name: onify-elasticsearch-bootstrap
    envs: [elasticsearch-bootstrap.env]
  - name: onify-elasticsearch-client
    envs: [elasticsearch-client.env]
```

Set `ONIFY_db_elasticsearch_host=https://onify-elasticsearch:9200` in `config.env`
as well, to keep the human-readable configuration consistent with the patch's
explicit override. Keep generated name hashes: certificate/CA/credential changes
then update workload references and cause the relevant restarts.

This example retains `discovery.type=single-node`. Multi-node Elasticsearch also
requires [native transport TLS](https://www.elastic.co/docs/deploy-manage/security/set-up-basic-security);
mesh encryption alone does not satisfy Elasticsearch's transport TLS checks.

### Roll out and provision the account

The installation operator owns this rollout; it is not triggered by code review.
For an existing installation, verify a snapshot first and schedule downtime for
the single Elasticsearch node. Preserve the PVC, index prefix and application
secrets. Record current replica counts and preserve any existing resource volumes.

1. Prepare a maintenance revision that sets API, worker, app and Gateway replicas
   to zero in the overlay, leaving Elasticsearch at one. Run
   `bash tests/check.sh deployments/acme-test`, review the private diff and use
   the [server dry run and apply procedure](operations.md#apply-changes).
   A command-line scale alone is insufficient: applying an overlay with
   `replicas: 1` would start the clients again.
2. Wait for `statefulset/onify-elasticsearch` to finish rolling out. Create the
   application role/user through the Elasticsearch security API over HTTPS using
   a dedicated administrative account. For first bootstrap only, use `elastic`
   and the bootstrap password. Keep passwords out of shell history and logs.
   The mounted CA path inside Elasticsearch is
   `/usr/share/elasticsearch/config/ca/ca.crt`; connect using
   `https://onify-elasticsearch:9200`, matching the certificate SAN.
3. Store the created account in `elasticsearch-client.env`, validate again and
   restore the recorded replica counts in the final revision. Apply it and
   verify login, file upload/download, Git-resource sync, indexing, a worker job
   and logs. Require a valid HTTPS request to succeed, and missing/wrong passwords,
   an untrusted CA and the wrong hostname to fail. TCP readiness alone cannot
   prove authentication or TLS trust.

The runtime proof below uses a separate account with `monitor` on the cluster and
`all` on `onify-*` indices for health and document CRUD. **That is not a verified
complete production role.** Installation/upgrades/reindexing also call cluster
settings APIs, so the release owner must verify maintenance privileges separately
and review any additional privileges before customer use. Do not solve missing
permissions by permanently giving the application `superuser`. User provisioning
is covered by Elastic's [native realm guidance](https://www.elastic.co/docs/deploy-manage/users-roles/cluster-or-deployment-auth/native).

`ELASTIC_PASSWORD` is a bootstrap mechanism, not ongoing password rotation. On an
existing secured cluster, use its current administrative credentials; changing
that environment variable does not reset an already established password. Rotate
the application user in Elasticsearch and update its Secret in a coordinated
maintenance change, or provision a replacement user before switching clients.
See [built-in users](https://www.elastic.co/docs/deploy-manage/users-roles/cluster-or-deployment-auth/built-in-users).

Update backup, monitoring and maintenance clients to HTTPS with CA validation and
appropriate separate credentials. The plain-HTTP curl examples in
[Backups](backups.md) apply only to the default installation. Preserve users/roles
through the secret store and a tested security-feature-state recovery procedure;
the default application snapshot excludes feature states.

For certificate renewal, replace the generated files through the PKI process and
reapply; Node must restart to load changed CA trust. For a CA rollover, distribute
an old+new trust bundle first, roll clients, rotate the server certificate, then
remove the old CA after verification. Roll back to the previous **secured**
revision/credentials where possible; never delete the PVC or silently turn off
security to recover from a failed rollout.

## Non-root API, worker and app-root

Yes: the examined images can run with explicit non-root UIDs. The API and worker
use the same image and must use the same UID. `app-root` means the app is served
at URL `/`; it is built from `citizen-app`. The name is not a requirement to run
as Linux root.

| Workload | UID:GID | Writable paths with this installation's configuration |
|---|---|---|
| API | `1000:1000` (`node`) | `/usr/share/onify/resources`, `/usr/share/onify/temp_resources`, `/tmp`. |
| Worker | `1000:1000` (`node`) | Same paths, owned by the worker's storage. |
| app-root | `101:101` (`nginx`) | `/etc/nginx/conf.d` for startup template output, `/var/cache/nginx` for request/proxy temporary files, `/run` for `nginx.pid`. |

These are configuration-specific paths, not a promise for every historical tag.
API image defaults use `/usr/app/data/resources` and `/usr/app/data/temp` if the
installation does not override them. File logging additionally needs
`/usr/app/logs`; this template uses `stdout,elastic` and does not need that mount.
Custom BPMN/scripts, plugins and Git/SSH configuration may require additional
explicit paths. App assets `/etc/nginx/html` and templates can remain read-only;
ports 8181 and 4000 require no privileged bind capability.

For a **new empty installation**, copy
[non-root-patch.yaml](../examples/security/non-root-patch.yaml) into the installation
and append `- path: non-root-patch.yaml` to its existing `patches` list. The patch
sets explicit UIDs/GIDs, `fsGroup`, `runAsNonRoot`, a read-only root filesystem,
`allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]` and `RuntimeDefault`
seccomp. Kubernetes supplies writable volumes without a root init container;
see [security contexts](https://kubernetes.io/docs/tasks/configure-pod-container/security-context/).

The sample resource volumes are **emptyDir**: their contents disappear when the
Pod is replaced. Before applying to an existing installation, copy/preserve any
files currently in the container and replace these volumes with the appropriate
PVCs if uploads or resources must survive. Do not mask existing files with an
empty mount. Preserve existing API/worker sharing and locking semantics; do not
invent a shared resource PVC merely to resolve permissions. Check that the storage
driver honors the required group access. The app's empty config directory is
regenerated from its image template; retain any custom Nginx includes explicitly.

To **deliver images that declare non-root by default**, the image maintainers
still need to publish new releases:

- Hub API Dockerfile: create/chown the required default writable directories at
  build time, retain application code as read-only, then set `USER 1000:1000` in
  the final stage. Worker inherits it. Kubernetes volume permissions still need
  the security context.
- APP `Dockerfile.root-proxy`: ensure template output, cache and PID paths are
  writable for `101:101`, or use an approved unprivileged Nginx base with a
  deliberately pinned UID and adjusted paths; set a numeric `USER` in the final
  stage. Remove the unnecessary master `user` directive when adapting Nginx.
- Verify default startup without a `--user` override and inspect `.Config.User`
  for each published image digest. Manifest overrides do not change image
  metadata and therefore do not resolve an image scanner's missing-`USER` finding.

No image release was built or published by these infrastructure changes.

## Verification and boundaries

Offline wiring and rejection checks:

```bash
bash tests/check.sh
bash tests/prepare-installation.sh
bash tests/compose.sh
bash tests/security.sh
```

The disposable runtime test requires a local Docker engine, OpenSSL and already
downloaded images. It creates an isolated internal network, an empty temporary
Elasticsearch 9.5.6, test certificates and test users, then removes them. It does
not read `.env`, use a license, publish host ports or mount customer data:

```bash
bash tests/security-runtime.sh \
  eu.gcr.io/onify-images/hub/api:dev \
  eu.gcr.io/onify-images/citizen/app-root:dev
```

The local proof was run against API digest
`sha256:00b1dd16c01dfa0669e4d9f0daa38b3f5abd3adc78a2e9aa886304f5ec491f06`
and app-root digest
`sha256:478afd0f9c770121b141b2f528b5e64c7f13710b84a1182846997d0d405d2ee2`.
Tags are mutable; repeat with the approved release images before delivery.
The proof covers the real API configuration/database client, non-root file writes,
authenticated HTTPS document CRUD, negative auth/trust/hostname cases, and app
HTTP startup as UID 101. It does not start a licensed API/worker service, exercise
customer workflows, test Kubernetes admission/storage/network policy, or prove
all-container TLS. Those checks remain with the release and installation owners.
