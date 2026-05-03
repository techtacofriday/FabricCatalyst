###############################################################################
# Script Name:  WarehouseFunctions.ps1
# Description:  Temporal description
# Author:       Hector Lopez (Manager @Intelligent Platforms)
# Contact:      svenchio@techtacofriday.com
# Blog:         https://www.techtacofriday.com/
###############################################################################

function New-Warehouse {
    param (
        [parameter(Mandatory = $true)]  [String]         $warehouseName,
        [parameter(Mandatory = $true)]  [String]         $workspaceId,
        [parameter(Mandatory = $false)] [PSCustomObject] $Context = $null
    )
    $endPoint = "/workspaces/$($workspaceId)/warehouses" #https://learn.microsoft.com/en-us/rest/api/fabric/warehouse/items/list-warehouses
    $warehousesResponse = Invoke-ApiEndpoint -endPoint $endPoint -Context $Context
    if ($warehousesResponse.responseObject.StatusCode -eq 200) {
        $warehouse = ($warehousesResponse.responseObject.Content | ConvertFrom-Json).value | Where-Object {$_.displayName -eq $warehouseName}
        if ($null -eq $warehouse) {
            Write-Message "Action" "Creating new warehouse $($warehouseName)."
            $requestBody = @{
                displayName = $warehouseName
                description = $warehouseName
            } | ConvertTo-Json -Depth 4
            $endPoint = "/workspaces/$($workspaceId)/warehouses" #https://learn.microsoft.com/en-us/rest/api/fabric/warehouse/items/create-warehouse
            #This endPoint supports long running operations (LRO).
            $warehouseResponse = Invoke-ApiEndpoint -endPoint $endPoint -method "POST" -body $requestBody -Context $Context
            if ($warehouseResponse.isException) {
                throw (APIReturnedError -apiCallResponse $warehouseResponse -intendedAction "create a warehouse")
            }
            elseif ($warehouseResponse.isException -eq $false -and $warehouseResponse.responseObject.StatusCode -eq 202) {
                $operationId   = [string]($warehouseResponse.responseObject.Headers.'x-ms-operation-id' | Select-Object -First 1)
                $retryInterval = [int]($warehouseResponse.responseObject.Headers.'Retry-After'          | Select-Object -First 1)
                Write-Message "Info" "Request accepted (operation id $($operationId)), deployment in progress."
                $warehouse = Wait-FabricLRO -operationId $operationId -retryInterval $retryInterval -Context $Context
                Write-Message "Info" "Warehouse $($warehouseName) has been deployed successfully"
            }
            else {
                $warehouse = $warehouseResponse.responseObject.Content | ConvertFrom-Json
                Write-Message "Info" "Warehouse $($warehouseName) has been deployed successfully"
            }
        }
        else {
            Write-Message "Info" "Warehouse $warehouseName ($($warehouse.id)) was found."
        }
        return $warehouse.id
    }
    else {
        throw (APIReturnedError -apiCallResponse $warehousesResponse -intendedAction "list available warehouses")
    }
}

function Get-Warehouse {
    param (
        [parameter(Mandatory = $true)]  [String]         $warehouseId,
        [parameter(Mandatory = $true)]  [String]         $workspaceId,
        [parameter(Mandatory = $false)] [PSCustomObject] $Context = $null
    )
    $endPoint = "/workspaces/$($workspaceId)/warehouses/$warehouseId" #https://learn.microsoft.com/en-us/rest/api/fabric/warehouse/items/get-warehouse
    $warehouseResponse = Invoke-ApiEndpoint -endPoint $endPoint -Context $Context
    if ($warehouseResponse.responseObject.StatusCode -eq 200) {
        return $warehouseResponse.responseObject.Content | ConvertFrom-Json
    }
    else {
        throw (APIReturnedError -apiCallResponse $warehouseResponse -intendedAction "retrieve warehouse")
    }
}
