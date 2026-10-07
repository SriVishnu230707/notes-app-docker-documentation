# Security and logic fixes

Reviewed and verified on 2026-10-07. The app remains a local, single-user notebook
bound to loopback. This review does not add user accounts or public hosting.

## Issues corrected

| Issue | Change |
| --- | --- |
| Arbitrary Host values reached the local API, weakening protection against DNS rebinding. | Trusted-host checking permits only `localhost`, `127.0.0.1` and the internal `api` name. Other hosts receive 400. |
| Local HTTP clients had no explicit browser-origin or payload-type boundary. | Writes reject a mismatched/null Origin or cross-site Fetch Metadata with 403; JSON writes require `application/json` and reject simple form/text payloads with 415. CLI requests without Origin remain supported. |
| The API's direct published port bypassed Nginx's request-body limit. | ASGI middleware checks declared size and actual streamed bytes, rejecting bodies over 1 MiB with 413. Body reception has a total 15-second deadline and returns 408 on stalled input. |
| API responses and production HTML lacked explicit browser security headers. | API responses use no-store, nosniff, frame denial and no-referrer. Nginx also supplies a strict self-only CSP, including asset and error responses, and suppresses its version token. |
| Two tabs could silently overwrite or delete a newer note. | GET-one/POST/PUT expose a version ETag. The editor sends `If-Match` for PUT/DELETE; PostgreSQL performs the version comparison atomically in the mutation statement. Stale requests return 412 without committing or incrementing Redis. |
| Statement timestamps could fail to reflect the actual order of concurrent/waiting updates. | Additive migration `0002_monotonic_note_versions` uses the greater of wall-clock time and the previous version plus one microsecond. The original migration is unchanged. |
| A conflict needed a usable recovery flow. | Preserve the competing draft, disable further stale writes/deletes, and offer copying as a new note or confirmed reload of saved notes. |
| Duplicate note IDs could produce ambiguous React state; lowercase method options were interpreted incorrectly by the response helper. | Reject duplicate IDs before rendering and normalize HTTP methods before fetch and response validation. |
| API/migration containers retained avoidable write access and capabilities. | Read-only root filesystems, writable temporary storage, dropped capabilities and no-new-privileges. Web also prevents privilege escalation. Development source bind mounts are read-only. |
| Vite's string-form proxy rewrote Host, breaking valid origin checks. | Explicit proxy configuration preserves the original browser-facing Host and port; Nginx does the same. |
| Browser tests could attach to an unrelated existing Vite server. | Always start the test suite's own server and allow an explicit `NOTES_TEST_PORT`. |

Origin checks protect browser access; they are not authentication. Clients on the
local machine can omit or set HTTP headers. `If-Match` is optional for CLI/API
compatibility: writers that omit it still perform unconditional writes. Browser
editor saves and deletes always send it.

## Runtime updates

| Component | Previous version | Verified replacement |
| --- | --- | --- |
| Python | 3.12.11 slim | 3.12.15 slim-bookworm |
| Node build/development runtime | 22.18.0 Alpine | 22.23.3 Alpine |
| Nginx | 1.28.0 Alpine | 1.30.5 Alpine |
| PostgreSQL | 17.6 Alpine | 17.11 Alpine |
| Redis | 7.4.5 Alpine | 7.4.11 Alpine |

Each official runtime image is pinned to its verified multi-platform manifest
digest. PostgreSQL stays on major version 17, and Redis stays on 7.4. Pinning
digests prevents silent tag changes; future security patches require deliberate
updates and testing. Python uses an explicit Debian variant.

Official image metadata: [Python](https://raw.githubusercontent.com/docker-library/official-images/master/library/python),
[Node](https://raw.githubusercontent.com/docker-library/official-images/master/library/node),
[Nginx](https://raw.githubusercontent.com/docker-library/official-images/master/library/nginx),
[PostgreSQL](https://raw.githubusercontent.com/docker-library/official-images/master/library/postgres),
[Redis](https://raw.githubusercontent.com/docker-library/official-images/master/library/redis).
The prior Nginx version fell in ranges listed in [Nginx's security advisories](https://nginx.org/en/security_advisories.html);
individual module applicability depends on configuration.

## Verification

- 20 isolated API contract/security tests.
- 2 ASGI tests for multi-chunk overflow and stalled request bodies.
- 8 real PostgreSQL tests, including stale update/delete protection.
- 1 real API/PostgreSQL/Redis integration test.
- 9 frontend request-helper tests.
- 11 mocked browser regressions, including conflict recovery.
- 3 production browser tests using the real Docker stack, including two tabs
  editing the same note and production security/cache headers.

**54 automated tests passed.** The isolated full-stack script also verified
image builds, startup health, migrations, Nginx syntax, HTTP CRUD and both volumes
surviving container replacement. Development mode was separately checked for
startup, valid same-origin writes and hostile-origin rejection. Both temporary
stacks were removed after checking.

`npm audit` and `pip-audit -r backend/requirements.txt` reported no known
dependency vulnerabilities at review time. These are advisory snapshots and do
not constitute a comprehensive container OS/package scan or penetration test.

Before updating the real running stack, a PostgreSQL custom-format dump was
saved under the Git-ignored `backups/` directory. The runtime/schema update
preserved the complete notes snapshot and Redis activity, and all four running
services became healthy. Backups contain private note data; they are not Git
artifacts. The dump was created and checked for nonzero size; restore recovery
was not exercised during this review.

Repeat the Docker checks:

```powershell
$env:PLAYWRIGHT_CHANNEL = 'chrome'
pwsh -File ./scripts/verify-stack.ps1 -BrowserTests
```

Run mocked browser regressions separately from `frontend/`:

```powershell
$env:PLAYWRIGHT_CHANNEL = 'chrome'
$env:NOTES_TEST_PORT = '15173'
npm test
```

Public deployment would need authentication, TLS, restricted database roles,
backups with restore testing, and resource/load testing as a separate phase.
