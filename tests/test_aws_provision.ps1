# Exercise the Windows entry point with a fake AWS command. No AWS API is called.
#requires -Version 5.1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot '../deploy/aws/provision.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('sgi fiis tests ' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $testRoot
$script:failed = 0
$script:passed = 0

function global:aws {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$AwsArguments)
    $a = @($AwsArguments)
    if ($a[0] -ne '--profile' -or $a[1] -ne 'sgi' -or $a[2] -ne '--region' -or $a[3] -ne 'us-east-1') {
        throw 'The selected profile and region must be passed to every AWS call.'
    }
    $a = @($a | Select-Object -Skip 6)
    $null = $global:SgiFakeLog.Add([pscustomobject]@{ Command = $a })
    $global:LASTEXITCODE = 0
    switch ("$($a[0]) $($a[1])") {
        'sts get-caller-identity' { return '{"Account":"123456789012"}' }
        'cloudformation describe-stacks' {
            if ($global:SgiFakeMode -eq 'denied') { $global:LASTEXITCODE = 255; return 'AccessDenied: not authorized' }
            if ($global:SgiFakeMode -ne 'existing' -and -not $global:SgiFakeCreated) {
                $global:LASTEXITCODE = 255; return 'ValidationError: Stack does not exist'
            }
            return '{"Stacks":[{"StackStatus":"CREATE_COMPLETE","Outputs":[{"OutputKey":"PublicIp","OutputValue":"203.0.113.10"}]}]}'
        }
        'ec2 describe-instance-types' { if ($global:SgiFakeMode -eq 'ineligible') { return 'False' }; return 'True' }
        'ssm get-parameter' { return 'ami-0123456789abcdef0' }
        'ec2 describe-images' {
            $owner = '099720109477'
            if ($global:SgiFakeMode -eq 'wrong-owner') { $owner = '000000000000' }
            return (@{ Images = @(@{ OwnerId = $owner; Architecture = 'x86_64'; State = 'available'; FreeTierEligible = $true; RootDeviceName = '/dev/sda1' }) } | ConvertTo-Json -Depth 4)
        }
        'ec2 describe-instance-type-offerings' { return 'us-east-1a' }
        'cloudformation validate-template' { return '{}' }
        'ec2 create-vpc' {
            if ('--dry-run' -notin $a) { throw 'Creating a VPC outside CloudFormation is forbidden.' }
            $global:LASTEXITCODE = 255
            if ($global:SgiFakeMode -eq 'dry-denied') { return 'UnauthorizedOperation: not authorized' }
            return 'An error occurred (DryRunOperation): Request would have succeeded, but DryRun flag is set.'
        }
        'cloudformation create-stack' {
            $path = $a[[Array]::IndexOf($a, '--parameters') + 1].Substring(7)
            $global:SgiFakeParameters = [IO.File]::ReadAllText($path)
            if ([IO.File]::ReadAllBytes($path)[0] -eq 239) { throw 'Parameter JSON must not contain a UTF-8 BOM.' }
            $global:SgiFakeCreated = $true
            return '{"StackId":"test-stack"}'
        }
        'cloudformation wait' { return '' }
        default { throw "Unexpected AWS request: $($a -join ' ')" }
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Assert-NoCreate {
    Assert-True (-not $global:SgiFakeCreated) 'The stack must not be created.'
}
function Assert-Fails {
    param([scriptblock]$Body, [string]$Expected)
    $caught = $null
    try { & $Body } catch { $caught = $_ }
    Assert-True ($null -ne $caught) 'The operation should have failed.'
    Assert-True ($caught.ToString() -match $Expected) "Unexpected failure: $caught"
    Assert-NoCreate
}
function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    $global:SgiFakeMode = 'new'
    $global:SgiFakeCreated = $false
    $global:SgiFakeParameters = ''
    $global:SgiFakeLog = New-Object 'System.Collections.Generic.List[object]'
    $script:keyFile = Join-Path $testRoot ($Name + '/admin key')
    $script:options = @{ Profile = 'sgi'; Region = 'us-east-1'; SshCidr = '8.8.8.8/32'; KeyFile = $script:keyFile }
    try {
        & $Body
        $script:passed++
        Write-Host "PASS: $Name"
    } catch {
        $script:failed++
        Write-Host "FAIL: $Name - $_"
        Write-Host $_.ScriptStackTrace
    }
}

