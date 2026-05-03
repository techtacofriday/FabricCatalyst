###############################################################################
# Script Name:  SqlDatabaseFunctions.ps1
# Description:  Temporal description
# Author:       Hector Lopez (Manager @Intelligent Platforms)
# Contact:      svenchio@techtacofriday.com
# Blog:         https://www.techtacofriday.com/
###############################################################################


function Publish-DatabaseDacpac {
    param (
        [parameter(Mandatory = $true)] [String] $databaseName,
        [parameter(Mandatory = $true)] [String] $serverFqdn,
        [parameter(Mandatory = $true)] [String] $dfnDirectory
    )
    #CALLING VSBuild@1
    #CALLING SqlAzureDacpacDeployment@1 (check if deploy siccessfully)
    Write-Host "##vso[task.setvariable variable=targetSqlServerName;isOutput=true]$serverFqdn"
    Write-Host "##vso[task.setvariable variable=targetSqlDbName;isOutput=true]$databaseName"
    Write-Message "Warning" "Skipping dacapac deployment, this functionality is currently under development"
    Write-Message "Info" "Specificed definition directory $($dfnDirectory)"
    Write-Message "Info" "Returning the server name $($serverFqdn) and database name $($databaseName)"
    return $true
}

function New-SqlDatabase {
    param (
        [parameter(Mandatory = $true)]  [String]         $sqlDatabaseName,
        [parameter(Mandatory = $false)] [String]         $dfnDirectory = $null,
        [parameter(Mandatory = $true)]  [String]         $workspaceId,
        [parameter(Mandatory = $false)] [bool]           $updateDefinition = $false,
        [parameter(Mandatory = $false)] [PSCustomObject] $Context = $null
    )
    $endPoint = "/workspaces/$($workspaceId)/sqldatabases" #URL yet to be published
    $sqldatabasesResponse = Invoke-ApiEndpoint -endPoint $endPoint -Context $Context
    if ($sqldatabasesResponse.responseObject.StatusCode -eq 200) {
        $sqldatabase = ($sqldatabasesResponse.responseObject.Content | ConvertFrom-Json).value | Where-Object {$_.displayName -eq $sqlDatabaseName}
        if (($null -ne $sqldatabase) -and ($null -ne $dfnDirectory) -and $updateDefinition) {
            Write-Message "Info" "Deploying database dacpac"
            Publish-DatabaseDacpac  `
                -databaseName $sqldatabase.properties.databaseName  `
                -serverFqdn $sqldatabase.properties.serverFqdn `
                -dfnDirectory $dfnDirectory | Out-Null
        }
        elseif ($null -eq $sqldatabase) {
            Write-Message "Action" "Creating new SQL Database $($sqlDatabaseName)."
            $requestBody = @{
                displayName = $sqlDatabaseName
                description = $sqlDatabaseName
            } | ConvertTo-Json -Depth 4
            $endPoint = "/workspaces/$($workspaceId)/sqldatabases" #URL yet to be published
            #This endPoint supports long running operations (LRO).
            $sqldatabaseResponse = Invoke-ApiEndpoint -endPoint $endPoint -method "POST" -body $requestBody -Context $Context
            if ($sqldatabaseResponse.isException) {
                throw (APIReturnedError -apiCallResponse $sqldatabaseResponse -intendedAction "create a databases")
            }
            elseif ($sqldatabaseResponse.isException -eq $false -and $sqldatabaseResponse.responseObject.StatusCode -eq 202) {
                $operationId   = [string]($sqldatabaseResponse.responseObject.Headers.'x-ms-operation-id' | Select-Object -First 1)
                $retryInterval = [int]($sqldatabaseResponse.responseObject.Headers.'Retry-After'          | Select-Object -First 1)
                Write-Message "Info" "Request accepted (operation id $($operationId)), deployment in progress."
                Wait-FabricLRO -operationId $operationId -retryInterval $retryInterval -Context $Context | Out-Null
                $sqldatabase = Get-SqlDatabase -sqlDatabaseName $sqlDatabaseName -workspaceId $workspaceId -Context $Context
                if ($null -ne $dfnDirectory) {
                    Publish-DatabaseDacpac  `
                        -databaseName $sqldatabase.properties.databaseName  `
                        -serverFqdn $sqldatabase.properties.serverFqdn `
                        -dfnDirectory $dfnDirectory | Out-Null
                }
                Write-Message "Info" "SQL Database $($sqlDatabaseName) has been deployed successfully"
            }
            else {
                $sqldatabase = $sqldatabaseResponse.responseObject.Content | ConvertFrom-Json
                Write-Message "Info" "SQL Database $($sqlDatabaseName) has been deployed successfully"
            }
            return $sqldatabase.id
        }
        else {
            Write-Message "Info" "SQL Database $sqlDatabaseName ($($sqldatabase.id)) was found."
        }
        return $sqldatabase.id
    }
    else {
        throw (APIReturnedError -apiCallResponse $sqldatabasesResponse -intendedAction "list available databases")
    }
}

function Get-SqlDatabase {
    [CmdletBinding(DefaultParameterSetName = 'ById')]
    param (
        [parameter(Mandatory = $true, ParameterSetName = 'ById')]   [String]         $sqlDatabaseId,
        [parameter(Mandatory = $true, ParameterSetName = 'ByName')] [String]         $sqlDatabaseName,
        [parameter(Mandatory = $true)]                              [String]         $workspaceId,
        [parameter(Mandatory = $false)]                             [PSCustomObject] $Context = $null
    )
    if ($PSCmdlet.ParameterSetName -eq 'ByName') {
        $endPoint = "/workspaces/$($workspaceId)/sqldatabases" #https://learn.microsoft.com/en-us/rest/api/fabric/sqldatabases/items/list-databases
        $response = Invoke-ApiEndpoint -endPoint $endPoint -Context $Context
        if ($response.responseObject.StatusCode -eq 200) {
            return ($response.responseObject.Content | ConvertFrom-Json).value | Where-Object { $_.displayName -eq $sqlDatabaseName }
        }
        throw (APIReturnedError -apiCallResponse $response -intendedAction "list available databases")
    }
    else {
        $endPoint = "/workspaces/$($workspaceId)/sqldatabases/$sqlDatabaseId" #https://learn.microsoft.com/en-us/rest/api/fabric/sqldatabase/items/get-sqldatabase
        $response = Invoke-ApiEndpoint -endPoint $endPoint -Context $Context
        if ($response.responseObject.StatusCode -eq 200) {
            return $response.responseObject.Content | ConvertFrom-Json
        }
        throw (APIReturnedError -apiCallResponse $response -intendedAction "retrieve sql database")
    }
}
