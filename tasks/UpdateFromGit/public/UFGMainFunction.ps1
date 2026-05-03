###############################################################################
# Accelerator:  FabricCatalyst
# Script Name:  UFGMainFunction.ps1
# Description:  Temporal description
# Author:       Hector Lopez (Manager @Intelligent Platforms)
# Contact:      svenchio@techtacofriday.com
# Blog:         https://www.techtacofriday.com/
# Usage:        If executed as a Stand-alone script:
#               Step 1. Open a new PowerShell session from the root of the script
#               Step 2. PS> Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
#               Step 3  PS> .\UFGMainFunction.ps1
###############################################################################
param
(
    [parameter(Mandatory = $false)] [String] $fabricGitConnectionName,
    [parameter(Mandatory = $false)] [String] $workspaceName,
    [parameter(Mandatory = $false)] [String] $semanticModelsBinding = "[]",
    [parameter(Mandatory = $false)] [String] $folderName = "Vertipaq",
    [parameter(Mandatory = $false)]
    [ValidateSet("True", "False")] [String] $isWorkspaceGitEnabled = "False",
    [parameter(Mandatory = $false)]
    [ValidateSet("True", "False")] [String] $enableDiagnostics = "False",
    [parameter(Mandatory = $false)] [Bool] $developerView = $true,
    # Local-run auth - omit when running inside an ADO pipeline (AzurePowerShell@5 handles auth)
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
. "$private\WorkspaceFunctions.ps1"
. "$private\ItemFunctions.ps1"
. "$private\ConnectionFunctions.ps1"

try {
    Write-Message "Info" "Powershell version : $($PSVersionTable.PSVersion)"
    # Get all defined parameters in the script
    $scriptParams = $MyInvocation.MyCommand.Parameters.Keys
    $maxLength = ($scriptParams | Measure-Object -Maximum -Property Length).Maximum
    foreach ($param in $scriptParams) {
        $value = Get-Variable -Name $param -ValueOnly -ErrorAction SilentlyContinue
        $displayValue = if ([string]::IsNullOrEmpty($value)) { "empty" } else { $value }
        Write-Message "Info" ("{0,-$maxLength} : {1}" -f $param, $displayValue)
    }

    Initialize-AuthContext -TenantId $tenantId -ServicePrincipalId $servicePrincipalId -ServicePrincipalSecret $servicePrincipalSecret | Out-Null
    Get-AzContext | Out-Null

    $workspace = Get-FabricWorkspace -workspaceName $workspaceName
    if ($null -eq $workspace) {
        throw "Workspace '$workspaceName' was not found. Verify the workspace name and that the service principal has access."
    }

    #1. CONNECT WORKSPACE TO GIT
    if ([Convert]::ToBoolean($isWorkspaceGitEnabled)) {
        $script:fabricGitConnectionId = (Get-FabricConnection -connectionName $script:fabricGitConnectionName).id
        Connect-WorkspaceToGit -workspaceId $workspace.id -connectToGit $false | Out-Null
    }

    #2. BIND ANY MODELS
    if ($semanticModelsBinding -and $semanticModelsBinding -ne "[]") {
        $parsedSemanticModels = $semanticModelsBinding | ConvertFrom-Json

        # Split explicit mappings from the catch-all wildcard entry (modelName = '*')
        $specificMappings = @($parsedSemanticModels | Where-Object { $_.modelName -ne '*' })
        $wildcardMapping  = $parsedSemanticModels | Where-Object { $_.modelName -eq '*' } | Select-Object -First 1
        $boundModelNames  = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

        foreach ($model in $specificMappings) {
            if (-not ($model.modelName -and $model.cnnName)) {
                $errorMessage = "semanticModelsBinding entry is missing modelName or cnnName: $($model)"
                Write-Message "Error" $errorMessage
                throw $errorMessage
            }
            $semanticModel = Get-FabricItem -itemName $model.modelName -itemType "semanticmodel" -workspaceId $workspace.id
            $connection    = Get-FabricConnection -connectionName $model.cnnName
            if (-not ($semanticModel -and $connection)) {
                $errorMessage = "Semantic model '$($model.modelName)' or connection '$($model.cnnName)' can't be reached or does not exist"
                Write-Message "Error" $errorMessage
                throw $errorMessage
            }
            Set-SemanticModelConnection `
                -workspaceId $workspace.id `
                -semanticModelId $semanticModel.id `
                -connectionId $connection.id `
                -connectivityType $connection.connectivityType `
                -connectionDetailsType $connection.connectionDetails.type `
                -connectionDetailsPath $connection.connectionDetails.path | Out-Null
            $boundModelNames.Add($model.modelName) | Out-Null
        }

        if ($null -ne $wildcardMapping) {
            if (-not $wildcardMapping.cnnName) {
                $errorMessage = "Wildcard semanticModelsBinding entry ('*') is missing cnnName"
                Write-Message "Error" $errorMessage
                throw $errorMessage
            }
            $wildcardConnection = Get-FabricConnection -connectionName $wildcardMapping.cnnName
            if ($null -eq $wildcardConnection) {
                $errorMessage = "Wildcard connection '$($wildcardMapping.cnnName)' can't be reached or does not exist"
                Write-Message "Error" $errorMessage
                throw $errorMessage
            }
            $allModels = Get-FabricItemsByType -workspaceId $workspace.id -itemType "semanticmodel"
            Write-Message "Info" "Wildcard binding: applying '$($wildcardMapping.cnnName)' to all remaining semantic models."
            foreach ($m in $allModels) {
                if (-not $boundModelNames.Contains($m.displayName)) {
                    Write-Message "Action" "Binding '$($m.displayName)' to '$($wildcardMapping.cnnName)' (wildcard)."
                    Set-SemanticModelConnection `
                        -workspaceId $workspace.id `
                        -semanticModelId $m.id `
                        -connectionId $wildcardConnection.id `
                        -connectivityType $wildcardConnection.connectivityType `
                        -connectionDetailsType $wildcardConnection.connectionDetails.type `
                        -connectionDetailsPath $wildcardConnection.connectionDetails.path | Out-Null
                }
            }
        }
    }
    else {
        Write-Message "Info" "No bindings provided, skipping binding and continue."
    }

    #3. CONFIGURE ROW LEVEL SECURITY
    # Run all notebooks and stop on first failure
    $folderId = Get-FabricFolder -workspaceId $workspace.id -displayName $script:folderName
    if (-not [string]::IsNullOrWhiteSpace($folderId)) {
        $items = Get-FabricItemsByFolder -workspaceId $workspace.id -type "Notebook" -rootFolderId $folderId
        if (-not $items -or $items.Count -eq 0) {
            Write-Message "Info" "No Notebook items found in folder '$($script:folderName)' (id=$folderId). Nothing to run."
        }
        else {
            foreach ($item in $items) {
                $itemId = $item.id
                $name   = $item.displayName
                if ($item.displayName -ne "notebookSample") {
                    Write-Message "Action" "Running notebook '$name' (id=$itemId) in folder '$($script:folderName)'..."
                    Invoke-FabricNotebook -workspaceId $workspace.id -notebookItemId $itemId -whatIf $whatIf | Out-Null
                }
            }
            Write-Message "Info" "All notebooks in folder '$($script:folderName)' completed successfully."
        }
    }

    Write-Message "Info" "Script execution completed successfully."
}
catch {
    $errorResponse = Get-ErrorResponse($_)
    Write-Message "Error" "$($errorResponse). Powershell script UpdateFromGit failed to complete"
    # Explicitly fail the task and set the result to Failed
    Write-Host "##vso[task.logissue type=error]$errorResponse"
    Write-Host "##vso[task.complete result=Failed;]"
    exit 1
}
