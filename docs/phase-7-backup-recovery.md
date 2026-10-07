# Phase 7: PostgreSQL backup and tested recovery

Notes live in PostgreSQL. Named volumes survive container replacement but do
not protect against volume deletion or laptop failure. Phase 7 creates
portable custom-format PostgreSQL dumps and restores them into a separate
Docker project for inspection. The running application is never overwritten.

Requirements: PowerShell 7, Docker running, and this project's PostgreSQL 17
stack. Run from the repository root:

```powershell
$backup = ./scripts/backup.ps1
$backup.ArchivePath
# Creates backups/notes-<time>-<unique-id>.dump plus a .dump.json manifest.
./scripts/restore.ps1 -BackupPath $backup.ArchivePath
```

Restore leaves the new app running at http://127.0.0.1:19080 with API port
19000, and prints/returns its project name and generated environment file.
Choose `-WebPort` and `-ApiPort` if these ports are occupied. New random database
credentials and separate volumes isolate the restored copy from your regular
stack. Keep the returned environment file to operate that copy:

```powershell
$copy = ./scripts/restore.ps1 -BackupPath $backup.ArchivePath -WebPort 19081 -ApiPort 19001
docker compose --env-file $copy.EnvFile -p $copy.ProjectName -f compose.yaml ps -a
# Stop the copy, preserving its volumes:
docker compose --env-file $copy.EnvFile -p $copy.ProjectName -f compose.yaml down
# When you are finished with this disposable recovery copy, delete its volumes:
docker compose --env-file $copy.EnvFile -p $copy.ProjectName -f compose.yaml down --volumes
```

Only use these cleanup commands with the recovery project's returned name.
Do not substitute the normal `notes-app` project. Clear shell PostgreSQL/port
overrides before running manual Compose commands so its environment file wins.

For a temporary restoration that is automatically removed after checking:

```powershell
./scripts/restore.ps1 -BackupPath $backup.ArchivePath -VerifyOnly
./scripts/verify-recovery.ps1
```

The drill creates two notes (including Unicode and quotes), backs them up,
restores into a second project and compares IDs, titles, contents and both
timestamps. It also tampers with an archive and requires refusal before
startup. Both drill projects and their volumes are cleaned up; synthetic
archive files remain under ignored `test-results/`. Interrupted processes may
need manual cleanup of their uniquely named projects.

`backup.ps1` supports `-ProjectName`, `-EnvFile` and `-OutputDirectory` for
another stack using this repository's Compose configuration. It runs pg_dump
inside the PostgreSQL container, validates the archive table of contents,
copies binary bytes directly with Docker and generates a SHA256/size manifest.
The dump is a consistent database snapshot; writes may continue during backup.
Restore checks the manifest before Docker operations, runs pg_restore in a
transaction with owner/ACL restoration disabled, then runs pending Alembic
migrations before starting the API. Failed restores remove their temporary
project and volumes.

Redis is a best-effort activity counter. Recovery starts it empty, so its count
resets; saved notes are unaffected. This is deliberately a PostgreSQL recovery
workflow, not a full Redis snapshot. The app has no user accounts or attachments
to back up separately.

Keep each `.dump` and `.dump.json` together. Backups contain private note data;
the files are not encrypted or signed. Checksums detect corruption but cannot
prove trust if someone replaces both files. Restore only your trusted backups.
Copy backup pairs to private storage outside the laptop to protect against
disk loss. Git ignores `backups/` and CI never uploads it. Backup scheduling
and retention deletion are manual; no automatic job deletes your archives.

References: [PostgreSQL 17 pg_dump](https://www.postgresql.org/docs/17/app-pgdump.html),
[PostgreSQL 17 pg_restore](https://www.postgresql.org/docs/17/app-pgrestore.html).
