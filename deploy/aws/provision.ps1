#requires -Version 5.1
<#
.SYNOPSIS
Create the SGI-FIIS EC2 stack from Windows PowerShell or PowerShell 7.
.DESCRIPTION
Authenticate first: aws login --profile sgi --region us-east-1
Use -CheckOnly to validate without creating keys or AWS resources.
The default mode is restore. Use -Mode fresh only for a new installation.
EC2, EBS and the public IPv4 consume AWS credit. Existing stacks are never updated.
#>
[CmdletBinding()]
param(
    [ValidateSet('restore', 'fresh')][string]$Mode = 'restore',
    [ValidatePattern('^[a-z0-9-]+$')][string]$Region = 'us-east-1',
    [Alias('Profile')][ValidatePattern('^[A-Za-z0-9_.-]+$')][string]$AwsProfile = 'sgi',
    [ValidatePattern('^[A-Za-z][A-Za-z0-9-]{0,79}$')][string]$StackName = 'sgi-fiis-equipo',
    [string]$SshCidr = '',
    [string]$KeyFile = '',
    [switch]$CheckOnly
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$templatePath = Join-Path $PSScriptRoot 'ec2.yaml'
if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) { throw 'Falta ec2.yaml junto al script.' }
$null = Get-Command aws -ErrorAction Stop
$script:SgiAwsOptions = @('--profile', $AwsProfile, '--region', $Region, '--no-cli-pager', '--no-cli-auto-prompt')
if (-not $KeyFile) {
    $KeyFile = Join-Path ([Environment]::GetFolderPath('UserProfile')) ".ssh/$StackName-aws"
}
$KeyFile = [IO.Path]::GetFullPath($KeyFile)

function Invoke-SgiAws {
    param([string[]]$AwsArguments, [switch]$AllowFailure)
    # Windows PowerShell turns native stderr into ErrorRecord objects.
    $ErrorActionPreference = 'Continue'
    $lines = @(& aws @script:SgiAwsOptions @AwsArguments 2>&1)
    $code = $LASTEXITCODE
    $message = ($lines | ForEach-Object { $_.ToString() }) -join "`n"
    if ($code -ne 0 -and -not $AllowFailure) { throw $message }
    return [pscustomobject]@{ Code = $code; Text = $message }
}

