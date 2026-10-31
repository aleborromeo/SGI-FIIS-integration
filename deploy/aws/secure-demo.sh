#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
if [[ "${1:-}" != --fresh-install || "$(python3 deploy/aws/config.py read DATA_MODE)" != fresh ]]; then
  echo 'Solo para una base nueva de pruebas: secure-demo.sh --fresh-install' >&2; exit 1
fi
echo 'Se desactivaran las cuentas que conservan la clave publica de la semilla.'
echo 'Se habilitara el administrador elegido con una nueva clave temporal.'
read -r -p 'Correo del administrador existente (ej. admin@unas.edu.pe): ' admin_email
read -r -s -p 'Nueva clave temporal (minimo 16 caracteres): ' admin_password
echo
if [[ ${#admin_password} -lt 16 ]]; then
  echo 'Clave demasiado corta.' >&2; exit 1
fi
read -r -s -p 'Repita la clave: ' repeat_password
echo
[[ "$admin_password" == "$repeat_password" ]] || { echo 'Las claves no coinciden.' >&2; exit 1; }
# Password is supplied via stdin, not a process argument or an SQL literal.
password_hash="$(printf '%s\n' "$admin_password" | "${compose[@]}" run --rm -T --no-deps --entrypoint caddy edge hash-password --algorithm bcrypt --bcrypt-cost 12)"
unset admin_password repeat_password
[[ "$password_hash" == '$2'* ]] || { echo 'No se obtuvo un hash BCrypt.' >&2; exit 1; }
"${compose[@]}" exec -T db sh -c 'exec psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" "$@"' sh \
  -v admin_email="$admin_email" -v password_hash="$password_hash" -v seed_hash="$seed_hash" <<'SQL'
BEGIN;
SELECT u.id_usuario AS admin_id
FROM usuarios u JOIN roles r ON r.id_rol=u.id_rol_principal
WHERE u.correo_institucional=:'admin_email' AND r.codigo_rol='ADMIN'
\gset
UPDATE usuarios SET es_activo=FALSE WHERE password_hash=:'seed_hash';
UPDATE usuarios SET password_hash=:'password_hash', es_activo=TRUE, must_change_password=TRUE
WHERE id_usuario=:'admin_id';
COMMIT;
SQL
echo 'Administrador actualizado; cambie la clave temporal al iniciar sesion.'
