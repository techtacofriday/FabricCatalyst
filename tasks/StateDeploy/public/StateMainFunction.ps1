###############################################################################
# Accelerator:  FabricCatalyst
# Script Name:  MapMainFunction.ps1
# Description:  Temporal description
# Author:       Hector Lopez (Manager @Intelligent Platforms)
# Contact:      svenchio@techtacofriday.com
# Blog:         https://www.techtacofriday.com/
# Usage:        If executed as a Stand-alone script:
#               Step 1. Open a new PowerShell session from the root of the script
#               Step 2. PS> Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
#               Step 3  PS> .\MapMainFunction.ps1
###############################################################################
param
(
    [parameter(Mandatory = $false)]
    [ValidateSet("UserMFA", "UserPSW", "SrvPrincipal")] [string] $authMethod = "UserMFA",
    [parameter(Mandatory = $false)] [String] $userAccount = "admin.hlopez@acnazure034hotmail.onmicrosoft.com",
    [parameter(Mandatory = $false)] [String] $userPassword = "********************",
    [parameter(Mandatory = $false)] [String] $tenantId = "8650e436-efa2-46c3-8288-a56355c8ebb8",
    [parameter(Mandatory = $false)] [String] $subscriptionId = "0efa21d6-26d2-4cdd-b5fe-6082d08c3032",
    [parameter(Mandatory = $false)] [String] $dataProduct = "Default",
    [parameter(Mandatory = $false)] [String] $jsonMapFileName = "_sqlMeetsFabric.json",
    [parameter(Mandatory = $false)] [String] $deploymentDirectoryPath = "devops\pipelines\fabriccatalyst\dataproduct\deployment",
    [parameter(Mandatory = $false)] [String] $fabricItemsLocation = "LocalDirectory",
    [parameter(Mandatory = $false)]
    [ValidateSet("True", "False")] [String] $remove = "False",
    [parameter(Mandatory = $false)]
    [ValidateSet("True", "False")] [String] $whatIf = "True",
    [parameter(Mandatory = $false)]
    [ValidateSet("True", "False")] [String] $enableDiagnostics = "False",
    [parameter(Mandatory = $false)] [String] $gitProviderType = "AzureDevOps",#(DO NOT CHANGE)
    [parameter(Mandatory = $false)] [String] $organizationName = "ACNBAIP",#(DO NOT CHANGE)
    [parameter(Mandatory = $false)] [String] $projectName = "FabricCatalyst",#(DO NOT CHANGE)
    [parameter(Mandatory = $false)] [String] $repositoryName = "FabricCatalyst",#(DO NOT CHANGE)
    [parameter(Mandatory = $false)] [String] $sourceBranchName = "feature/20250516_sql-meets-fabric",#USE THE BRANCH USED FOR DEVELOPMENT
    [parameter(Mandatory = $false)] [Bool] $developerView = $false
)

#References to the API's
$script:fabricBaseUrl = "https://api.fabric.microsoft.com/v1"
$script:powerbiBaseUrl = "https://api.powerbi.com/v1.0/myorg"
$script:azdoBaseUrl = "https://dev.azure.com"
$script:graphBaseUrl = "https://graph.microsoft.com/v1.0/"

. "$PSScriptRoot\..\private\SharedFunctions.ps1"
. "$PSScriptRoot\..\private\CapacityFunctions.ps1"
. "$PSScriptRoot\..\private\DomainFunctions.ps1"
. "$PSScriptRoot\..\private\WorkspaceFunctions.ps1"
. "$PSScriptRoot\..\private\GitFunctions.ps1"

