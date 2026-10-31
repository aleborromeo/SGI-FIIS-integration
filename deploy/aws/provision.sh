#!/usr/bin/env bash
# Run in AWS CloudShell or Bash with an authenticated AWS CLI v2 session.
set -euo pipefail
SGI_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
region=us-east-1
stack_name=sgi-fiis-equipo
data_mode=restore
ssh_cidr=""
key_file=""
usage() {
  cat <<'HELP'
Uso: bash deploy/aws/provision.sh [opciones]
  --mode restore|fresh    restore conserva pendiente la recuperacion de datos (predeterminado).
  --region REGION        us-east-1 de forma predeterminada.
  --stack NAME           sgi-fiis-equipo de forma predeterminada.
  --ssh-cidr IP/32        IP del equipo que ejecutara SSH; detecta la IP de esta terminal si se omite.
  --key-file RUTA         Clave privada ed25519; crea una nueva solo para un stack nuevo.

Crea recursos EC2/EBS/IPv4 que consumen credito AWS. No actualiza stacks existentes.
HELP
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode|--region|--stack|--ssh-cidr|--key-file)
      [[ $# -ge 2 && -n "$2" ]] || { usage >&2; exit 1; }
      case "$1" in
        --mode) data_mode="$2" ;;
        --region) region="$2" ;;
        --stack) stack_name="$2" ;;
        --ssh-cidr) ssh_cidr="$2" ;;
        --key-file) key_file="$2" ;;
      esac
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 1 ;;
  esac
done
[[ "$data_mode" == restore || "$data_mode" == fresh ]] || { echo 'Modo invalido.' >&2; exit 1; }
[[ "$stack_name" =~ ^[A-Za-z][A-Za-z0-9-]{0,79}$ ]] || { echo 'Nombre de stack invalido.' >&2; exit 1; }
[[ "$region" =~ ^[a-z0-9-]+$ ]] || { echo 'Region invalida.' >&2; exit 1; }
for program in aws python3 curl ssh-keygen; do
  command -v "$program" >/dev/null || { echo "Falta $program. Use AWS CloudShell." >&2; exit 1; }
done
aws_cmd=(aws --region "$region" --no-cli-pager)
umask 077
work_dir="$(mktemp -d)"
trap 'rm -rf -- "$work_dir"' EXIT
if [[ -z "$key_file" ]]; then
  key_file="$HOME/.ssh/$stack_name-aws"
fi
show_outputs() {
  "${aws_cmd[@]}" cloudformation describe-stacks --stack-name "$stack_name" --query 'Stacks[0].Outputs' --output table
  public_ip="$("${aws_cmd[@]}" cloudformation describe-stacks --stack-name "$stack_name" --query 'Stacks[0].Outputs[?OutputKey==`PublicIp`].OutputValue | [0]' --output text)"
  if [[ "$public_ip" != None && -n "$public_ip" ]]; then
    printf '\nEsperar instalacion (CREATE_COMPLETE solo confirma la infraestructura):\n'
    printf 'ssh -o StrictHostKeyChecking=accept-new -i %q ubuntu@%q "sudo cloud-init status --wait"\n' "$key_file" "$public_ip"
    printf '\nAbrir tunel para probar desde la misma maquina que ejecuta SSH:\n'
    printf 'ssh -i %q -L 8080:127.0.0.1:80 ubuntu@%q\n' "$key_file" "$public_ip"
  fi
}
"${aws_cmd[@]}" sts get-caller-identity --output json >/dev/null
if "${aws_cmd[@]}" cloudformation describe-stacks --stack-name "$stack_name" --output json > "$work_dir/stack.json" 2> "$work_dir/error"; then
  echo 'El stack ya existe. Se muestran sus recursos sin modificarlo ni generar otra clave.'
  show_outputs
  exit 0
elif ! grep -q 'does not exist' "$work_dir/error"; then
  cat "$work_dir/error" >&2
  exit 1
fi
if [[ -z "$ssh_cidr" ]]; then
  ssh_cidr="$(curl -fsS https://checkip.amazonaws.com)/32"
fi
python3 - "$ssh_cidr" <<'PY'
import ipaddress, sys
network = ipaddress.ip_network(sys.argv[1], strict=True)
if network.version != 4 or network.prefixlen != 32 or not network.network_address.is_global:
    raise SystemExit('SSH requiere una direccion IPv4 publica unica con /32.')
