# Running a release bundle

This bundle contains Linux Docker images for React/Nginx, FastAPI/migrations,
PostgreSQL and Redis. Use Docker Desktop in Linux-container mode or a Linux
Docker Engine, with Compose 2.24.4 or newer. Images target the architecture of
the packaging machine (GitHub CI packages linux/amd64).

The supplied Compose configuration includes CPU/memory/process ceilings and
rotated logs. `OPERATIONS.md` explains the resource profile and maintenance.
Its script commands are available in the Git repository; no scripts or source
installation are required for the bundle startup instructions below.

Extract the complete artifact into an empty directory. In PowerShell 7:

```powershell
$release = Get-Content ./release.json -Raw | ConvertFrom-Json
if ((Get-FileHash ./notes-images.tar.gz -Algorithm SHA256).Hash.ToLowerInvariant() -ne $release.sha256) { throw 'Checksum mismatch' }
docker load -i ./notes-images.tar.gz
foreach ($image in $release.images.PSObject.Properties) {
  if ((docker image inspect --format '{{.Id}}' $image.Name) -ne $image.Value) { throw 'Image ID mismatch' }
}
Copy-Item .env.example .env
# Edit .env: choose a private database password and available local ports.
docker compose --env-file .env --env-file .env.images -f compose.yaml -f compose.release.yaml up -d --wait --no-build --pull never
docker compose --env-file .env --env-file .env.images -f compose.yaml -f compose.release.yaml ps -a
```

Open http://localhost:8080 (or your chosen WEB_PORT). No source code, Node or
Python installation is needed on the receiving machine. Keep all bundle files
together. Clear any NOTES_*_IMAGE shell variables before starting; shell
variables take precedence over environment files.

To stop containers while retaining notes and the activity counter:

```powershell
docker compose --env-file .env --env-file .env.images -f compose.yaml -f compose.release.yaml down
```

Use a consistent project name/directory when restarting so Compose reuses the
same volumes. Back up PostgreSQL before upgrading. This bundle is for local
operation: public hosting still needs a chosen server, HTTPS and user access
controls. Checksums detect accidental corruption; they do not authenticate an
untrusted bundle. Obtain artifacts from this repository's successful workflow.
