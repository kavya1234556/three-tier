# Three-Tier App — React · Node.js · MongoDB

A containerized 3-tier application with an Nginx reverse proxy, automated MongoDB backups,
a GitHub Actions CI/CD pipeline that publishes images to Docker Hub, and Prometheus + Grafana monitoring.

> **Note:** The assignment specifies Bitbucket Pipelines; this project uses the equivalent
> **GitHub Actions** workflow (`.github/workflows/ci-cd.yml`) with GitHub secrets/variables.

## Architecture

```
                   ┌──────────────────────────── app-net (docker network) ─────────────────────────────┐
 Browser ──:80──►  │  nginx ──/────► frontend (nginx serving React build)                               │
                   │        └─/api/► backend (Node.js/Express :5000) ──► mongo (MongoDB 7, volume)      │
                   │                     ▲ /metrics                                                     │
                   │  prometheus :9090 ──┘        grafana :3000 ──► prometheus                          │
                   └────────────────────────────────────────────────────────────────────────────────────┘
```

| Path | Purpose |
|---|---|
| `frontend/` | React (Vite) app + multi-stage Dockerfile (Node build → nginx static) |
| `backend/` | Express API, Mongoose, `prom-client` metrics + multi-stage Dockerfile |
| `nginx/nginx.conf` | Reverse proxy: `/api/*` → backend, everything else → frontend |
| `docker-compose.yml` | Application stack: nginx, frontend, backend, MongoDB |
| `docker-compose.monitoring.yml` | Monitoring stack: Prometheus, Grafana |
| `monitoring/` | Prometheus scrape config, alert rules, Grafana provisioning + dashboard |
| `scripts/mongo-backup.sh` / `mongo-restore.sh` | `mongodump` backup with timestamped files / restore |
| `.github/workflows/ci-cd.yml` | CI/CD: build images, push to Docker Hub |

## Prerequisites

- Docker Engine 24+ with the Compose plugin (`docker compose`)
- Free ports: 80 (app), 3000 (Grafana), 9090 (Prometheus) — all configurable in `.env`

## 1. Run the application

```bash
cp .env.example .env        # then edit passwords / Docker Hub username
docker compose up -d --build
docker compose ps           # mongo + backend should report "healthy"
```

- App: http://localhost
- API health: http://localhost/api/health → `{"status":"ok","db":true}`
- API: `GET /api/items`, `POST /api/items` with `{"name": "..."}`

On first start the backend connects using
`mongodb://$MONGO_ROOT_USER:$MONGO_ROOT_PASSWORD@mongo:27017/$MONGO_DB?authSource=admin`
and inserts sample items if the collection is empty. MongoDB data is persisted in the `mongo-data` volume.

Stop: `docker compose down` (add `-v` to also delete the database volume).

### Configuration

All settings come from `.env` (never committed; see `.env.example`):

| Variable | Used by | Description |
|---|---|---|
| `MONGO_ROOT_USER`, `MONGO_ROOT_PASSWORD`, `MONGO_DB` | mongo, backend, backup | DB credentials and database name |
| `NGINX_PORT` | nginx | Host port for the app (default 80) |
| `DOCKERHUB_USER`, `TAG` | compose | Image names, e.g. `user/three-tier-backend:latest` |
| `GRAFANA_ADMIN_USER`, `GRAFANA_ADMIN_PASSWORD` | grafana | Grafana login |
| `GRAFANA_PORT`, `PROMETHEUS_PORT`, `PROMETHEUS_RETENTION` | monitoring | Ports and metric retention |
| `BACKUP_DIR`, `RETENTION_DAYS` | backup script | Backup location and how long to keep them |

## 2. Nginx reverse proxy

`nginx/nginx.conf` is mounted into the `nginx` container. It is the only service publishing a host port:

- `/api/` → `backend:5000`
- `/` → `frontend:80` (which itself serves the SPA with `try_files … /index.html` fallback)
- Forwards `Host`, `X-Real-IP`, `X-Forwarded-For`, `X-Forwarded-Proto` headers

The backend's `/metrics` endpoint is **not** exposed through nginx; only Prometheus reaches it over the internal network.

## 3. MongoDB backup & restore

```bash
./scripts/mongo-backup.sh
# [2026-09-27 15:46:00] Starting backup of 'appdb' -> backups/appdb_2026-09-27_15-46-00.archive.gz
# [2026-09-27 15:46:00] Backup complete (4.0K)
```

