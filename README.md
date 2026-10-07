# Full-stack Notes App

React + FastAPI + PostgreSQL + Redis, orchestrated with Docker Compose.

## Step 1: configuration and infrastructure

Step 1 defines all four services, environment configuration, networking,
persistent volumes, and dependency health checks. Step 2 adds the database layer,
backend image and versioned migrations. Step 3 adds the FastAPI routes and Redis
activity tracking. Step 4 adds the React frontend and its dependency lockfile.
Step 5 adds automated verification of the real Docker stack, production browser
flow, and volume persistence across container replacement.

### Requirements

- Docker Desktop running with **Linux containers** on Windows.
- Docker Compose v2.24.4 or newer if using `compose.dev.yaml` (`!override`).
- PowerShell for the commands below.

Node, Python, PostgreSQL and Redis do not need local installation to run their
containers. Docker Desktop supplies the engine and Compose command.

### Configure the project

Run from the project directory:

```powershell
# Run once, only if .env does not already exist.
Copy-Item .env.example .env

# Validate without building images or starting containers.
docker compose config --quiet
docker compose -f compose.yaml -f compose.dev.yaml config --quiet
```

`.env.example` is the shareable template. `.env` is local and ignored by Git.
Existing `.env` values take precedence over the template; shell environment
variables can override `.env` values during Compose interpolation.

| Variable | Purpose | Template value |
| --- | --- | --- |
| `POSTGRES_DB` | Database to create | `notes` |
| `POSTGRES_USER` | Local database user | `notes` |
| `POSTGRES_PASSWORD` | Local database password | Local sample password |
| `WEB_PORT` | Browser-facing host port | `8080` |
| `API_PORT` | API/docs host port | `8000` |

Compose rejects missing or empty database settings. The template password is
for local learning; set your own value in `.env`. Changing these initialization
values does not change credentials in an already initialized PostgreSQL volume.

### Start the Step 1 infrastructure

```powershell
docker version
docker compose up -d --wait db redis
docker compose ps
docker compose exec db sh -c 'pg_isready -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
docker compose exec redis redis-cli ping
```

Expected results: `db` and `redis` report healthy, PostgreSQL reports accepting
connections, and Redis returns `PONG`. If Docker reports a missing engine pipe,
open Docker Desktop, wait until the Linux engine is running, and retry.

### Service lineup

| Service | Container port | Host access | Role |
| --- | --- | --- | --- |
| `web` | `80` | `127.0.0.1:8080` by default | Nginx serves React and forwards `/api/` |
| `api` | `8000` | `127.0.0.1:8000` by default | FastAPI application and `/docs` |
| `db` | `5432` | Internal network only | PostgreSQL note storage |
| `redis` | `6379` | Internal network only | Redis write activity |

All services join the `notes` bridge network managed by Compose. Within it,
service names resolve as hostnames: the API connects to `db:5432` and
`redis:6379`. Nginx connects to `api:8000`. The browser uses `localhost` and
relative `/api` requests. `localhost` inside a container refers to that container.

```text
Browser -> localhost:8080 -> web -> api:8000 -> db:5432
                                           -> redis:6379
```

Startup order is `db -> migrate`, then `migrate + db + redis -> api -> web`.
`migrate` is a one-shot job in addition to the four running services. It must exit
successfully before the API starts. Each running dependency must pass its health
check before the next dependent service starts. PostgreSQL is checked over TCP
so its temporary initialization server does not report ready before the database
can accept connections from the API. Health checks are repeated, but
Compose does not automatically restart an unhealthy container or cascade later
dependency failures. `restart: unless-stopped` handles container process exits.

### Persistence

- `postgres_data` mounts at `/var/lib/postgresql/data`.
- `redis_data` mounts at `/data`; Redis append-only persistence is enabled.

Named volumes survive container replacement and ordinary shutdown. They are
local persistent storage; backups require a separate workflow.

```powershell
docker compose logs --tail 100 db redis
docker compose stop db redis
docker compose down
```

`down` removes containers and the Compose network while preserving volumes.
`docker compose down -v` deletes the volumes and their data; use it only for an
intentional reset.

### Run the complete application

Build and start all application services:

```powershell
docker compose up --build -d --wait
```

App: <http://localhost:8080>. API documentation: <http://localhost:8000/docs>.
Use your configured ports if you changed them.

