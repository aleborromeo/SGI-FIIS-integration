#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
case "${1:-}" in
  --build)
    # Build sequentially to reduce peak RAM on the EC2 host.
    "${compose[@]}" build api
    "${compose[@]}" build web
    ;;
  "") ;;
  *) echo 'Uso: bash deploy/aws/start.sh [--build]' >&2; exit 1 ;;
esac
"${compose[@]}" config --quiet
"${compose[@]}" up -d --wait --wait-timeout 120 db
if [[ "$(python3 deploy/aws/config.py read DATA_MODE)" == restore ]]; then
  history="$(printf "SELECT to_regclass('public.flyway_schema_history') IS NOT NULL;\n" | db_sql)"
  if [[ "$history" != t ]]; then
    echo 'DATA_MODE=restore: primero restaure la base con su historial Flyway; no se crearan datos de prueba.' >&2
    exit 1
  fi
fi
"${compose[@]}" up -d --no-build --wait --wait-timeout 300 api
if [[ "$(python3 deploy/aws/config.py read BIND_ADDRESS)" == 0.0.0.0 ]]; then
  remaining="$(printf "SELECT count(*) FROM usuarios WHERE es_activo AND password_hash = '%s';\n" "$seed_hash" | db_sql)"
  if [[ "$remaining" != 0 ]]; then
    "${compose[@]}" stop edge
    echo 'Hay usuarios activos con la clave publica de prueba; revise secure-demo.sh antes de publicar.' >&2
    exit 1
  fi
fi
"${compose[@]}" up -d --no-build --wait --wait-timeout 120 web edge
"${compose[@]}" ps
echo "URL configurada: $(python3 deploy/aws/config.py read PUBLIC_URL)"
