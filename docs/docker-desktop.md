# Quick start with Docker Desktop

Run an empty Onify Citizen environment for testing on your development computer
with one [Compose file](../compose.yaml):
API, APP, worker, Gateway and Elasticsearch. Fill in [.env](../.env.example) and
authenticate with Onify's `keyfile.json`. This runs published images without
building source code or providing hot reload.
Elasticsearch is pinned to **9.5.6**, matching Kubernetes. If an existing Docker
volume contains 7.x data, follow the [upgrade precautions](operations.md#elasticsearch-upgrades)
before starting this version.

Already configured? Go to [Start again, update or stop](#start-again-update-or-stop).

## 1. Prepare

- Start Docker Desktop using Linux containers. Allow roughly 6 GiB of memory and
  10 GiB of free disk for this starting environment; actual usage depends on the images and data.
- Obtain approved API, APP **app-root**, and Gateway version tags,
  Onify's supplied `keyfile.json` and a development license matching
  your client and instance codes.
  The API/worker image must support Elasticsearch 9.5.
  These private images and the license are not included in the repository.
- Open a terminal in this repository's root. Use Docker Compose 2.23.1 or newer
  (included in current Docker Desktop) for the inline Nginx configuration.
  Onify services use `linux/amd64`, including emulation on Apple Silicon.

For a new installation, copy `.env.example` to `.env`, then open `.env` in a text
editor. Keep an existing `.env` when restarting or updating:

```bash
cp .env.example .env
```

In Windows PowerShell, use `Copy-Item .env.example .env`.

Fill in the three image tags, client and instance codes, license and three different
secrets (admin password, APP-token secret and client secret). Both codes must match
the license; use lowercase letters, digits and hyphens. The initial username is `admin`.
For each secret, use a password manager or run `openssl rand -hex 32` separately.
On macOS/Linux, restrict the completed file with `chmod 600 .env`.
Leave the `K8S_*` section alone for Docker; it is only used when preparing Kubernetes.

Keep single quotes around license/secret values, especially values containing
`$`, `#` or spaces. Escape a literal apostrophe as `\'`. Compose's
[environment-file syntax](https://docs.docker.com/compose/how-tos/environment-variables/variable-interpolation/#env-file-syntax)
is also used by Kubernetes preparation, which generates its own literal env files.
`.env` is ignored by Git; transfer it only through your secure file transfer or
secret store. Shell variables override matching `.env` values.

### Authenticate to GCR with keyfile.json

Place the Google service-account JSON file supplied by Onify at `keyfile.json` beside
`compose.yaml` and `.env`. Use the original JSON containing `type: service_account`,
`client_email` and `private_key`; no base64 conversion is needed. The service account
needs read access to the repositories containing the three Onify images.

On macOS/Linux, run:

```bash
chmod 600 keyfile.json
docker login --username _json_key --password-stdin https://eu.gcr.io < keyfile.json
```

On Windows PowerShell, run:

```powershell
Get-Content -Raw .\keyfile.json | docker login --username _json_key --password-stdin https://eu.gcr.io
```

Wait for `Login Succeeded`, then continue with the start commands below. Docker
Compose automatically uses this registry login when pulling the images. Docker
Desktop saves the login in its configured credential store, so repeat this step
when changing customer credentials or after logging out. Google Cloud CLI is not
needed for this [service-account key login](https://docs.cloud.google.com/artifact-registry/docs/docker/authentication#json-key).

`keyfile.json` is ignored by Git and used only by Docker on the host. Keep it
private; do not substitute Kubernetes' generated `registryCredentials.json`.
If you change an image registry, log in to that hostname too.

## 2. Start

```bash
docker compose config --quiet
docker compose up -d --wait --wait-timeout 300
docker compose ps
```

Every service has [`pull_policy: always`](https://docs.docker.com/reference/compose-file/services/#pull_policy), so `up` fetches the current image for
each configured tag. Registry access and a valid Docker login are required.

Compose rejects missing required values before starting. `config --quiet` avoids
printing the rendered secrets. Elasticsearch starts first; API waits for its
cluster health, and APP, worker and Gateway wait for the API's listening port.
This uses Compose's [health-based startup order](https://docs.docker.com/compose/how-tos/startup-order/).
The API initializes its system data and admin account on the first start.

Open **[http://localhost/](http://localhost/)** and sign in with the
username/password from `.env`. Confirm the APP loads and login succeeds.
The stack appears as `onify-<client>_<instance>` in Docker Desktop, for example
`onify-acme_test`. `--wait` checks
Elasticsearch/API/APP health and that the other containers are running; it does not
verify login or worker jobs. `docker compose ps` should list all five services
as running, with Elasticsearch, API and APP marked healthy.

| Component | Address |
|---|---|
| APP | `http://localhost/` |
| API | `http://localhost/api/v2/` through the APP proxy |
| Login | `http://localhost/login` |
| Gateway | `http://onify-gateway:8686` inside the Compose network |
| Elasticsearch | `http://onify-elasticsearch:9200` inside the Compose network |
| Worker | Background process using the API image |

Only APP publishes a port, bound to this computer's loopback interface.
Its existing Nginx serves the SPA and proxies `/api/v2/` and `/login`
to API at `http://onify-api:8181`. Browser requests and login
cookies use one origin; API has no separate host port. The inline Nginx config
keeps legacy `/helix/...` redirects relative so they preserve the public host
and port, including a custom `APP_PORT`.

Gateway validates API user JWTs using the same client code and secret as API.
All three standard integrations are explicitly disabled; enable only those you
configure in [Gateway configuration](configuration.md#gateway-integrations).
Import the Citizen workspace/customer content separately for your tests.
For Compose, add additional settings explicitly under the relevant service's
`environment`; adding a name to `.env` alone does not pass it to a container.
API and worker share the API environment block; Gateway has its own.

No agent server is included; API and worker disable the outbound connection with
an empty `ONIFY_websockets_agent_url`.

## Local login

Use the **app-root** image, built to serve the SPA at `/` and call `/api/v2` and
`/login`. Compose sets its runtime upstream with
`ONIFY_API_URL_INTERNAL=http://onify-api:8181`. Adding SPA build variables to
Compose does not rebuild the image.

Use an API image with root-path defaults: `internal_login_page=/login/internal`,
`error_url=/error` and `logout_url=/logout`. Compose uses the image's own defaults.
Explicit values saved by an administrator are preserved; if those still use
`/helix`, update the affected settings through API administration.

The empty installation uses the initial admin username/password from `.env`.
Open `/login` and sign in with those credentials. Use the same hostname throughout: `localhost` and
`127.0.0.1` have separate browser cookies.

## Start again, update or stop

Start Docker Desktop, open a terminal in the directory containing your existing
`compose.yaml` and `.env`, and run:

```bash
docker compose up -d --wait --wait-timeout 300
```

This is also the update command when a new `dev` image is published or you change
an image tag in `.env`. Compose pulls the configured images and
[recreates containers whose image or configuration changed](https://docs.docker.com/reference/cli/docker/compose/up/).
It keeps the selected tags, including the pinned Elasticsearch version.
`docker compose restart` and Docker Desktop's start button only restart existing
containers. There is no need to run `down` before updating.

To stop the installation and remove its containers and network:

```bash
docker compose down
```

### Persistent data

Elasticsearch data remains in a named Docker volume across these commands.
The volume is `onify-<client>_<instance>_elasticsearch-data`, mounted only by
Elasticsearch at `/usr/share/elasticsearch/data`. Docker creates it on the first
start and reuses it when containers are recreated. Different client/instance pairs
get separate volumes and networks through [Compose project scoping](https://docs.docker.com/compose/how-tos/project-name/).
This is persistent storage inside Docker Desktop, not a backup.

Do not change client/instance codes to restart an installation: that selects a
different project and volume, leaving the previous data in its original volume.
If you already started the earlier example named `onify-citizen-local`, add
`COMPOSE_PROJECT_NAME=onify-citizen-local` to its `.env` to keep using its existing
containers and data. No data is moved automatically.

Keep `.env` stable when reusing that volume: changing the initial admin password
or license is not a supported way to update an initialized installation.
Local resource/temp directories inside API and worker are disposable, as in the
Kubernetes base; this example only persists Elasticsearch. Add appropriate shared
storage before using workflows that depend on local files.

**To deliberately erase this local installation**, run `docker compose down --volumes`.
This deletes its Elasticsearch data, including users and configuration; the next
start creates an empty installation again. A Docker Desktop factory reset or
manual volume deletion also removes the data.

## Multiple local installations

Keep each installation's `compose.yaml` and `.env` in its own directory. Different
client/instance pairs automatically use different projects. Set an unused `APP_PORT`
in the second `.env`, for example `4001`, then
open `http://localhost:4001`. Internal service addresses stay the same.

For two independent copies with the **same** licensed client/instance codes, set
a different `COMPOSE_PROJECT_NAME` in each `.env`, for example `onify-acme-test-a`
and `onify-acme-test-b`. Copying the directory alone does not isolate identical
project names. Keep the project name stable and avoid shell overrides or `-p`
unless you intentionally want to select a different installation.

## Continue with Kubernetes

Reuse `.env` and `keyfile.json` with [Getting started](../README.md#getting-started).
Set real `K8S_APP_HOST`/`K8S_API_HOST` names before preparation for a live cluster.
Kubernetes starts with a separate empty database: Docker data, users and application
configuration are not copied. Use production credentials and approved images/license
for production.

## Troubleshooting

```bash
docker compose ps --all
docker compose logs --tail=100 onify-elasticsearch onify-api onify-app onify-worker onify-gateway
```

- **Cannot connect to the Docker daemon:** start Docker Desktop and wait for its
  engine to be running, then rerun the start command.
- **Image pull denied or tag missing:** repeat the JSON-key login, check that the
  service account has read access to the Onify repositories, and verify the three tags.
- **Browser shows `ERR_CONNECTION_REFUSED`:** check that APP is running and use
  `http://localhost/` for `APP_PORT=80`, or `http://localhost:<APP_PORT>` otherwise.
  Port 8181 is internal; open the APP address to reach both the UI and API.
- **Port already allocated:** stop the conflicting local service, or change
  `APP_PORT` in `.env`, for example `APP_PORT=4001`.
- **Startup times out:** inspect the logs for license/configuration errors or
  memory pressure. After correcting the problem, rerun the start command.
  See [Elastic's Docker guidance](https://www.elastic.co/docs/deploy-manage/deploy/self-managed/install-elasticsearch-docker-prod)
  for Elasticsearch host requirements if its logs report a bootstrap failure.
- **APP opens but login fails:** verify the credentials used on the first start,
  license/client/instance agreement and compatibility of the selected API/APP tags.
- **Login still redirects to `/helix/...`:** rerun the update command to fetch
  the current image for your API tag. Check saved `internal_login_page`,
  `error_url` and `logout_url` settings as described in [Local login](#local-login);
  explicit stored values override the image defaults.
- **`Failed to initialize agent OVERRIDE_IN_ENV socket`:** use this Compose file's
  empty `ONIFY_websockets_agent_url` in the shared API/worker environment and rerun
  `docker compose up -d --wait --wait-timeout 300`. No agent socket is required.
- **Login works but `workspace "citizen" not found` appears:** the empty database
  lacks the Citizen workspace/configuration. Import the intended application
  configuration separately; Compose initializes API system data and the admin account.

This local HTTP example has one Elasticsearch node and no TLS or backup setup.
