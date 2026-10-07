# Step 5 verification results

Verified on 2026-10-07 using Docker Desktop's Linux engine on Windows,
Docker Engine 28.3.2, Compose 2.38.2, PowerShell 7 and installed Google Chrome.

## Repeat the verification

From the project root:

```powershell
$env:PLAYWRIGHT_CHANNEL = 'chrome'
pwsh -File ./scripts/verify-stack.ps1 -BrowserTests
```

The successful run used a generated `notes-check-...` project on ports
18080/18000. It did not restart or remove the normal `notes-app` project.

| Check | Result |
| --- | --- |
| Build production backend, migration and frontend images | Passed |
| Fresh PostgreSQL migration and subsequent migration on existing volumes | Passed |
| PostgreSQL, Redis, API and web health checks | All healthy |
| Nginx configuration validation | Passed |
| Isolated API contract/failure tests | 13 passed |
| Real PostgreSQL schema, CRUD, constraints and rollback tests | 7 passed |
| API contract using real PostgreSQL and Redis | 1 passed |
| Frontend request-helper regressions | 8 passed |
| Live browser CRUD, reload, search, database read and Redis counter | Passed |
| Live health, hashed JavaScript, cache headers and missing-asset 404 | Passed |
| HTTP CRUD through production Nginx | Passed |
| Note and original timestamp survive complete container replacement | Passed |
| Redis count survives complete container replacement | Passed |
| Removal of temporary containers, network and volumes | Passed |

There were **31 passing automated tests**, plus the script's Docker startup,
proxy, HTTP CRUD and persistence assertions. Live browser tests do not mock the
API. Existing mocked UI tests remain a separate suite; they were not counted in
this run.

The persistence check runs `down` without `--volumes`, creates new containers
over the retained named volumes, asserts a different PostgreSQL container ID,
then checks the saved note and Redis count. Cleanup afterwards uses
`down --volumes` for the generated test project only. Shared base images and
build caches remain on the machine.

This verifies a local single-user Docker deployment. It does not establish
production readiness, backup recovery, multi-user authentication or load capacity.
