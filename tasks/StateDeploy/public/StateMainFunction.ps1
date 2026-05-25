###############################################################################
# Accelerator:  FabricCatalyst
# Script Name:  StateMainFunction.ps1
# Description:  Enforces governance rules (domain, capacity, RBAC) across Fabric workspaces.
# Author:       Svenchio — https://techtacofriday.com
# Project:      https://fabriccatalyst.com
# Usage:        If executed as a Stand-alone script:
#               Step 1. Open a new PowerShell session from the root of the script
#               Step 2. PS> Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
#               Step 3  PS> .\StateMainFunction.ps1
###############################################################################
param
(
    [parameter(Mandatory = $false)] [String] $jsonMapFileName,
    [ValidateSet("AzureDevOps")]
    [parameter(Mandatory = $false)] [String] $gitProviderType = "AzureDevOps",
    [parameter(Mandatory = $false)] [String] $organizationName,
    [parameter(Mandatory = $false)] [String] $projectName,
    [parameter(Mandatory = $false)] [String] $repositoryName,
    [parameter(Mandatory = $false)] [String] $sourceBranchName = "main",
    [parameter(Mandatory = $false)] [String] $deploymentDirectoryPath,
    [parameter(Mandatory = $false)]
    [ValidateSet("True", "False")] [String] $whatIf = "True",
    [parameter(Mandatory = $false)]
    [ValidateSet("True", "False")] [String] $remove = "False",
    [parameter(Mandatory = $false)]
    [ValidateSet("True", "False")] [String] $enableDiagnostics = "False",
    [parameter(Mandatory = $false)] [Bool] $developerView = $false,
    # Local-run auth — omit when running inside an ADO pipeline (AzurePowerShell@5 handles auth)
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
. "$private\CapacityFunctions.ps1"
. "$private\DomainFunctions.ps1"
. "$private\WorkspaceFunctions.ps1"

function Invoke-StateRule {
    param (
        [parameter(Mandatory = $true)]  [psobject]       $item,
        [parameter(Mandatory = $true)]  [String]         $type,
        [parameter(Mandatory = $false)] [String]         $parent = "",
        [parameter(Mandatory = $false)] [String]         $domainName = "",
        [parameter(Mandatory = $false)] [String]         $subDomainName = "",
        [parameter(Mandatory = $true)]  [String]         $whatIf,
        [parameter(Mandatory = $true)]  [String]         $remove,
        [parameter(Mandatory = $false)] [object[]]       $allWorkspaces = @(),
        [parameter(Mandatory = $false)] [PSCustomObject] $Context = $null
    )
    switch ($type) {
        "Domains" {
            Write-Message "Action" "Creating Domain $($item.name)"
            $domainId = New-FabricDomain -domainName $item.name -Context $Context
            if (![String]::IsNullOrEmpty($domainId) -and $item.rbacAssignments) {
                foreach ($rbacAssignment in $item.rbacAssignments | Where-Object { ($_.type -in @('Admins', 'Contributors')) -and (![string]::IsNullOrWhiteSpace($_.upnList)) }) {
                    Add-DomainUsers -domainId $domainId -upnList $rbacAssignment.upnList -domainRole $rbacAssignment.type -Context $Context
                }
            }
        }
        "SubDomains" {
            $parentDomain = Get-FabricDomain -domainName $parent -Context $Context
            if ($null -ne $parentDomain) {
                Write-Message "Action" "Creating SubDomain $($item.name) under $parent"
                $subDomainId = New-FabricDomain -domainName $item.name -parentDomainId $parentDomain.id -Context $Context
                if (![String]::IsNullOrEmpty($subDomainId) -and $item.rbacAssignments) {
                    foreach ($rbacAssignment in $item.rbacAssignments | Where-Object { ($_.type -in @('Admins', 'Contributors')) -and (![string]::IsNullOrWhiteSpace($_.upnList)) }) {
                        Add-DomainUsers -domainId $subDomainId -upnList $rbacAssignment.upnList -domainRole $rbacAssignment.type -Context $Context
                    }
                }
            }
        }
        "Rules" {
            $capacity = Get-FabricCapacities -Context $Context |
                Where-Object { $_.displayName -eq $item.capacity -and $_.state -eq 'Active' } |
                Select-Object -First 1
            if ($null -eq $capacity) {
                Write-Message "Error" "Capacity '$($item.capacity)' not found or inactive. Skipping rule '$($item.name)'."
                return
            }

            if ($null -eq $item.match) {
                Write-Message "Warning" "Rule '$($item.name)' has no match block. Skipping."
                return
            }

            $candidates = Select-WorkspacesByMatch -Match $item.match -Workspaces $allWorkspaces
            Write-Message "Info" "Rule '$($item.name)' matched $($candidates.Count) workspace(s) under [$domainName/$subDomainName]."

            $targetDomain = if (-not [string]::IsNullOrWhiteSpace($subDomainName)) {
                Get-FabricDomain -domainName $subDomainName -Context $Context
            } else {
                Get-FabricDomain -domainName $domainName -Context $Context
            }

            if ($null -eq $targetDomain) {
                Write-Message "Error" "Target domain/subdomain '$domainName/$subDomainName' not found. Skipping rule '$($item.name)'."
                return
            }

            $isWhatIf = [Convert]::ToBoolean($whatIf)
            foreach ($ws in $candidates) {
                try {
                    if ([Convert]::ToBoolean($remove) -eq $false) {
                        if ([string]$ws.domainId -ne [string]$targetDomain.id) {
                            if (-not $isWhatIf) {
                                Add-WorkspaceToDomain -domainId $targetDomain.id -workspaceId $ws.id -Context $Context | Out-Null
                            }
                            Register-WorkspaceAction -Workspace $ws -Action (if ($isWhatIf) { "WouldChange" } else { "Changed" }) `
                                -RuleName $item.name -DomainName $domainName -SubDomainName $subDomainName -Reason "DomainAssigned"
                        } else {
                            Register-WorkspaceAction -Workspace $ws -Action "Skipped" `
                                -RuleName $item.name -DomainName $domainName -SubDomainName $subDomainName -Reason "AlreadyInDomain"
                        }
                    } else {
                        if ([string]$ws.domainId -ne [string]$targetDomain.id) {
                            Register-WorkspaceAction -Workspace $ws -Action "Skipped" `
                                -RuleName $item.name -DomainName $domainName -SubDomainName $subDomainName -Reason "IncorrectDomain"
                        } else {
                            if (-not $isWhatIf) {
                                Remove-Workspace -workspaceId $ws.id | Out-Null
                            }
                            Register-WorkspaceAction -Workspace $ws -Action (if ($isWhatIf) { "WouldRemove" } else { "Removed" }) `
                                -RuleName $item.name -DomainName $domainName -SubDomainName $subDomainName -Reason "DomainRemoved"
                        }
                    }
                }
                catch {
                    $err = Get-ErrorResponse($_)
                    Register-WorkspaceAction -Workspace $ws -Action "Error" -RuleName $item.name `
                        -DomainName $domainName -SubDomainName $subDomainName -Reason $err
                    Write-Message "Error" "Rule '$($item.name)' failed for workspace '$($ws.name)': $err"
                }
            }
        }
        default {
            Write-Message "Warning" "Skipped $($type) $($item.name), type is not supported."
        }
    }
}

function Invoke-StateItems {
    param (
        [Parameter(Mandatory = $true)]  [psobject]       $jsonObject,
        [Parameter(Mandatory = $false)] [string]         $parentName = "",
        [Parameter(Mandatory = $false)] [string]         $currentDomainName = "",
        [Parameter(Mandatory = $false)] [string]         $currentSubDomainName = "",
        [Parameter(Mandatory = $true)]  [String]         $whatIf,
        [Parameter(Mandatory = $true)]  [String]         $remove,
        [Parameter(Mandatory = $false)] [object[]]       $allWorkspaces = @(),
        [Parameter(Mandatory = $false)] [PSCustomObject] $Context = $null
    )

    if ($jsonObject.PSObject.Properties.Name -contains 'Domains' -and $null -ne $jsonObject.domains) {
        foreach ($domain in $jsonObject.domains | Where-Object { $_.active -eq 1 }) {
            Invoke-StateRule -item $domain -type "Domains" -parent $parentName `
                -whatIf $whatIf -remove $remove -allWorkspaces $allWorkspaces -Context $Context
            Invoke-StateItems -jsonObject $domain -parentName $domain.name `
                -currentDomainName $domain.name -currentSubDomainName "" `
                -whatIf $whatIf -remove $remove -allWorkspaces $allWorkspaces -Context $Context
        }
    }

    if ($jsonObject.PSObject.Properties.Name -contains 'SubDomains' -and $null -ne $jsonObject.subDomains) {
        foreach ($subDomain in $jsonObject.subDomains | Where-Object { $_.active -eq 1 }) {
            Invoke-StateRule -item $subDomain -type "SubDomains" -parent $parentName `
                -whatIf $whatIf -remove $remove -allWorkspaces $allWorkspaces -Context $Context
            Invoke-StateItems -jsonObject $subDomain -parentName $subDomain.name `
                -currentDomainName $currentDomainName -currentSubDomainName $subDomain.name `
                -whatIf $whatIf -remove $remove -allWorkspaces $allWorkspaces -Context $Context
        }
    }

    if ($jsonObject.PSObject.Properties.Name -contains 'Rules' -and $null -ne $jsonObject.rules) {
        foreach ($rule in $jsonObject.rules | Where-Object { $_.active -eq 1 }) {
            Invoke-StateRule -item $rule -type "Rules" -parent $parentName `
                -domainName $currentDomainName -subDomainName $currentSubDomainName `
                -whatIf $whatIf -remove $remove -allWorkspaces $allWorkspaces -Context $Context
        }
    }
}

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
        -RepositoryName      $script:repositoryName `
        -SourceBranchName    $script:sourceBranchName `
        -DevOpsRequestHeader $script:devOpsRequestHeader

    Write-Message "Info" "Downloading state JSON file '$jsonMapFileName' from branch '$sourceBranchName'."
    $repoJsonMapFilePath = "$deploymentDirectoryPath/$jsonMapFileName"
    $jsonMap = Get-JsonMapContent -mapFilePath $repoJsonMapFilePath -branchName $sourceBranchName -AzdoConfig $azdoConfig

    $script:fabricWorkspacesCatalog = @{}
    $allWorkspaces = @(Get-Workspaces)
    Write-Message "Info" "Loaded $($allWorkspaces.Count) workspace(s). whatIf=$whatIf, remove=$remove."

    if ($jsonMap.exemptions) {
        foreach ($exemption in $jsonMap.exemptions) {
            $exemptWorkspaces = Select-WorkspacesByMatch -Match $exemption -Workspaces $allWorkspaces
            foreach ($ws in $exemptWorkspaces) {
                Register-WorkspaceAction -Workspace $ws -Action "Exempt" -Reason "ExplicitExemption"
            }
            Write-Message "Info" "Exempted $($exemptWorkspaces.Count) workspace(s) matching '$($exemption.nameGlob)'."
        }
    }

    Invoke-StateItems -jsonObject $jsonMap -whatIf $whatIf -remove $remove -allWorkspaces $allWorkspaces

    $processedCount = $script:fabricWorkspacesCatalog.Count
    $unmatchedCount = $allWorkspaces.Count - $processedCount
    Write-Message "Info" "Workspace State Summary (whatIf=$whatIf, remove=$remove) - $($allWorkspaces.Count) total, $processedCount matched, $unmatchedCount unmatched by any rule."

    if ($processedCount -gt 0) {
        $summary = $script:fabricWorkspacesCatalog.Values
        $summary | Group-Object action | Sort-Object Count -Descending | ForEach-Object {
            Write-Message "Info" ("{0,-12} : {1}" -f $_.Name, $_.Count)
        }
        $summary |
            Select-Object domain, subDomain, rule, action, reason, workspaceName |
            Sort-Object domain, subDomain, action, rule |
            Format-Table -AutoSize | Out-String | ForEach-Object { Write-Message "Info" $_ }
    }
    Write-Message "Info" "Script execution completed successfully."
}
catch {
    $errorResponse = Get-ErrorResponse($_)
    Write-Message "Error" "$($errorResponse). Powershell script StateMainFunction failed to complete"
    Write-Host "##vso[task.logissue type=error]$errorResponse"
    Write-Host "##vso[task.complete result=Failed;]"
    exit 1
}
