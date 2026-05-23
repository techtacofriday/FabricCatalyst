###############################################################################
# Accelerator:  FabricCatalyst
# Script Name:  ExportMainFunction.ps1
# Description:  Exports Fabric item definitions from one or more workspaces to local disk for offline exploration.
# Author:       Svenchio — https://techtacofriday.com
# Project:      https://fabriccatalyst.com
# Usage:        If executed as a Stand-alone script:
#               Step 1. Open a new PowerShell session from the root of the script
#               Step 2. PS> Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
#               Step 3  PS> .\ExportMainFunction.ps1
#               Local MFA run: set $env:FC_LOCAL_FILES = 'True' before executing
###############################################################################
param
(
    [ValidateSet("Core","Admin")]
    [parameter(Mandatory = $false)] [String] $scanType = "Core",
    # When provided, only the workspace with this name is exported
    [parameter(Mandatory = $false)] [String] $workspaceName,
    # When provided, only workspaces assigned to this capacity are exported
    [parameter(Mandatory = $false)] [String] $capacityName,
    # Root directory where each item's definition parts will be written
    [parameter(Mandatory = $true)]  [String] $outputDirectory,
    [parameter(Mandatory = $false)]
    [ValidateSet("True", "False")] [String] $enableDiagnostics = "False",
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

$private = "$PSScriptRoot\..\..\tasks\shared\private"

. "$private\SharedFunctions.ps1"
. "$private\CapacityFunctions.ps1"
. "$private\WorkspaceFunctions.ps1"
. "$private\ItemFunctions.ps1"

try {
    Write-Message "Info" "Powershell version : $($PSVersionTable.PSVersion)"
    $scriptParams = $MyInvocation.MyCommand.Parameters.Keys
    $maxLength = ($scriptParams | Measure-Object -Maximum -Property Length).Maximum
    foreach ($param in $scriptParams) {
        $value = Get-Variable -Name $param -ValueOnly -ErrorAction SilentlyContinue
        $displayValue = if ([string]::IsNullOrEmpty($value)) { "empty" } elseif ($param -eq 'servicePrincipalSecret') { '****' } else { $value }
        Write-Message "Info" ("{0,-$maxLength} : {1}" -f $param, $displayValue)
    }

    Initialize-AuthContext -TenantId $tenantId -ServicePrincipalId $servicePrincipalId -ServicePrincipalSecret $servicePrincipalSecret | Out-Null

    Write-Message "Info" "Fetching workspaces..."
    $workspaces = Get-WorkspacesCore
    Write-Message "Info" "Found $($workspaces.Count) workspace(s)."

    if (-not [string]::IsNullOrWhiteSpace($capacityName)) {
        $capacities      = Get-FabricCapacities
        $targetCapacityId = ($capacities | Where-Object { $_.displayName -eq $capacityName }).id
        if ($null -eq $targetCapacityId) {
            throw "Capacity '$capacityName' not found. Verify the name and that the principal has access."
        }
        $workspaces = @($workspaces | Where-Object { $_.capacityId -eq $targetCapacityId })
        Write-Message "Info" "Filtered to $($workspaces.Count) workspace(s) on capacity '$capacityName'."
    }

    if (-not [string]::IsNullOrWhiteSpace($workspaceName)) {
        $workspaces = @($workspaces | Where-Object { $_.displayName -eq $workspaceName })
        if ($workspaces.Count -eq 0) {
            $capacityNote = if (-not [string]::IsNullOrWhiteSpace($capacityName)) { " on capacity '$capacityName'" } else { '' }
            throw "Workspace '$workspaceName' not found$capacityNote. Verify the name and that the principal has access."
        }
        Write-Message "Info" "Filtered to $($workspaces.Count) workspace(s) named '$workspaceName'."
    }

    $totalItems     = 0
    $totalWithDef   = 0

    foreach ($workspace in $workspaces) {
        Write-Message "Info" "Workspace: '$($workspace.displayName)' ($($workspace.id))"

        $items = Get-FabricItems -workspaceId $workspace.id
        Write-Message "Info" "  $($items.Count) item(s) found."
        $totalItems += $items.Count

        foreach ($item in $items) {
            Write-Message "Info" "  [$($item.type)] $($item.displayName) ($($item.id))"
            try {
                $defOutDir = "$outputDirectory\$($workspace.displayName)\$($item.displayName)"
                $definition = Get-FabricItemDefinition `
                    -itemId              $item.id `
                    -itemType            $item.type `
                    -workspaceId         $workspace.id `
                    -outputFileDirectory $defOutDir
                $partCount = if ($definition.definition.parts) { $definition.definition.parts.Count } else { 0 }
                Write-Message "Info" "    Definition OK - $partCount part(s), written to '$defOutDir'"
                $totalWithDef++
            }
            catch {
                Write-Message "Warning" "    Definition not available: $($_.Exception.Message)"
            }
        }
    }

    Write-Message "Info" "Export complete. Workspaces: $($workspaces.Count), Items: $totalItems, Definitions retrieved: $totalWithDef."
    Write-Message "Info" "Script execution completed successfully."
}
catch {
    $errorResponse = Get-ErrorResponse($_)
    Write-Message "Error" "$($errorResponse). Powershell script ExportMainFunction failed to complete"
    Write-Host "##vso[task.logissue type=error]$errorResponse"
    Write-Host "##vso[task.complete result=Failed;]"
    exit 1
}