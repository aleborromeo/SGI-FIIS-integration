# Crear y preparar AWS mediante comandos

Esta ruta sustituye la creación manual de EC2 y su red. Usa AWS CLI y una plantilla CloudFormation versionada. Cree primero la cuenta y compruebe su plan/crédito como indica la [guía principal](README.md#1-comprobar-la-cuenta-y-el-crédito).

## Ejecutar desde AWS CloudShell

Abra CloudShell desde la consola de su cuenta AWS. Ya dispone de una sesión autenticada y herramientas de línea de comandos; no necesita escribir claves de acceso en el repositorio. Clone solo el repositorio de integración en CloudShell, sin los submódulos: se descargarán y compilarán en EC2.

```bash
aws sts get-caller-identity
git clone --depth 1 --single-branch --branch codex/aws-ec2-setup https://github.com/aleborromeo/SGI-FIIS-integration.git
cd SGI-FIIS-integration
bash deploy/aws/provision.sh --region us-east-1 --mode restore
```

`restore` prepara Docker, las imágenes y PostgreSQL, y deja pendiente recuperar la base y los documentos anteriores. No inicializa otra base de prueba. Para una instalación nueva sin datos anteriores, el último comando es:

```bash
bash deploy/aws/provision.sh --region us-east-1 --mode fresh
```

El modo `fresh` inicia la aplicación, desactiva las cuentas que conservan la contraseña pública de la semilla y asigna al administrador una contraseña temporal nueva. La guarda en `/home/ubuntu/.sgi-fiis-initial-admin`, con acceso solo para ese usuario. Se consulta por SSH y se cambia en el primer inicio de sesión; después debe eliminar el archivo con la clave temporal.

Si ya clonó esta rama antes, actualícela con `git pull --ff-only` en vez de volver a clonar. Tras integrar el PR, se podrá obtener la configuración desde `main`.

## Ejecutar desde Windows sin CloudShell

Si CloudShell sigue bloqueado pero la API de EC2 responde, puede crear el mismo stack desde PowerShell. Instale [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) y autentíquese con credenciales temporales mediante `aws login` (requiere CLI 2.32.0 o posterior):

```powershell
aws login --profile sgi --region us-east-1
```

Descargue el ZIP de la rama desde GitHub, extráigalo en una carpeta de su usuario y abra PowerShell en esa carpeta. No necesita descargar los submódulos ni compilar la aplicación en su PC; se compilan en EC2. Si tiene Git, también puede clonar la rama como en el ejemplo de CloudShell.

Primero compruebe la sesión, la elegibilidad, la AMI oficial y el permiso de crear una VPC. `-CheckOnly` no genera claves ni crea recursos; la comprobación de permisos usa `--dry-run`:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\deploy\aws\provision.ps1 -Profile sgi -Region us-east-1 -CheckOnly
```

`ExecutionPolicy Bypass` se limita a ese proceso y no cambia la política del equipo. Revise antes el script descargado. La comprobación previa no garantiza todos los permisos necesarios para crear el stack ni sustituye revisar el plan y el crédito.

Para crear el entorno y dejar pendiente la recuperación de datos:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\deploy\aws\provision.ps1 -Profile sgi -Region us-east-1 -Mode restore
```

Solo para una instalación nueva, use `-Mode fresh`. El script usa la misma plantilla y versiones de la aplicación que la ruta de CloudShell; crea recursos que consumen crédito. Necesita OpenSSH (`ssh` y `ssh-keygen`, incluidos habitualmente en Windows 10/11) para crear la clave y conectarse. Se permite SSH desde la IPv4 pública detectada de su PC y la clave queda en `%USERPROFILE%\.ssh\sgi-fiis-equipo-aws`, con permisos limitados a su usuario. Si el stack ya existe, se muestran sus datos sin actualizarlo ni regenerar la clave.

Al finalizar, ejecute el comando SSH que muestra el script para esperar a `cloud-init`; después abra el túnel que muestra para acceder a `http://localhost:8080`. Como creó el entorno desde su PC, no necesita descargar una clave desde CloudShell ni añadir la IP de CloudShell al grupo de seguridad.

Si EC2 o CloudFormation responden que la cuenta todavía no está activada, ejecutar la CLI local no elimina ese bloqueo. Si recibe `AccessDenied` o `UnauthorizedOperation`, revise los permisos de su identidad. Los problemas persistentes de activación se tramitan con [AWS Support](https://console.aws.amazon.com/support/) en Cuenta y facturación. Referencias: [inicio de sesión local](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sign-in.html) y [comprobación sin crear una VPC](https://docs.aws.amazon.com/cli/latest/reference/ec2/create-vpc.html).

## Qué crea el comando

- Una VPC, subred pública, Internet Gateway y ruta; no requiere una VPC predeterminada.
- Reglas de SSH limitadas a una IPv4 `/32` y puertos 80/443 para HTTPS.
- Un par SSH ed25519 generado en la terminal; AWS recibe únicamente la clave pública.
- Una instancia `t3.small` con Ubuntu 24.04 oficial, CPU Standard y metadatos IMDSv2.
- Un disco gp3 de 30 GiB cifrado y una IPv4 pública.
- Docker, las imágenes de la aplicación y la configuración privada inicial.

El script consulta la AMI actual en el Parameter Store público de Canonical, comprueba su propietario y arquitectura, y exige que la AMI y `t3.small` estén marcadas como elegibles. Estos controles no sustituyen revisar el saldo ni garantizan coste cero. Los recursos comienzan a consumir crédito al crearse; CloudFormation no añade cargos por gestionar estos recursos nativos de AWS.

La instalación utiliza el commit de integración ya validado `510cfda533dfd1e96f15ea8e79576ed2ac5cbaf7`, con las revisiones fijadas del backend y frontend. El script no actualiza un stack existente: si encuentra el mismo nombre, muestra sus recursos y conserva su clave e instancia. La actualización de la aplicación se hace por SSH con el procedimiento de respaldo de la guía principal.

## Esperar a que termine Ubuntu

CloudFormation puede indicar `CREATE_COMPLETE` antes de que termine la instalación del software. El script muestra la IP y un comando como este; sustituya `IP_PUBLICA` por el valor real:

```bash
ssh -o StrictHostKeyChecking=accept-new -i "$HOME/.ssh/sgi-fiis-equipo-aws" ubuntu@IP_PUBLICA 'sudo cloud-init status --wait'
```

Si SSH todavía no responde, vuelva a ejecutar ese comando cuando la instancia termine de arrancar. Para revisar un fallo de instalación:

```bash
ssh -i "$HOME/.ssh/sgi-fiis-equipo-aws" ubuntu@IP_PUBLICA 'sudo tail -n 100 /var/log/sgi-fiis-provision.log'
```

Después entre por SSH:

```bash
ssh -i "$HOME/.ssh/sgi-fiis-equipo-aws" ubuntu@IP_PUBLICA
cd SGI-FIIS-integration
docker compose --env-file .env.aws -f docker-compose.aws.yml ps
```

En modo `restore`, continúe con la [recuperación de datos](README.md#4-elegir-la-ruta-de-datos). En modo `fresh`, la web está disponible de forma privada en el puerto 80 del servidor; para comprobar PostgreSQL puede usar `curl -fsS http://localhost/health` dentro de EC2.

## Acceder desde su PC

Por defecto se permite SSH desde la IP de la terminal que ejecutó el script. Si fue CloudShell, el túnel se abriría en CloudShell, no en Windows. Para usar su navegador local:

1. Descargue la clave desde **CloudShell → Actions → Download file**. La ruta que debe descargar se obtiene con `echo "$HOME/.ssh/sgi-fiis-equipo-aws"`. Consérvela en privado.
2. Obtenga su IPv4 desde PowerShell:

```powershell
(Invoke-RestMethod https://checkip.amazonaws.com).Trim()
```

3. En CloudShell, permita esa IP en el grupo creado. Sustituya `IP_DE_SU_PC`:

```bash
SGI_GROUP=$(aws cloudformation describe-stacks --region us-east-1 --stack-name sgi-fiis-equipo --query 'Stacks[0].Outputs[?OutputKey==`SecurityGroupId`].OutputValue | [0]' --output text)
aws ec2 authorize-security-group-ingress --region us-east-1 --group-id "$SGI_GROUP" --protocol tcp --port 22 --cidr IP_DE_SU_PC/32
```

4. En PowerShell, abra el túnel con la clave descargada:

```powershell
ssh -i "C:\ruta\sgi-fiis-equipo-aws" -L 8080:127.0.0.1:80 ubuntu@IP_PUBLICA
```

Abra `http://localhost:8080` en su PC. Para compartir una URL con el equipo, continúe con la [configuración de DNS y HTTPS](README.md#6-publicar-una-url-con-https). El comando de infraestructura conserva el acceso inicial privado y no compra ni registra un dominio.

También puede indicar la IP de su PC desde el inicio con `--ssh-cidr IP_DE_SU_PC/32`. En ese caso deberá hacer las conexiones SSH desde ese PC. Si cambia la IP del administrador o la de CloudShell, ajuste la regla SSH `/32` del grupo correspondiente.

## Requisitos y conservación de datos

Se necesita AWS CLI v2, Bash, Python 3, curl y OpenSSH, disponibles en CloudShell. Su identidad AWS necesita leer AMIs y parámetros públicos SSM, consultar tipos/zonas EC2 y crear los recursos EC2/VPC y el stack CloudFormation. No se crea un usuario IAM ni se envían credenciales AWS a la instancia. Si AWS rechaza una operación por permisos o por su plan, el script muestra el error y no cambia su plan de facturación.

El nombre predeterminado del stack es `sgi-fiis-equipo`; puede usar `--stack OTRO_NOMBRE` para un entorno deliberadamente separado. Crear otro nombre crea otro conjunto de recursos y consume crédito adicional.

El disco tiene `DeleteOnTermination=false`: eliminar el stack o terminar la instancia conserva el disco, que continúa consumiendo recursos. Antes de cerrar el entorno, descargue sus copias, anote el ID del volumen y decida expresamente si conservarlo o eliminarlo. No utilice una actualización de CloudFormation como sustituto de la migración de datos o del procedimiento de actualización de la aplicación.

Validación sin cuenta AWS: `cfn-lint deploy/aws/ec2.yaml`, `bash -n deploy/aws/provision.sh` y `python3 -m unittest discover -s tests -p 'test_aws_provision.py'`. Las pruebas sustituyen la CLI por un simulador y no crean infraestructura. La creación real y `cloud-init` deben comprobarse en la cuenta donde se ejecute.

Referencias: [AWS CloudShell](https://docs.aws.amazon.com/cloudshell/latest/userguide/welcome.html), [CloudFormation y Ubuntu](https://ubuntu.com/aws/docs/aws-how-to/instances/build-cloudformation-templates/), [KeyPair](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-ec2-keypair.html) y [precios de CloudFormation](https://aws.amazon.com/cloudformation/pricing/).
