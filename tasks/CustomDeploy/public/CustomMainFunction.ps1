###############################################################################
# Accelerator:  FabricCatalyst
# Script Name:  CustomMainFunction.ps1
# Description:  Deploys Fabric items by copying from a template workspace; no Git integration.
# Author:       Svenchio — https://techtacofriday.com
# Project:      https://fabriccatalyst.com
# Usage:        If executed as a Stand-alone script:
#               Step 1. Open a new PowerShell session from the root of the script
#               Step 2. PS> Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
#               Step 3  PS> .\CustomMainFunction.ps1
###############################################################################
param
(
    [parameter(Mandatory = $false)] [String] $dataProduct = "Default",
    [parameter(Mandatory = $false)] [String] $workspacePrefix,
    [parameter(Mandatory = $false)] [String] $capacityName,
    [parameter(Mandatory = $false)] [String] $domainName,
    [parameter(Mandatory = $false)] [String] $subDomainName,
    [parameter(Mandatory = $false)] [String] $environmentList,
    [parameter(Mandatory = $false)] [String] $workspaceAdminsList, #semicolon-separated UPNs
    [parameter(Mandatory = $false)]
    [ValidateSet("True", "False")] [String] $updateDefinition = "True",
    [parameter(Mandatory = $false)]
    [ValidateSet("True", "False")] [String] $enableDiagnostics = "False",
    [ValidateSet("AzureDevOps")]
    [parameter(Mandatory = $false)] [String] $gitProviderType = "AzureDevOps",
    [parameter(Mandatory = $false)] [String] $organizationName,
    [parameter(Mandatory = $false)] [String] $projectName,
    [parameter(Mandatory = $false)] [String] $repositoryName,
    [parameter(Mandatory = $false)] [String] $sourceBranchName = "main",
    [parameter(Mandatory = $false)] [String] $sourceWorkspaceName,
    [parameter(Mandatory = $false)] [String] $deploymentDirectoryPath,
    [ValidateSet("LocalDirectory")]
    [parameter(Mandatory = $false)] [String] $fabricItemsLocation = "LocalDirectory",
    [parameter(Mandatory = $false)] [Bool] $developerView = $false
)

#References to the API's
$script:powerbiBaseUrl = "https://api.powerbi.com/v1.0/myorg"
$script:fabricBaseUrl = "https://api.fabric.microsoft.com"
$script:azdoBaseUrl = "https://dev.azure.com"
$script:graphBaseUrl = "https://graph.microsoft.com/v1.0"

$private = if (Test-Path "$PSScriptRoot\..\private") { "$PSScriptRoot\..\private" } else { "$PSScriptRoot\..\..\shared\private" }
. "$private\SharedFunctions.ps1"
. "$private\CapacityFunctions.ps1"
. "$private\ConnectionFunctions.ps1"
. "$private\DomainFunctions.ps1"
. "$private\WorkspaceFunctions.ps1"
. "$private\LakehouseFunctions.ps1"
. "$private\WarehouseFunctions.ps1"
. "$private\SqlDatabaseFunctions.ps1"
. "$private\ItemFunctions.ps1"
. "$private\GitFunctions.ps1"

