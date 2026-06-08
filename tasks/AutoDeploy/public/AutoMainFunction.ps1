###############################################################################
# Accelerator:  FabricCatalyst
# Script Name:  AutoMainFunction.ps1
# Description:  Deploys Fabric items from a GideploymentConfigFileNamet-connected workspace using branch auto-discovery.
# Author:       Svenchio — https://techtacofriday.com
# Project:      https://fabriccatalyst.com
# Usage:        If executed as a Stand-alone script:
#               Step 1. Open a new PowerShell session from the root of the script
#               Step 2. PS> Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
#               Step 3  PS> .\AutoMainFunction.ps1
###############################################################################
param
(
    [parameter(Mandatory = $false)] [String] $fabricGitConnectionName,
    [parameter(Mandatory = $false)] [String] $workspacePrefix,
    [parameter(Mandatory = $false)] [String] $capacityName,
    [parameter(Mandatory = $false)] [String] $domainName,
    [parameter(Mandatory = $false)] [String] $subDomainName,
    [ValidateSet("AzureDevOps","GitHub")]
    [parameter(Mandatory = $false)] [String] $gitProviderType = "AzureDevOps",
    [parameter(Mandatory = $false)] [String] $externalGitPat,
    [parameter(Mandatory = $false)] [String] $organizationName,
    [parameter(Mandatory = $false)] [String] $projectName,
    [parameter(Mandatory = $false)] [String] $repositoryName,
    [parameter(Mandatory = $false)]
    [ValidateSet("True", "False")] [String] $useEmptyBranch = "False",
    [parameter(Mandatory = $false)]
    [ValidateSet("True", "False")] [String] $forceRecreateBranch = "False",
    [parameter(Mandatory = $false)] [String] $sourceBranchName = "main",
    [parameter(Mandatory = $false)] [String] $itemsGitFolder = "/fabric",
    [parameter(Mandatory = $false)] [String] $environmentList,
    [parameter(Mandatory = $false)] [String] $workspaceAdminsList,      #semicolon-separated UPNs
    [parameter(Mandatory = $false)] [String] $workspaceContributorsList, #semicolon-separated UPNs
    [parameter(Mandatory = $false)] [String] $workspaceMembersList,      #semicolon-separated UPNs
    [parameter(Mandatory = $false)] [String] $workspaceViewersList,      #semicolon-separated UPNs
    [parameter(Mandatory = $false)]
    [ValidateSet("True", "False")] [String] $fixItemReferences = "False",
    [parameter(Mandatory = $false)] [String] $deploymentDirectoryPath,
    [ValidateSet("LocalDirectory")]
    [parameter(Mandatory = $false)] [String] $fabricItemsLocation = "LocalDirectory",
    [parameter(Mandatory = $false)]
    [ValidateSet("True", "False")] [String] $enableDiagnostics = "False",
    [parameter(Mandatory = $false)] [Bool] $developerView = $false,
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
. "$private\CapacityFunctions.ps1"
. "$private\DomainFunctions.ps1"
. "$private\GitFunctions.ps1"
. "$private\WorkspaceFunctions.ps1"
. "$private\PipelineFunctions.ps1"
. "$private\LakehouseFunctions.ps1"
. "$private\WarehouseFunctions.ps1"
. "$private\SqlDatabaseFunctions.ps1"
. "$private\ItemFunctions.ps1"
. "$private\ConnectionFunctions.ps1"


try {
    Write-Message "Info" "Powershell version : $($PSVersionTable.PSVersion)"
    # Get all defined parameters in the script
    $scriptParams = $MyInvocation.MyCommand.Parameters.Keys
    $maxLength = ($scriptParams | Measure-Object -Maximum -Property Length).Maximum
    foreach ($param in $scriptParams) {
        $value = Get-Variable -Name $param -ValueOnly -ErrorAction SilentlyContinue
        $displayValue = if ([string]::IsNullOrEmpty($value)) { "empty" } elseif ($param -eq 'externalGitPat') { '****' } else { $value }
        Write-Message "Info" ("{0,-$maxLength} : {1}" -f $param, $displayValue)
    }

    Initialize-AuthContext -TenantId $tenantId -ServicePrincipalId $servicePrincipalId -ServicePrincipalSecret $servicePrincipalSecret | Out-Null
    Get-AzContext | Out-Null

    if ($script:workspacePrefix -notmatch '^[A-Za-z0-9-]+$') {
        throw "The value for workspacePrefix contains invalid characters. Only letters, numbers, and dashes are allowed."
    }
    if ([Convert]::ToBoolean($script:fixItemReferences)) {
        $missingParams = @()
        if ([string]::IsNullOrWhiteSpace($script:deploymentDirectoryPath))                                                                         { $missingParams += 'deploymentDirectoryPath' }
        if ([string]::IsNullOrWhiteSpace($script:organizationName))                                                                                { $missingParams += 'organizationName' }
        if ($script:gitProviderType -eq 'AzureDevOps' -and [string]::IsNullOrWhiteSpace($script:projectName))                                     { $missingParams += 'projectName' }
        if ([string]::IsNullOrWhiteSpace($script:repositoryName))                                                                                  { $missingParams += 'repositoryName' }
        if ([string]::IsNullOrWhiteSpace($script:sourceBranchName))                                                                                { $missingParams += 'sourceBranchName' }
        if ($script:gitProviderType -eq 'GitHub' -and [string]::IsNullOrWhiteSpace($script:externalGitPat))                                       { $missingParams += 'externalGitPat' }
        if ($missingParams.Count -gt 0) {
            throw "fixItemReferences is 'True' but the following required parameters are missing or empty: $($missingParams -join ', ')"
        }
    }
    $availableCapacities = Get-FabricCapacities
    $capacityId = ($availableCapacities | Where-Object { $_.displayName -eq $script:capacityName -and $_.state -eq 'Active' }).id
    if($null -eq $capacityId) {
        Write-Message "Info" "List of capacities the principal can access (either administrator or a contributor):"
        $i = 0
        $availableCapacities | ForEach-Object {
            $i += 1
            Write-Message "Info" "$($i). $($_.displayName) (id:$($_.id), state:$($_.state))"
        }
        throw "Capacity '$($script:capacityName)' could not be found, the process cannot create any fabric items without an EXISTENT & ACTIVE capacity"
    }

    If (![String]::IsNullOrWhiteSpace($script:domainName)) {
        $domainId = New-FabricDomain -domainName $script:domainName
        If (![String]::IsNullOrWhiteSpace($domainId) -and ![String]::IsNullOrWhiteSpace($script:subDomainName)) {
            $domainId = New-FabricDomain -domainName $script:subDomainName -parentDomainId $domainId
        }
    }

    if (![string]::IsNullOrWhiteSpace($script:environmentList)) {
        # Iterate through each item in the array
        Write-Message "Action" "Iterating thru list of enviroments provided $($script:environmentList)"
        $environments = $script:environmentList | ConvertFrom-Json

        if ($environments | Where-Object { [int]$_.gitEnabled -eq 1 }) {
            $missingGitParams = @()
            if ([string]::IsNullOrWhiteSpace($script:organizationName))                                                                            { $missingGitParams += 'organizationName' }
            if ($script:gitProviderType -eq 'AzureDevOps' -and [string]::IsNullOrWhiteSpace($script:projectName))                                 { $missingGitParams += 'projectName' }
            if ([string]::IsNullOrWhiteSpace($script:repositoryName))                                                                              { $missingGitParams += 'repositoryName' }
            if ([string]::IsNullOrWhiteSpace($script:sourceBranchName))                                                                            { $missingGitParams += 'sourceBranchName' }
            if ($script:gitProviderType -eq 'GitHub' -and [string]::IsNullOrWhiteSpace($script:externalGitPat))                                   { $missingGitParams += 'externalGitPat' }
            if ($missingGitParams.Count -gt 0) {
                throw "One or more environments have gitEnabled set but the following required Git parameters are missing or empty: $($missingGitParams -join ', ')"
            }
        }

        foreach ($environment in $environments) {
            $workspaceFQN = "ws_{0}_{1}" -f $script:workspacePrefix, $environment.Code #$envCode
            Write-Message "Action" "Creating workspace $($workspaceFQN) in capacity $($script:capacityName)"
            $workspaceId = New-FabricWorkspace -workspaceName $workspaceFQN -capacityId $capacityId
            If (![String]::IsNullOrWhiteSpace($domainId)) {
                Add-WorkspaceToDomain -domainId $domainId -workspaceId $workspaceId | Out-Null
            }
            Write-Message "Action" "Adding Users to Workspace $($workspaceFQN) ($($workspaceId))"
            Add-WorkspaceUsers -workspaceId $workspaceId -upnList $script:workspaceAdminsList      -workspaceRole "Admin"
            Add-WorkspaceUsers -workspaceId $workspaceId -upnList $script:workspaceContributorsList -workspaceRole "Contributor"
            Add-WorkspaceUsers -workspaceId $workspaceId -upnList $script:workspaceMembersList      -workspaceRole "Member"
            Add-WorkspaceUsers -workspaceId $workspaceId -upnList $script:workspaceViewersList      -workspaceRole "Viewer"

            $configBranchName = $script:sourceBranchName

            if([int]$environment.gitEnabled -eq 1) {
                $script:fabricGitConnectionId = (Get-FabricConnection -connectionName $script:fabricGitConnectionName).id
                if ([string]::IsNullOrWhiteSpace($script:fabricGitConnectionId)) {
                    throw "Cannot connect the workspace to Git because I could not locate the connection '$script:fabricGitConnectionName'"
                }
                $script:newBranchName = "workspace/$($workspaceFQN)"
                
                $gitBranchAzdoConfig = New-AzdoConfig `
                    -AzdoBaseUrl         $script:azdoBaseUrl `
                    -OrganizationName    $script:organizationName `
                    -ProjectName         $script:projectName `
                    -RepositoryName      $script:repositoryName `
                    -SourceBranchName    $script:sourceBranchName `
                    -DevOpsRequestHeader $script:devOpsRequestHeader `
                    -GitProviderType     $script:gitProviderType `
                    -Pat                 $script:externalGitPat
                if([Convert]::ToBoolean($script:useEmptyBranch)) {
                    New-GitBranchFromScratch -newBranchName $newBranchName -itemsGitFolder $script:itemsGitFolder -AzdoConfig $gitBranchAzdoConfig -ForceRecreate:([Convert]::ToBoolean($script:forceRecreateBranch)) | Out-Null
                } else {
                    if (-not (Test-DevOpsRepoPath -gitPath $script:itemsGitFolder -AzdoConfig $gitBranchAzdoConfig)) {
                        throw "Path '$($script:itemsGitFolder)' not found in source branch '$($gitBranchAzdoConfig.SourceBranchName)'. Add this folder to the source branch before running the deployment."
                    }
                    New-GitBranchFromExisting -newBranchName $newBranchName -AzdoConfig $gitBranchAzdoConfig -ForceRecreate:([Convert]::ToBoolean($script:forceRecreateBranch)) | Out-Null
                }
                Write-Message "Action" "Connecting workspace $($workspaceFQN) ($($workspaceId)) to branch $($newBranchName)"
                $gitConfig = New-GitConfig `
                    -GitProviderType       $script:gitProviderType `
                    -OrganizationName      $script:organizationName `
                    -ProjectName           $script:projectName `
                    -RepositoryName        $script:repositoryName `
                    -NewBranchName         $script:newBranchName `
                    -ItemsGitFolder        $script:itemsGitFolder `
                    -FabricGitConnectionId $script:fabricGitConnectionId
                Connect-WorkspaceToGit -workspaceId $workspaceId -GitConfig $gitConfig
            }

            if([Convert]::ToBoolean($script:fixItemReferences)) {
                $configFilePath = "{0}/config-{1}.csv" -f $script:deploymentDirectoryPath, $environment.Code
                $azdoConfig = New-AzdoConfig `
                    -AzdoBaseUrl         $script:azdoBaseUrl `
                    -OrganizationName    $script:organizationName `
                    -ProjectName         $script:projectName `
                    -RepositoryName      $script:repositoryName `
                    -SourceBranchName    $configBranchName `
                    -DevOpsRequestHeader $script:devOpsRequestHeader `
                    -GitProviderType     $script:gitProviderType `
                    -Pat                 $script:externalGitPat
                if (-not (Test-DevOpsRepoPath -gitPath $configFilePath -branchName $configBranchName -AzdoConfig $azdoConfig)) {
                    throw "Customization config file '$configFilePath' not found in the repository. Stopping deployment for '$($workspaceFQN)'."
                }
                Write-Message "Action" "Customizing deployment on $($workspaceFQN)"
                Write-Message "Action" "Scanning workspace $($script:itemsDirectoryPath)"
                $fabricItemsDiscovered = ScanWorkspaceForSupportedItems -workspaceId $workspaceId
                if ($null -ne $fabricItemsDiscovered) {
                    $script:fabricItemsPropertiesCatalog = [PSCustomObject]@{}
                    $script:fabricItemsPropertiesCatalog | Add-Member -MemberType NoteProperty -Name "HomeWorkspace.Id" -Value $workspaceId
                    Invoke-FabricItemCustomization `
                        -workspaceFQN $workspaceFQN `
                        -workspaceId $workspaceId `
                        -fabricItemsDiscovered $fabricItemsDiscovered `
                        -configBranchName $configBranchName `
                        -configFilePath $configFilePath `
                        -enableDiagnostics $script:enableDiagnostics `
                        -catalog $script:fabricItemsPropertiesCatalog `
                        -AzdoConfig $azdoConfig
                }
            }
        }
    }
    else {
        Write-Message "Warning" "Skipping Workspace creation, no environment list was provided"
    }

    Write-Message "Info" "Script execution completed successfully."
}
catch {
    $errorResponse = Get-ErrorResponse($_)
    Write-Message "Error" "$($errorResponse). Powershell script AutoMainFunction failed to complete"
    # Explicitly fail the task and set the result to Failed
    Write-Host "##vso[task.logissue type=error]$errorResponse"
    Write-Host "##vso[task.complete result=Failed;]"
    exit 1
}