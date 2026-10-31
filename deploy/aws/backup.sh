#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
umask 077
backup_dir="$SGI_ROOT/backups/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$backup_dir"
api_was_running="$("${compose[@]}" ps --status running -q api)"
resume_api() {
  if [[ -n "$api_was_running" ]]; then
    "${compose[@]}" up -d --no-deps --no-build api >/dev/null
  fi
}
trap resume_api EXIT
# Stop application writes so the database dump and uploaded files agree.
"${compose[@]}" stop api
"${compose[@]}" exec -T db sh -c 'exec pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc --no-owner --no-privileges' > "$backup_dir/database.dump.tmp"
mv "$backup_dir/database.dump.tmp" "$backup_dir/database.dump"
"${compose[@]}" run --rm -T --no-deps --entrypoint tar api -C /app/uploads-fiis -czf - . > "$backup_dir/uploads.tar.gz.tmp"
mv "$backup_dir/uploads.tar.gz.tmp" "$backup_dir/uploads.tar.gz"
git rev-parse HEAD > "$backup_dir/integration-commit.txt"
git submodule status > "$backup_dir/submodules.txt"
(cd "$backup_dir" && sha256sum database.dump uploads.tar.gz > SHA256SUMS)
echo "Copia completada: $backup_dir"
echo 'Descargue esta carpeta fuera de EC2. .env.aws se conserva por separado.'
