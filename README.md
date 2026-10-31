# SGI-FIIS: integración y despliegue

Este repositorio fija las versiones del backend y del frontend mediante submódulos Git. Para obtener ambos:

```bash
git clone --recurse-submodules https://github.com/aleborromeo/SGI-FIIS-integration.git
cd SGI-FIIS-integration
git submodule status
```

La [guía para desplegar en AWS EC2](deploy/aws/README.md) incluye la preparación de la cuenta, instalación, recuperación de datos, acceso del equipo, HTTPS, copias de respaldo y actualización del sistema. La configuración inicial escucha solo en localhost; se comprueba por un túnel SSH antes de publicarla.

También puede [crear la infraestructura por comandos desde CloudShell o PowerShell](deploy/aws/CLI.md), mediante AWS CLI y la plantilla CloudFormation del repositorio:

```bash
bash deploy/aws/provision.sh --region us-east-1 --mode restore
```

El workflow `Validate AWS deployment` construye las imágenes y comprueba PostgreSQL, la API, el frontend y el inicio de sesión en un entorno temporal. El despliegue anterior de Google Cloud queda disponible únicamente mediante ejecución manual.

No se deben subir `.env.aws`, claves SSH, respaldos ni credenciales al repositorio.
