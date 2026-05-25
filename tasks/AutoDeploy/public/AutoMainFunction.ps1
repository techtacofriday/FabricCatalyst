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
    [parameter(Mandatory = $false)] [String] $sourceBranchName = "main",
    [parameter(Mandatory = $false)] [String] $itemsGitFolder = "/fabric",
    [parameter(Mandatory = $false)] [String] $environmentList,
    [parameter(Mandatory = $false)] [String] $workspaceAdminsList,      #semicolon-separated UPNs
    [parameter(Mandatory = $false)] [String] $workspaceContributorsList, #semicolon-separated UPNs
    [parameter(Mandatory = $false)] [String] $workspaceMembersList,      #semicolon-separated UPNs
    [parameter(Mandatory = $false)] [String] $workspaceViewersList,      #semicolon-separated UPNs
    [parameter(Mandatory = $false)]
    [ValidateSet("True", "False")] [String] $customizeDeployment = "False",
    [parameter(Mandatory = $false)] [String] $deploymentDirectoryPath,
    [ValidateSet("LocalDirectory")]
    [parameter(Mandatory = $false)] [String] $fabricItemsLocation = "LocalDirectory",
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


function Invoke-FabricItemCustomization() {
    param (
        [parameter(Mandatory = $true)]  [String]         $workspaceFQN,
        [parameter(Mandatory = $true)]  [String]         $workspaceId,
        [parameter(Mandatory = $true)]  [PSCustomObject] $fabricItemsDiscovered,
        [parameter(Mandatory = $true)]  [String]         $configBranchName,
        [parameter(Mandatory = $true)]  [String]         $configFilePath,
        [parameter(Mandatory = $true)]  [String]         $enableDiagnostics,
        [parameter(Mandatory = $true)]  [PSCustomObject] $catalog,
        [parameter(Mandatory = $false)] [PSCustomObject] $Context = $null,
        [parameter(Mandatory = $false)] [PSCustomObject] $AzdoConfig = $null
    )

    Write-Message "Info" "Selected config file $($configFilePath)."
    $csvContent = Get-DeploymentCsvContent -configFilePath $configFilePath -branchName $configBranchName -AzdoConfig $AzdoConfig

    #Deploy Tier 1 Fabric Items
    $customFabricItemsTier = 1 #Tier 1 items are those that do not have dependencies to other items
    $tierCustomFabricItems = $fabricItemsDiscovered | Where-Object {($_.tier) -eq $customFabricItemsTier} | Sort-Object -Property priority #-Ascending
    foreach ($tierCustomFabricItem in $tierCustomFabricItems) {
        if ($tierCustomFabricItem.type -eq "lakehouse") {
            $lakehouseName = $tierCustomFabricItem.name
            $catalog | Add-Member -MemberType NoteProperty -Name "$($tierCustomFabricItem.itemFQN).Id" -Value $tierCustomFabricItem.id
            $catalog | Add-Member -MemberType NoteProperty -Name "$($tierCustomFabricItem.itemFQN).Name" -Value $tierCustomFabricItem.name
            #Get the Connection string id from the Item
            $lakehouseConnStr = Get-LakehouseSqlEndpoint -lakehouseId $tierCustomFabricItem.id -workspaceId $workspaceId -Context $Context
            $MConnectionExpresion = "let database = Sql.Database(`"`"$($lakehouseConnStr)`"`",`"`"$($lakehouseName)`"`") in database"
            $catalog | Add-Member -MemberType NoteProperty -Name "$($tierCustomFabricItem.itemFQN).MConnectionExpresion" -Value $MConnectionExpresion
        }
        elseif ($tierCustomFabricItem.type -eq "warehouse") {
            $catalog | Add-Member -MemberType NoteProperty -Name "$($tierCustomFabricItem.itemFQN).Id" -Value $tierCustomFabricItem.id
            $catalog | Add-Member -MemberType NoteProperty -Name "$($tierCustomFabricItem.itemFQN).Name" -Value $tierCustomFabricItem.name
            #Get the SqlCnnString from the Item
            $warehouse = Get-Warehouse -warehouseId $tierCustomFabricItem.id -workspaceId $workspaceId -Context $Context
            $catalog | Add-Member -MemberType NoteProperty -Name "$($tierCustomFabricItem.itemFQN).CnnString" -Value $warehouse.properties.connectionString
        }
        <# THE SQL DATABASE EXPERIENCE IS STILL IN PRIVATE PREVIEW #>
        elseif ($tierCustomFabricItem.type -eq "sqldatabase") {
            $catalog | Add-Member -MemberType NoteProperty -Name "$($tierCustomFabricItem.itemFQN).Id" -Value $tierCustomFabricItem.id
            $catalog | Add-Member -MemberType NoteProperty -Name "$($tierCustomFabricItem.itemFQN).Name" -Value $tierCustomFabricItem.name
            #Get the SqlCnnString from the Item
            $sqldatabase = Get-SqlDatabase -sqldatabaseId $tierCustomFabricItem.id -workspaceId $workspaceId -Context $Context
            $catalog | Add-Member -MemberType NoteProperty -Name "$($tierCustomFabricItem.itemFQN).CnnString" -Value $sqldatabase.properties.connectionString
        }
    }

    #Detokenize config file with tier 1 PropertiesCatalog
    $newCsvFilePath = Invoke-DetokenizeConfigFile -csvContent $csvContent -customFabricItemsTier $customFabricItemsTier -catalog $catalog -deploymentConfigFileName (Split-Path -Leaf $configFilePath)
    #Deploy Tier 2 Fabric Items
    $customFabricItemsTier++ #Tier 1 items are those with direct dependency to Tier 1
    $tierCustomFabricItems = $fabricItemsDiscovered | Where-Object {($_.tier) -eq $customFabricItemsTier} |  Sort-Object -Property priority #-Ascending

    foreach ($tierCustomFabricItem in $tierCustomFabricItems) {
        if ($tierCustomFabricItem.type -eq "notebook") {
            Write-Message "Action" "Preparing Notebook $($tierCustomFabricItem.name) Definition Parts"
            $notebookDefinitionParts = New-ItemDefinitionParts `
                -itemName $tierCustomFabricItem.name `
                -itemType $tierCustomFabricItem.type `
                -csvFilePath $newCsvFilePath `
                -dfnDirectory $tierCustomFabricItem.directory `
                -dfnParts $tierCustomFabricItem.dfnParts `
                -enableDiagnostics $enableDiagnostics

            if ($null -ne $notebookDefinitionParts) {
                Write-Message "Action" "Updating Notebook $($tierCustomFabricItem.name)"
                New-FabricItem `
                    -itemName $tierCustomFabricItem.name `
                    -itemType $tierCustomFabricItem.type `
                    -itemDefinitionParts $notebookDefinitionParts  `
                    -partsMandatory $tierCustomFabricItem.partsMandatory `
                    -workspaceId $workspaceId `
                    -updateDefinition $true `
                    -Context $Context | Out-Null
            }
            $catalog | Add-Member -MemberType NoteProperty -Name "$($tierCustomFabricItem.itemFQN).Id" -Value $tierCustomFabricItem.id -Force
            $catalog | Add-Member -MemberType NoteProperty -Name "$($tierCustomFabricItem.itemFQN).Name" -Value $tierCustomFabricItem.name -Force
        }
        elseif ($tierCustomFabricItem.type -eq "semanticmodel") {
            Write-Message "Action" "Preparing Semantic Model $($tierCustomFabricItem.name) Definition Parts"
            $semanticModelDefinitionParts = New-ItemDefinitionParts `
                -itemName $tierCustomFabricItem.name `
                -itemType $tierCustomFabricItem.type `
                -csvFilePath $newCsvFilePath `
                -dfnDirectory $tierCustomFabricItem.directory `
                -dfnParts $tierCustomFabricItem.dfnParts `
                -enableDiagnostics $enableDiagnostics

            if ($null -ne $semanticModelDefinitionParts) {
                Write-Message "Action" "Updating Semantic Model $($tierCustomFabricItem.name)"
                New-FabricItem `
                    -itemName $tierCustomFabricItem.name `
                    -itemType $tierCustomFabricItem.type `
                    -itemDefinitionParts $semanticModelDefinitionParts  `
                    -partsMandatory $tierCustomFabricItem.partsMandatory `
                    -workspaceId $workspaceId `
                    -updateDefinition $true `
                    -Context $Context | Out-Null
            }
            $catalog | Add-Member -MemberType NoteProperty -Name "$($tierCustomFabricItem.itemFQN).Id" -Value $tierCustomFabricItem.id -Force
            $catalog | Add-Member -MemberType NoteProperty -Name "$($tierCustomFabricItem.itemFQN).Name" -Value $tierCustomFabricItem.name -Force
            $ConnectionString = "Data Source=powerbi://api.powerbi.com/v1.0/myorg/$($workspaceFQN);Initial Catalog=$($tierCustomFabricItem.name);Integrated Security=ClaimsToken"
            $catalog | Add-Member -MemberType NoteProperty -Name "$($tierCustomFabricItem.itemFQN).CnnString" -Value $ConnectionString -Force
            $FlattenedJson = "{`"`"byConnection`"`":{`"`"connectionString`"`":`"`"$($ConnectionString)`"`",`"`"connectionType`"`":`"`"pbiServiceXmlaStyleLive`"`",`"`"name`"`":`"`"EntityDataSource`"`",`"`"pbiModelDatabaseName`"`":`"`"$($tierCustomFabricItem.id)`"`",`"`"pbiModelVirtualServerName`"`":`"`"sobe_wowvirtualserver`"`",`"`"pbiServiceModelId`"`":null},`"`"byPath`"`":null}"
            $catalog | Add-Member -MemberType NoteProperty -Name "$($tierCustomFabricItem.itemFQN).DatasetReference" -Value $FlattenedJson -Force
        }
        elseif ($tierCustomFabricItem.type -eq "datapipeline") {
            Write-Message "Action" "Preparing Data Pipeline $($tierCustomFabricItem.name) Definition Parts"
            $dataPipelineDefinitionParts = New-ItemDefinitionParts `
                    -itemName $tierCustomFabricItem.name `
                    -itemType $tierCustomFabricItem.type `
                    -csvFilePath $newCsvFilePath `
                    -dfnDirectory $tierCustomFabricItem.directory `
                    -dfnParts $tierCustomFabricItem.dfnParts `
                    -enableDiagnostics $enableDiagnostics

            if ($null -ne $dataPipelineDefinitionParts) {
                Write-Message "Action" "Updating Data Pipeline $($tierCustomFabricItem.name)"
                New-FabricItem `
                    -itemName $tierCustomFabricItem.name `
                    -itemType $tierCustomFabricItem.type `
                    -itemDefinitionParts $dataPipelineDefinitionParts  `
                    -partsMandatory $tierCustomFabricItem.partsMandatory `
                    -workspaceId $workspaceId `
                    -updateDefinition $true `
                    -Context $Context | Out-Null
            }
            $catalog | Add-Member -MemberType NoteProperty -Name "$($tierCustomFabricItem.itemFQN).Id" -Value $tierCustomFabricItem.id -Force
            $catalog | Add-Member -MemberType NoteProperty -Name "$($tierCustomFabricItem.itemFQN).Name" -Value $tierCustomFabricItem.name -Force
        }
    }

    #Detokenize config file with tier 2 PropertiesCatalog
    $newCsvFilePath = Invoke-DetokenizeConfigFile -csvContent $csvContent -customFabricItemsTier $customFabricItemsTier -catalog $catalog -deploymentConfigFileName (Split-Path -Leaf $configFilePath)
    #Deploy Tier 3 Fabric Items
    $customFabricItemsTier++
    $tierCustomFabricItems = $fabricItemsDiscovered | Where-Object {($_.tier) -eq $customFabricItemsTier} |  Sort-Object -Property priority #-Ascending
    foreach ($tierCustomFabricItem in $tierCustomFabricItems) {
        if ($tierCustomFabricItem.type -eq "report") {
            Write-Message "Action" "Preparing Report $($tierCustomFabricItem.name) Definition Parts"
            $reportDefinitionParts = New-ItemDefinitionParts `
                -itemName $tierCustomFabricItem.name `
                -itemType $tierCustomFabricItem.type `
                -csvFilePath $newCsvFilePath `
                -dfnDirectory $tierCustomFabricItem.directory `
                -dfnParts $tierCustomFabricItem.dfnParts `
                -enableDiagnostics $enableDiagnostics

            if ($null -ne $reportDefinitionParts) {
                Write-Message "Action" "Updating Report $($tierCustomFabricItem.name)"
                New-FabricItem `
                    -itemName $tierCustomFabricItem.name `
                    -itemType $tierCustomFabricItem.type `
                    -itemDefinitionParts $reportDefinitionParts  `
                    -partsMandatory $tierCustomFabricItem.partsMandatory `
                    -workspaceId $workspaceId `
                    -updateDefinition $true `
                    -Context $Context | Out-Null
            }
            $catalog | Add-Member -MemberType NoteProperty -Name "$($tierCustomFabricItem.itemFQN).Id" -Value $tierCustomFabricItem.id -Force
            $catalog | Add-Member -MemberType NoteProperty -Name "$($tierCustomFabricItem.itemFQN).Name" -Value $tierCustomFabricItem.name -Force
        }
    }
}

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
    if ([Convert]::ToBoolean($script:customizeDeployment)) {
        $missingParams = @()
        if ([string]::IsNullOrWhiteSpace($script:deploymentDirectoryPath))                                                                         { $missingParams += 'deploymentDirectoryPath' }
        if ([string]::IsNullOrWhiteSpace($script:organizationName))                                                                                { $missingParams += 'organizationName' }
        if ($script:gitProviderType -eq 'AzureDevOps' -and [string]::IsNullOrWhiteSpace($script:projectName))                                     { $missingParams += 'projectName' }
        if ([string]::IsNullOrWhiteSpace($script:repositoryName))                                                                                  { $missingParams += 'repositoryName' }
        if ([string]::IsNullOrWhiteSpace($script:sourceBranchName))                                                                                { $missingParams += 'sourceBranchName' }
        if ($script:gitProviderType -eq 'GitHub' -and [string]::IsNullOrWhiteSpace($script:externalGitPat))                                       { $missingParams += 'externalGitPat' }
        if ($missingParams.Count -gt 0) {
            throw "customizeDeployment is 'True' but the following required parameters are missing or empty: $($missingParams -join ', ')"
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
                    New-GitBranchFromScratch -newBranchName $newBranchName -itemsGitFolder $script:itemsGitFolder -AzdoConfig $gitBranchAzdoConfig | Out-Null
                } else {
                    New-GitBranchFromExisting -newBranchName $newBranchName -AzdoConfig $gitBranchAzdoConfig | Out-Null
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

            if([Convert]::ToBoolean($script:customizeDeployment)) {
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