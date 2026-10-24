#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
if [[ $# != 1 || ! -f "$1/database.dump" || ! -f "$1/uploads.tar.gz" ]]; then
  echo 'Uso: bash deploy/aws/restore.sh CARPETA_COPIA (database.dump + uploads.tar.gz)' >&2
  exit 1
fi
if [[ "$(python3 deploy/aws/config.py read DATA_MODE)" != restore ]]; then
  echo 'Configure DATA_MODE=restore antes de restaurar.' >&2; exit 1
fi
backup_dir="$(cd -- "$1" && pwd)"
if [[ -f "$backup_dir/SHA256SUMS" ]]; then
  (cd "$backup_dir" && sha256sum -c SHA256SUMS)
fi
python3 - "$backup_dir/uploads.tar.gz" <<'PY'
import sys, tarfile
from pathlib import PurePosixPath
with tarfile.open(sys.argv[1], 'r:gz') as archive:
    for item in archive:
        path = PurePosixPath(item.name)
        if path.is_absolute() or '..' in path.parts or not (item.isfile() or item.isdir()):
            raise SystemExit('Archivo no valido en uploads.tar.gz: ' + item.name)
PY
"${compose[@]}" stop edge web api
"${compose[@]}" up -d --wait --wait-timeout 120 db
tables="$(printf "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';\n" | db_sql)"
if [[ "$tables" != 0 ]]; then
  echo 'La base de destino tiene tablas. Se detiene para conservar sus datos.' >&2; exit 1
fi
"${compose[@]}" run --rm -T --no-deps --user 0 --entrypoint sh api -c 'test -z "$(ls -A /app/uploads-fiis)"' || {
  echo 'El volumen de documentos no esta vacio; no se sobrescribira.' >&2; exit 1;
}
"${compose[@]}" exec -T db sh -c 'exec pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner --no-privileges --exit-on-error' < "$backup_dir/database.dump"
"${compose[@]}" run --rm -T --no-deps --user 0 --entrypoint sh api -c 'tar -xzf - -C /app/uploads-fiis && chown -R 10001:10001 /app/uploads-fiis' < "$backup_dir/uploads.tar.gz"
echo 'Restauracion completada. Ejecute start.sh para comprobar las migraciones y el arranque.'