The development override swaps Nginx for Vite on container port `5173`, binds
frontend source, and enables Uvicorn reload for backend source:

```powershell
docker compose -f compose.yaml -f compose.dev.yaml up --build
```

### Docker concepts

1. A **Dockerfile** describes how to build an application image.
2. An **image** packages the runtime, dependencies and application files.
3. A **container** runs an image as an isolated process.
4. **Compose** describes the services, configuration, connections and startup.
5. A **network** lets containers communicate through service names.
6. A **volume** retains data independently of a container's lifecycle.

Compose builds the database migration/API image from `backend/` and the web
image from `frontend/`. PostgreSQL and Redis
use official images with explicit version tags. The application build contexts
include `.dockerignore` files excluding local dependencies and environment
files. Official runtime images now use version tags plus verified manifest
digests; future runtime patches require explicit digest updates. The frontend
dependency lockfile is committed. Backend requirements pin direct dependencies;
transitive dependency resolution is not fully locked.

References: [Compose networking](https://docs.docker.com/compose/how-tos/networking/),
[dependency startup](https://docs.docker.com/compose/how-tos/startup-order/), and
[Compose application model](https://docs.docker.com/compose/intro/compose-application-model/).

## Step 2: PostgreSQL schema and migrations

The initial migration `0001_create_notes` creates:

| Column | PostgreSQL type | Rules |
| --- | --- | --- |
| `id` | `UUID` | Primary key; generated by PostgreSQL |
| `title` | `VARCHAR(200)` | Required; must contain a non-whitespace character |
| `content` | `TEXT` | Required; defaults to empty; maximum 50,000 characters |
| `created_at` | `TIMESTAMPTZ` | Defaults to the insertion transaction time |
| `updated_at` | `TIMESTAMPTZ` | Defaults on insert; trigger refreshes on update |

An index on `(updated_at DESC, id DESC)` supports the notes listing order.
Database constraints protect notes even when written outside the API. Queries in
`backend/app/repository.py` pass values separately using psycopg parameters.
Connections commit on a successful context exit and roll back on exceptions.

### Apply and inspect the schema

```powershell
docker compose up -d --wait db
docker compose build migrate
docker compose run --rm migrate
# Running again is safe: Alembic applies only pending revisions.
docker compose run --rm migrate
docker compose run --rm migrate alembic current
docker compose exec db sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "\d notes"'
```

The migration reads the same PG environment as the API. Credentials are not
stored in `alembic.ini`. Alembic records the applied revision in `alembic_version`.
PostgreSQL applies the migration transactionally, and an advisory lock serializes
concurrent migration runners. Completed migrations should remain unchanged;
add a new revision for each future schema change.

Migration `0002_monotonic_note_versions` subsequently makes `updated_at` strictly
advance on each update for optimistic concurrency checks. It replaces the trigger
function without dropping notes or editing the initial migration.

### Run database integration checks

```powershell
docker compose run --rm migrate python -m unittest discover -s tests -p test_database.py -v
```

Checks cover the migration version, CRUD, UUID/timestamp defaults, timestamp
updates, missing notes, SQL-like text, invalid values, maximum lengths, and
transaction rollback. Each test rolls back its own writes without deleting
existing notes. The checks require the migration to have been applied first.

Implementation validation passed Python syntax checks, dependency compatibility,
offline upgrade/downgrade SQL generation, and both Compose configurations. Live
migration execution and PostgreSQL integration tests also passed during Step 5.

The initial migration expects a fresh schema. If you previously created a notes
table manually or with the local prototype, migration will fail rather than
silently adopt an unknown schema. Back up that data and plan a migration before
proceeding. Do not delete a volume containing notes you need to keep.

Normal startup only upgrades the schema. Downgrading the initial revision drops
the notes table and is an explicit destructive operation. Volume persistence
remains as documented in Step 1.

References: [Alembic migration tutorial](https://alembic.sqlalchemy.org/en/latest/tutorial.html),
[PostgreSQL constraints](https://www.postgresql.org/docs/17/ddl-constraints.html),
and [PostgreSQL triggers](https://www.postgresql.org/docs/17/plpgsql-trigger.html).

## Step 3: FastAPI backend

The API uses the Step 2 repository and schema. It does not create tables on
startup. Compose runs migrations before starting Uvicorn. The backend runs as a
non-root user, and each database operation uses its own transaction/connection.

### Start the API without the frontend

```powershell
docker compose up --build -d --wait api
docker compose ps -a
docker compose logs --tail 100 migrate api
Invoke-RestMethod http://localhost:8000/api/health
```

This starts the database, Redis, migration job and API. A successful migration
job exits with code 0; it is not a continuously running service. Open
<http://localhost:8000/docs> for the interactive API explorer or
<http://localhost:8000/openapi.json> for its schema. Use your configured API port
if it differs from 8000. Full-stack startup is available with Step 4.

### Endpoints

| Method | Path | Result |
| --- | --- | --- |
| GET | `/api/notes` | `200`: notes, newest update first |
| GET | `/api/notes/{id}` | `200`: one note; `404` if missing |
| POST | `/api/notes` | `201`: created note and `Location` header |
| PUT | `/api/notes/{id}` | `200`: replaced title/content; `404` if missing |
| DELETE | `/api/notes/{id}` | `204`: empty body; `404` if missing |
| GET | `/api/stats` | `200`: Redis write count and availability |
| GET | `/api/health` | `200` when notes schema and Redis are reachable; otherwise `503` |

POST and PUT require a string `title` of 1–200 characters, containing a
non-whitespace character. Leading/trailing title whitespace is trimmed.
`content` is a string up to 50,000 characters; omitting it supplies an empty
string. PUT replaces the complete title/content pair, so omitted content clears
the previous body. Nulls and unknown fields are rejected. Invalid input, malformed
JSON and invalid UUIDs receive FastAPI's structured `422` validation response.

Responses contain `id`, `title`, `content`, `created_at` and `updated_at`. UUIDs
are strings in JSON, and timestamps include their timezone. GET-one, POST and
PUT return an `ETag` derived from `updated_at`. The browser sends this value in
`If-Match` on PUT/DELETE; stale versions receive `412` without changing data.
Command-line writes without `If-Match` remain supported but do not prevent
concurrent overwrites. Database connection
errors return `503`; other database failures return a generic `500` without
SQL or credentials in the response. The app is scoped to local single-user use.

### Try the CRUD flow in PowerShell

```powershell
$apiBase = 'http://localhost:8000'
$body = @{ title = 'My first note'; content = 'Built with FastAPI and Docker.' } | ConvertTo-Json
$note = Invoke-RestMethod "$apiBase/api/notes" -Method Post -ContentType 'application/json' -Body $body
Invoke-RestMethod "$apiBase/api/notes/$($note.id)"
Invoke-RestMethod "$apiBase/api/notes"

$editedBody = @{ title = 'Updated note'; content = 'Changes are saved in PostgreSQL.' } | ConvertTo-Json
Invoke-RestMethod "$apiBase/api/notes/$($note.id)" -Method Put -ContentType 'application/json' -Body $editedBody
Invoke-RestMethod "$apiBase/api/notes/$($note.id)" -Method Delete
Invoke-RestMethod "$apiBase/api/stats"
```

### Redis activity behavior

Successful create, update and delete operations increment `notes:write_count`
after the database commit. Reads, validation failures and missing-note operations
do not increment it. If Redis fails, a committed note operation still returns
success; `/api/stats` returns `writes: null` and `redis_available: false`.
The count is best-effort activity telemetry: database commits and Redis writes
are separate operations, so an outage can cause missed counts. Redis append-only
persistence stores the count across normal restarts.

### API checks

The test image adds HTTPX2; it is excluded from the production image. Run the
HTTP contract and failure tests without starting database dependencies:

```powershell
docker compose -f compose.yaml -f compose.test.yaml run --rm --build --no-deps api python -m unittest discover -s tests -p test_api.py -v
```

For a local Python environment, install both requirements files and run from
`backend/`:

```powershell
python -m pip install -r requirements.txt -r requirements-test.txt
python -m unittest discover -s tests -p test_api.py -v
```

For real PostgreSQL/Redis integration, first start the API as above, then run:

```powershell
docker compose -f compose.yaml -f compose.test.yaml run --rm --build --no-deps -e RUN_API_INTEGRATION=1 api python -m unittest discover -s tests -p test_api_integration.py -v
```

The integration test creates and deletes its own note, checks committed data
through a second application instance, and verifies Redis write activity.
It does not reset existing data or counters. It is skipped unless explicitly
enabled. The 13 isolated HTTP tests passed during implementation, along with
Python syntax, dependency compatibility and Compose configuration checks. Live
PostgreSQL/Redis integration and Docker image builds also passed during Step 5.

References: [FastAPI testing](https://fastapi.tiangolo.com/tutorial/testing/) and
[FastAPI error handling](https://fastapi.tiangolo.com/tutorial/handling-errors/).

## Step 4: React notes interface

The responsive notebook interface includes:

- A sidebar with saved notes and case-insensitive title/content search.
- A title field and content editor with the API's length limits.
- Create, edit and delete actions with loading and error states.
- An unsaved-edits indicator and confirmation when switching away from a draft.
- Browser leave/reload protection while there are unsaved edits.
- Delete confirmation and a retry button when the initial notes request fails.
- Draft preservation after failed saves, and optional activity information.
- Protection against stale saves/deletes from another tab, with draft copying
  and confirmed reload recovery.

The frontend uses relative `/api` requests. In Docker, Nginx serves the React
production build and forwards `/api/` to `api:8000`. In development, Vite proxies
those requests to the same backend service. There are no database credentials
in browser code. Fonts fall back to installed system fonts without requiring an
external font service.

### Run the complete stack

From the project root, with `.env` configured and Docker Desktop running:

```powershell
docker compose up --build -d --wait
docker compose ps -a
```

Open <http://localhost:8080>. To edit frontend and backend source with live reload:

```powershell
docker compose -f compose.yaml -f compose.dev.yaml up --build
```

The development browser address is also <http://localhost:8080>; the override
maps the host web port to Vite's container port 5173. Changing package dependencies
requires rebuilding the frontend image; source edits update through bind mounts.

### Run the frontend outside Docker

Requires Node.js 22 and a running API at <http://localhost:8000>.
From `frontend/`:

```powershell
npm ci
npm run dev
```

Open <http://localhost:5173>. If the API runs elsewhere, configure the Vite
server-side proxy target before starting it:

```powershell
$env:VITE_API_PROXY_TARGET = 'http://localhost:8000'
npm run dev
```

This value configures the development proxy; it is not a database credential or
a production browser setting. The production Nginx proxy uses the Compose API
service. A failed initial API request displays an error with a retry action.

### Build and browser checks

```powershell
npm run build
npx playwright install chromium
npm test
```

Alternatively, use an installed Chrome browser without downloading Chromium:

```powershell
$env:PLAYWRIGHT_CHANNEL = 'chrome'
npm test
```

Playwright starts and stops its own Vite server on port 5173. Tests use controlled
API responses and do not require PostgreSQL or Redis. They cover CRUD, search,
reload, discard confirmation, failed-save recovery, failed-load retry, activity
failure, title validation, desktop rendering and mobile overflow. The tests do
not prove real database persistence; use the Step 2/3 integration checks and
the full-stack checklist below for that.

The production build and all 8 browser tests passed during Step 4, with desktop
and mobile screenshots inspected. npm reported no known dependency vulnerabilities
at implementation time. `package-lock.json` is committed and Docker uses `npm ci`.
Rollup is pinned to `4.63.6`: the resolved `4.64.0` version stalled during builds
on this workstation, while the pinned version completed successfully.

### Real Docker browser checks

Step 5 adds a separate browser suite using the production frontend and real API.
It runs without Vite or mocked requests; see the commands below.

Reference: [Playwright API mocking](https://playwright.dev/docs/mock).

## Step 5: automated Docker integration and persistence verification

See [the verification results](docs/step-5-verification.md) for the completed run.

Run from the project root using **PowerShell 7+** (`pwsh`) and Docker Desktop:

```powershell
# All Docker/backend and HTTP persistence checks; no local Python or Node needed.
pwsh -File ./scripts/verify-stack.ps1

# Also test the real browser UI. Requires Node.js 22 and installed Google Chrome.
$env:PLAYWRIGHT_CHANNEL = 'chrome'
pwsh -File ./scripts/verify-stack.ps1 -BrowserTests

# Choose unused ports if the default verification ports are occupied.
pwsh -File ./scripts/verify-stack.ps1 -WebPort 28080 -ApiPort 28000
```

The script creates a uniquely named `notes-check-<random>` Compose project with
its own credentials, network, containers and volumes. It uses ports 18080/18000
by default, checks for conflicts, and overrides ambient database/port values
only for its process. It leaves your regular `notes-app` containers and notes
untouched. Temporary environment values are restored after the run.

The verification covers:

1. Production image builds, startup health checks, migrations and Nginx syntax.
2. API contract/security tests, real PostgreSQL tests, ASGI body-limit/timeout
   tests, and real API/Redis integration inside the backend test image.
3. HTTP requests through Nginx: dependency health, React HTML, missing-asset 404,
   create, update and delete, plus the Redis write count.
4. Removal and recreation of all test containers **without removing volumes**.
   The PostgreSQL container ID must change while the saved note, original creation
   timestamp and Redis count stay intact. Re-running migrations must succeed.
5. With `-BrowserTests`: request-helper tests and real browser tests covering
   create/edit/search/reload/delete, PostgreSQL reads, Redis activity, dependency
   health, JavaScript delivery, production security/cache headers and two-tab
   edit conflict protection.

On success or failure, cleanup removes **only that run's temporary containers,
network and volumes**. Shared base images and build caches remain available.
Failed Docker checks print recent container logs; failed browser checks retain
screenshots and traces under `frontend/test-results/`. A cleanup failure is
reported as an error with the temporary project name. An interrupted/killed
process may require manual cleanup of that project.

You can also run the browser suite against your existing running stack:

```powershell
Set-Location frontend
npm ci
$env:PLAYWRIGHT_CHANNEL = 'chrome'
$env:NOTES_E2E_BASE_URL = 'http://127.0.0.1:8080'
npm run test:live
```

This suite creates and removes only its own uniquely titled note. It increments
the real Redis activity counter. To use Playwright's bundled Chromium instead
of Chrome, install it with `npx playwright install chromium` and unset
`PLAYWRIGHT_CHANNEL`. Existing mocked browser tests remain available with
`npm test`; they are separate from the live suite.

References: [Compose startup and health waits](https://docs.docker.com/reference/cli/docker/compose/up/),
[Compose teardown and volume behavior](https://docs.docker.com/reference/cli/docker/compose/down/),
and [Playwright configuration](https://playwright.dev/docs/test-configuration).

## Phase 6: CI/CD and versioned Docker releases

Pushes, pull requests and manual runs now verify dependencies, frontend/backend
tests, the complete Docker stack and recovery. Successful main runs deliver a
versioned Docker image bundle, tested without source folders or registry pulls.
See [Phase 6 setup and commands](docs/phase-6-ci-cd.md) and
[running a release bundle](docs/release-bundle.md).

## Phase 7: backup and recovery

```powershell
$backup = ./scripts/backup.ps1
./scripts/restore.ps1 -BackupPath $backup.ArchivePath -VerifyOnly
./scripts/verify-recovery.ps1
```

Backups include PostgreSQL notes and a checksum manifest. Restore uses a
separate project; omit `-VerifyOnly` to inspect the recovered app on port 19080.
Redis activity resets in recovered copies. See [the recovery runbook](docs/phase-7-backup-recovery.md).

## Error review and regression checks

See [the security and logic review](docs/security-and-logic-review.md) for the
subsequent request protections, runtime updates and concurrent-edit fixes.

See [the error review](docs/error-review.md) for the cross-layer fixes and
verification limits. Request-helper checks can now be run from `frontend/` with
`npm run test:unit`, alongside the browser tests. HTTP requests have a 15-second
timeout, and successful responses are validated before being rendered.

If a write times out or its connection is interrupted, the server may have
committed it. The interface preserves the draft and asks you to reload notes
before retrying; it does not retry mutations automatically. If a saved note has
been deleted elsewhere, use **Keep draft as a new note** to preserve your edits.

Application PostgreSQL connections now use a 10-second statement timeout and a
5-second lock timeout. Migration connections keep their separate configuration.
API validation rejects null characters in note strings before PostgreSQL sees
them. The backend pins a compatible patched FastAPI/Starlette pair, and API
tests use HTTPX2. Rebuild the backend image to apply dependency changes.
