# Phase 6 and 7 verification

Local verification on 2026-10-07 with Docker Desktop Linux containers and
PowerShell 7:

| Check | Result |
| --- | --- |
| Backend contract/security, real PostgreSQL and Redis | 31 tests passed |
| Frontend request helpers | 9 tests passed |
| Mocked browser interactions | 11 tests passed |
| Production browser flows and two-tab conflicts | 3 tests passed |
| Compose startup, migration, Nginx and CRUD | Passed |
| PostgreSQL and Redis across container replacement | Passed |
| Recovery of two synthetic notes including Unicode | IDs/content/timestamps match |
| Corrupt backup detection | Refused before starting containers |
| Existing application backup/recovery | One note matches; running data unchanged |
| Exported release startup | Passed with no builds or registry pulls |
| Archive SHA256 and all four image IDs | Passed |
| Workflow actionlint 1.7.7 | Passed |
| PowerShell parsing and Git whitespace checks | Passed |
| npm audit and pip-audit | No known vulnerabilities reported |

The release smoke check uses its own database and Redis volumes and verifies
React serving, API health, migrations, create and read. It does not replace the
full application regression suite. Temporary verification containers and
volumes were removed. A real PostgreSQL backup pair remains under ignored
`backups/`; the local image bundle remains under ignored `artifacts/local-phase6/`.
GitHub workflow results are recorded separately on the repository Actions page.