function CreateMapItem {
    param (
        [psobject] $item,
        [String] $type,
        [String] $parent,
        [String] $domainName = "",
        [String] $subDomainName = ""
    )
    switch ($type) {
        "Domains" {
            $domainId = CreateDomain -domainName $item.name
            if (![String]::IsNullOrEmpty($domainId) -and $item.rbacAssignments){
                foreach ($rbacAssignment in $item.rbacAssignments | Where-Object { ($_.type -in @('Admins', 'Contributors')) -and (![string]::IsNullOrWhiteSpace($_.upnList)) } ) {
                    AddDomainUsers -domainId $domainId -upnList $rbacAssignment.upnList -domainRole $rbacAssignment.type
                }
            }
        }
        "SubDomains" {
            $parentDomain = GetDomainByName -domainName $parent
            if($null -ne $parentDomain) {
                $subDomainId = CreateDomain -domainName $item.name -parentDomainId $parentDomain.id
                if (![String]::IsNullOrEmpty($subDomainId) -and $item.rbacAssignments){
                    foreach ($rbacAssignment in $item.rbacAssignments | Where-Object { ($_.type -in @('Admins', 'Contributors')) -and (![string]::IsNullOrWhiteSpace($_.upnList)) } ) {
                        AddDomainUsers -domainId $subDomainId -upnList $rbacAssignment.upnList -domainRole $rbacAssignment.type
                    }
                }
            }
        }
        "Rules"  {
            # 1) Validate capacity exists (your current logic)
            $capacity = GetCapacityByName -capacityName  $item.capacity
            if ($null -eq $capacity) {
                WriteMessage "Error" "Capacity '$($item.capacity)' not found. Cannot proceed."
                return
            }

            # 2) Load all workspaces once
            if ($null -eq $script:cachedWorkspaces) { $script:cachedWorkspaces = @(Get-Workspaces) }

            # 3) Select candidates for this rule (excluding already processed)
            $match = $item.match
            if ($null -eq $match) {
                WriteMessage "Warning" "Rule '$($item.name)' has no match block. Skipping."
                return
            }

            $candidates = Select-WorkspacesByMatch -Match $match -Workspaces $script:cachedWorkspaces
            WriteMessage "Info" "Rule '$($item.name)' matched $($candidates.Count) workspaces under [$domainName/$subDomainName]."

            # 4) Resolve target domain/subdomain object ids
            $targetDomain = if (-not [string]::IsNullOrWhiteSpace($subDomainName)) {
                GetDomainByName -domainName $subDomainName  # your implementation returns domain object for subdomain too
            } else {
                GetDomainByName -domainName $domainName
            }

            if ($null -eq $targetDomain) {
                WriteMessage "Error" "Target domain/subdomain '$($domainName)/$($subDomainName)' not found."
                return
            }

            foreach ($ws in $candidates) {
                try {
                    if($false -eq [Convert]::ToBoolean($script:remove)) {
                        if ([string]$ws.domainId -ne [string]$targetDomain.id) {
                            if($false -eq [Convert]::ToBoolean($script:whatIf)) {
                                AssignWorkspaceToDomain -domainId $targetDomain.id -workspaceId $ws.id | Out-Null
                            }
                            Register-WorkspaceAction -Workspace $ws -Action "Chang" -RuleName $item.name `
                                -DomainName $domainName -SubDomainName $subDomainName -Reason "DomainAssigned"                            
                        }
                        else {
                            Register-WorkspaceAction -Workspace $ws -Action "Skipp" -RuleName $item.name `
                                -DomainName $domainName -SubDomainName $subDomainName -Reason "AlreadyInDomain"
                        }
                    }
                    else {
                        if ([string]$ws.domainId -ne [string]$targetDomain.id) {
                            Register-WorkspaceAction -Workspace $ws -Action "Skipp" -RuleName $item.name `
                                -DomainName $domainName -SubDomainName $subDomainName -Reason "IncorrectDomain"
                        }
                        else {
                            if($false -eq [Convert]::ToBoolean($script:whatIf)) {
                                Remove-Workspace -workspaceId $ws.id | Out-Null
                            }
                            Register-WorkspaceAction -Workspace $ws -Action "Remov" -RuleName $item.name `
                                -DomainName $domainName -SubDomainName $subDomainName -Reason "Removed"      
                        }
                    }
                }
                catch {
                    $err = GetErrorResponse($_)
                    Register-WorkspaceAction -Workspace $ws -Action "Error" -RuleName $item.name `
                        -DomainName $domainName -SubDomainName $subDomainName -Reason $err
                    WriteMessage "Error" "Rule '$($item.name)' failed for workspace '$($ws.name)': $err"
                }
            }
        }
        default  {
            WriteMessage "Warning" "Skipped  $($type) $($item.name), this Fabric Item is not yet supported."
            Return
        }
    }
}

function ProcessMapItems {
    param (
        [Parameter(Mandatory=$true)] [psobject]$jsonObject,
        [Parameter(Mandatory=$false)] [string]$parentName = "",
        [Parameter(Mandatory=$false)] [string]$currentDomainName = "",
        [Parameter(Mandatory=$false)] [string]$currentSubDomainName = ""
    )

    if ($jsonObject.PSObject.Properties.Name -contains 'Domains' -and $null -ne $jsonObject.domains) {
        foreach ($domain in $jsonObject.domains | Where-Object { $_.active -eq 1 }) {
            CreateMapItem -item $domain -type "Domains" -parent $parentName
            ProcessMapItems -jsonObject $domain -parentName $domain.name -currentDomainName $domain.name -currentSubDomainName ""
        }
    }

    if ($jsonObject.PSObject.Properties.Name -contains 'SubDomains' -and $null -ne $jsonObject.subDomains) {
        foreach ($subDomain in $jsonObject.subDomains | Where-Object { $_.active -eq 1 }) {
            CreateMapItem -item $subDomain -type "SubDomains" -parent $parentName
            ProcessMapItems -jsonObject $subDomain -parentName $subDomain.name -currentDomainName $currentDomainName -currentSubDomainName $subDomain.name
        }
    }

    if ($jsonObject.PSObject.Properties.Name -contains 'Rules' -and $null -ne $jsonObject.rules) {
        foreach ($rule in $jsonObject.rules | Where-Object { $_.active -eq 1 }) {
            # pass context via a wrapper object or add parameters to CreateMapItem
            CreateMapItem -item $rule -type "Rules" -parent $parentName -domainName $currentDomainName -subDomainName $currentSubDomainName
        }
    }
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
    WriteMessage "Info" "Selected map JSON file $($script:jsonMapFileName)."
    
    $deploymentDirectoryPathAux = ".\temp\stateDeployment"
    Copy-DevOpsRepoBranchRestAPI `
        -itemsGitFolder "$($script:deploymentDirectoryPath)/$($script:dataProduct)" `
        -localFolder $deploymentDirectoryPathAux | Out-Null

    $jsonMapFilePath = "$($deploymentDirectoryPathAux)\$($script:deploymentDirectoryPath)\$($script:dataProduct)\state\$($script:jsonMapFileName)"
    $jsonMap =  GetFileContent -filePath $jsonMapFilePath | ConvertFrom-Json

    $script:fabricWorkspacesCatalog = @{}
    ProcessMapItems -jsonObject $jsonMap

    if ($script:fabricWorkspacesCatalog -and $script:fabricWorkspacesCatalog.Count -gt 0) {
        WriteMessage "Info" "Workspace State Summary:"
        $summary = $script:fabricWorkspacesCatalog.Values

        $summary | Group-Object action | Sort-Object Count -Descending | ForEach-Object {
            WriteMessage "Info" ("{0,-10} : {1}" -f $_.Name, $_.Count)
        }

        $summary |
            Select-Object domain, subDomain, rule, action, workspaceName |
            Sort-Object domain, subDomain, action, rule |
            Format-Table -AutoSize | Out-String | ForEach-Object { WriteMessage "Info" $_ }
    }
    WriteMessage "Info" "Script execution completed successfully."
}
catch {
    $errorResponse = GetErrorResponse($_)
    WriteMessage "Error" "$($errorResponse). Powershell script MapMainFunction failed to complete"
    # Explicitly fail the task and set the result to Failed
    Write-Host "##vso[task.logissue type=error]$errorResponse"
    Write-Host "##vso[task.complete result=Failed;]"
    exit 1
}