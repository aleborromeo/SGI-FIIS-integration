# Despliegue de SGI-FIIS en AWS EC2

Configuración preparada para un entorno académico compartido con tráfico bajo. Una instancia ejecuta PostgreSQL 15, la API Java 17, el frontend y Caddy. El equipo utiliza una URL; la administración del servidor se reserva a los responsables designados.

Para crear la instancia y la red mediante AWS CLI, use la [ruta por comandos desde CloudShell](CLI.md), que automatiza los pasos 2 y 3. Esta guía continúa sirviendo para recuperar los datos y publicar la URL.

## 1. Comprobar la cuenta y el crédito

En AWS abra **Billing and Cost Management → Free Tier / Credits** y confirme el plan, saldo y vencimiento. Para cuentas nuevas desde el 15 de julio de 2025, el Free account plan ofrece USD 100 iniciales, hasta USD 100 adicionales por actividades y una duración máxima de seis meses, o hasta agotar el crédito. El Paid plan puede facturar cuando se agota el crédito. La etiqueta de instancia elegible no significa consumo ilimitado ni un servidor gratuito permanente.

Configure alertas de gasto y de saldo. Para esta primera versión use una sola región y una sola instancia. EC2, EBS y la IPv4 pública consumen recursos facturables que pueden descontarse del crédito; las IPv4 públicas tienen una tarifa publicada de USD 0,005 por hora. No se necesita contratar un dominio mediante AWS para usar un subdominio que ya controle el equipo.

Referencias oficiales revisadas el 24 de octubre de 2026:

- https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/free-tier.html
- https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-free-tier-usage.html
- https://aws.amazon.com/vpc/pricing/

## 2. Crear la instancia

En **EC2 → Launch instance**, configure:

| Campo | Valor para esta guía |
|---|---|
| Región | US East (N. Virginia), `us-east-1` |
| Nombre | `sgi-fiis-equipo` |
| AMI | Ubuntu Server 24.04 LTS, x86_64, imagen oficial elegible de Canonical |
| Tipo | `t3.small`, 2 GiB de RAM, si la consola confirma elegibilidad y crédito |
| CPU credits | Standard, para limitar recargos de CPU Unlimited; el rendimiento puede reducirse al agotar créditos de CPU |
| Disco | 30 GiB gp3, cifrado |
| Red | Subred pública con ruta al Internet Gateway y una IPv4 pública |
| Clave SSH | Un par nuevo, por ejemplo `sgi-fiis-aws.pem`; guardarlo en privado |

Una `t3.micro` tiene menos memoria y no es la recomendación para Java, PostgreSQL y las compilaciones juntos. El swap de 2 GiB ayuda durante la construcción, pero no sustituye RAM. Si la consola no permite el tipo indicado bajo su plan, revise las opciones elegibles antes de lanzar otro tipo.

Reglas entrantes del Security Group:

| Puerto TCP | Origen | Momento |
|---|---|---|
| 22 | Solo su IP pública, `/32` | Administración SSH |
| 80 | Internet (`0.0.0.0/0`) | Cuando se configure el dominio, para ACME y redirección |
| 443 | Internet (`0.0.0.0/0`) | Cuando se publique HTTPS |

La base de datos y la API no publican puertos del host. El acceso web inicial también está limitado por Docker a `127.0.0.1`, aunque exista una regla de red para 80/443. Antes de generar certificados, 80/443 deben llegar desde Internet.

Conserve una IPv4 estable mientras use el DNS. Una IP pública automática puede cambiar al detener e iniciar EC2; en ese caso debe actualizar el registro DNS y la conexión SSH. Una Elastic IP mantiene la dirección, consume el recurso de IPv4 y debe liberarse al dejar de utilizarla.

## 3. Conectarse desde Windows e instalar Docker

En PowerShell, sustituya la ruta de la clave y la IP:

```powershell
ssh -i "C:\ruta\sgi-fiis-aws.pem" ubuntu@IP_PUBLICA
```

En Ubuntu:

```bash
git clone --recurse-submodules https://github.com/aleborromeo/SGI-FIIS-integration.git
cd SGI-FIIS-integration
# Si estos cambios siguen en revisión, cambiar a la rama del PR y actualizar submódulos.
git switch codex/aws-ec2-setup
git submodule update --init --recursive
bash deploy/aws/bootstrap-ubuntu.sh
exit
```

Vuelva a entrar por SSH y compruebe:

```bash
cd SGI-FIIS-integration
docker version
docker compose version
free -h
df -h /
```

El instalador usa el repositorio oficial de Docker: https://docs.docker.com/engine/install/ubuntu/ . El grupo `docker` permite administrar el host; agréguelo solo a quienes administren el servidor.

## 4. Elegir la ruta de datos

No debe crear una base nueva como sustituto de los datos existentes. Se proporcionan dos rutas; el generador requiere elegir una y nunca reemplaza un `.env.aws` existente. Sus secretos no se imprimen.

### A. Recuperar datos y documentos anteriores

