###############################################################################
# Accelerator:  FabricCatalyst
# Script Name:  PipelineDeployMainFunction.ps1
# Description:  Creates a Fabric deployment pipeline and assigns workspaces to its stages.
# Author:       Svenchio — https://techtacofriday.com
# Project:      https://fabriccatalyst.com
# Usage:        If executed as a Stand-alone script:
#               Step 1. Open a new PowerShell session from the root of the script
#               Step 2. PS> Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
#               Step 3  PS> .\PipelineDeployMainFunction.ps1
###############################################################################
param
(
    [parameter(Mandatory = $false)] [String] $workspacePrefix, 
    [parameter(Mandatory = $false)] [String] $environmentList,
    [parameter(Mandatory = $false)] [String] $deploymentPipelinePrefix,
    [parameter(Mandatory = $false)] [String] $pipelineAdminsList,
    [parameter(Mandatory = $false)]
    [ValidateSet("True", "False")] [String] $enableDiagnostics = "False",
    [parameter(Mandatory = $false)] [Bool] $developerView = $false,
    # Local-run auth — omit when running inside an ADO pipeline (AzurePowerShell@5 handles auth)
    [parameter(Mandatory = $false)] [String] $tenantId,
    [parameter(Mandatory = $false)] [String] $servicePrincipalId,
    [parameter(Mandatory = $false)] [String] $servicePrincipalSecret
)

$script:powerbiBaseUrl = "https://api.powerbi.com/v1.0/myorg"
$script:fabricBaseUrl  = "https://api.fabric.microsoft.com"
$script:azdoBaseUrl    = "https://dev.azure.com"
$script:graphBaseUrl   = "https://graph.microsoft.com/v1.0"

$private = if (Test-Path "$PSScriptRoot\..\private") { "$PSScriptRoot\..\private" } else { "$PSScriptRoot\..\..\shared\private" }
. "$private\SharedFunctions.ps1"
. "$private\WorkspaceFunctions.ps1"
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

    if ([string]::IsNullOrWhiteSpace($script:deploymentPipelinePrefix)) {
        throw "deploymentPipelinePrefix is required"
    }
    if ($script:workspacePrefix -notmatch '^[A-Za-z0-9-]+$') {
        throw "The value for workspacePrefix contains invalid characters. Only letters, numbers, and dashes are allowed."
    }
    if ($script:deploymentPipelinePrefix -notmatch '^[A-Za-z0-9-]+$') {
        throw "The value for deploymentPipelinePrefix contains invalid characters. Only letters, numbers, and dashes are allowed."
    }
    if ([string]::IsNullOrWhiteSpace($script:environmentList)) {
        throw "environmentList is required"
    }

    $environments = $script:environmentList | ConvertFrom-Json

    $sortedEnvironments = if ($environments | Where-Object { $null -ne $_.order -and $_.order -ne '' }) {
        @($environments | Sort-Object { [int]$_.order })
    } else {
        @($environments)
    }

    $pipelineStages = @($sortedEnvironments | ForEach-Object {
        [PSCustomObject]@{ displayName = $_.Code; isPublic = $false }
    })

    if ($pipelineStages.Count -lt 2) {
        throw "The Fabric API requires at least 2 pipeline stages but only $($pipelineStages.Count) environment(s) were provided."
    }

    $deploymentPipelineFQN = "pl_{0}" -f $script:deploymentPipelinePrefix
    Write-Message "Action" "Creating Fabric Pipeline $($deploymentPipelineFQN)"
    $deploymentPipelineId = New-DeploymentPipeline -pipelineName $deploymentPipelineFQN -pipelineDescription $deploymentPipelineFQN -stages $pipelineStages

    Write-Message "Action" "Adding Users to Pipeline $($deploymentPipelineFQN) ($($deploymentPipelineId))"
    Add-PipelineUsers -deploymentPipelineId $deploymentPipelineId -upnList $script:pipelineAdminsList -deploymentPipelineAccessRight "Admin"

    Write-Message "Action" "Assigning workspaces to pipeline stages"
    for ($i = 0; $i -lt $sortedEnvironments.Count; $i++) {
        $environment = $sortedEnvironments[$i]
        $workspaceFQN = "ws_{0}_{1}" -f $script:workspacePrefix, $environment.Code
        Write-Message "Action" "Assigning workspace $($workspaceFQN) to stage (order $($i))"
        $workspaceId = (Get-FabricWorkspace -workspaceName $workspaceFQN).id
        Set-PipelineStageWorkspace -deploymentPipelineId $deploymentPipelineId -orderIndex $i -workspaceId $workspaceId
    }

    Write-Message "Info" "Script execution completed successfully."
}
catch {
    $errorResponse = Get-ErrorResponse($_)
    Write-Message "Error" "$($errorResponse). Powershell script PipelineDeployMainFunction failed to complete"
    Write-Host "##vso[task.logissue type=error]$errorResponse"
    Write-Host "##vso[task.complete result=Failed;]"
    exit 1
}
