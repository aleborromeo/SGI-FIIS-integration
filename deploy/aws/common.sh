#!/usr/bin/env bash
# Source this file from the other AWS scripts; never source .env.aws as shell code.
set -euo pipefail
SGI_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$SGI_ROOT"
python3 deploy/aws/config.py validate
compose=(docker compose --env-file "$SGI_ROOT/.env.aws" -f "$SGI_ROOT/docker-compose.aws.yml")
seed_hash='$2a$10$woQ5pX6m6t.KeVMOTNiZwuOJz6wsR.oM30jwUQ2EdUwEpoEN66ZYO'

db_sql() {
  "${compose[@]}" exec -T db sh -c 'exec psql -X -qAt -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' "$@"
}
