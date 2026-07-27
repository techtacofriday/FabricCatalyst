###############################################################################
# Accelerator:  FabricCatalyst
# Script Name:  ExecuteAutoDeployment.ps1
# Description:  Temporal description
# Author:       Hector Lopez (Manager @Intelligent Platforms)
# Contact:      svenchio@techtacofriday.com
# Blog:         https://www.techtacofriday.com/
# Usage:        If executed as a Stand-alone script:
#               Step 1. Open a new PowerShell session from the root of the script
#               Step 2. PS> Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
#               Step 3  PS> .\ExecuteAutoDeployment.ps1
###############################################################################
param
(
    # --- Azure DevOps context (required) ---
    [parameter(Mandatory = $true)] [string] $OrganizationName,
    [parameter(Mandatory = $true)] [string] $ProjectName,
    [parameter(Mandatory = $true)] [string] $TargetPipelineName,  # display name or numeric ID
    [parameter(Mandatory = $true)] [string] $BranchName,

    # --- Orchestrator behavior ---
    [parameter(Mandatory = $false)] [switch] $Wait,                # wait for completion
    [parameter(Mandatory = $false)] [int] $PollSeconds = 10,
    [parameter(Mandatory = $false)] [int] $TimeoutMinutes = 120,

    # --- Parameters to forward to the TARGET pipeline ---
    [parameter(Mandatory = $true)] [String] $userAccount = "cicdwflow_app_automation",
    [parameter(Mandatory = $true)] [String] $userPassword = "********************",
    [parameter(Mandatory = $true)] [String] $dataProduct,
    [parameter(Mandatory = $true)] [String] $domainName,
    [parameter(Mandatory = $true)] [String] $subDomainName, 
    [parameter(Mandatory = $true)] [String] $workspacePrefix,
    [parameter(Mandatory = $true)] [String] $layerList,
    [parameter(Mandatory = $true)] [String] $workspaceAdminsList,
    [parameter(Mandatory = $true)] [String] $createDeploymentPipeline,
    [parameter(Mandatory = $true)] [String] $deploymentPipelineName,
    [parameter(Mandatory = $true)] [String] $pipelineAdminsList,
    [parameter(Mandatory = $true)] [String] $useEmptyBranch,
    [parameter(Mandatory = $true)] [String] $sourceBranchName,
    [parameter(Mandatory = $true)] [String] $itemsGitFolder,
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

# --------------------------------------------------------------------
# Set script-scoped variables used by DevOpsFunctions.ps1 helpers
# --------------------------------------------------------------------
$script:organizationName   = $OrganizationName
$script:projectName        = $ProjectName
$script:targetPipelineName = $TargetPipelineName
$script:branchName         = $BranchName

# Convert boolean-like strings to real booleans for YAML parameters of type 'boolean'
$tpCreateDeploymentPipeline = Convert-ToBoolean $createDeploymentPipeline
$tpUseEmptyBranch           = Convert-ToBoolean $useEmptyBranch
$tpEnableDiagnostics        = Convert-ToBoolean $enableDiagnostics

# --------------------------------------------------------------------
# Runtime variables (optional) — available as $(var) during the run
# --------------------------------------------------------------------
$runtimeVariables = @{
    dataProduct = $dataProduct
    # Add more runtime variables only if you need them as $(var) during execution
}

# --------------------------------------------------------------------
# YAML template parameters — MUST match target pipeline parameter names
# --------------------------------------------------------------------
$templateParameters = @{
    dataProduct              = $dataProduct
    domainName               = $domainName
    subDomainName            = $subDomainName
    workspacePrefix          = $workspacePrefix
    layerList                = $layerList
    workspaceAdminsList      = $workspaceAdminsList
    createDeploymentPipeline = $tpCreateDeploymentPipeline
    deploymentPipelineName   = $deploymentPipelineName
    pipelineAdminsList       = $pipelineAdminsList
    useEmptyBranch           = $tpUseEmptyBranch
    sourceBranchName         = $sourceBranchName
    itemsGitFolder           = $itemsGitFolder
    enableDiagnostics        = $tpEnableDiagnostics
}

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

    WriteMessage "Action" "Calling the Auto Deployment pipeline."

    WriteMessage "Info" "Queuing target pipeline '$TargetPipelineName' on branch '$BranchName'..."

    $result = ExecutePipeline `
        -PipelineNameOrId $TargetPipelineName `
        -Branch $BranchName `
        -Variables $runtimeVariables `
        -TemplateParameters $templateParameters `
        -Wait:$Wait `
        -PollSeconds $PollSeconds `
        -TimeoutMinutes $TimeoutMinutes

    if ($Wait) {
        if ($null -eq $result) { throw "Pipeline execution returned null while waiting." }
        if ($result.result -ne 'succeeded') {
            throw "Pipeline did not succeed. state=$($result.state) result=$($result.result)"
        }
        WriteMessage "Info" "Pipeline run $($result.id) succeeded. ✅"
    }
    else {
        if ($null -eq $result) { throw "Queue operation returned null run id." }
        WriteMessage "Info" "Pipeline queued successfully. RunId=$result"
    }

    WriteMessage "Info" "Script execution completed successfully."
}
catch {
    $errorResponse = GetErrorResponse($_)
    WriteMessage "Error" "$($errorResponse). Powershell script AutoMainFunction failed to complete"
    # Explicitly fail the task and set the result to Failed
    Write-Host "##vso[task.logissue type=error]$errorResponse"
    Write-Host "##vso[task.complete result=Failed;]"
    exit 1
}


