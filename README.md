# Full-stack Notes App

React + FastAPI + PostgreSQL + Redis, orchestrated with Docker Compose.

## Step 1: configuration and infrastructure

Step 1 defines all four services, environment configuration, networking,
persistent volumes, and dependency health checks. Step 2 adds the database layer,
backend image and versioned migrations. API routes, frontend source and frontend
dependency lockfiles will be added in subsequent steps. The full stack build
becomes available after those steps; the database can be used independently now.

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

### Later: run the complete application

Once the application dependencies and images have been verified:

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

Compose builds the database migration/API image from `backend/`; the API entry
point will be added in Step 3. The web image will be built from `frontend/` in a
later step. PostgreSQL and Redis
use official images with explicit version tags. The application build contexts
will include `.dockerignore` files excluding local dependencies and environment
files. Image tags are versioned but can be republished; digest pins and dependency
lockfiles are needed for stricter reproducibility.

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

### Run database integration checks

```powershell
docker compose run --rm migrate python -m unittest discover -s tests -v
```

Checks cover the migration version, CRUD, UUID/timestamp defaults, timestamp
updates, missing notes, SQL-like text, invalid values, maximum lengths, and
transaction rollback. Each test rolls back its own writes without deleting
existing notes. The checks require the migration to have been applied first.

Implementation validation passed Python syntax checks, dependency compatibility,
offline upgrade/downgrade SQL generation, and both Compose configurations. Live
migration execution and integration tests are not yet verified: this workstation's
Docker Linux engine was unavailable when Step 2 was implemented. Run the commands
above after Docker Desktop's engine is ready.

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
