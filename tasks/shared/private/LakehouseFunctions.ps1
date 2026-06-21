###############################################################################
# Script Name:  LakehouseFunctions.ps1
# Description:  Temporal description
# Author:       Hector Lopez (Manager @Intelligent Platforms)
# Contact:      svenchio@techtacofriday.com
# Blog:         https://www.techtacofriday.com/
###############################################################################

function Add-LakehouseShortcuts {
    param (
        [parameter(Mandatory = $true)]  [String]         $lakehouseId,
        [parameter(Mandatory = $true)]  [String]         $workspaceId,
        [parameter(Mandatory = $true)]  [psobject]       $shortcuts,
        [parameter(Mandatory = $false)] [PSCustomObject] $catalog  = $null,
        [parameter(Mandatory = $false)] [PSCustomObject] $Context  = $null
    )
    $resolvedCatalog = if ($null -ne $catalog) { $catalog } else { $script:fabricItemsPropertiesCatalog }
    $endPoint = "/workspaces/$($workspaceId)/items/$($lakehouseId)/shortcuts"
    $lakehouseShortcutsResponse = Invoke-ApiEndpoint -endPoint $endPoint -Context $Context
    if ($lakehouseShortcutsResponse.responseObject.StatusCode -eq 200) {
        Foreach ($shortcut in $shortcuts) {
            $lakehouseShortcut = ($lakehouseShortcutsResponse.responseObject.Content | ConvertFrom-Json).value | Where-Object {$_.name -eq $shortcut.name}
            if ($null -eq $lakehouseShortcut) {
                $detokenizedShortcut = Update-CatalogTokens -jsonData $shortcut `
                    -propertiesCatalog $resolvedCatalog `
                    -targetPropertyName "connectionId"
                $requestBody = $detokenizedShortcut | ConvertTo-Json -Depth 4
                $endPoint = "/workspaces/$($workspaceId)/items/$($lakehouseId)/shortcuts"
                $lakehouseShortcutResponse = Invoke-ApiEndpoint -endPoint $endPoint -method "POST" -body $requestBody -Context $Context
                if ($lakehouseShortcutResponse.responseObject.StatusCode -eq 201) {
                    Write-Message "Info" "Shortcut $($shortcut.name) (path:$($shortcut.path)) on Lakehouse was created."
                }
                else {
                    throw (APIReturnedError -apiCallResponse $lakehouseShortcutResponse -intendedAction "creating Lakehouse shortcut")
                }
            }
            else {
                Write-Message "Info" "Shortcut $($shortcut.name) (path:$($shortcut.path)) on Lakehouse was found."
            }
        }
    }
    else {
        throw (APIReturnedError -apiCallResponse $lakehouseShortcutsResponse -intendedAction "list available Lakehouse shortcuts")
    }
}