En el servidor anterior detenga las escrituras de la API mientras obtiene la copia de PostgreSQL y los archivos. No elimine ese servidor todavía. Utilice PostgreSQL 15 como origen; si utiliza otra versión mayor, revise compatibilidad antes de restaurar.

Obtenga primero los nombres reales con `docker ps` e `docker inspect`. Sustituya `CONTENEDOR_DB`, `CONTENEDOR_API`, `USUARIO_DB` y `NOMBRE_DB`:

```bash
mkdir -p migracion-sgi
chmod 700 migracion-sgi
umask 077
docker stop CONTENEDOR_API
docker exec CONTENEDOR_DB pg_dump -U USUARIO_DB -d NOMBRE_DB -Fc --no-owner --no-privileges > migracion-sgi/database.dump
# docker cp puede leer el sistema de archivos de un contenedor detenido.
docker cp CONTENEDOR_API:/app/uploads-fiis migracion-sgi/uploads-fiis
tar -C migracion-sgi/uploads-fiis -czf migracion-sgi/uploads.tar.gz .
docker start CONTENEDOR_API
```

Esto presupone que el almacenamiento anterior está en `/app/uploads-fiis`, como el Docker del backend revisado. Si usa otro directorio, respete su ruta real. Para realizar el corte definitivo, mantenga las escrituras detenidas hasta comprobar AWS; si vuelve a permitir escrituras en el servidor anterior, deberá repetir la copia final antes del cambio.

Descargue la carpeta a su PC y súbala al nuevo EC2 mediante `scp`. En PowerShell:

```powershell
scp -i "C:\ruta\sgi-fiis-aws.pem" -r "C:\ruta\migracion-sgi" ubuntu@IP_PUBLICA:~/
```

En el nuevo servidor:

```bash
python3 deploy/aws/config.py init --mode restore
docker compose --env-file .env.aws -f docker-compose.aws.yml build api
docker compose --env-file .env.aws -f docker-compose.aws.yml build web
bash deploy/aws/restore.sh ~/migracion-sgi
bash deploy/aws/start.sh
```

La restauración rechaza una base con tablas o un volumen de documentos con contenido. No borra una base existente. `DATA_MODE=restore` impide que la API inicialice silenciosamente otra base de prueba cuando todavía falta recuperar el historial Flyway. Si la copia no tiene `flyway_schema_history`, revise el esquema y el historial original antes de continuar; no fuerce un baseline ni modifique checksums a ciegas.

El código guarda rutas físicas de documentos en la tabla `documentos`. Se conserva `/app/uploads-fiis` para mantener esas rutas. Revise una muestra de `ruta_almacenamiento` y pruebe descargas; si antes se ejecutaba en Windows u otra ruta, necesitará una conversión del prefijo que respete los archivos originales.

### B. Crear una instalación nueva de pruebas

Use esta ruta solo si no debe recuperar datos anteriores:

```bash
python3 deploy/aws/config.py init --mode fresh
bash deploy/aws/start.sh --build
bash deploy/aws/secure-demo.sh --fresh-install
```

Las migraciones del backend crean usuarios de prueba con una contraseña pública. El último script solicita un administrador existente (por ejemplo `admin@unas.edu.pe`) y una contraseña temporal nueva, desactiva las cuentas que conservan aquella contraseña pública y habilita ese administrador. Pide cambiar la contraseña en el siguiente inicio de sesión. No se debe ejecutar este procedimiento en una base restaurada de usuarios reales.

## 5. Probar en privado

Desde otra ventana PowerShell, abra un túnel:

```powershell
ssh -i "C:\ruta\sgi-fiis-aws.pem" -L 8080:127.0.0.1:80 ubuntu@IP_PUBLICA
```

Abra `http://localhost:8080` en su PC. Compruebe:

1. Inicio de sesión y cambio de la contraseña temporal, si corresponde.
2. Listados de proyectos, planes de tesis y usuarios según el rol.
3. Carga y descarga de un documento de prueba.
4. Una ruta interna abierta directamente y una recarga del navegador.
5. En `/health`, la propiedad `database` debe indicar `CONNECTED`; no basta recibir HTTP 200.

En la EC2:

```bash
docker compose --env-file .env.aws -f docker-compose.aws.yml ps
docker compose --env-file .env.aws -f docker-compose.aws.yml logs --tail=100 api
curl -fsS http://localhost/health
```

El frontend usa la misma dirección que la web para `/api/...`; no debe solicitar `localhost:5173` desde los equipos de sus compañeros.

## 6. Publicar una URL con HTTPS

Se requiere un dominio o subdominio que controle, por ejemplo `sgi.sudominio.edu.pe`, o un subdominio gratuito que pueda administrar. Apunte su registro A a la IPv4 de EC2. No configure AAAA salvo que tenga IPv6 operativa. Espere a que DNS responda y habilite 80/443 en el Security Group.

Edite con `nano .env.aws`, conservando los secretos existentes:

