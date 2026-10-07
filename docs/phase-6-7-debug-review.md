# CI, release and recovery debug review

The earlier successful pipeline covered normal startup and recovery. This
review adds regression checks for invalid release metadata and failed cleanup.

| Bug | Fix |
| --- | --- |
| Empty/incomplete image manifests reached Docker before rejection | Require four exact service tags with valid image IDs and revision/checksum |
| Duplicate image variables overwrote saved shell values | Reject duplicates before Docker or environment changes |
| Missing image variables could inherit ambient shell overrides | Require all four variables; validate each service's assignment |
| An API image could be assigned to the web service with valid image membership | Match each variable to its intended service tag |
| Cleanup errors masked the original startup/restore failure | Preserve the original exception and report cleanup failure separately |
| Release verification ran teardown after configuration failed, before startup | Teardown only after an attempted startup |
| Recovery drill deleted its environment file even when teardown failed | Retain credentials/configuration until successful cleanup |
| Export could label modified code with another Git revision | Require HEAD revision and committed source/configuration before export |
| Docker failures only identified the command, hiding exit status | Include the exit code without printing secret arguments |

`scripts/test-docker-tools.ps1` reproduces these failure cases with a Docker
stub. It also checks corrupt archive refusal and absent/empty/present shell
variable restoration. The stub contacts no Docker engine and deletes no real
containers. Before the fix, the empty-manifest check failed because Docker was
called twice before rejection. The corrected workflow runs these checks before
real stack and recovery tests.

Local checks passed: eleven script failure/environment checks, a real Docker
release startup and a real PostgreSQL recovery/corruption drill. PowerShell
parsing, workflow lint and Git whitespace checks passed. The existing full
application regression suite runs again in GitHub CI for the pushed revision.

Run locally with PowerShell 7:

```powershell
./scripts/test-docker-tools.ps1
./scripts/verify-recovery.ps1
./scripts/verify-release.ps1 -BundlePath ./artifacts/local-phase6
```

If Docker teardown fails, the original error is raised and a warning identifies
the temporary project and retained environment file. Retry cleanup only for
that named project. Temporary credentials stay outside Git under ignored
`test-results/`, `backups/` or the bundle directory.