function Publish-CustomFabricItems() {
    param (
        [parameter(Mandatory = $true)]  [String]         $workspaceFQN,
        [parameter(Mandatory = $true)]  [String]         $workspaceId,
        [parameter(Mandatory = $true)]  [PSCustomObject] $fabricItemsDiscovered,
        [parameter(Mandatory = $true)]  [String]         $configFilePath,
        [parameter(Mandatory = $true)]  [String]         $branchName,
        [parameter(Mandatory = $true)]  [String]         $enableDiagnostics,
        [parameter(Mandatory = $true)]  [PSCustomObject] $catalog,
        [parameter(Mandatory = $false)] [PSCustomObject] $Context = $null,
        [parameter(Mandatory = $false)] [PSCustomObject] $AzdoConfig = $null
    )

    Write-Message "Info" "Selected config file $($configFilePath)."
    $csvContent = Get-DeploymentCsvContent -configFilePath $configFilePath -branchName $branchName -AzdoConfig $AzdoConfig

    #Discover Fabric Connections
    Write-Message "Action" "Discovering available connections"
    $FabricConnections = Get-FabricConnections -Context $Context
    foreach ($FabricConnection in $FabricConnections) {
        Write-Message "Info" "Connection $($FabricConnection.displayname) ($($FabricConnection.id))"
        $catalog | Add-Member -MemberType NoteProperty -Name "$($FabricConnection.displayname).Connection.Id" -Value $FabricConnection.id -Force
    }

    #Deploy Tier 1 Fabric Items
    $customFabricItemsTier = 1 #Tier 1 items are those that do not have dependencies to other items
    $tierCustomFabricItems = $fabricItemsDiscovered | Where-Object {($_.tier) -eq $customFabricItemsTier} | Sort-Object -Property priority #-Ascending
    foreach ($tierCustomFabricItem in $tierCustomFabricItems) {
        if ($tierCustomFabricItem.type -eq "lakehouse") {
            Write-Message "Action" "Deploying Lakehouse $($tierCustomFabricItem.name) on $($workspaceFQN)"
            $lakehouseId = New-Lakehouse -lakehouseName $tierCustomFabricItem.name -workspaceId $workspaceId -Context $Context
            $lakehouseName = $tierCustomFabricItem.name
            $catalog | Add-Member -MemberType NoteProperty -Name "$($tierCustomFabricItem.itemFQN).Id" -Value $lakehouseId -Force
            $catalog | Add-Member -MemberType NoteProperty -Name "$($tierCustomFabricItem.itemFQN).Name" -Value $lakehouseName -Force
            #Get the Connection string id from the Item
            $lakehouseConnStr = Get-LakehouseSqlEndpoint -lakehouseId $lakehouseId -workspaceId $workspaceId -Context $Context
            $MConnectionExpresion = "let database = Sql.Database(`"`"$($lakehouseConnStr)`"`",`"`"$($lakehouseName)`"`") in database"
            $catalog | Add-Member -MemberType NoteProperty -Name "$($tierCustomFabricItem.itemFQN).MConnectionExpresion" -Value $MConnectionExpresion -Force
        }
        elseif ($tierCustomFabricItem.type -eq "warehouse") {
            Write-Message "Action" "Deploying Warehouse $($tierCustomFabricItem.name) on $($workspaceFQN)"
            $warehouseId = New-Warehouse -warehouseName $tierCustomFabricItem.name -workspaceId $workspaceId -Context $Context
            $catalog | Add-Member -MemberType NoteProperty -Name "$($tierCustomFabricItem.itemFQN).Id" -Value $warehouseId -Force
            $catalog | Add-Member -MemberType NoteProperty -Name "$($tierCustomFabricItem.itemFQN).Name" -Value $tierCustomFabricItem.name -Force
            #Get the SqlCnnString from the Item
            $warehouse = Get-Warehouse -warehouseId $warehouseId -workspaceId $workspaceId -Context $Context
            $catalog | Add-Member -MemberType NoteProperty -Name "$($tierCustomFabricItem.itemFQN).CnnString" -Value $warehouse.properties.connectionString -Force
        }
        <# THE SQL DATABASE EXPERIENCE IS STILL IN PRIVATE PREVIEW #>
        elseif ($tierCustomFabricItem.type -eq "sqldatabase") {
            Write-Message "Action" "Deploying SQL Database $($tierCustomFabricItem.name) on $($workspaceFQN)"
            $sqldatabaseId = New-SqlDatabase  `
                -sqlDatabaseName $tierCustomFabricItem.name  `
                -dfnDirectory $tierCustomFabricItem.directory `
                -workspaceId $workspaceId `
                -updateDefinition ([Convert]::ToBoolean($updateDefinition)) `
                -Context $Context

            $catalog | Add-Member -MemberType NoteProperty -Name "$($tierCustomFabricItem.itemFQN).Id" -Value $sqldatabaseId -Force
            $catalog | Add-Member -MemberType NoteProperty -Name "$($tierCustomFabricItem.itemFQN).Name" -Value $tierCustomFabricItem.name -Force
            #Get the SqlCnnString from the Item
            $sqldatabase = Get-SqlDatabase -sqldatabaseId $sqldatabaseId -workspaceId $workspaceId -Context $Context
            $catalog | Add-Member -MemberType NoteProperty -Name "$($tierCustomFabricItem.itemFQN).CnnString" -Value $sqldatabase.properties.connectionInfo -Force
            $catalog | Add-Member -MemberType NoteProperty -Name "$($tierCustomFabricItem.itemFQN).DatabaseName" -Value $sqldatabase.properties.databaseName -Force
            $catalog | Add-Member -MemberType NoteProperty -Name "$($tierCustomFabricItem.itemFQN).ServerFqdn" -Value $sqldatabase.properties.serverFqdn -Force
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
                Write-Message "Action" "Deploying Notebook $($tierCustomFabricItem.name) on $($workspaceFQN)"
                $notebookId = New-FabricItem `
                    -itemName $tierCustomFabricItem.name `
                    -itemType $tierCustomFabricItem.type `
                    -itemDefinitionParts $notebookDefinitionParts  `
                    -partsMandatory $tierCustomFabricItem.partsMandatory `
                    -workspaceId $workspaceId `
                    -updateDefinition ([Convert]::ToBoolean($updateDefinition)) `
                    -Context $Context
                $catalog | Add-Member -MemberType NoteProperty -Name "$($tierCustomFabricItem.itemFQN).Id" -Value $notebookId -Force
                $catalog | Add-Member -MemberType NoteProperty -Name "$($tierCustomFabricItem.itemFQN).Name" -Value $tierCustomFabricItem.name -Force
            }
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
                Write-Message "Action" "Deploying Semantic Model $($tierCustomFabricItem.name) on $($workspaceFQN)"
                $semanticmodelId = New-FabricItem `
                    -itemName $tierCustomFabricItem.name `
                    -itemType $tierCustomFabricItem.type `
                    -itemDefinitionParts $semanticModelDefinitionParts  `
                    -partsMandatory $tierCustomFabricItem.partsMandatory `
                    -workspaceId $workspaceId `
                    -updateDefinition ([Convert]::ToBoolean($updateDefinition)) `
                    -Context $Context
                $catalog | Add-Member -MemberType NoteProperty -Name "$($tierCustomFabricItem.itemFQN).Id" -Value $semanticmodelId -Force
                $catalog | Add-Member -MemberType NoteProperty -Name "$($tierCustomFabricItem.itemFQN).Name" -Value $tierCustomFabricItem.name -Force
                $ConnectionString = "Data Source=powerbi://api.powerbi.com/v1.0/myorg/$($workspaceFQN);Initial Catalog=$($tierCustomFabricItem.name);Integrated Security=ClaimsToken"
                $catalog | Add-Member -MemberType NoteProperty -Name "$($tierCustomFabricItem.itemFQN).CnnString" -Value $ConnectionString -Force
                $FlattenedJson = "{`"`"byConnection`"`":{`"`"connectionString`"`":`"`"$($ConnectionString)`"`",`"`"connectionType`"`":`"`"pbiServiceXmlaStyleLive`"`",`"`"name`"`":`"`"EntityDataSource`"`",`"`"pbiModelDatabaseName`"`":`"`"$($semanticmodelId)`"`",`"`"pbiModelVirtualServerName`"`":`"`"sobe_wowvirtualserver`"`",`"`"pbiServiceModelId`"`":null},`"`"byPath`"`":null}"
                $catalog | Add-Member -MemberType NoteProperty -Name "$($tierCustomFabricItem.itemFQN).DatasetReference" -Value $FlattenedJson -Force
            }
        }
        elseif ($tierCustomFabricItem.type -eq "mirroreddatabase") {
            Write-Message "Action" "Preparing Mirrored Database $($tierCustomFabricItem.name) Definition Parts"
            $mirroredDatabaseDefinitionParts = New-ItemDefinitionParts `
                    -itemName $tierCustomFabricItem.name `
                    -itemType $tierCustomFabricItem.type `
                    -csvFilePath $newCsvFilePath `
                    -dfnDirectory $tierCustomFabricItem.directory `
                    -dfnParts $tierCustomFabricItem.dfnParts `
                    -enableDiagnostics $enableDiagnostics

            if ($null -ne $mirroredDatabaseDefinitionParts) {
                Write-Message "Action" "Deploying Mirrored Database $($tierCustomFabricItem.name) on $($workspaceFQN)"
                $mirroredDatabaseId = New-FabricItem `
                    -itemName $tierCustomFabricItem.name `
                    -itemType $tierCustomFabricItem.type `
                    -itemDefinitionParts $mirroredDatabaseDefinitionParts  `
                    -partsMandatory $tierCustomFabricItem.partsMandatory `
                    -workspaceId $workspaceId `
                    -updateDefinition ([Convert]::ToBoolean($updateDefinition)) `
                    -Context $Context
                $catalog | Add-Member -MemberType NoteProperty -Name "$($tierCustomFabricItem.itemFQN).Id" -Value $mirroredDatabaseId -Force
                $catalog | Add-Member -MemberType NoteProperty -Name "$($tierCustomFabricItem.itemFQN).Name" -Value $tierCustomFabricItem.name -Force
            }
        }
    }

    #Detokenize config file with tier 2 PropertiesCatalog
    $newCsvFilePath = Invoke-DetokenizeConfigFile -csvContent $csvContent -customFabricItemsTier $customFabricItemsTier -catalog $catalog -deploymentConfigFileName (Split-Path -Leaf $configFilePath)
    #Deploy Tier 3 Fabric Items
    $customFabricItemsTier++
    $tierCustomFabricItems = $fabricItemsDiscovered | Where-Object {($_.tier) -eq $customFabricItemsTier} |  Sort-Object -Property priority #-Ascending
    foreach ($tierCustomFabricItem in $tierCustomFabricItems) {
        if ($tierCustomFabricItem.type -eq "datapipeline") {
            Write-Message "Action" "Preparing Data Pipeline $($tierCustomFabricItem.name) Definition Parts"
            $dataPipelineDefinitionParts = New-ItemDefinitionParts `
                    -itemName $tierCustomFabricItem.name `
                    -itemType $tierCustomFabricItem.type `
                    -csvFilePath $newCsvFilePath `
                    -dfnDirectory $tierCustomFabricItem.directory `
                    -dfnParts $tierCustomFabricItem.dfnParts `
                    -enableDiagnostics $enableDiagnostics

            if ($null -ne $dataPipelineDefinitionParts) {
                Write-Message "Action" "Deploying Data Pipeline $($tierCustomFabricItem.name) on $($workspaceFQN)"
                $dataPipelineId = New-FabricItem `
                    -itemName $tierCustomFabricItem.name `
                    -itemType $tierCustomFabricItem.type `
                    -ItemDefinitionFormat $tierCustomFabricItem.dfnFormat `
                    -itemDefinitionParts $dataPipelineDefinitionParts  `
                    -partsMandatory $tierCustomFabricItem.partsMandatory `
                    -workspaceId $workspaceId `
                    -updateDefinition ([Convert]::ToBoolean($updateDefinition)) `
                    -Context $Context
                $catalog | Add-Member -MemberType NoteProperty -Name "$($tierCustomFabricItem.itemFQN).Id" -Value $dataPipelineId -Force
                $catalog | Add-Member -MemberType NoteProperty -Name "$($tierCustomFabricItem.itemFQN).Name" -Value $tierCustomFabricItem.name -Force
            }
        }
        elseif ($tierCustomFabricItem.type -eq "report") {
            Write-Message "Action" "Preparing Report $($tierCustomFabricItem.name) Definition Parts"
            $reportDefinitionParts = New-ItemDefinitionParts `
                -itemName $tierCustomFabricItem.name `
                -itemType $tierCustomFabricItem.type `
                -csvFilePath $newCsvFilePath `
                -dfnDirectory $tierCustomFabricItem.directory `
                -dfnParts $tierCustomFabricItem.dfnParts `
                -enableDiagnostics $enableDiagnostics

            if ($null -ne $reportDefinitionParts) {
                Write-Message "Action" "Deploying Report $($tierCustomFabricItem.name) on $($workspaceFQN)"
                $reportId = New-FabricItem `
                    -itemName $tierCustomFabricItem.name `
                    -itemType $tierCustomFabricItem.type `
                    -itemDefinitionParts $reportDefinitionParts  `
                    -partsMandatory $tierCustomFabricItem.partsMandatory `
                    -workspaceId $workspaceId `
                    -updateDefinition ([Convert]::ToBoolean($updateDefinition)) `
                    -Context $Context
                $catalog | Add-Member -MemberType NoteProperty -Name "$($tierCustomFabricItem.itemFQN).Id" -Value $reportId -Force
                $catalog | Add-Member -MemberType NoteProperty -Name "$($tierCustomFabricItem.itemFQN).Name" -Value $tierCustomFabricItem.name -Force
            }
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
        $displayValue = if ([string]::IsNullOrEmpty($value)) { "empty" } else { $value }
        Write-Message "Info" ("{0,-$maxLength} : {1}" -f $param, $displayValue)
    }
    Initialize-AuthContext | Out-Null
    Get-AzContext | Out-Null

    if ($script:workspacePrefix -notmatch '^[A-Za-z0-9-]+$') {
        throw "The value for workspacePrefix contains invalid characters. Only letters, numbers, and dashes are allowed."
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

    #This will contain all the tokens properties collected form item as they are bein created
    if (![string]::IsNullOrWhiteSpace($script:environmentList)) {
        $environments = $script:environmentList | ConvertFrom-Json

        $azdoConfig = New-AzdoConfig `
            -AzdoBaseUrl         $script:azdoBaseUrl `
            -OrganizationName    $script:organizationName `
            -ProjectName         $script:projectName `
            -RepositoryName      $script:repositoryName `
            -SourceBranchName    $script:sourceBranchName `
            -DevOpsRequestHeader $script:devOpsRequestHeader

        $missingConfigs = @()
        foreach ($env in $environments) {
            $configFilePath = "$($script:deploymentDirectoryPath)/$($script:dataProduct)/config-$($env.Code).csv"
            if (-not (Test-DevOpsRepoPath -gitPath $configFilePath -AzdoConfig $azdoConfig)) {
                $missingConfigs += $configFilePath
            }
        }
        if ($missingConfigs.Count -gt 0) {
            throw "The following required config files were not found in the repository: $($missingConfigs -join ', ')"
        }

        $sourceWorkspace = Get-FabricWorkspace -workspaceName $script:sourceWorkspaceName
        if ($null -eq $sourceWorkspace)
        {
            throw "Workspace '$($script:sourceWorkspaceName)' could not be found"
        }
        Write-Message "Action" "Scanning workspace $($sourceWorkspace.displayName)"
        $fabricItemsDiscovered = ScanWorkspaceForSupportedItems -workspaceId $sourceWorkspace.id
        # Iterate through each item in the array
        Write-Message "Action" "Iterating thru list of enviroments provided $($script:environmentList)"
        foreach ($environment in $environments) {
            $script:fabricItemsPropertiesCatalog = [PSCustomObject]@{}
            $workspaceFQN = "ws_{0}_{1}" -f $script:workspacePrefix, $environment.Code #$envCode
            Write-Message "Action" "Creating workspace $($workspaceFQN) in capacity $($script:capacityName)"
            $workspaceId = New-FabricWorkspace -workspaceName $workspaceFQN -capacityId $capacityId
            If (![String]::IsNullOrWhiteSpace($domainId)) {
                Add-WorkspaceToDomain -domainId $domainId -workspaceId $workspaceId | Out-Null
            }
            #Adding user to the workspace
            Write-Message "Action" "Adding Users to Workspace $($workspaceFQN) ($($workspaceId))"
            Add-WorkspaceUsers -workspaceId $workspaceId -upnList $script:workspaceAdminsList -workspaceRole "Admin"
            # Adding the workspace id to my properties catalog
            $script:fabricItemsPropertiesCatalog | Add-Member -MemberType NoteProperty -Name "HomeWorkspace.Id" -Value $workspaceId -Force
            $script:fabricItemsPropertiesCatalog | Add-Member -MemberType NoteProperty -Name "HomeWorkspace.Name" -Value $workspaceFQN -Force
            if([bool]$environment.gitEnabled) {
                Write-Message "Warning" "Skipping Git-enabling this workspace, this functionality is not currently support on Custom Deployment. "
            }
            if ($null -ne $fabricItemsDiscovered) {
                $configFilePath = "{0}/config-{1}.csv" -f $script:deploymentDirectoryPath, $environment.Code
                Publish-CustomFabricItems `
                    -workspaceFQN $workspaceFQN `
                    -workspaceId $workspaceId `
                    -fabricItemsDiscovered $fabricItemsDiscovered `
                    -configFilePath $configFilePath `
                    -branchName $script:sourceBranchName `
                    -enableDiagnostics $script:enableDiagnostics `
                    -catalog $script:fabricItemsPropertiesCatalog `
                    -AzdoConfig $azdoConfig
            }
        }
    }
    else {
        Write-Message "Warning" "Skipping workspace creation, no environment list was provided"
    }
    Write-Message "Info" "Script execution completed successfully."
}
catch {
    $errorResponse = Get-ErrorResponse($_)
    Write-Message "Error" "$($errorResponse). Powershell script CustomMainFunction failed to complete"
    # Explicitly fail the task and set the result to Failed
    Write-Host "##vso[task.logissue type=error]$errorResponse"
    Write-Host "##vso[task.complete result=Failed;]"
    exit 1
}