```dotenv
PUBLIC_URL=https://sgi.sudominio.edu.pe
SITE_ADDRESS=sgi.sudominio.edu.pe
BIND_ADDRESS=0.0.0.0
```

Después:

```bash
chmod 600 .env.aws
python3 deploy/aws/config.py validate
bash deploy/aws/start.sh
```

El arranque público se detiene si siguen existiendo cuentas activas con la contraseña original de la semilla. En una restauración, el responsable debe revisar y cambiar esas cuentas antes de publicar; no se desactivan automáticamente usuarios de la base recuperada.

Caddy solicita y renueva el certificado y redirige HTTP a HTTPS. Compruebe la URL desde otra red y repita las pruebas de login y documentos. Referencia: https://caddyserver.com/docs/automatic-https . Mientras no tenga dominio, puede seguir probando con el túnel SSH. No se publica el inicio de sesión mediante HTTP abierto.

## 7. Acceso del equipo y correo

Comparta la URL y cree una cuenta individual para cada integrante con su rol. Los usuarios de la aplicación no necesitan acceder a AWS ni recibir su clave `.pem`. Para mantenimiento, use una clave SSH individual por administrador; las claves públicas se agregan a `~/.ssh/authorized_keys` y sus IP a la regla 22. El acceso a la consola AWS se asigna con identidades individuales y permisos limitados, sin compartir la cuenta raíz ni desactivar MFA.

El modo inicial `APP_MAIL_MOCK=true` permite comprobar el servidor, pero no envía correos de registro, verificación o recuperación. Para probar esas funciones complete en `.env.aws` el SMTP existente del proyecto, su contraseña de aplicación y `APP_MAIL_FROM`, y cambie `APP_MAIL_MOCK=false`. Al aplicar el cambio, recree la API con `start.sh`.

Hay un enlace `http://localhost:5173/login` escrito directamente en `EmailSenderAdapter.java` del backend fijado. Debe sustituirse en el backend por el valor configurable de `APP_FRONTEND_URL` antes de utilizar los correos de alta como flujo final para el equipo. Las variables Azure por sí solas tampoco acreditan que SSO funcione: si utilizará Microsoft, valide la implementación y registre los redirect URI de la URL HTTPS en Entra ID. La prueba básica de este despliegue utiliza autenticación local.

## 8. Respaldos y actualizaciones

```bash
bash deploy/aws/backup.sh
```

La API se detiene brevemente para que la base y los archivos correspondan al mismo estado; se reinicia al finalizar. Descargue la carpeta generada a una ubicación privada fuera de EC2. El respaldo contiene datos y documentos, no debe subirse a este repositorio público. Conserve `.env.aws` por separado en un lugar privado. Pruebe la recuperación en una EC2 de prueba o en volúmenes nuevos antes de depender de una copia.

Para actualizar, el responsable revisa el commit de integración y sus dos submódulos, hace un respaldo y ejecuta:

```bash
git fetch origin
# Sustituya COMMIT_REVISADO por la revisión que el equipo decidió desplegar.
git checkout COMMIT_REVISADO
git submodule sync --recursive
git submodule update --init --recursive
bash deploy/aws/start.sh --build
```

La revisión debe incluir estos archivos de despliegue. No use `git reset --hard` ni limpieza forzada para preservar cambios locales; compruebe antes `git status`. Las migraciones se validan y no se reparan automáticamente. Volver a una imagen anterior no revierte una migración: si el esquema es incompatible, recupere la base y los documentos desde una copia verificada en volúmenes nuevos.

Recrear contenedores conserva los volúmenes Docker. Eliminar la instancia o su disco EBS puede perderlos. Detener EC2 no elimina el consumo de EBS ni necesariamente el de una Elastic IP. Al cerrar el entorno, conserve y descargue las copias primero, y revise instancia, discos, snapshots e IP para no dejar recursos consumiendo crédito.

## Verificación y límites

El workflow `Validate AWS deployment` construye ambos contenedores y comprueba el arranque, migraciones, SPA, conexión a PostgreSQL, login, actualización de la cuenta administradora y una copia/restauración en volúmenes separados. No necesita credenciales AWS y no despliega en la nube. `down --volumes` se usa exclusivamente al limpiar ese entorno temporal de CI; no se utiliza para operar la instancia del equipo.

La comprobación de TypeScript de producción excluye fixtures y pruebas `.test`/`.spec`. El comando original `npm run build` de este commit incluye pruebas y presenta errores de tipos en esos archivos. La imagen AWS conserva la comprobación del código de producción mediante `tsconfig.production.json`; esto no acredita que las pruebas del frontend pasen.

El Dockerfile de backend compila el JAR dentro de su etapa Maven, en lugar de depender de un `target/*.jar` que no se conserva en Git. Los secretos se generan en el servidor, y los puertos de PostgreSQL y la API quedan dentro de Docker. La guía prepara un servidor único: no ofrece alta disponibilidad ni sustituye pruebas de todos los flujos del sistema.