try {
    Test-Case 'check-only creates no resources or keys' {
        & $scriptPath @options -CheckOnly
        Assert-NoCreate
        Assert-True (-not (Test-Path -LiteralPath $keyFile)) 'No key should be created.'
    }
    Test-Case 'access denied is not a missing stack' {
        $global:SgiFakeMode = 'denied'
        Assert-Fails { & $scriptPath @options } 'AccessDenied'
    }
    Test-Case 'dry run denied prevents provisioning' {
        $global:SgiFakeMode = 'dry-denied'
        Assert-Fails { & $scriptPath @options } 'UnauthorizedOperation'
        Assert-True (-not (Test-Path -LiteralPath $keyFile)) 'No key should be created.'
    }
    Test-Case 'ineligible instance prevents provisioning' {
        $global:SgiFakeMode = 'ineligible'
        Assert-Fails { & $scriptPath @options } 'elegible'
    }
    Test-Case 'wrong AMI owner prevents provisioning' {
        $global:SgiFakeMode = 'wrong-owner'
        Assert-Fails { & $scriptPath @options } 'Canonical'
    }
    Test-Case 'existing stack is never updated' {
        $global:SgiFakeMode = 'existing'
        & $scriptPath @options -Mode fresh
        Assert-NoCreate
        Assert-True ($global:SgiFakeLog.Count -eq 3) 'Existing stacks should only be read.'
        Assert-True (-not (Test-Path -LiteralPath $keyFile)) 'The original key must be retained.'
    }
    Test-Case 'wide SSH network is rejected' {
        $options.SshCidr = '0.0.0.0/0'
        Assert-Fails { & $scriptPath @options } 'IPv4'
    }
    Test-Case 'private SSH address is rejected' {
        $options.SshCidr = '192.168.1.10/32'
        Assert-Fails { & $scriptPath @options } 'IPv4'
    }
    Test-Case 'partial SSH key is preserved' {
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $keyFile) -Force
        [IO.File]::WriteAllText($keyFile, 'original-key-material')
        Assert-Fails { & $scriptPath @options } 'parte del par'
        Assert-True ([IO.File]::ReadAllText($keyFile) -eq 'original-key-material') 'Existing material must not be overwritten.'
    }
    Test-Case 'new stack defaults to restore and imports only public key' {
        & $scriptPath @options
        Assert-True $global:SgiFakeCreated 'The simulated stack should be created.'
        $params = @{}
        foreach ($parameter in ($global:SgiFakeParameters | ConvertFrom-Json)) {
            $params[$parameter.ParameterKey] = $parameter.ParameterValue
        }
        Assert-True ($params.DataMode -eq 'restore') 'Restore must be the default.'
        Assert-True ($params.SshPublicKey -match '^ssh-ed25519 ') 'Only an ed25519 public key should be imported.'
        Assert-True ($global:SgiFakeParameters -notmatch 'PRIVATE KEY') 'Private material must not be sent to AWS.'
        Assert-True (Test-Path -LiteralPath $keyFile) 'The private key must be retained locally.'
        if ($env:OS -eq 'Windows_NT') {
            $acl = Get-Acl -LiteralPath $keyFile
            Assert-True $acl.AreAccessRulesProtected 'Key permissions should not inherit other users.'
            Assert-True ($acl.Access.Count -eq 1) 'Only the current user should have explicit key access.'
        }
    }
    Test-Case 'fresh requires an explicit mode' {
        & $scriptPath @options -Mode fresh
        $parsed = $global:SgiFakeParameters | ConvertFrom-Json
        $mode = @($parsed | Where-Object { $_.ParameterKey -eq 'DataMode' })[0].ParameterValue
        Assert-True ($mode -eq 'fresh') 'Explicit fresh mode must be forwarded.'
    }
} finally {
    Remove-Item Function:\aws -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
Write-Host "$script:passed passed, $script:failed failed. No AWS resources created."
if ($script:failed -ne 0) { throw 'Provisioning contract tests failed.' }
