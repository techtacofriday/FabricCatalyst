###############################################################################
# Script Name:  ConnectionFunctions.ps1
# Description:  Temporal descriptionThis module deals with connection in fabric
# Author:       Hector Lopez (Manager @Intelligent Platforms)
# Contact:      svenchio@techtacofriday.com
# Blog:         https://www.techtacofriday.com/
###############################################################################

function New-FabricConnection {
    param (
        [parameter(Mandatory = $true)]  [String]         $connectionName,
        [parameter(Mandatory = $false)] [PSCustomObject] $Context = $null
    )
    $endPoint = "/connections" #https://learn.microsoft.com/en-us/rest/api/fabric/core/connections/list-connections
    $connectionsResponse = Invoke-ApiEndpoint -endPoint $endPoint -Context $Context
    if ($connectionsResponse.responseObject.StatusCode -eq 200) {
        $connection = ($connectionsResponse.responseObject.Content | ConvertFrom-Json).value | Where-Object {$_.displayName -eq $connectionName}
        if ($null -eq $connection) {
            throw "Connection '$($connectionName)' was not found and automatic connection creation is not yet implemented. Create the connection manually in the Fabric portal before running this deployment."
        }
        else {
            Write-Message "Info" "Connection $($connectionName) ($($connection.id)) was found."
            return $connection.id
        }
    }
    else {
        throw (APIReturnedError -apiCallResponse $connectionsResponse -intendedAction "list available connections")
    }
}


function Get-FabricConnections {
    param (
        [parameter(Mandatory = $false)] [PSCustomObject] $Context = $null
    )
    $endPoint = "/connections" #https://learn.microsoft.com/en-us/rest/api/fabric/core/connections/list-connections
    $connectionsResponse = Invoke-ApiEndpoint -endPoint $endPoint -Context $Context
    if ($connectionsResponse.responseObject.StatusCode -eq 200) {
        return ($connectionsResponse.responseObject.Content | ConvertFrom-Json).value
    }
    else {
        throw (APIReturnedError -apiCallResponse $connectionsResponse -intendedAction "list available connections")
    }
}

function Get-FabricConnection {
    param (
        [parameter(Mandatory = $true)]  [String]         $connectionName,
        [parameter(Mandatory = $false)] [PSCustomObject] $Context = $null
    )
    return Get-FabricConnections -Context $Context | Where-Object {$_.displayName -eq $connectionName}
}
