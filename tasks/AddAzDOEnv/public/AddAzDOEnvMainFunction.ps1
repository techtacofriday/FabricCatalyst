###############################################################################
# Accelerator:  FabricCatalyst
# Script Name:  ProvisioningDevOps.ps1
# Description:  Temporal description
# Author:       Hector Lopez (Manager @Intelligent Platforms)
# Contact:      svenchio@techtacofriday.com
# Blog:         https://www.techtacofriday.com/
# Usage:        If executed as a Stand-alone script:
#               Step 1. Open a new PowerShell session from the root of the script
#               Step 2. PS> Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
#               Step 3  PS> .\ProvisioningDevOps.ps1
###############################################################################
param
(
    # --- Azure DevOps context (required) ---
    [parameter(Mandatory = $true)] [string] $OrganizationName,
    [parameter(Mandatory = $true)] [string] $ProjectName,

    [parameter(Mandatory = $false)] [String] $userAccount = "cicdwflow_app_automation",
    [parameter(Mandatory = $false)] [String] $userPassword = "********************",
    [parameter(Mandatory = $false)] [String] $tenantId = "e3a9d37c-9a36-44b9-92c1-d623ce3a5308",
    [parameter(Mandatory = $false)] [String] $subscriptionId = "f956967d-5bdb-47b3-b67e-2e33777335db",
    [parameter(Mandatory = $false)] [String] $environment = "AutoDeploymentDemo",
    [parameter(Mandatory = $false)]
    [ValidateSet("True", "False")] [String] $enableDiagnostics = "False",
    [parameter(Mandatory = $false)] [Bool] $developerView = $true
)

#References to the API's
$script:powerbiBaseUrl = "https://api.powerbi.com/v1.0/myorg"
$script:fabricBaseUrl = "https://api.fabric.microsoft.com/v1"
$script:azdoBaseUrl = "https://dev.azure.com"
$script:graphBaseUrl = "https://graph.microsoft.com/v1.0/"

. "$PSScriptRoot\..\private\SharedFunctions.ps1"
. "$PSScriptRoot\..\private\DevOpsFunctions.ps1"

try {
    WriteMessage "Info" "Powershell version : $($PSVersionTable.PSVersion)"
    # Get all defined parameters in the script
    $scriptParams = $MyInvocation.MyCommand.Parameters.Keys
    $maxLength = ($scriptParams | Measure-Object -Maximum -Property Length).Maximum
    foreach ($param in $scriptParams) {
        $value = Get-Variable -Name $param -ValueOnly -ErrorAction SilentlyContinue
        $displayValue = if ([string]::IsNullOrEmpty($value)) { "empty" } else { $value }
        WriteMessage "Info" ("{0,-$maxLength} : {1}" -f $param, $displayValue)
    }

    AuthenticationProtocol | Out-Null
    Get-AzContext | Out-Null

    if (![string]::IsNullOrWhiteSpace($environment)) {
        WriteMessage "Action" "Creating environment $($environment)"
        CreateDevOpsEnvironment -environmentName $environment | Out-Null 
    }
    else {
        WriteMessage "Warning" "Skipping Workspace creation, no environment list was provided"
    }

    WriteMessage "Info" "Script execution completed successfully."
}
catch {
    $errorResponse = GetErrorResponse($_)
    WriteMessage "Error" "$($errorResponse). Powershell script ProvisioningDevOps failed to complete"
    # Explicitly fail the task and set the result to Failed
    Write-Host "##vso[task.logissue type=error]$errorResponse"
    Write-Host "##vso[task.complete result=Failed;]"
    exit 1
}