function Show-SgiStack {
    $result = Invoke-SgiAws -AwsArguments @('cloudformation', 'describe-stacks', '--stack-name', $StackName, '--output', 'json')
    $stack = ($result.Text | ConvertFrom-Json).Stacks[0]
    Write-Host "Estado: $($stack.StackStatus)"
    $outputs = @()
    if ($stack.PSObject.Properties['Outputs']) { $outputs = @($stack.Outputs) }
    $outputs | Format-Table OutputKey, OutputValue -AutoSize | Out-Host
    $publicIp = @($outputs | Where-Object { $_.OutputKey -eq 'PublicIp' } | Select-Object -ExpandProperty OutputValue)
    if ($publicIp.Count -gt 0) {
        Write-Host "`nCREATE_COMPLETE solo confirma la infraestructura. Espere la instalacion:"
        Write-Host "ssh -o StrictHostKeyChecking=accept-new -i `"$KeyFile`" ubuntu@$($publicIp[0]) 'sudo cloud-init status --wait'"
        Write-Host "`nDespues abra el tunel y visite http://localhost:8080 en su PC:"
        Write-Host "ssh -i `"$KeyFile`" -L 8080:127.0.0.1:80 ubuntu@$($publicIp[0])"
    }
}

$null = Invoke-SgiAws -AwsArguments @('sts', 'get-caller-identity', '--output', 'json')
$existing = Invoke-SgiAws -AwsArguments @('cloudformation', 'describe-stacks', '--stack-name', $StackName, '--output', 'json') -AllowFailure
if ($existing.Code -eq 0) {
    Write-Host 'El stack ya existe. Se conservan sus recursos y su clave; no se actualiza.'
    Show-SgiStack
    return
}
if ($existing.Text -notmatch 'does not exist') { throw $existing.Text }

if (-not $SshCidr) { $SshCidr = ((Invoke-RestMethod 'https://checkip.amazonaws.com').Trim()) + '/32' }
if ($SshCidr -notmatch '^(\d{1,3}\.){3}\d{1,3}/32$') { throw 'SSH requiere una unica IPv4 publica con /32.' }
$octets = @($SshCidr.Split('/')[0].Split('.') | ForEach-Object { [int]$_ })
if (@($octets | Where-Object { $_ -gt 255 }).Count -gt 0 -or
    $octets[0] -in @(0, 10, 127) -or $octets[0] -ge 224 -or
    ($octets[0] -eq 100 -and $octets[1] -ge 64 -and $octets[1] -le 127) -or
    ($octets[0] -eq 169 -and $octets[1] -eq 254) -or
    ($octets[0] -eq 172 -and $octets[1] -ge 16 -and $octets[1] -le 31) -or
    ($octets[0] -eq 192 -and ($octets[1] -eq 168 -or ($octets[1] -eq 0 -and $octets[2] -in @(0, 2)))) -or
    ($octets[0] -eq 198 -and ($octets[1] -in @(18, 19) -or ($octets[1] -eq 51 -and $octets[2] -eq 100))) -or
    ($octets[0] -eq 203 -and $octets[1] -eq 0 -and $octets[2] -eq 113)) {
    throw 'SSH requiere una IPv4 publica, no una red privada o reservada.'
}
$eligible = Invoke-SgiAws -AwsArguments @('ec2', 'describe-instance-types', '--instance-types', 't3.small', '--query', 'InstanceTypes[0].FreeTierEligible', '--output', 'text')
if ($eligible.Text.Trim() -ne 'True') { throw 'AWS no marca t3.small como elegible. Revise plan y credito.' }
$ami = Invoke-SgiAws -AwsArguments @('ssm', 'get-parameter', '--name', '/aws/service/canonical/ubuntu/server/noble/stable/current/amd64/hvm/ebs-gp3/ami-id', '--query', 'Parameter.Value', '--output', 'text')
$imageId = $ami.Text.Trim()
$imagesResult = Invoke-SgiAws -AwsArguments @('ec2', 'describe-images', '--image-ids', $imageId, '--output', 'json')
$images = @(($imagesResult.Text | ConvertFrom-Json).Images)
if ($images.Count -ne 1) { throw 'No se encontro una unica AMI de Ubuntu.' }
$image = $images[0]
if ($image.OwnerId -ne '099720109477' -or $image.Architecture -ne 'x86_64' -or $image.State -ne 'available') {
    throw 'La AMI no corresponde a Canonical x86_64 disponible.'
}
if ($image.FreeTierEligible -ne $true) { throw 'La AMI no esta marcada como elegible. Revise el plan.' }
$zoneResult = Invoke-SgiAws -AwsArguments @('ec2', 'describe-instance-type-offerings', '--location-type', 'availability-zone', '--filters', 'Name=instance-type,Values=t3.small', '--query', 'InstanceTypeOfferings[0].Location', '--output', 'text')
$zone = $zoneResult.Text.Trim()
if (-not $zone -or $zone -eq 'None') { throw 'No hay una zona disponible para t3.small.' }
$null = Invoke-SgiAws -AwsArguments @('cloudformation', 'validate-template', '--template-body', "file://$templatePath")
$dryRun = Invoke-SgiAws -AwsArguments @('ec2', 'create-vpc', '--cidr-block', '10.63.0.0/16', '--dry-run') -AllowFailure
if ($dryRun.Text -notmatch '\bDryRunOperation\b') { throw "No se pudo comprobar el permiso de creacion EC2: $($dryRun.Text)" }
Write-Host "Comprobacion correcta: perfil $AwsProfile, region $Region, t3.small, Ubuntu oficial, SSH $SshCidr, modo $Mode."
if ($CheckOnly) {
    Write-Host 'No se crearon claves ni recursos. Esto no garantiza coste cero ni todos los permisos del stack.'
    return
}

$null = Get-Command ssh-keygen -ErrorAction Stop
$newKey = -not (Test-Path -LiteralPath $KeyFile) -and -not (Test-Path -LiteralPath "$KeyFile.pub")
$legacyArguments = $PSVersionTable.PSVersion.Major -lt 7 -or
    ((Get-Variable PSNativeCommandArgumentPassing -ErrorAction SilentlyContinue) -and $PSNativeCommandArgumentPassing -eq 'Legacy')
$emptyPassphrase = ''
if ($legacyArguments) { $emptyPassphrase = '""' }
if ($newKey) {
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $KeyFile) -Force
    & ssh-keygen -q -t ed25519 -N $emptyPassphrase -C $StackName -f $KeyFile
    if ($LASTEXITCODE -ne 0) { throw 'No se pudo generar la clave SSH.' }
} elseif (-not (Test-Path -LiteralPath $KeyFile -PathType Leaf) -or -not (Test-Path -LiteralPath "$KeyFile.pub" -PathType Leaf)) {
    throw 'Falta una parte del par SSH. Recupere la clave original; no se sobrescribira.'
}
if ($env:OS -eq 'Windows_NT') {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $acl = New-Object Security.AccessControl.FileSecurity
    $acl.SetOwner($identity.User)
    $acl.SetAccessRuleProtection($true, $false)
    $rule = New-Object Security.AccessControl.FileSystemAccessRule($identity.User, 'FullControl', 'Allow')
    $acl.AddAccessRule($rule)
    Set-Acl -LiteralPath $KeyFile -AclObject $acl
} else {
    & chmod 600 $KeyFile
    if ($LASTEXITCODE -ne 0) { throw 'No se pudieron limitar los permisos de la clave.' }
}
$derived = @(& ssh-keygen -y -P $emptyPassphrase -f $KeyFile)
if ($LASTEXITCODE -ne 0) { throw 'No se pudo leer la clave SSH. Se requiere una clave sin frase de paso.' }
$derived = (($derived -join '').Trim() -split '\s+')[0..1] -join ' '
$publicKey = (Get-Content -LiteralPath "$KeyFile.pub" -Raw).Trim()
if ($publicKey -notmatch '^ssh-ed25519 [A-Za-z0-9+/=]+( .*)?$' -or
    (($publicKey -split '\s+')[0..1] -join ' ') -cne $derived) { throw 'El par SSH ed25519 no coincide.' }
$values = [ordered]@{
    ImageId = $imageId; RootDeviceName = $image.RootDeviceName; AvailabilityZone = $zone
    SshCidr = $SshCidr; SshPublicKey = $publicKey; DataMode = $Mode
}
$parameters = @($values.GetEnumerator() | ForEach-Object { @{ ParameterKey = $_.Key; ParameterValue = $_.Value } })
$parameterFile = Join-Path ([IO.Path]::GetTempPath()) ("sgi-fiis-" + [Guid]::NewGuid().ToString('N') + '.json')
try {
    [IO.File]::WriteAllText($parameterFile, ($parameters | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
    Write-Host "Creando ${StackName}: una t3.small, disco cifrado gp3 de 30 GiB y una IPv4 publica."
    Write-Host 'Consumen credito AWS. El disco se conserva al eliminar la instancia y sigue consumiendo recursos.'
    $null = Invoke-SgiAws -AwsArguments @('cloudformation', 'create-stack', '--stack-name', $StackName, '--template-body', "file://$templatePath", '--parameters', "file://$parameterFile", '--tags', 'Key=Project,Value=sgi-fiis', '--output', 'json')
    $null = Invoke-SgiAws -AwsArguments @('cloudformation', 'wait', 'stack-create-complete', '--stack-name', $StackName)
    Show-SgiStack
} finally {
    if (Test-Path -LiteralPath $parameterFile) { Remove-Item -LiteralPath $parameterFile -Force }
}
Write-Host 'Conserve la clave privada. No la suba a GitHub ni la comparta en el chat.'