function New-Lakehouse {
    param (
        [parameter(Mandatory = $true)]  [String]         $lakehouseName,
        [parameter(Mandatory = $true)]  [String]         $workspaceId,
        [parameter(Mandatory = $false)] [PSCustomObject] $Context = $null
    )
    $endPoint = "/workspaces/$($workspaceId)/lakehouses" #https://learn.microsoft.com/en-us/rest/api/fabric/lakehouse/items/list-lakehouses
    $lakehousesResponse = Invoke-ApiEndpoint -endPoint $endPoint -Context $Context
    if ($lakehousesResponse.responseObject.StatusCode -eq 200) {
        $lakehouse = ($lakehousesResponse.responseObject.Content | ConvertFrom-Json).value | Where-Object {$_.displayName -eq $lakehouseName}
        if ($null -eq $lakehouse) {
            Write-Message "Action" "Creating new lakehouse $($lakehouseName)."
            $requestBody = @{
                displayName = $lakehouseName
                description = $lakehouseName
            } | ConvertTo-Json -Depth 4
            $endPoint = "/workspaces/$($workspaceId)/lakehouses" #https://learn.microsoft.com/en-us/rest/api/fabric/lakehouse/items/create-lakehouse
            #This endPoint supports long running operations (LRO).
            $lakehouseResponse = Invoke-ApiEndpoint -endPoint $endPoint -method "POST" -body $requestBody -Context $Context
            if ($lakehouseResponse.isException) {
                throw (APIReturnedError -apiCallResponse $lakehouseResponse -intendedAction "create a lake house")
            }
            elseif ($lakehouseResponse.isException -eq $false -and $lakehouseResponse.responseObject.StatusCode -eq 202) {
                $operationId   = [string]($lakehouseResponse.responseObject.Headers.'x-ms-operation-id' | Select-Object -First 1)
                $retryInterval = [int]($lakehouseResponse.responseObject.Headers.'Retry-After'          | Select-Object -First 1)
                Write-Message "Info" "Request accepted (operation id $($operationId)), deployment in progress."
                $lakehouse = Wait-FabricLRO -operationId $operationId -retryInterval $retryInterval -Context $Context
                Write-Message "Info" "Lakehouse $($lakehouseName) has been deployed successfully"
            }
            else {
                $lakehouse = $lakehouseResponse.responseObject.Content | ConvertFrom-Json
                Write-Message "Info" "Lakehouse $($lakehouseName) has been deployed successfully"
            }
        }
        else {
            Write-Message "Info" "Lakehouse $lakehouseName ($($lakehouse.id)) was found."
        }
        return $lakehouse.id
    }
    else {
        throw (APIReturnedError -apiCallResponse $lakehousesResponse -intendedAction "list available lakehouses")
    }
}

function Get-Lakehouse {
    param (
        [parameter(Mandatory = $true)]  [String]         $lakehouseId,
        [parameter(Mandatory = $true)]  [String]         $workspaceId,
        [parameter(Mandatory = $false)] [PSCustomObject] $Context = $null
    )
    $endPoint = "/workspaces/$($workspaceId)/lakehouses/$lakehouseId" #https://learn.microsoft.com/en-us/rest/api/fabric/lakehouse/items/get-lakehouse
    $lakehouseResponse = Invoke-ApiEndpoint -endPoint $endPoint -Context $Context
    if ($lakehouseResponse.responseObject.StatusCode -eq 200) {
        return $lakehouseResponse.responseObject.Content | ConvertFrom-Json
    }
    else {
        throw (APIReturnedError -apiCallResponse $lakehouseResponse -intendedAction "retrieveing lakehouse")
    }
}

function Get-LakehouseSqlEndpoint {
    param (
        [parameter(Mandatory = $true)]  [String]         $lakehouseId,
        [parameter(Mandatory = $true)]  [String]         $workspaceId,
        [parameter(Mandatory = $false)] [PSCustomObject] $Context = $null
    )
    #Get the Connection string id from the Item
    $lakehouse = Get-Lakehouse -lakehouseId $lakehouseId -workspaceId $workspaceId -Context $Context
    $attemptCount = 1 # Tracks the total elapsed time
    $retryInterval = 5 # Retry interval in seconds
    $attemptMax = 12 # Total timeout in seconds
    while ($true) {
        if ($lakehouse.properties.sqlEndpointProperties.provisioningStatus -eq "Success") {
            return $lakehouse.properties.sqlEndpointProperties.connectionString
        }
        elseif ($attemptCount -eq $attemptMax) {
            throw "Max number of attempts has been reached"
        }
        Write-Message "Action" "Waiting $($retryInterval) secs for sqlEndpointProperties to be successfully provisioned (Attempt $($attemptCount) out of $($attemptMax))"
        Start-Sleep -Seconds $retryInterval
        $lakehouse = Get-Lakehouse -lakehouseId $lakehouseId -workspaceId $workspaceId -Context $Context
        $attemptCount = $attemptCount+1
    }
}
