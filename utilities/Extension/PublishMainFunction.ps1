###############################################################################
# Accelerator:  FabricCatalyst
# Script Name:  PublishMainFunction.ps1
# Description:  Local fast-track publish: packages the extension with tfx-cli
#               and publishes it to the Visual Studio Marketplace. The publish
#               token is read from Azure Key Vault using either the caller's
#               own Az context (interactive sign-in if no context exists yet)
#               or, when -servicePrincipalId/-servicePrincipalSecret/-tenantId
#               are supplied, a Service Principal - useful when your active
#               interactive session is signed into a different tenant than
#               the one hosting the Key Vault.
# Author:       Svenchio - https://techtacofriday.com
# Project:      https://fabriccatalyst.com
# Usage:        If executed as a Stand-alone script:
#               Step 1. Open a new PowerShell session from the root of the script
#               Step 2. PS> Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
#               Step 3. PS> .\PublishMainFunction.ps1
#
# Prerequisites (one-time, per machine cloning this branch):
#   - Az PowerShell modules:
#       Install-Module Az.Accounts, Az.KeyVault -Scope CurrentUser
#   - tfx-cli, which requires Node.js:
#       npm install -g tfx-cli
#   - Your account (or the Service Principal, if using -servicePrincipalId)
#     needs "Get" permission on secrets in the target Key Vault.
###############################################################################
param
(
    [parameter(Mandatory = $false)] [String] $keyVaultName = "fabcat-shared-d-kv",
    [parameter(Mandatory = $false)] [String] $secretName = "scrt-vsts-publish-token",
    # Pin to a specific secret version; omit to use the current version
    [parameter(Mandatory = $false)] [String] $secretVersion,

    [parameter(Mandatory = $false)] [String] $manifestPath = "$PSScriptRoot\..\..\vss-extension.json",
    [parameter(Mandatory = $false)] [String] $outputPath = "$PSScriptRoot\dist",

    # Provide an already-built .vsix to skip 'tfx extension create' and publish it directly
    [parameter(Mandatory = $false)] [String] $vsixPath,

    [parameter(Mandatory = $false)] [String] $tenantId,

    # Provide both to authenticate with a Service Principal instead of reusing/interactively
    # signing in with the caller's own Az context. Required together, and require -tenantId.
    [parameter(Mandatory = $false)] [String] $servicePrincipalId,
    [parameter(Mandatory = $false)] [String] $servicePrincipalSecret
)

$private = "$PSScriptRoot\..\..\tasks\shared\private"
. "$private\SharedFunctions.ps1"

try {
    Write-Message "Info" "Powershell version : $($PSVersionTable.PSVersion)"
    $scriptParams = $MyInvocation.MyCommand.Parameters.Keys
    $maxLength = ($scriptParams | Measure-Object -Maximum -Property Length).Maximum
    foreach ($param in $scriptParams) {
        $value = Get-Variable -Name $param -ValueOnly -ErrorAction SilentlyContinue
        $displayValue = if ([string]::IsNullOrEmpty($value)) { "empty" } else { $value }
        Write-Message "Info" ("{0,-$maxLength} : {1}" -f $param, $displayValue)
    }

    if (-not (Get-Command tfx -ErrorAction SilentlyContinue)) {
        throw "tfx-cli was not found on PATH. Install it with 'npm install -g tfx-cli' and retry."
    }
    if (-not (Get-Command Get-AzKeyVaultSecret -ErrorAction SilentlyContinue)) {
        throw "Az.KeyVault module was not found. Install it with 'Install-Module Az.Accounts, Az.KeyVault -Scope CurrentUser' and retry."
    }

    if (-not [string]::IsNullOrWhiteSpace($servicePrincipalId) -or -not [string]::IsNullOrWhiteSpace($servicePrincipalSecret)) {
        if ([string]::IsNullOrWhiteSpace($servicePrincipalId) -or [string]::IsNullOrWhiteSpace($servicePrincipalSecret) -or [string]::IsNullOrWhiteSpace($tenantId)) {
            throw "-servicePrincipalId, -servicePrincipalSecret and -tenantId must all be supplied together."
        }
        # Always connect fresh with the SPN, even if an interactive context already exists for a
        # different tenant - the Key Vault lives in a specific tenant regardless of what the
        # caller is currently signed into elsewhere.
        Write-Message "Action" "Connecting to Azure using Service Principal '$servicePrincipalId' on tenant '$tenantId'"
        $secureSecret = ConvertTo-SecureString $servicePrincipalSecret -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential($servicePrincipalId, $secureSecret)
        Connect-AzAccount -ServicePrincipal -Credential $credential -Tenant $tenantId | Out-Null
    }
    elseif ($null -eq (Get-AzContext -ErrorAction SilentlyContinue)) {
        if (-not [string]::IsNullOrWhiteSpace($tenantId)) {
            Write-Message "Action" "Connecting interactively on tenant '$tenantId'"
            Connect-AzAccount -Tenant $tenantId | Out-Null
        }
        else {
            Write-Message "Action" "Connecting interactively"
            Connect-AzAccount | Out-Null
        }
    }
    else {
        Write-Message "Info" "Reusing existing Az context ($((Get-AzContext).Account))"
    }

    Write-Message "Action" "Fetching publish token from Key Vault '$keyVaultName' (secret '$secretName')"
    $secretParams = @{ VaultName = $keyVaultName; Name = $secretName; AsPlainText = $true }
    if (-not [string]::IsNullOrWhiteSpace($secretVersion)) { $secretParams.Version = $secretVersion }
    $patToken = Get-AzKeyVaultSecret @secretParams
    if ([string]::IsNullOrWhiteSpace($patToken)) {
        throw "Secret '$secretName' in vault '$keyVaultName' returned no value."
    }

    if ([string]::IsNullOrWhiteSpace($vsixPath)) {
        if (-not (Test-Path $manifestPath)) {
            throw "Manifest not found at '$manifestPath'."
        }

        Write-Message "Action" "Packaging extension: tfx extension create"
        tfx extension create --manifest-globs "$manifestPath" --output-path "$outputPath"
        if ($LASTEXITCODE -ne 0) { throw "tfx extension create failed with exit code $LASTEXITCODE." }

        $vsix = Get-ChildItem -Path $outputPath -Filter *.vsix | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($null -eq $vsix) { throw "No .vsix file was produced in '$outputPath'." }
        $vsixPath = $vsix.FullName
    }
    else {
        if (-not (Test-Path $vsixPath)) { throw ".vsix not found at '$vsixPath'." }
        Write-Message "Info" "Skipping package step, publishing existing package '$vsixPath'"
    }

    Write-Message "Action" "Publishing extension: tfx extension publish"
    tfx extension publish --vsix "$vsixPath" --token "$patToken"
    if ($LASTEXITCODE -ne 0) { throw "tfx extension publish failed with exit code $LASTEXITCODE." }

    Write-Message "Info" "Script execution completed successfully."
}
catch {
    $errorResponse = Get-ErrorResponse($_)
    Write-Message "Error" "$($errorResponse). Powershell script PublishMainFunction failed to complete"
    exit 1
}
