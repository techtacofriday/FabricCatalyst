###############################################################################
# Script Name:  CapacityFunctions.ps1
# Description:  Temporal descriptionThis module list the capacities reachable by the subscription
# Author:       Hector Lopez (Manager @Intelligent Platforms)
# Contact:      svenchio@techtacofriday.com
# Blog:         https://www.techtacofriday.com/
###############################################################################

function Get-FabricCapacities {
    param (
        [parameter(Mandatory = $false)] [PSCustomObject] $Context = $null
    )
    $endPoint = "/capacities" #https://learn.microsoft.com/en-us/rest/api/fabric/core/capacities/list-capacities
    $capacitiesResponse = Invoke-ApiEndpoint -endPoint $endPoint -Context $Context
    if ($capacitiesResponse.responseObject.StatusCode -eq 200) {
        return ($capacitiesResponse.responseObject.Content | ConvertFrom-Json).value
    }
    else {
        throw (APIReturnedError -apiCallResponse $capacitiesResponse -intendedAction "list available capacities")
    }
}

function Get-FabricCapacity {
    param (
        [parameter(Mandatory = $true)]  [String]         $capacityName,
        [parameter(Mandatory = $false)] [PSCustomObject] $Context = $null
    )
    return Get-FabricCapacities -Context $Context | Where-Object {$_.displayName -eq $capacityName -and $_.state -eq 'Active'}
}
