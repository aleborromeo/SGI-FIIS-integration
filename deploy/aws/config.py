#!/usr/bin/env python3
"""Create and validate the local AWS environment without printing secrets."""
import argparse
import os
from pathlib import Path
import re
import secrets
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[2]
ENV_FILE = ROOT / '.env.aws'
PUBLIC_KEYS = {'DATA_MODE', 'PUBLIC_URL', 'SITE_ADDRESS', 'BIND_ADDRESS', 'IMAGE_TAG'}


def read_values():
    if not ENV_FILE.is_file():
        raise ValueError('Falta .env.aws; ejecute config.py init primero.')
    values = {}
    for line in ENV_FILE.read_text(encoding='utf-8').splitlines():
        line = line.strip()
        if line and not line.startswith('#') and '=' in line:
            key, value = line.split('=', 1)
            value = value.strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                value = value[1:-1]
            values[key.strip()] = value
    return values


def validate(values):
    if values.get('DATA_MODE') not in ('fresh', 'restore'):
        raise ValueError('DATA_MODE debe ser fresh o restore.')
    for key in ('DB_NAME', 'DB_USER'):
        if not re.fullmatch(r'[a-z][a-z0-9_]{0,40}', values.get(key, '')):
            raise ValueError(key + ': use minusculas, numeros y guion bajo.')
    for key in ('DB_PASSWORD', 'JWT_SECRET'):
        value = values.get(key, '')
        if len(value) < 32 or 'GENERATE' in value or 'CHANGE' in value:
            raise ValueError(key + ': se requiere un secreto nuevo de al menos 32 caracteres.')
    url = urlsplit(values.get('PUBLIC_URL', ''))
    if (url.scheme not in ('http', 'https') or not url.hostname or url.path not in ('', '/')
            or url.query or url.fragment or url.username or url.password):
        raise ValueError('PUBLIC_URL debe ser un origen http(s), sin ruta ni credenciales.')
    if url.port not in (None, 80 if url.scheme == 'http' else 443):
        raise ValueError('PUBLIC_URL debe usar los puertos normales 80/443.')
    site = url.hostname if url.scheme == 'https' else 'http://' + url.hostname
    if values.get('SITE_ADDRESS') != site:
        raise ValueError('SITE_ADDRESS debe ser ' + site)
    if values.get('BIND_ADDRESS') not in ('127.0.0.1', '0.0.0.0'):
        raise ValueError('BIND_ADDRESS debe ser 127.0.0.1 o 0.0.0.0.')
    if values.get('BIND_ADDRESS') == '0.0.0.0' and url.scheme != 'https':
        raise ValueError('Para publicar use HTTPS con un dominio; HTTP queda para la prueba por SSH.')
    if values.get('APP_MAIL_MOCK', 'true').lower() == 'false':
        for key in ('SPRING_MAIL_HOST', 'SPRING_MAIL_USERNAME', 'SPRING_MAIL_PASSWORD', 'APP_MAIL_FROM'):
            if not values.get(key) or values[key] == 'localhost':
                raise ValueError('Correo real: falta configurar ' + key)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    init = commands.add_parser('init')
    init.add_argument('--mode', choices=['fresh', 'restore'], required=True)
    init.add_argument('--url', default='http://localhost')
    commands.add_parser('validate')
    read = commands.add_parser('read')
    read.add_argument('key', choices=sorted(PUBLIC_KEYS))
    args = parser.parse_args()
    try:
        if args.command == 'init':
            url = urlsplit(args.url)
            values = read_template()
            values.update(DATA_MODE=args.mode, DB_PASSWORD=secrets.token_hex(24),
                          JWT_SECRET=secrets.token_hex(32), PUBLIC_URL=args.url.rstrip('/'),
                          SITE_ADDRESS=(url.hostname if url.scheme == 'https' else 'http://' + (url.hostname or '')))
            validate(values)
            # O_EXCL prevents accidentally replacing a working database password/JWT.
            fd = os.open(ENV_FILE, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, 'w', encoding='utf-8') as file:
                for key, value in values.items():
                    file.write(key + '=' + value + '\n')
            print('.env.aws creado; acceso inicial limitado a localhost.')
        elif args.command == 'read':
            print(read_values().get(args.key, ''))
        else:
            validate(read_values())
            print('Configuracion valida; secretos omitidos.')
    except (ValueError, OSError) as error:
        parser.exit(1, str(error) + '\n')


def read_template():
    values = {}
    for line in (ROOT / 'deploy/aws/.env.aws.example').read_text(encoding='utf-8').splitlines():
        if line and not line.startswith('#') and '=' in line:
            key, value = line.split('=', 1)
            values[key] = value
    return values


if __name__ == '__main__':
    main()