PY
eligible="$("${aws_cmd[@]}" ec2 describe-instance-types --instance-types t3.small --query 'InstanceTypes[0].FreeTierEligible' --output text)"
[[ "$eligible" == True || "$eligible" == true ]] || {
  echo 'AWS no marca t3.small como elegible en esta cuenta/region. Revise plan y credito antes de elegir otro tipo.' >&2
  exit 1
}
image_id="$("${aws_cmd[@]}" ssm get-parameter --name /aws/service/canonical/ubuntu/server/noble/stable/current/amd64/hvm/ebs-gp3/ami-id --query Parameter.Value --output text)"
"${aws_cmd[@]}" ec2 describe-images --image-ids "$image_id" --output json > "$work_dir/image.json"
root_device="$(python3 - "$work_dir/image.json" <<'PY'
import json, sys
images = json.load(open(sys.argv[1], encoding='utf-8'))['Images']
if len(images) != 1:
    raise SystemExit('No se encontro la AMI de Ubuntu.')
image = images[0]
if image.get('OwnerId') != '099720109477' or image.get('Architecture') != 'x86_64' or image.get('State') != 'available':
    raise SystemExit('La AMI no corresponde a Canonical x86_64 disponible.')
if image.get('FreeTierEligible') is not True:
    raise SystemExit('La AMI no esta marcada como elegible. Revise el plan antes de continuar.')
print(image['RootDeviceName'])
PY
)"
availability_zone="$("${aws_cmd[@]}" ec2 describe-instance-type-offerings --location-type availability-zone --filters Name=instance-type,Values=t3.small --query 'InstanceTypeOfferings[0].Location' --output text)"
[[ -n "$availability_zone" && "$availability_zone" != None ]] || { echo 'No hay zona disponible para t3.small.' >&2; exit 1; }
"${aws_cmd[@]}" cloudformation validate-template --template-body "file://$SGI_ROOT/deploy/aws/ec2.yaml" >/dev/null
if [[ ! -e "$key_file" && ! -e "$key_file.pub" ]]; then
  mkdir -p -- "$(dirname -- "$key_file")"
  ssh-keygen -q -t ed25519 -N '' -C "$stack_name" -f "$key_file"
elif [[ ! -f "$key_file" || ! -f "$key_file.pub" ]]; then
  echo 'Falta una parte del par SSH. Recupere la clave original; no se sobrescribira.' >&2
  exit 1
fi
chmod 600 "$key_file"
derived_key="$(ssh-keygen -y -f "$key_file" | awk '{print $1 " " $2}')"
stored_key="$(awk '{print $1 " " $2}' "$key_file.pub")"
[[ "$derived_key" == "$stored_key" && "$derived_key" == ssh-ed25519\ * ]] || { echo 'El par SSH ed25519 no coincide.' >&2; exit 1; }
python3 - "$image_id" "$root_device" "$availability_zone" "$ssh_cidr" "$key_file.pub" "$data_mode" "$work_dir/parameters.json" <<'PY'
import json, sys
from pathlib import Path
image, root, zone, cidr, key, mode, output = sys.argv[1:]
values = {'ImageId': image, 'RootDeviceName': root, 'AvailabilityZone': zone,
          'SshCidr': cidr, 'SshPublicKey': Path(key).read_text().strip(), 'DataMode': mode}
Path(output).write_text(json.dumps([{'ParameterKey': k, 'ParameterValue': v} for k,v in values.items()]), encoding='utf-8')
PY
echo "Creando $stack_name en $region: una t3.small, disco cifrado gp3 de 30 GiB y una IPv4 publica."
echo "SSH permitido desde $ssh_cidr. El disco se conserva si elimina la instancia y sigue consumiendo recursos."
"${aws_cmd[@]}" cloudformation create-stack --stack-name "$stack_name" \
  --template-body "file://$SGI_ROOT/deploy/aws/ec2.yaml" \
  --parameters "file://$work_dir/parameters.json" \
  --tags Key=Project,Value=sgi-fiis --output json > "$work_dir/created.json"
"${aws_cmd[@]}" cloudformation wait stack-create-complete --stack-name "$stack_name"
show_outputs
echo 'Conserve la clave privada en un lugar seguro. No la suba a GitHub ni la comparta en el chat.'
