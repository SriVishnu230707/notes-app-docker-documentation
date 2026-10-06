# Error review — 7 October 2026

Reviewed configuration and Docker build inputs, migrations and database queries,
API contracts and dependencies, client request handling, editor behavior, and
Nginx routing/caching. Existing migration history was preserved.

## Issues corrected

| Layer | Problem and effect | Correction |
| --- | --- | --- |
| Dependencies | The old FastAPI dependency constrained Starlette to a version with known advisories. | Installed and pinned compatible FastAPI 0.136.3 and Starlette 1.3.1; the subsequent backend audit was clean. Advisory presence does not establish exploitability of every affected feature in this JSON-only app. |
| API | Null characters passed input validation but cannot be stored in PostgreSQL text, producing a server error. | Reject null characters in titles/content with a structured 422 response. |
| Database | A long-running statement or lock wait could keep a worker occupied indefinitely. | Added 10-second statement and 5-second lock timeouts to application connections, separately from migration settings. |
| Client | A 200 response containing an object instead of a notes array could crash React. Malformed notes and counters were also accepted. | Check arrays, UUIDs, strings, timestamps and counter types before updating component state. |
| Client | A request that never completed left the editor disabled indefinitely. | Abort requests after 15 seconds, release the busy state, and preserve the draft. Interrupted writes warn that the server may already have saved them. |
| Editor | A note deleted by another client left its draft stuck behind repeated 404 errors. | Keep the draft as a new note without losing its title or content. |
| Editor | After deleting a note, focus was attempted while the title input was disabled. | Defer focus until React has rendered the enabled editor; a browser regression checks focus. |
| Proxy | HTML relied on default cache behavior, and missing asset paths fell back to HTML. | Revalidate HTML, cache hashed assets, and return 404 for missing assets. Add upstream connection/read timeouts. Runtime Nginx validation remains pending. |
| Build inputs | Backend environment-file variants and nested Python bytecode were not explicitly excluded. | Extended `.dockerignore` exclusions. |
| Tests | Patched Starlette deprecated the previous HTTPX test-client dependency. | Switched the test image to pinned HTTPX2; the API suite runs without that deprecation warning. |

## Verification

- 13 isolated API tests, including null-character rejection and commit/Redis failure handling.
- 8 request-helper regressions covering malformed payloads, status preservation,
  proxy errors, timeouts, cancellation, and empty responses.
- 10 browser tests covering CRUD, search/reload, draft protection, failed-save/load
  recovery, malformed response recovery, deleted-note recovery, and mobile layout.
- Frontend production build.
- Backend dependency compatibility and syntax checks.
- Frontend and backend vulnerability audits: no known vulnerabilities reported
  after the dependency update. Audits are snapshots, not guarantees.
- Standard, development and test Compose configuration validation.

The API tests replace database/Redis boundaries. Browser tests use controlled
API responses. They verify application behavior without proving a live
PostgreSQL/Redis round trip.

## Remaining environment limitation

Docker's `desktop-linux` engine pipe is unavailable. Docker Desktop could not
report a running status, and a startup attempt did not make the engine available.
WSL reports version 2 with the `docker-desktop` default distribution; its presence
alone does not establish that the Docker engine is running.

Container image builds, migration execution, real database/API integration,
restart persistence, and Nginx syntax/runtime behavior still need verification
with a working Docker engine. The README contains the commands and full-stack
checklist. No notes or volumes were deleted during this review.

Dependency reference: [Starlette advisory and patched-version guidance](https://github.com/Kludex/starlette/security/advisories/GHSA-82w8-qh3p-5jfq).
