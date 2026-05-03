###############################################################################
# Script Name:  DomainFunctions.ps1
# Description:  Temporal description
# Author:       Hector Lopez (Manager @Intelligent Platforms)
# Contact:      svenchio@techtacofriday.com
# Blog:         https://www.techtacofriday.com/
###############################################################################

function New-FabricDomain {
    param (
        [parameter(Mandatory = $true)]  [String]         $domainName,
        [parameter(Mandatory = $false)] [String]         $parentDomainId = $null,
        [parameter(Mandatory = $false)] [PSCustomObject] $Context = $null
    )
    $endPoint = "/admin/domains" #https://learn.microsoft.com/en-us/rest/api/fabric/admin/domains/list-domains
    $domainsResponse = Invoke-ApiEndpoint -endPoint $endPoint -Context $Context
    if ($domainsResponse.responseObject.StatusCode -eq 200) {
        $domain = ($domainsResponse.responseObject.Content | ConvertFrom-Json).domains | Where-Object {$_.displayName -eq $domainName}
        if ($null -eq $domain) {
            Write-Message "Action" "Creating new domain $($domainName)."
            $requestBody = @{
                displayName    = $domainName
                description    = $domainName
                parentDomainId = $parentDomainId
            } | ConvertTo-Json -Depth 4
            $endPoint = "/admin/domains" #https://learn.microsoft.com/en-us/rest/api/fabric/admin/domains/create-domain
            $domainResponse = Invoke-ApiEndpoint -endPoint $endPoint -method "POST" -body $requestBody -Context $Context
            if ($domainResponse.responseObject.StatusCode -eq 201) {
                $domain = $domainResponse.responseObject.Content | ConvertFrom-Json
                Write-Message "Info" "Domain $($domainName) ($($domain.id)) was created."
                return $domain.id
            }
            else {
                throw (APIReturnedError -apiCallResponse $domainResponse -intendedAction "creating domain")
            }
        }
        else {
            Write-Message "Info" "Domain $($domainName) ($($domain.id)) was found."
            return $domain.id
        }
    }
    else {
        throw (APIReturnedError -apiCallResponse $domainsResponse -intendedAction "list available domains")
    }
}

function Add-WorkspaceToDomain {
    param (
        [parameter(Mandatory = $true)]  [String]         $domainId,
        [parameter(Mandatory = $true)]  [String]         $workspaceId,
        [parameter(Mandatory = $false)] [PSCustomObject] $Context = $null
    )
    Write-Message "Action" "Assigning workspace $($workspaceId) to domain $($domainId)"
    $requestBody = @{
        workspacesIds = @($workspaceId)
    } | ConvertTo-Json -Depth 4
    $endPoint = "/admin/domains/$($domainId)/assignWorkspaces" #https://learn.microsoft.com/en-us/rest/api/fabric/admin/domains/assign-domain-workspaces-by-ids
    $assignDomainWorkspaceResponse = Invoke-ApiEndpoint -endPoint $endPoint -method "POST" -body $requestBody -Context $Context
    if ($assignDomainWorkspaceResponse.responseObject.StatusCode -eq 200) {
        return $true
    }
    else {
        throw (APIReturnedError -apiCallResponse $assignDomainWorkspaceResponse -intendedAction "assigning a workspace to domain")
    }
}

function Get-FabricDomain {
    param (
        [parameter(Mandatory = $true)]  [String]         $domainName,
        [parameter(Mandatory = $false)] [PSCustomObject] $Context = $null
    )
    $endPoint = "/admin/domains" #https://learn.microsoft.com/en-us/rest/api/fabric/admin/domains/list-domains
    $domainsResponse = Invoke-ApiEndpoint -endPoint $endPoint -Context $Context
    if ($domainsResponse.responseObject.StatusCode -eq 200) {
        return ($domainsResponse.responseObject.Content | ConvertFrom-Json).domains | Where-Object {$_.displayName -eq $domainName}
    }
    else {
        throw (APIReturnedError -apiCallResponse $domainsResponse -intendedAction "list available domains")
    }
}

function Add-DomainUsers {
    param (
        [parameter(Mandatory = $true)]  [String]         $domainId,
        [parameter(Mandatory = $true)]  [String]         $upnList,
        [parameter(Mandatory = $true)]  [String]         $domainRole,
        [parameter(Mandatory = $false)] [bool]           $strictMode = $false,
        [parameter(Mandatory = $false)] [PSCustomObject] $Context = $null
    )
    if ([string]::IsNullOrWhiteSpace($upnList)) { return }
    $upnArray = Resolve-NormalizedUpnList -upnList $upnList
    $failed = @()
    foreach ($upn in $upnArray) {
        $userOrGroup = Resolve-UpnToId -upn $upn -Context $Context
        if ($null -ne $userOrGroup) {
            $addAdminBody = @{
                principals = @(
                @{
                    id   = $userOrGroup.Id
                    type = $userOrGroup.Type
                })
                type = $domainRole #Admins,Contributors
            } | ConvertTo-Json -Depth 4
            $endPoint = "/admin/domains/$($domainId)/roleAssignments/bulkAssign" #https://learn.microsoft.com/en-us/rest/api/fabric/admin/domains/role-assignments-bulk-assign
            $domainRoleAssignmentResponse = Invoke-ApiEndpoint -endPoint $endPoint -method "POST" -body $addAdminBody -Context $Context

            if ($domainRoleAssignmentResponse.responseObject.StatusCode -eq 200) {
                Write-Message "Info" "Added UPN $($upn) as $($domainRole) to the domain."
            }
            else {
                if (@(401, 409) -contains $domainRoleAssignmentResponse.responseObject.StatusCode) {
                    Write-Message "Info" "User with UPN $($upn) is already assigned."
                }
                else {
                    throw (APIReturnedError -apiCallResponse $domainRoleAssignmentResponse -intendedAction "assign user to domain")
                }
            }
        } else {
            $failed += $upn
        }
    }
    if ($failed.Count -gt 0) {
        $message = "Could not resolve the following UPNs for domain role '$($domainRole)': $($failed -join ', ')"
        if ($strictMode) { throw $message }
        else             { Write-Message "Warning" $message }
    }
}
