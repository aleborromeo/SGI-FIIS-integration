#!/usr/bin/env python3
"""Configure Gmail SMTP interactively; credentials stay in the private environment file."""
import argparse
import getpass
import os
from pathlib import Path
import re
import smtplib
import ssl
import sys
import tempfile

import config


def authenticate(values):
    """Check TLS and SMTP authentication without sending a message."""
    with smtplib.SMTP(values['SPRING_MAIL_HOST'], int(values['SPRING_MAIL_PORT']), timeout=15) as smtp:
        smtp.ehlo()
        smtp.starttls(context=ssl.create_default_context())
        smtp.ehlo()
        smtp.login(values['SPRING_MAIL_USERNAME'], values['SPRING_MAIL_PASSWORD'])


def gmail_values(email, password):
    email = email.strip().lower()
    if not re.fullmatch(r'[a-z0-9._%+\-]+@(?:gmail|googlemail)\.com', email):
        raise ValueError('Use la direccion completa de su cuenta personal Gmail.')
    password = ''.join(password.split())
    if not re.fullmatch(r'[A-Za-z0-9]{16}', password):
        raise ValueError('Se requiere la contrasena de aplicacion de Google de 16 caracteres.')
    return {
        'APP_MAIL_MOCK': 'false',
        'APP_MAIL_FROM': email,
        'SPRING_MAIL_HOST': 'smtp.gmail.com',
        'SPRING_MAIL_PORT': '587',
        'SPRING_MAIL_USERNAME': email,
        'SPRING_MAIL_PASSWORD': password,
    }


def update_environment(path, updates):
    """Replace only mail settings, atomically, with owner-only permissions."""
    original = path.read_text(encoding='utf-8')
    lines, pending = [], dict(updates)
    for line in original.splitlines():
        key = line.split('=', 1)[0].strip() if '=' in line and not line.lstrip().startswith('#') else ''
        if key in updates:
            line = key + '=' + updates[key]
            pending.pop(key, None)
        lines.append(line)
    lines.extend(key + '=' + value for key, value in pending.items())
    descriptor, temporary = tempfile.mkstemp(prefix='.env.aws-mail-', dir=path.parent)
    try:
        with os.fdopen(descriptor, 'w', encoding='utf-8') as stream:
            stream.write('\n'.join(lines) + '\n')
        os.replace(temporary, path)
    finally:
        if Path(temporary).exists():
            Path(temporary).unlink()


def configure_gmail():
    values = config.read_values()
    config.validate(values)
    email = input('Cuenta Gmail remitente (ej. cuenta@gmail.com): ')
    password = getpass.getpass('Contrasena de aplicacion de Google (entrada oculta): ')
    updates = gmail_values(email, password)
    candidate = dict(values, **updates)
    config.validate(candidate)
    authenticate(candidate)
    update_environment(config.ENV_FILE, updates)
    print('Gmail autenticado mediante TLS; configuracion guardada con permisos privados.')
    print('Aplique el cambio con bash deploy/aws/start.sh. Falta comprobar la recepcion de un correo.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['gmail', 'check'])
    args = parser.parse_args()
    try:
        if args.command == 'gmail':
            if not sys.stdin.isatty():
                raise ValueError('Ejecute gmail dentro de una sesion SSH interactiva.')
            configure_gmail()
        else:
            values = config.read_values()
            if values.get('APP_MAIL_MOCK', 'true').lower() != 'false':
                raise ValueError('El correo sigue en modo MOCK; configure Gmail primero.')
            config.validate(values)
            authenticate(values)
            print('Conexion TLS y autenticacion SMTP correctas; prueba sin envio de mensajes.')
    except smtplib.SMTPAuthenticationError:
        parser.exit(1, 'Gmail rechazo las credenciales. Revise la cuenta y su contrasena de aplicacion; no se guardaron cambios.\n')
    except (ValueError, OSError, smtplib.SMTPException) as error:
        if isinstance(error, ValueError):
            parser.exit(1, str(error) + '\n')
        parser.exit(1, 'No se pudo completar la comprobacion SMTP (' + type(error).__name__ + ').\n')


if __name__ == '__main__':
    main()