The script:
- runs `mongodump` inside the running `mongo` container (credentials are read from the container's env, not passed on the host command line)
- writes a gzipped archive named `<db>_<YYYY-MM-DD_HH-MM-SS>.archive.gz`
- writes to a `.partial` file first and only renames on success, so a failed run never leaves a corrupt backup
- fails fast (`set -euo pipefail`) if the container isn't running or the dump is empty
- deletes backups older than `RETENTION_DAYS`

Schedule it daily at 02:00 with cron (`crontab -e`):

```cron
0 2 * * * cd /path/to/three-tier && ./scripts/mongo-backup.sh >> backups/backup.log 2>&1
```

Restore (drops and replaces existing collections):

```bash
./scripts/mongo-restore.sh backups/appdb_2026-09-27_15-46-00.archive.gz
```

## 4. CI/CD — GitHub Actions → Docker Hub

`.github/workflows/ci-cd.yml` runs on every push and pull request to `main`:

1. Builds the `frontend` and `backend` images in parallel (matrix job) with Docker Buildx.
2. Uses the GitHub Actions layer cache (`cache-from/to: type=gha`) so unchanged layers aren't rebuilt.
3. On **push to `main`** only: logs in to Docker Hub and pushes
   `<user>/three-tier-<service>:latest` and `<user>/three-tier-<service>:<git-sha>`.
   Pull requests only build (validate) and never push.

### Setting up credentials

1. Docker Hub → Account settings → **Personal access tokens** → create a token with *Read & Write* scope.
2. GitHub repo → **Settings → Secrets and variables → Actions**:
   - **Variables** tab: `DOCKERHUB_USERNAME` = your Docker Hub username
   - **Secrets** tab: `DOCKERHUB_TOKEN` = the access token

The token is only referenced as `${{ secrets.DOCKERHUB_TOKEN }}`; GitHub masks it in logs and it is never committed.

### Deploying the published images

On any server with Docker:

```bash
cp .env.example .env   # set DOCKERHUB_USER and TAG (latest or a commit sha)
docker compose pull
docker compose up -d
```

### Image build practices

- Multi-stage builds: dependencies/build tooling stay out of the runtime image
- Small `alpine` base images, pinned major versions
- `package*.json` copied before source so the `npm ci` layer is cached
- Backend: `npm ci --omit=dev`, `NODE_ENV=production`, runs as non-root `node` user, `HEALTHCHECK`
- `.dockerignore` excludes `node_modules`, `.env`, `.git`

## 5. Monitoring — Prometheus & Grafana

The monitoring stack is a separate compose file that joins the app's `app-net` network,
so **start the app first**:

```bash
docker compose up -d
docker compose -f docker-compose.monitoring.yml up -d
```

- Prometheus: http://localhost:9090 → *Status → Targets* shows `backend` as **UP**; *Alerts* lists the rules
- Grafana: http://localhost:3000 (login from `.env`) → *Dashboards → Three-Tier App → Three-Tier Backend*

The Prometheus datasource and dashboard are provisioned automatically — no manual setup.
(On first boot Grafana runs DB migrations, which can take a minute.)

### Metrics exposed by the backend (`/metrics`)

| Metric | Type | Description |
|---|---|---|
| `http_requests_total{method,route,status}` | counter | Request count |
| `http_request_duration_seconds{method,route,status}` | histogram | Request latency |
| `items_created_total` | counter | Custom: items created via the API |
| `items_stored` | gauge | Custom: documents currently in the `items` collection |
| `mongodb_connection_up` | gauge | Custom: 1 if the backend is connected to MongoDB |
| `process_resident_memory_bytes`, `nodejs_heap_*`, `process_cpu_seconds_total`, `nodejs_eventloop_lag_*`, … | default | Node.js process metrics from `collectDefaultMetrics` |

Check it directly: `docker compose exec backend wget -qO- localhost:5000/metrics`

### Dashboard panels

Backend up · MongoDB connected · items stored · request rate · 5xx error rate · uptime ·
requests/s by route · responses by status code · latency p50/p95/p99 · items created/min ·
memory (RSS, heap) · CPU · event loop lag · active handles.

### Alert rules (`monitoring/prometheus/alert.rules.yml`)

| Alert | Condition |
|---|---|
| `BackendDown` | scrape target down > 1m |
| `MongoDBDisconnected` | `mongodb_connection_up == 0` > 1m |
| `HighErrorRate` | 5xx ratio > 5% for 5m |
| `HighLatencyP95` | p95 latency > 1s for 5m |
| `HighMemoryUsage` | RSS > 300MB for 5m |
| `EventLoopLag` | event loop p99 lag > 500ms for 5m |

Generate some traffic to see the graphs move:

```bash
for i in $(seq 1 50); do curl -s localhost/api/items >/dev/null; done
curl -s -X POST localhost/api/items -H 'Content-Type: application/json' -d '{"name":"hello"}'
```

Stop: `docker compose -f docker-compose.monitoring.yml down`

## Troubleshooting

- **`network app-net declared as external, but could not be found`** — start the app stack (`docker compose up -d`) before the monitoring stack.
- **Backend exits with `MongoDB connection failed`** — check `MONGO_*` values in `.env`. Mongo only applies root credentials on first init; if you changed them, recreate the volume with `docker compose down -v`.
- **Logs:** `docker compose logs -f backend`
