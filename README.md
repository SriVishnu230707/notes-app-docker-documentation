# Full-stack Notes App

React + FastAPI + PostgreSQL + Redis, orchestrated with Docker Compose.

## Step 1: configuration and infrastructure

Step 1 defines all four services, environment configuration, networking,
persistent volumes, and dependency health checks. Application source, Dockerfiles
and dependency lockfiles will be added to this repository in subsequent steps.
The full stack build becomes available after those steps; Step 1 can start and
verify PostgreSQL and Redis independently.

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

Startup order is `db + redis -> api -> web`. Each dependency must pass its health
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

Compose is configured to build the API and web images from `backend/` and
`frontend/` once those directories are added in later steps. PostgreSQL and Redis
use official images with explicit version tags. The application build contexts
will include `.dockerignore` files excluding local dependencies and environment
files. Image tags are versioned but can be republished; digest pins and dependency
lockfiles are needed for stricter reproducibility.

References: [Compose networking](https://docs.docker.com/compose/how-tos/networking/),
[dependency startup](https://docs.docker.com/compose/how-tos/startup-order/), and
[Compose application model](https://docs.docker.com/compose/intro/compose-application-model/).
