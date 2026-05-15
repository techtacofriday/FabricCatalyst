###############################################################################
# Accelerator:  FabricCatalyst
# Script Name:  MapMainFunction.ps1
# Description:  Deploys Fabric items using a JSON map file for SQL-to-Fabric migration scenarios.
# Author:       Svenchio — https://techtacofriday.com
# Project:      https://fabriccatalyst.com
# Usage:        If executed as a Stand-alone script:
#               Step 1. Open a new PowerShell session from the root of the script
#               Step 2. PS> Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
#               Step 3  PS> .\MapMainFunction.ps1
###############################################################################
param
(
    [parameter(Mandatory = $false)] [String] $jsonMapFileName,
    [parameter(Mandatory = $false)]
    [ValidateSet("True", "False")] [String] $updateDefinition = "False",
    [ValidateSet("AzureDevOps")]
    [parameter(Mandatory = $false)] [String] $gitProviderType = "AzureDevOps",
    [parameter(Mandatory = $false)] [String] $organizationName,
    [parameter(Mandatory = $false)] [String] $projectName,
    [parameter(Mandatory = $false)] [String] $repositoryName,
    [parameter(Mandatory = $false)] [String] $sourceBranchName = "main",
    [parameter(Mandatory = $false)] [String] $deploymentDirectoryPath,
    [parameter(Mandatory = $false)] [String] $deploymentDefinitionsPath,
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
$script:fabricBaseUrl = "https://api.fabric.microsoft.com"
$script:powerbiBaseUrl = "https://api.powerbi.com/v1.0/myorg"
$script:azdoBaseUrl = "https://dev.azure.com"
$script:graphBaseUrl = "https://graph.microsoft.com/v1.0"

$private = if (Test-Path "$PSScriptRoot\..\private") { "$PSScriptRoot\..\private" } else { "$PSScriptRoot\..\..\shared\private" }
. "$private\SharedFunctions.ps1"
. "$private\ConnectionFunctions.ps1"
. "$private\CapacityFunctions.ps1"
. "$private\DomainFunctions.ps1"
. "$private\WorkspaceFunctions.ps1"
. "$private\LakehouseFunctions.ps1"
. "$private\WarehouseFunctions.ps1"
. "$private\SqlDatabaseFunctions.ps1"
. "$private\ItemFunctions.ps1"
. "$private\GitFunctions.ps1"

function New-MapItem {
    param (
        [parameter(Mandatory = $true)]  [psobject]       $item,
        [parameter(Mandatory = $true)]  [String]         $type,
        [parameter(Mandatory = $false)] [String]         $parent,
        [parameter(Mandatory = $true)]  [PSCustomObject] $catalog,
        [parameter(Mandatory = $true)]  [String]         $enableDiagnostics,
        [parameter(Mandatory = $false)] [String]         $definitionsLocalPath = $null,
        [parameter(Mandatory = $false)] [PSCustomObject] $Context = $null
    )
    switch ($type) {
        "Connections" {
            Write-Message "Action" "Creating Connection $($item.name)"
            $connectionId = New-FabricConnection -connectionName $item.name -Context $Context
            $catalog | Add-Member -MemberType NoteProperty -Name "$($item.name).Id" -Value $connectionId
            $catalog | Add-Member -MemberType NoteProperty -Name "$($item.name).Name" -Value $item.name
        }
        "Domains" {
            Write-Message "Action" "Creating Domain $($item.name)"
            $domainId = New-FabricDomain -domainName $item.name -Context $Context
            if ($item.rbacAssignments) {
                Write-Message "Action" "Adding users to Domain $($item.name)"
                foreach ($rbacAssignment in $item.rbacAssignments | Where-Object { ($_.type -in @('Admins', 'Contributors')) -and (![string]::IsNullOrWhiteSpace($_.upnList)) } ) {
                    Add-DomainUsers -domainId $domainId -upnList $rbacAssignment.upnList -domainRole $rbacAssignment.type -Context $Context
                }
            }
        }
        "SubDomains" {
            Write-Message "Action" "Creating SubDomain $($item.name) under $parent"
            $parentDomain = Get-FabricDomain -domainName $parent -Context $Context
            if($null -ne $parentDomain) {
                $subDomainId = New-FabricDomain -domainName $item.name -parentDomainId $parentDomain.id -Context $Context
                if ($item.rbacAssignments) {
                    Write-Message "Action" "Adding users to SubDomain $($item.name)"
                    foreach ($rbacAssignment in $item.rbacAssignments | Where-Object { ($_.type -in @('Admins', 'Contributors')) -and (![string]::IsNullOrWhiteSpace($_.upnList)) } ) {
                        Add-DomainUsers -domainId $subDomainId -upnList $rbacAssignment.upnList -domainRole $rbacAssignment.type -Context $Context
                    }
                }
            }
        }
        "Workspaces"  {
            Write-Message "Action" "Creating Workspace $($item.name) in capacity $($item.capacity)"
            $availableCapacities = Get-FabricCapacities -Context $Context
            $capacity = $availableCapacities | Where-Object { $_.displayName -eq $item.capacity -and $_.state -eq 'Active' }
            if($null -ne $capacity) {
                $workspaceId = New-FabricWorkspace -workspaceName $item.name -capacityId $capacity.id -Context $Context
                if ($item.rbacAssignments) {
                    Write-Message "Action" "Adding users to Workspace $($item.name)"
                    foreach ($rbacAssignment in $item.rbacAssignments | Where-Object { ($_.type -in @('Admins', 'Members', 'Contributors', 'Viewers')) -and (![string]::IsNullOrWhiteSpace($_.upnList)) } ) {
                        Add-WorkspaceUsers -workspaceId $workspaceId -upnList $rbacAssignment.upnList -workspaceRole $rbacAssignment.type.Trimend('s') -Context $Context
                    }
                }
                $catalog | Add-Member -MemberType NoteProperty -Name "$($item.name).Id" -Value $workspaceId
                if ([String]::IsNullOrEmpty($parent)) { return }
                Write-Message "Action" "Assigning Workspace $($item.name) to Domain $parent"
                $domain = Get-FabricDomain -domainName $parent -Context $Context
                Add-WorkspaceToDomain -domainId $domain.id -workspaceId $workspaceId -Context $Context | Out-Null
            }
            else {
                Write-Message "Info" "List of capacities the principal can access (either administrator or a contributor):"
                $i = 0
                $availableCapacities | ForEach-Object {
                    $i += 1
                    Write-Message "Info" "$($i). $($_.displayName) (id:$($_.id), state:$($_.state))"
                }
                throw "Capacity '$($item.capacity)' could not be found, the process cannot create any fabric items without an EXISTENT & ACTIVE capacity"
            }
        }
        "Lakehouses"  {
            Write-Message "Action" "Creating Lakehouse $($item.name) in $parent"
            $workspace = Get-FabricWorkspace -workspaceName $parent -Context $Context
            if($null -ne $workspace) {
                $lakehouseId = New-Lakehouse -lakehouseName $item.name -workspaceId $workspace.id -Context $Context
                $catalog | Add-Member -MemberType NoteProperty -Name "$($parent).$($item.name).Id" -Value $lakehouseId
                $catalog | Add-Member -MemberType NoteProperty -Name "$($parent).$($item.name).Name" -Value $item.name
                $lakehouseConnStr = Get-LakehouseSqlEndpoint -lakehouseId $lakehouseId -workspaceId $workspace.id -Context $Context
                $MConnectionExpresion = "let database = Sql.Database(`"$($lakehouseConnStr)`",`"$($item.name)`") in database"
                $catalog | Add-Member -MemberType NoteProperty -Name "$($parent).$($item.name).MConnectionExpresion" -Value $MConnectionExpresion
                if ($item.shortcuts) {
                    Write-Message "Action" "Adding shortcuts to Lakehouse $($item.name)"
                    Add-LakehouseShortcuts -lakehouseId $lakehouseId -workspaceId $workspace.id -shortcuts $item.shortcuts -catalog $catalog -Context $Context
                }
            }
        }
        "Warehouses"  {
            Write-Message "Action" "Creating Warehouse $($item.name) in $parent"
            $workspace = Get-FabricWorkspace -workspaceName $parent -Context $Context
            if($null -ne $workspace) {
                $warehouseId = New-Warehouse -warehouseName $item.name -workspaceId $workspace.id -Context $Context
                $catalog | Add-Member -MemberType NoteProperty -Name "$($parent).$($item.name).Id" -Value $warehouseId
                $catalog | Add-Member -MemberType NoteProperty -Name "$($parent).$($item.name).Name" -Value $item.name
                $warehouse = Get-Warehouse -warehouseId $warehouseId -workspaceId $workspace.id -Context $Context
                $catalog | Add-Member -MemberType NoteProperty -Name "$($parent).$($item.name).CnnString" -Value $warehouse.properties.connectionString
            }
        }
        "SqlDatabases"  {
            Write-Message "Action" "Creating SQL Database $($item.name) in $parent"
            $workspace = Get-FabricWorkspace -workspaceName $parent -Context $Context
            if($null -ne $workspace) {
                $sqldatabaseId = New-SqlDatabase -sqlDatabaseName $item.name -workspaceId $workspace.id -Context $Context
                $catalog | Add-Member -MemberType NoteProperty -Name "$($parent).$($item.name).Id" -Value $sqldatabaseId
                $catalog | Add-Member -MemberType NoteProperty -Name "$($parent).$($item.name).Name" -Value $item.name
                $sqldatabase = Get-SqlDatabase -sqldatabaseId $sqldatabaseId -workspaceId $workspace.id -Context $Context
                $catalog | Add-Member -MemberType NoteProperty -Name "$($parent).$($item.name).CnnString" -Value $sqldatabase.properties.connectionString
            }
        }
        "MirroredDatabases"  {
            Write-Message "Warning" "Skipped  $($type) $($item.name), this Fabric Item is in construction."
        }
        "Notebooks"  {
            $workspace = Get-FabricWorkspace -workspaceName $parent -Context $Context
            if($null -ne $workspace) {
                $detokenizedItem = Update-CatalogTokens -jsonData $item -propertiesCatalog $catalog
                if (![string]::IsNullOrWhiteSpace($detokenizedItem.directory)) {
                    if ([string]::IsNullOrWhiteSpace($definitionsLocalPath)) {
                        throw "Notebook '$($item.name)' has a definition directory but 'deploymentDefinitionsPath' was not provided."
                    }
                    $dfnDirectory = $definitionsLocalPath | Join-Path -ChildPath $detokenizedItem.directory
                    Write-Message "Action" "Preparing Notebook $($item.name) definition parts"
                    $notebookDefinitionParts = New-ItemDefinitionParts `
                        -itemName $item.name `
                        -itemType "Notebook" `
                        -dfnDirectory $dfnDirectory `
                        -dfnParts $detokenizedItem.dfnParts `
                        -NewItem:(-not [Convert]::ToBoolean($updateDefinition)) `
                        -enableDiagnostics $enableDiagnostics

                    if ($null -ne $notebookDefinitionParts) {
                        Write-Message "Action" "Creating Notebook $($item.name) with definition"
                        $notebookId = New-FabricItem `
                            -itemName $item.name `
                            -itemType "Notebook" `
                            -itemDefinitionParts $notebookDefinitionParts  `
                            -partsMandatory 0 `
                            -workspaceId $workspace.id `
                            -updateDefinition ([Convert]::ToBoolean($updateDefinition)) `
                            -Context $Context
                        $catalog | Add-Member -MemberType NoteProperty -Name "$($parent).$($item.name).Id" -Value $notebookId
                        $catalog | Add-Member -MemberType NoteProperty -Name "$($parent).$($item.name).Name" -Value $item.name
                    }
                }
                else {
                    Write-Message "Action" "Creating Notebook $($item.name)"
                    $notebookId = New-FabricItem `
                        -itemName $item.name `
                        -itemType "Notebook" `
                        -workspaceId $workspace.id `
                        -Context $Context
                    $catalog | Add-Member -MemberType NoteProperty -Name "$($parent).$($item.name).Id" -Value $notebookId
                    $catalog | Add-Member -MemberType NoteProperty -Name "$($parent).$($item.name).Name" -Value $item.name
                }
            }
        }
        "SemanticModels"  {
            $workspace = Get-FabricWorkspace -workspaceName $parent -Context $Context
            if($null -ne $workspace) {
                $detokenizedItem = Update-CatalogTokens -jsonData $item -propertiesCatalog $catalog
                if ([string]::IsNullOrWhiteSpace($detokenizedItem.directory)) {
                    throw "Semantic Model '$($item.name)' requires a 'directory' field in the map JSON."
                }
                if ([string]::IsNullOrWhiteSpace($definitionsLocalPath)) {
                    throw "Semantic Model '$($item.name)' requires definition parts but 'deploymentDefinitionsPath' was not provided."
                }
                $dfnDirectory = $definitionsLocalPath | Join-Path -ChildPath $detokenizedItem.directory
                Write-Message "Action" "Preparing Semantic Model $($item.name) definition parts"
                $semanticModelDefinitionParts = New-ItemDefinitionParts `
                    -itemName $item.name `
                    -itemType "SemanticModel" `
                    -dfnDirectory $dfnDirectory `
                    -dfnParts $detokenizedItem.dfnParts `
                    -NewItem:(-not [Convert]::ToBoolean($updateDefinition)) `
                    -enableDiagnostics $enableDiagnostics

                if ($null -ne $semanticModelDefinitionParts) {
                    Write-Message "Action" "Creating Semantic Model $($item.name)"
                    $semanticmodelId = New-FabricItem `
                        -itemName $item.name `
                        -itemType "SemanticModel" `
                        -itemDefinitionParts $semanticModelDefinitionParts  `
                        -partsMandatory 1 `
                        -workspaceId $workspace.id `
                        -updateDefinition ([Convert]::ToBoolean($updateDefinition)) `
                        -Context $Context
                    $catalog | Add-Member -MemberType NoteProperty -Name "$($parent).$($item.name).Id" -Value $semanticmodelId
                    $catalog | Add-Member -MemberType NoteProperty -Name "$($parent).$($item.name).Name" -Value $item.name
                    $ConnectionString = "Data Source=powerbi://api.powerbi.com/v1.0/myorg/$($parent);Initial Catalog=$($item.name);Integrated Security=ClaimsToken"
                    $catalog | Add-Member -MemberType NoteProperty -Name "$($parent).$($item.name).CnnString" -Value $ConnectionString
                    $FlattenedJson = "{'byConnection':{'connectionString':'$($ConnectionString)','connectionType':'pbiServiceXmlaStyleLive','name':'EntityDataSource','pbiModelDatabaseName':'$($semanticmodelId)','pbiModelVirtualServerName':'sobe_wowvirtualserver','pbiServiceModelId':null},'byPath':null}"
                    $catalog | Add-Member -MemberType NoteProperty -Name "$($parent).$($item.name).DatasetReference" -Value $FlattenedJson
                }
            }
        }
        "DataPipelines"  {
            $workspace = Get-FabricWorkspace -workspaceName $parent -Context $Context
            if($null -ne $workspace) {
                $detokenizedItem = Update-CatalogTokens -jsonData $item -propertiesCatalog $catalog
                if (![string]::IsNullOrWhiteSpace($detokenizedItem.directory)) {
                    if ([string]::IsNullOrWhiteSpace($definitionsLocalPath)) {
                        throw "Data Pipeline '$($item.name)' has a definition directory but 'deploymentDefinitionsPath' was not provided."
                    }
                    $dfnDirectory = $definitionsLocalPath | Join-Path -ChildPath $detokenizedItem.directory
                    Write-Message "Action" "Preparing Data Pipeline $($item.name) definition parts"
                    $dataPipelineDefinitionParts = New-ItemDefinitionParts `
                        -itemName $item.name `
                        -itemType "DataPipeline" `
                        -dfnDirectory $dfnDirectory `
                        -dfnParts $detokenizedItem.dfnParts `
                        -NewItem:(-not [Convert]::ToBoolean($updateDefinition)) `
                        -enableDiagnostics $enableDiagnostics

                    if ($null -ne $dataPipelineDefinitionParts) {
                        Write-Message "Action" "Creating Data Pipeline $($item.name) with definition"
                        $dataPipelineId = New-FabricItem `
                            -itemName $item.name `
                            -itemType "DataPipeline" `
                            -itemDefinitionParts $dataPipelineDefinitionParts  `
                            -partsMandatory 0 `
                            -workspaceId $workspace.id `
                            -updateDefinition ([Convert]::ToBoolean($updateDefinition)) `
                            -Context $Context
                        $catalog | Add-Member -MemberType NoteProperty -Name "$($parent).$($item.name).Id" -Value $dataPipelineId
                        $catalog | Add-Member -MemberType NoteProperty -Name "$($parent).$($item.name).Name" -Value $item.name
                    }
                }
                else {
                    Write-Message "Action" "Creating Data Pipeline $($item.name)"
                    $dataPipelineId = New-FabricItem `
                        -itemName $item.name `
                        -itemType "DataPipeline" `
                        -workspaceId $workspace.id `
                        -Context $Context
                    $catalog | Add-Member -MemberType NoteProperty -Name "$($parent).$($item.name).Id" -Value $dataPipelineId
                    $catalog | Add-Member -MemberType NoteProperty -Name "$($parent).$($item.name).Name" -Value $item.name
                }
            }
        }
        "Reports"  {
            $workspace = Get-FabricWorkspace -workspaceName $parent -Context $Context
            if($null -ne $workspace) {
                $detokenizedItem = Update-CatalogTokens -jsonData $item -propertiesCatalog $catalog
                if ([string]::IsNullOrWhiteSpace($detokenizedItem.directory)) {
                    throw "Report '$($item.name)' requires a 'directory' field in the map JSON."
                }
                if ([string]::IsNullOrWhiteSpace($definitionsLocalPath)) {
                    throw "Report '$($item.name)' requires definition parts but 'deploymentDefinitionsPath' was not provided."
                }
                $dfnDirectory = $definitionsLocalPath | Join-Path -ChildPath $detokenizedItem.directory
                Write-Message "Action" "Preparing Report $($item.name) definition parts"
                $reportDefinitionParts = New-ItemDefinitionParts `
                    -itemName $item.name `
                    -itemType "Report" `
                    -dfnDirectory $dfnDirectory `
                    -dfnParts $detokenizedItem.dfnParts `
                    -NewItem:(-not [Convert]::ToBoolean($updateDefinition)) `
                    -enableDiagnostics $enableDiagnostics

                if ($null -ne $reportDefinitionParts) {
                    Write-Message "Action" "Creating Report $($item.name)"
                    $reportId = New-FabricItem `
                        -itemName $item.name `
                        -itemType "Report" `
                        -itemDefinitionParts $reportDefinitionParts  `
                        -workspaceId $workspace.id `
                        -updateDefinition ([Convert]::ToBoolean($updateDefinition)) `
                        -Context $Context
                    $catalog | Add-Member -MemberType NoteProperty -Name "$($parent).$($item.name).Id" -Value $reportId
                    $catalog | Add-Member -MemberType NoteProperty -Name "$($parent).$($item.name).Name" -Value $item.name
                }
            }
        }
        default  {
            Write-Message "Warning" "Skipped  $($type) $($item.name), this Fabric Item is not yet supported."
            Return
        }
    }
}

function Invoke-MapItemProcessing {
    param (
        [Parameter(Mandatory=$true)]  [psobject]       $jsonObject,
        [Parameter(Mandatory=$false)] [string]         $parentName = "",
        [Parameter(Mandatory=$true)]  [PSCustomObject] $catalog,
        [Parameter(Mandatory=$true)]  [string]         $enableDiagnostics,
        [Parameter(Mandatory=$false)] [string]         $definitionsLocalPath = $null,
        [Parameter(Mandatory=$false)] [PSCustomObject] $Context = $null
    )

    # Priority groups
    $priority1 = @("Lakehouses", "Warehouses", "SqlDatabases")
    $priority2 = @("MirroredDatabases", "Notebooks", "SemanticModels", "DataPipelines")
    $priority3 = @("Reports")
    # Helper function to process items based on priority
    function ProcessItemGroup {
        param (
            [Parameter(Mandatory=$true)]  [psobject]       $items,
            [Parameter(Mandatory=$true)]  [array]          $priorityGroup,
            [Parameter(Mandatory=$true)]  [string]         $workspaceName,
            [Parameter(Mandatory=$true)]  [PSCustomObject] $catalog,
            [Parameter(Mandatory=$true)]  [string]         $enableDiagnostics,
            [Parameter(Mandatory=$false)] [string]         $definitionsLocalPath = $null,
            [Parameter(Mandatory=$false)] [PSCustomObject] $Context = $null
        )

        foreach ($category in $priorityGroup) {
            if ($items.PSObject.Properties[$category]) {
                foreach ($item in $items.$category | Where-Object { $_.active -eq 1 }) {
                    New-MapItem -item $item -type $category -parent $workspaceName -catalog $catalog -enableDiagnostics $enableDiagnostics -definitionsLocalPath $definitionsLocalPath -Context $Context
                }
            }
        }
    }

    # Recursive traversal for connections
    if ($jsonObject.PSObject.Properties.Name -contains 'Connections' -and $null -ne $jsonObject.connections) {
        foreach ($connection in $jsonObject.connections | Where-Object { $_.active -eq 1 }) {
            New-MapItem -item $connection -type "Connections" -parent $parentName -catalog $catalog -enableDiagnostics $enableDiagnostics -definitionsLocalPath $definitionsLocalPath -Context $Context
            Invoke-MapItemProcessing -jsonObject $connection -parentName $connection.name -catalog $catalog -enableDiagnostics $enableDiagnostics -definitionsLocalPath $definitionsLocalPath -Context $Context
        }
    }

    # Recursive traversal for domains and subdomains
    if ($jsonObject.PSObject.Properties.Name -contains 'Domains' -and $null -ne $jsonObject.domains) {
        foreach ($domain in $jsonObject.domains | Where-Object { $_.active -eq 1 }) {
            New-MapItem -item $domain -type "Domains" -parent $parentName -catalog $catalog -enableDiagnostics $enableDiagnostics -definitionsLocalPath $definitionsLocalPath -Context $Context
            Invoke-MapItemProcessing -jsonObject $domain -parentName $domain.name -catalog $catalog -enableDiagnostics $enableDiagnostics -definitionsLocalPath $definitionsLocalPath -Context $Context
        }
    }

    if ($jsonObject.PSObject.Properties.Name -contains 'SubDomains' -and $null -ne $jsonObject.subDomains) {
        foreach ($subDomain in $jsonObject.subDomains | Where-Object { $_.active -eq 1 }) {
            New-MapItem -item $subDomain -type "SubDomains" -parent $parentName -catalog $catalog -enableDiagnostics $enableDiagnostics -definitionsLocalPath $definitionsLocalPath -Context $Context
            Invoke-MapItemProcessing -jsonObject $subDomain -parentName $subDomain.name -catalog $catalog -enableDiagnostics $enableDiagnostics -definitionsLocalPath $definitionsLocalPath -Context $Context
        }
    }

    if ($jsonObject.PSObject.Properties.Name -contains 'Workspaces' -and $null -ne $jsonObject.workspaces) {
        foreach ($workspace in $jsonObject.workspaces | Where-Object { $_.active -eq 1 }) {
            New-MapItem -item $workspace -type "Workspaces" -parent $parentName -catalog $catalog -enableDiagnostics $enableDiagnostics -definitionsLocalPath $definitionsLocalPath -Context $Context
            # Process items by priority groups within the workspace
            if ($workspace.PSObject.Properties.Name -contains 'Items' -and $null -ne $workspace.items) {
                $items = $workspace.items
                # Process the first group (lakehouses, warehouses, databases)
                ProcessItemGroup -items $items -priorityGroup $priority1 -workspaceName $workspace.name -catalog $catalog -enableDiagnostics $enableDiagnostics -definitionsLocalPath $definitionsLocalPath -Context $Context
                # Process the second group (semanticModels, dataPipelines, notebooks)
                ProcessItemGroup -items $items -priorityGroup $priority2 -workspaceName $workspace.name -catalog $catalog -enableDiagnostics $enableDiagnostics -definitionsLocalPath $definitionsLocalPath -Context $Context
                # Process the third group (reports)
                ProcessItemGroup -items $items -priorityGroup $priority3 -workspaceName $workspace.name -catalog $catalog -enableDiagnostics $enableDiagnostics -definitionsLocalPath $definitionsLocalPath -Context $Context
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
    Initialize-AuthContext -TenantId $tenantId -ServicePrincipalId $servicePrincipalId -ServicePrincipalSecret $servicePrincipalSecret | Out-Null
    Get-AzContext | Out-Null

    $azdoConfig = New-AzdoConfig `
        -AzdoBaseUrl         $script:azdoBaseUrl `
        -OrganizationName    $script:organizationName `
        -ProjectName         $script:projectName `
        -RepositoryName      $script:repositoryName `
        -SourceBranchName    $script:sourceBranchName `
        -DevOpsRequestHeader $script:devOpsRequestHeader

    Write-Message "Info" "Downloading map JSON file '$jsonMapFileName' from branch '$sourceBranchName'."
    $repoJsonMapFilePath = "$deploymentDirectoryPath/$jsonMapFileName"
    $jsonMap = Get-JsonMapContent -mapFilePath $repoJsonMapFilePath -branchName $sourceBranchName -AzdoConfig $azdoConfig

    $definitionsLocalPath = $null
    if (-not [string]::IsNullOrWhiteSpace($deploymentDefinitionsPath)) {
        Write-Message "Info" "Downloading item definitions from '$deploymentDefinitionsPath'."
        $tempDefinitionsRoot = ".\temp\FabricItems"
        Copy-DevOpsRepoBranchRestAPI `
            -gitPath $deploymentDefinitionsPath `
            -localFolder $tempDefinitionsRoot `
            -AzdoConfig $azdoConfig | Out-Null
        $definitionsLocalPath = $tempDefinitionsRoot | Join-Path -ChildPath $deploymentDefinitionsPath
    }

    #This will contain all the tokens properties collected form item as they are bein created
    $script:fabricItemsPropertiesCatalog = [PSCustomObject]@{}
    # Call the recursive function
    Invoke-MapItemProcessing -jsonObject $jsonMap -catalog $script:fabricItemsPropertiesCatalog -enableDiagnostics $script:enableDiagnostics -definitionsLocalPath $definitionsLocalPath
    Write-Message "Info" "Script execution completed successfully."
}
catch {
    $errorResponse = Get-ErrorResponse($_)
    Write-Message "Error" "$($errorResponse). Powershell script MapMainFunction failed to complete"
    # Explicitly fail the task and set the result to Failed
    Write-Host "##vso[task.logissue type=error]$errorResponse"
    Write-Host "##vso[task.complete result=Failed;]"
    exit 1
}