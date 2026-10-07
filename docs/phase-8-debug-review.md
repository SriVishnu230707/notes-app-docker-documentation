# Phase 8 bug fixes and regression coverage

| Issue | Fix |
| --- | --- |
| Status's default port could probe another healthy project | Derive the selected project's published Nginx/Vite port; reject mismatched explicit ports before HTTP |
| Resource-stat errors masked health/load outcomes | Treat stats as optional diagnostics and preserve the actual check result |
| Direct execution of the Python driver could target a normal container's web service | Require the generated disposable project marker and notes_load database before any HTTP |
| Malformed/truthy/incomplete load results could produce misleading errors or success | Validate result types, workload/count, finite latency and failure consistency |
| Generator crash/empty output left no JSON diagnostic | Save a failed report with native exit code before cleanup |
| Production Nginx's small resource budget was inherited by Node/Vite | Give the development override a 512 MiB, one-CPU budget |

Regression tests reproduced the status bug (wrong endpoint reported healthy)
and the generator guard bug (an HTTP attempt happened without disposable
project configuration) before fixes. `test-phase8.ps1` uses Docker/HTTP stubs
for port selection, optional stats and malformed reports. Python tests verify
refusal before HTTP for four unsafe environments and allow the marked project.
CI runs these checks plus an isolated development startup/source transformation/
same-origin proxy CRUD/status test. The new development check uses response
ETags verbatim so PowerShell's JSON date conversion cannot alter note versions.

Local repeat commands:

```powershell
./scripts/test-phase8.ps1
python scripts/test_load_test.py
./scripts/verify-load.ps1
./scripts/verify-dev.ps1
./scripts/status.ps1
```

The corrected full load run passed 705 requests with p95 226.98 ms on this
laptop. All mutation/data/Redis checks passed. Tests use their own project and
volumes; existing user notes are never used as load data. Reports and temporary
credentials remain outside Git.
