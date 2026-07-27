###############################################################################
# Accelerator:  FabricCatalyst
# Script Name:  AddAzDOEnvMainFunction.ps1
# Description:  Provisions an Azure DevOps Environment: creates it if missing,
#               syncs Administrators (the running identity plus a configurable
#               set of co-administrators), and optionally configures a single
#               approver check.
# Author:       Svenchio - https://techtacofriday.com
# Project:      https://fabriccatalyst.com
# Usage:        If executed as a Stand-alone script:
#               Step 1. Open a new PowerShell session from the root of the script
#               Step 2. PS> Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
#               Step 3  PS> .\AddAzDOEnvMainFunction.ps1
###############################################################################
param
(
    [parameter(Mandatory = $true)]  [String] $organizationName,
    [parameter(Mandatory = $true)]  [String] $projectName,
    [parameter(Mandatory = $true)]  [String] $environmentName,
    [parameter(Mandatory = $false)] [String] $description = "",
    # semicolon-separated list of UPNs/group names to grant Administrator, in addition to the caller
    [parameter(Mandatory = $false)] [String] $coAdministrators = "",
    # single UPN/group name required to approve deployments to this environment; empty skips approval configuration
    [parameter(Mandatory = $false)] [String] $approverUpn = "",
    [parameter(Mandatory = $false)]
    [ValidateSet("True", "False")] [String] $enableDiagnostics = "False",
    [parameter(Mandatory = $false)] [Bool] $developerView = $false,
    # Local-run auth - omit when running inside an ADO pipeline (AzurePowerShell@5 handles auth)
    [parameter(Mandatory = $false)] [String] $tenantId,
    [parameter(Mandatory = $false)] [String] $servicePrincipalId,
    [parameter(Mandatory = $false)] [String] $servicePrincipalSecret
)

#References to the API's
$script:fabricBaseUrl  = "https://api.fabric.microsoft.com"
$script:powerbiBaseUrl = "https://api.powerbi.com/v1.0/myorg"
$script:azdoBaseUrl    = "https://dev.azure.com"
$script:graphBaseUrl   = "https://graph.microsoft.com/v1.0"

$private = if (Test-Path "$PSScriptRoot\..\private") { "$PSScriptRoot\..\private" } else { "$PSScriptRoot\..\..\shared\private" }
. "$private\SharedFunctions.ps1"
. "$private\DevOpsFunctions.ps1"

try {
    Write-Message "Info" "Powershell version : $($PSVersionTable.PSVersion)"
    $scriptParams = $MyInvocation.MyCommand.Parameters.Keys
    $maxLength = ($scriptParams | Measure-Object -Maximum -Property Length).Maximum
    foreach ($param in $scriptParams) {
        $value = Get-Variable -Name $param -ValueOnly -ErrorAction SilentlyContinue
        $displayValue = if ([string]::IsNullOrEmpty($value)) { "empty" } else { $value }
        Write-Message "Info" ("{0,-$maxLength} : {1}" -f $param, $displayValue)
    }

    Initialize-AuthContext -TenantId $tenantId -ServicePrincipalId $servicePrincipalId -ServicePrincipalSecret $servicePrincipalSecret | Out-Null
    Get-AzContext | Out-Null

    $azdoConfig = New-AzdoConfig `
        -AzdoBaseUrl         $script:azdoBaseUrl `
        -OrganizationName    $script:organizationName `
        -ProjectName         $script:projectName `
        -DevOpsRequestHeader $script:devOpsRequestHeader

    Write-Message "Action" "Creating environment '$environmentName' in project '$projectName'"
    $environmentId = New-DevOpsEnvironment -environmentName $environmentName -description $description -Context $azdoConfig

    Write-Message "Action" "Syncing Administrators on environment '$environmentName' (id=$environmentId)"
    Set-DevOpsEnvironmentAdministrators -EnvironmentId $environmentId -CoAdministrators $coAdministrators -Context $azdoConfig

    if (![string]::IsNullOrWhiteSpace($approverUpn)) {
        Write-Message "Action" "Configuring approver '$approverUpn' on environment '$environmentName' (id=$environmentId)"
        Set-DevOpsEnvironmentApprover -EnvironmentId $environmentId -ApproverUpn $approverUpn -Context $azdoConfig
    }
    else {
        Write-Message "Info" "No approver UPN provided; skipping approval check configuration."
    }

    Write-Message "Info" "Script execution completed successfully."
}
catch {
    $errorResponse = Get-ErrorResponse($_)
    Write-Message "Error" "$($errorResponse). Powershell script AddAzDOEnvMainFunction failed to complete"
    Write-Host "##vso[task.logissue type=error]$errorResponse"
    Write-Host "##vso[task.complete result=Failed;]"
    exit 1
}
