# Phase 8: operational readiness and final handoff

This final phase adds bounded Docker resources, rotated container logs,
concurrent load verification and a day-to-day operations runbook. The project
is complete for local use and reproducible release delivery. Public hosting
still needs authentication, HTTPS and a chosen deployment environment.

The scripts below live in the Git repository and run from its root. Exported
bundles include this runbook as `OPERATIONS.md`; their `README.md` contains the
source-free image startup commands. Use the repository for script-based checks
and backup/recovery automation.

## Resource profile

The base `compose.yaml` applies these limits, including exported release bundles:

| Service | CPU ceiling | Memory ceiling | Process/thread ceiling |
| --- | --- | --- | --- |
| PostgreSQL | 1 CPU | 512 MiB | 256 |
| Redis | 0.5 CPU | 128 MiB | 64 |
| Migration job | 0.5 CPU | 256 MiB | 128 |
| FastAPI | 1 CPU | 256 MiB | 128 |
| React/Nginx | 0.5 CPU | 64 MiB | 128 |

These are ceilings, not reservations. Give Docker Desktop enough memory for
the stack, image builds and other containers. A migration runs briefly; the
four long-running services have a combined configured memory ceiling of 960
MiB. Build processes and load-generation overhead are additional.

Redis has a 64 MiB dataset limit with `noeviction`: if full, writes to the
activity counter may fail rather than silently evicting it. The API continues
to commit PostgreSQL notes and logs Redis write errors. The stats endpoint
reports unavailable activity when it cannot read a valid counter.
The container's larger memory ceiling allows overhead; it does not guarantee
memory safety for arbitrary datasets or persistence rewrites.

All five containers use `json-file` logs with a 10 MB rotation threshold and
three retained files per container. Old rotated logs are removed by Docker.
This bounds local logs approximately; it is not centralized log retention.
Changing limits requires container recreation; ordinary `restart` does not
apply new Compose settings.

## Start and inspect

From the repository root with PowerShell 7:

```powershell
# First setup only; keep an existing .env.
if (-not (Test-Path .env)) { Copy-Item .env.example .env }
docker compose config --quiet
docker compose up -d --build --wait --wait-timeout 120
./scripts/status.ps1
docker compose logs --tail 100 --timestamps api web
docker compose logs --tail 100 --timestamps db redis migrate
docker compose stats --no-stream
```

Open http://localhost:8080. For a custom port, pass it to the status script:
`./scripts/status.ps1 -WebPort 9080`. For an isolated recovered project also
pass `-ProjectName` and `-EnvFile`. Status is read-only, checks every required
container and the completed migration, then reaches dependencies through the
web endpoint. It raises an error when a check fails, so it can be used in a
manual script. It does not schedule monitoring or send notifications.

## Bounded load verification

```powershell
./scripts/verify-load.ps1
# Optional larger check, still limited to a disposable project:
./scripts/verify-load.ps1 -Concurrency 8 -Iterations 50 -MaxP95Ms 2000
```

Default: four concurrent workers, 25 note lifecycles each, 705 HTTP requests
including initial/final checks. Each lifecycle creates, reads, updates,
rejects a stale-version delete, reads again, deletes with the current version
and verifies 404. It compares Redis's count with 300 successful mutations,
requires no synthetic notes to remain and checks dependency health afterward.

The script creates a unique `notes-load-*` Docker project, new credentials and
new volumes, verifies Engine CPU/memory/process/log settings and sends requests
through Nginx to FastAPI/PostgreSQL/Redis. It never points at the regular app.
The generator uses Python already installed in the API container, sets an
explicit localhost Host header for the app's local-host policy and has a
15-second request timeout. No host Python or load-testing package is needed.

Pass conditions: all expected HTTP statuses/data checks succeed and aggregate
p95 request duration stays below the configurable threshold (2,000 ms by
default). Expected 404/412 responses count as successful checks. The report
records request counts, latency, throughput and failures in ignored
`test-results/notes-load-*/report.json`. CI runs this gate and uploads only the
synthetic JSON report for 14 days before permitting release delivery.

This is a small regression workload, not a production capacity promise or an
internet-scale stress test. The generator shares API container resources; host
load, Docker Desktop settings and hardware affect timing. Resource stats are
a snapshot after the workload, not peak memory measurements. Concurrency is
bounded to 1–16 workers and iterations to 1–100 per worker.

Successful cleanup removes only that run's project and volumes. If teardown
fails, the original error remains visible and the generated environment file
is retained for cleanup. Interrupted/killed scripts may leave a temporary
project; inspect `docker compose ls -a` before removing that named project.

## Troubleshooting

| Symptom | Check and action |
| --- | --- |
| Docker engine pipe unavailable | Open Docker Desktop and wait for Linux engine readiness; run `docker version` |
| Port already allocated | Find the listener or choose unused WEB_PORT/API_PORT values; recreate containers |
| PostgreSQL authentication fails after editing .env | Initialization variables do not change existing database credentials; restore the previous .env values |
| Migration exits nonzero | Read `docker compose logs migrate`; fix the migration before allowing API startup |
| API unhealthy | Read API/db/Redis logs and `./scripts/status.ps1`; health checks do not automatically restart unhealthy processes |
| Container exited or restarts | Inspect its OOM state/exit code below; review logs and memory limits before changing them |
| p95 gate fails | Open report.json, rerun at default concurrency on a quiet host, inspect resource stats and logs; do not hide functional failures by raising the threshold |
| Browser receives 403 on writes | Use the configured local web URL; browser Origin and forwarded Host must match |
| Browser receives 412 | Reload saved notes or preserve the draft as a new note; another edit changed its version |
| Disk pressure | Inspect `docker system df`; back up notes before deleting any volumes |

```powershell
$apiId = docker compose ps -a -q api
docker inspect --format '{{json .State}}' $apiId
docker system df
# Stop and keep persistent notes/activity:
docker compose down
# Restart an exited process; this does not apply changed resource settings:
docker compose restart api
```

Do not use `docker compose down --volumes` on your normal project as routine
cleanup: it deletes the notes database and Redis data. `docker system prune
--volumes` is also not routine app maintenance.

## Upgrade and rollback

Before an upgrade:

```powershell
$backup = ./scripts/backup.ps1
./scripts/restore.ps1 -BackupPath $backup.ArchivePath -VerifyOnly
git status --short
git pull --ff-only
docker compose up -d --build --wait --wait-timeout 120
./scripts/status.ps1
```

Keep the previous successful release bundle and backup pair outside the
laptop. GitHub release artifacts expire after 14 days. Follow the bundle's
README when deploying exported images. Keep the same project name/directory
when reusing persistent volumes.

Application rollback may be unsafe after a schema migration. Prefer restoring
the pre-upgrade backup into a separate project and inspecting it. Do not assume
an older image understands a newer schema or run destructive downgrade commands
without reviewing the migration. Phase 7 intentionally opens recovered copies
without overwriting your normal stack.

## Final project lineup

| Phase | Delivered |
| --- | --- |
| 1 | Compose configuration, networking, environment and volumes |
| 2 | Backend image, PostgreSQL layer and versioned migrations |
| 3 | FastAPI CRUD and Redis activity |
| 4 | React frontend and Nginx proxy |
| 5 | End-to-end Docker/browser/persistence verification |
| 6 | GitHub CI and verified Docker release bundles |
| 7 | Checksummed backups and isolated recovery |
| 8 | Resource/log limits, load verification and operations handoff |

References: [Compose service resource settings](https://docs.docker.com/reference/compose-file/services/),
[Docker JSON log rotation](https://docs.docker.com/engine/logging/drivers/json-file/).
