###############################################################################
# Accelerator:  FabricCatalyst
# Script Name:  PromoteStageMainFunction.ps1
# Description:  Promotes items from one stage to the next in a Fabric deployment pipeline.
# Author:       Svenchio — https://techtacofriday.com
# Project:      https://fabriccatalyst.com
# Usage:        If executed as a Stand-alone script:
#               Step 1. Open a new PowerShell session from the root of the script
#               Step 2. PS> Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
#               Step 3  PS> .\PromoteStageMainFunction.ps1
###############################################################################
param
(
    [parameter(Mandatory = $false)] [String] $deploymentPipelineName = "AutoDeploymentDemo",
    [parameter(Mandatory = $false)] [String] $targetStageName,
    [parameter(Mandatory = $false)]
    [ValidateSet("True", "False")] [String] $enableDiagnostics = "False",
    [parameter(Mandatory = $false)] [Bool] $developerView = $true,
    # Local-run auth — omit when running inside an ADO pipeline (AzurePowerShell@5 handles auth)
    [parameter(Mandatory = $false)] [String] $tenantId,
    [parameter(Mandatory = $false)] [String] $servicePrincipalId,
    [parameter(Mandatory = $false)] [String] $servicePrincipalSecret
)

#References to the API's
$script:powerbiBaseUrl = "https://api.powerbi.com/v1.0/myorg"
$script:fabricBaseUrl = "https://api.fabric.microsoft.com"
$script:azdoBaseUrl = "https://dev.azure.com"
$script:graphBaseUrl = "https://graph.microsoft.com/v1.0"

$private = if (Test-Path "$PSScriptRoot\..\private") { "$PSScriptRoot\..\private" } else { "$PSScriptRoot\..\..\shared\private" }
. "$private\SharedFunctions.ps1"
. "$private\PipelineFunctions.ps1"

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

    $deploymentPipelineFQN = "pl_{0}" -f $script:deploymentPipelineName
    $pipeline = Get-DeploymentPipeline -deploymentPipelineName $deploymentPipelineFQN
    if ($null -eq $pipeline) {
        throw "Deployment pipeline '$deploymentPipelineFQN' was not found."
    }

    $stages = Get-PipelineStages -deploymentPipelineId $pipeline.id
    $target  = $stages | Where-Object { $_.displayName -eq $script:targetStageName } | Select-Object -First 1

    if ($null -eq $target) {
        $available = ($stages | Select-Object -ExpandProperty displayName) -join ', '
        throw "Stage '$($script:targetStageName)' not found in pipeline '$deploymentPipelineFQN'. Available stages: $available"
    }
    if ($target.order -eq 0) {
        throw "Stage '$($script:targetStageName)' is the first stage (order 0) and cannot be a promotion target."
    }

    Write-Message "Action" "Promoting stage order $($target.order - 1) to $($target.order) ('$($script:targetStageName)') in pipeline '$deploymentPipelineFQN'."
    Publish-PipelineStageByOrder -deploymentPipelineId $pipeline.id -stageOrder ($target.order - 1)

    Write-Message "Info" "Script execution completed successfully."
}
catch {
    $errorResponse = Get-ErrorResponse($_)
    Write-Message "Error" "$($errorResponse). Powershell script PromoteStageMainFunction failed to complete"
    Write-Host "##vso[task.logissue type=error]$errorResponse"
    Write-Host "##vso[task.complete result=Failed;]"
    exit 1
}
