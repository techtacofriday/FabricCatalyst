###############################################################################
# Script Name:  WorkspaceFunctions.ps1
# Description:  Temporal description
# Author:       Hector Lopez (Manager @Intelligent Platforms)
# Contact:      svenchio@techtacofriday.com
# Blog:         https://www.techtacofriday.com/
###############################################################################

function Get-Workspaces {
    [CmdletBinding()]
    param(
        [Parameter()] [string]         $workspaceName,
        [Parameter()] [string]         $capacityId,
        [Parameter()]
        [ValidateSet('active','deleted')]
        [string] $workspaceState = 'active',
        [Parameter()]
        [ValidateSet('personal','workspace','adminworkspace')]
        [string] $workspaceType = 'workspace',
        [Parameter()] [PSCustomObject] $Context = $null
    )
    # Build query parameters only when provided
    $query = [ordered]@{
        type  = $workspaceType
        state = $workspaceState
    }
    if ($workspaceName) { $query.name = $workspaceName }
    if ($capacityId) { $query.capacityId = $capacityId }  # confirm the param name matches the API

    # Build query string with URL encoding
    $queryString = ($query.GetEnumerator() | ForEach-Object {
        '{0}={1}' -f $_.Key, [uri]::EscapeDataString([string]$_.Value)
    }) -join '&'

    $endPoint = "/admin/workspaces?$queryString" #https://learn.microsoft.com/en-us/rest/api/fabric/admin/workspaces/list-workspaces?tabs=HTTP

    $resp = Invoke-ApiEndpoint -endPoint $endPoint -Context $Context

    if ($resp.responseObject.StatusCode -ne 200) {
        throw (APIReturnedError -apiCallResponse $resp -intendedAction "list workspaces")
    }

    $payload = $resp.responseObject.Content | ConvertFrom-Json
    return @($payload.workspaces)  # always an array even if 0/1 items
}

function Get-WorkspacesCore {
    [CmdletBinding()]
    param(
        [Parameter()] [PSCustomObject] $Context = $null
    )
    $results = [System.Collections.Generic.List[object]]::new()
    $endPoint = "/workspaces" #https://learn.microsoft.com/en-us/rest/api/fabric/core/workspaces/list-workspaces

    do {
        $resp = Invoke-ApiEndpoint -endPoint $endPoint -Context $Context
        if ($resp.responseObject.StatusCode -ne 200) {
            throw (APIReturnedError -apiCallResponse $resp -intendedAction "list workspaces (core)")
        }
        $payload = $resp.responseObject.Content | ConvertFrom-Json
        if ($null -ne $payload.value) { $results.AddRange([object[]]$payload.value) }

        if (![string]::IsNullOrWhiteSpace($payload.continuationToken)) {
            $endPoint = "/workspaces?continuationToken=$([uri]::EscapeDataString($payload.continuationToken))"
        } else {
            $endPoint = $null
        }
    } while ($null -ne $endPoint)

    return @($results)
}

function New-FabricWorkspace {
    param (
        [parameter(Mandatory = $true)]  [String]         $workspaceName,
        [parameter(Mandatory = $true)]  [String]         $capacityId,
        [parameter(Mandatory = $false)] [bool]           $ProvisionIdentity = $true,
        [parameter(Mandatory = $false)] [PSCustomObject] $Context = $null
    )

    $workspace = (Get-Workspaces -workspaceName $workspaceName -Context $Context | Select-Object -First 1)

    if ($null -eq $workspace) {
        Write-Message "Action" "Creating new workspace $($workspaceName)."
        $requestBody = @{
            displayName = $workspaceName
            capacityId  = $capacityId
        } | ConvertTo-Json -Depth 4
        $endPoint = "/workspaces" #https://learn.microsoft.com/en-us/rest/api/fabric/core/workspaces/create-workspace
        $workspaceResponse = Invoke-ApiEndpoint -endPoint $endPoint -method "POST" -body $requestBody -Context $Context
        if ($workspaceResponse.responseObject.StatusCode -eq 201) {
            $workspace = $workspaceResponse.responseObject.Content | ConvertFrom-Json
            Write-Message "Info" "Workspace $workspaceName($($workspace.id)) was created."
        }
        else {
            if (@(409) -contains $workspaceResponse.responseObject.StatusCode) {
                throw "Workspace with this name already exists within this tenant administered by another user"
            }
            else {
                throw (APIReturnedError -apiCallResponse $workspaceResponse -intendedAction "create workspace")
            }
        }
    }
    else {
        If ($workspace.capacityId -eq $capacityId) { Write-Message "Info" "Workspace $workspaceName ($($workspace.id)) was found." }
        else { Write-Message "Warning" "Workspace $workspaceName ($($workspace.id)) was found in a different capacity." }
    }

    if ($ProvisionIdentity) {
        $hasIdentity = $null -ne $workspace.workspaceIdentity -and
                       -not [string]::IsNullOrWhiteSpace($workspace.workspaceIdentity.servicePrincipalId)
        if (-not $hasIdentity) {
            Write-Message "Action" "Provisioning identity for workspace $($workspace.id)."
            $endPoint = "/workspaces/$($workspace.id)/provisionIdentity" #https://learn.microsoft.com/en-us/rest/api/fabric/core/workspaces/provision-identity
            $identityResponse = Invoke-ApiEndpoint -endPoint $endPoint -method "POST" -Context $Context
            if ($identityResponse.responseObject.StatusCode -eq 202) {
                $operationId   = [string]($identityResponse.responseObject.Headers.'x-ms-operation-id' | Select-Object -First 1)
                $retryHeader   = [string]($identityResponse.responseObject.Headers.'Retry-After'        | Select-Object -First 1)
                $retryInterval = if ($retryHeader -match '^\d+$') { [int]$retryHeader } else { 5 }
                Wait-FabricLRO -operationId $operationId -retryInterval $retryInterval -Context $Context | Out-Null
                Write-Message "Info" "Identity provisioned for workspace $($workspace.id)."
            }
            elseif ($identityResponse.responseObject.StatusCode -eq 200) {
                Write-Message "Info" "Identity provisioned for workspace $($workspace.id)."
            }
            elseif ($identityResponse.isException) {
                throw (APIReturnedError -apiCallResponse $identityResponse -intendedAction "provision workspace identity")
            }
        }
        else {
            Write-Message "Info" "Workspace $($workspace.id) already has an identity, skipping provisioning."
        }
    }

    return $workspace.id

}

function Connect-WorkspaceToGit {
    param (
        [parameter(Mandatory = $true)]  [String]         $workspaceId,
        [parameter(Mandatory = $false)] [Bool]           $connectToGit = $true,
        [parameter(Mandatory = $false)] [PSCustomObject] $GitConfig = $null,
        [parameter(Mandatory = $false)] [PSCustomObject] $Context = $null
    )

    $resolvedGitProviderType       = if ($null -ne $GitConfig) { $GitConfig.GitProviderType }       else { $script:gitProviderType }
    $resolvedOrganizationName      = if ($null -ne $GitConfig) { $GitConfig.OrganizationName }      else { $script:organizationName }
    $resolvedProjectName           = if ($null -ne $GitConfig) { $GitConfig.ProjectName }           else { $script:projectName }
    $resolvedRepositoryName        = if ($null -ne $GitConfig) { $GitConfig.RepositoryName }        else { $script:repositoryName }
    $resolvedNewBranchName         = if ($null -ne $GitConfig) { $GitConfig.NewBranchName }         else { $script:newBranchName }
    $resolvedItemsGitFolder        = if ($null -ne $GitConfig) { $GitConfig.ItemsGitFolder }        else { $script:itemsGitFolder }
    $resolvedFabricGitConnectionId = if ($null -ne $GitConfig) { $GitConfig.FabricGitConnectionId } else { $script:fabricGitConnectionId }

    if ($connectToGit) {
        #Step 1. Configure the workspace to be Git-Enabled
        $gitProviderDetails = @{
            gitProviderType = $resolvedGitProviderType
            repositoryName  = $resolvedRepositoryName
            branchName      = $resolvedNewBranchName
            directoryName   = $resolvedItemsGitFolder
        }
        if ($resolvedGitProviderType -eq "AzureDevOps") {
            $gitProviderDetails.organizationName = $resolvedOrganizationName
            $gitProviderDetails.projectName      = $resolvedProjectName
        } else {
            $gitProviderDetails.ownerName = $resolvedOrganizationName
        }
        $myGitCredentials = @{
            source       = "ConfiguredConnection"
            connectionId = $resolvedFabricGitConnectionId
        }
        $requestBody = @{
            gitProviderDetails = $gitProviderDetails
            myGitCredentials   = $myGitCredentials
        } | ConvertTo-Json -Depth 4
        $endPoint = "/workspaces/$($workspaceId)/git/connect" #https://learn.microsoft.com/en-us/rest/api/fabric/core/git/connect
        $connectToGitResponse = Invoke-ApiEndpoint -endPoint $endPoint -method "POST" -body $requestBody -Context $Context
        if ($connectToGitResponse.isException) {
            if ($connectToGitResponse.responseObject.StatusCode -eq 409) {
                Write-Message "Info" "Workspace is already connected to git."
            }
            else {
                throw (APIReturnedError -apiCallResponse $connectToGitResponse -intendedAction "connect to git")
            }
        }
        elseif ($connectToGitResponse.responseObject.StatusCode -eq 200) {
            Write-Message "Info" "Workspace successfully connected to git repository and branch."
        }
    }
    else {
        $requestBody = @{
            source       = "ConfiguredConnection"
            connectionId = $resolvedFabricGitConnectionId
        } | ConvertTo-Json -Depth 4
        $endPoint = "/workspaces/$($workspaceId)/git/myGitCredentials" #https://learn.microsoft.com/en-us/rest/api/fabric/core/git/update-my-git-credentials
        #This endPoint supports long running operations (LRO).
        $updatemygitcredentials = Invoke-ApiEndpoint -endPoint $endPoint -method "PATCH" -body $requestBody -Context $Context
        if ($updatemygitcredentials.isException) {
            throw (APIReturnedError -apiCallResponse $updatemygitcredentials -intendedAction "update-my-git-credentials")
        }
    }

    #Step 2. Workspace need to be "initialized"
    $requestBody = @{
        InitializationStrategy = "PreferWorkspace"
    } | ConvertTo-Json -Depth 4
    $endPoint = "/workspaces/$($workspaceId)/git/initializeConnection" #https://learn.microsoft.com/en-us/rest/api/fabric/core/git/initialize-connection
    #This endPoint supports long running operations (LRO).
    $initializeConnectionResponse = Invoke-ApiEndpoint -endPoint $endPoint -method "POST" -body $requestBody -Context $Context
    if ($initializeConnectionResponse.isException) {
        if ($initializeConnectionResponse.responseObject.StatusCode -eq 409) {
            Write-Message "Info" "Workspace has already been initialized."
        }
        else {
            throw (APIReturnedError -apiCallResponse $initializeConnectionResponse -intendedAction "initialize git connection")
        }
    }
    elseif ($initializeConnectionResponse.isException -eq $false -and $initializeConnectionResponse.responseObject.StatusCode -eq 202) {
        $operationId   = [string]($initializeConnectionResponse.responseObject.Headers.'x-ms-operation-id' | Select-Object -First 1)
        $retryInterval = [int]($initializeConnectionResponse.responseObject.Headers.'Retry-After'          | Select-Object -First 1)
        Write-Message "Info" "Request accepted (operation id $($operationId)), initialize connection in progress."
        Wait-FabricLRO -operationId $operationId -retryInterval $retryInterval -Context $Context | Out-Null
        Write-Message "Info" "Workspace has been initialized."
    }

    $endPoint = "/workspaces/$($workspaceId)/git/status" #https://learn.microsoft.com/en-us/rest/api/fabric/core/git/get-status
    $gitStatusResponse = Invoke-ApiEndpoint -endPoint $endPoint -method "GET" -Context $Context

    if ($gitStatusResponse.isException) {
        throw (APIReturnedError -apiCallResponse $gitStatusResponse -intendedAction "getting git status.")
    }
    else {
        $gitStatus = $gitStatusResponse.responseObject.Content | ConvertFrom-Json
        if ($null -eq $gitStatus.remoteCommitHash) {
            Write-Message "Warning" "Skipping updateFromGit because the the remoteCommitHash on the selected branch is null"
            return
        }
    }

    #Step 3. By issuing updateFromGit the workspace will create any items on the repo/branch
    $requestBody = @{
        workspaceHead    = $gitStatus.workspaceHead
        remoteCommitHash = $gitStatus.remoteCommitHash
        conflictResolution = @{
            conflictResolutionType   = "Workspace"
            conflictResolutionPolicy = "PreferRemote"
        }
        options = @{
            allowOverrideItems = $TRUE
        }
    } | ConvertTo-Json -Depth 4
    $endPoint = "/workspaces/$($workspaceId)/git/updateFromGit" #https://learn.microsoft.com/en-us/rest/api/fabric/core/git/update-from-git
    #This endPoint supports long running operations (LRO).
    $updateFromGitResponse = Invoke-ApiEndpoint -endPoint $endPoint -method "POST" -body $requestBody -Context $Context
    if ($updateFromGitResponse.isException) {
        if ($updateFromGitResponse.responseObject.StatusCode -eq 409) {
            Write-Message "Info" "Workspace has already been updated."
        }
        else {
            throw (APIReturnedError -apiCallResponse $updateFromGitResponse -intendedAction "update from git")
        }
    }
    elseif ($updateFromGitResponse.isException -eq $false -and $updateFromGitResponse.responseObject.StatusCode -eq 202) {
        $operationId   = [string]($updateFromGitResponse.responseObject.Headers.'x-ms-operation-id' | Select-Object -First 1)
        $retryInterval = [int]($updateFromGitResponse.responseObject.Headers.'Retry-After'          | Select-Object -First 1)
        Write-Message "Info" "Request accepted (operation id $($operationId)), update from Git in progress."
        Wait-FabricLRO -operationId $operationId -retryInterval $retryInterval -Context $Context | Out-Null
        Write-Message "Info" "Workspace has been updated."
    }
    else {
        Write-Message "Info" "Workspace has been updated."
    }

}

function Test-WorkspaceGitConnected {
    param (
        [parameter(Mandatory = $true)]  [String]         $workspaceId,
        [parameter(Mandatory = $false)] [PSCustomObject] $Context = $null
    )

    $requestBody = @{ InitializationStrategy = "PreferWorkspace" } | ConvertTo-Json -Depth 4
    $endPoint = "/workspaces/$workspaceId/git/initializeConnection"
    $resp = Invoke-ApiEndpoint -endPoint $endPoint -method "POST" -body $requestBody -Context $Context

    if ($resp.isException) {
        # 409 = already initialized — workspace IS connected to git
        if ($resp.responseObject.StatusCode -eq 409) {
            return $true
        }
        # 400 = WorkspaceNotConnectedToGit (Fabric returns this as a non-2xx so the body is lost in the catch block)
        if ($resp.responseObject.StatusCode -eq 400) {
            return $false
        }
        # API-level error in a 2xx body (defensive — Fabric currently uses 400 for this case)
        if ($resp.responseObject.ErrorCode -eq "WorkspaceNotConnectedToGit") {
            return $false
        }
        throw (APIReturnedError -apiCallResponse $resp -intendedAction "probe git connection status")
    }
    return $true
}

function Add-WorkspaceUsers {
    param (
        [parameter(Mandatory = $true)]
        [String] $workspaceId,

        # semicolon-separated list of UPNs
        [parameter(Mandatory = $false)]
        [String] $upnList = "",

        [parameter(Mandatory = $true)]
        [ValidateSet("Admin", "Contributor", "Member", "Viewer")]
        [String] $workspaceRole,

        [parameter(Mandatory = $false)]
        [bool] $strictMode = $false,

        [parameter(Mandatory = $false)]
        [PSCustomObject] $Context = $null
    )

    # 0) No-op when list is null/empty/whitespace
    if ([string]::IsNullOrWhiteSpace($upnList)) {
        Write-Message "Info" "No UPNs provided; leaving current '$workspaceRole' role assignments unchanged."
        return
    }

    # 1) Normalize and de-duplicate target UPNs
    $targetUpns = Resolve-NormalizedUpnList -upnList $upnList

    if ($targetUpns.Count -eq 0) {
        Write-Message "Info" "Parsed UPN list is empty after normalization; leaving current '$workspaceRole' role assignments unchanged."
        return
    }

    # 2) Resolve target UPNs -> principals (Users/Groups only; SPNs are not resolvable here)
    $resolvedTargetsByUpn = @{}
    $validAssignableTypes = @('User','Group')
    $failed = @()

    foreach ($upn in $targetUpns) {
        $userOrGroup = Resolve-UpnToId -upn $upn -Context $Context
        if ($null -ne $userOrGroup -and -not [string]::IsNullOrWhiteSpace($userOrGroup.Id)) {
            if (-not [string]::IsNullOrWhiteSpace($userOrGroup.Type) -and ($validAssignableTypes -contains $userOrGroup.Type)) {
                $resolvedTargetsByUpn[$upn] = $userOrGroup
            } else {
                $failed += "'$upn' (unsupported type: $($userOrGroup.Type))"
            }
        } else {
            $failed += "'$upn' (could not be resolved)"
        }
    }
    if ($failed.Count -gt 0) {
        $message = "Could not resolve the following identifiers for role '$($workspaceRole)': $($failed -join ', ')"
        if ($strictMode) { throw $message }
        else             { Write-Message "Warning" $message }
    }

    if ($resolvedTargetsByUpn.Count -eq 0) {
        Write-Message "Warning" "No identifiers could be resolved for role '$($workspaceRole)'; skipping role assignment sync to avoid removing existing members."
        return
    }

    $targetPrincipalIds = @($resolvedTargetsByUpn.Values |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_.Id) -and ($validAssignableTypes -contains $_.Type) } |
        ForEach-Object { $_.Id } |
        Select-Object -Unique)

    # 3) Fetch current role assignments
    $listEndpoint = "/workspaces/$workspaceId/roleAssignments"
    $roleAssignmentsResponse = Invoke-ApiEndpoint -endPoint $listEndpoint -method "GET" -Context $Context

    if ($roleAssignmentsResponse.responseObject.StatusCode -ne 200) {
        throw (APIReturnedError -apiCallResponse $roleAssignmentsResponse -intendedAction "list workspace role assignments")
    }

    $assignmentsJson = $roleAssignmentsResponse.responseObject.Content
    $assignmentsObj  = $assignmentsJson | ConvertFrom-Json
    $allAssignments  = if ($assignmentsObj.value) { $assignmentsObj.value } else { @($assignmentsObj) }

    # Consider only assignments for the requested role
    $currentRoleAssignments = $allAssignments | Where-Object { $_.role -eq $workspaceRole }

    $existingPrincipalIds    = @()
    $assignmentByPrincipalId = @{}
    $principalContextById    = @{}

    foreach ($a in $currentRoleAssignments) {
        $p = $a.principal
        $principalId = $p.id
        if (-not [string]::IsNullOrWhiteSpace($principalId)) {
            $existingPrincipalIds += $principalId
            $assignmentByPrincipalId[$principalId] = $a
            $principalCtx = @{
                DisplayName = $p.displayName
                Type        = $p.type                  # "User" | "Group" | "ServicePrincipal"
                UPN         = $p.userDetails.userPrincipalName
                AadAppId    = $p.servicePrincipalDetails.aadAppId
            }
            $principalContextById[$principalId] = $principalCtx
        }
    }
    $existingPrincipalIds = $existingPrincipalIds | Select-Object -Unique

    # Identify existing Service Principals in THIS role (to preserve them)
    $existingSpnIdsForRole = @(
        $principalContextById.GetEnumerator() |
        Where-Object { $_.Value.Type -eq 'ServicePrincipal' } |
        ForEach-Object { $_.Key }
    )

    # 4) Decide adds and removals (Users/Groups only; SPNs are always preserved)
    $diff = Compare-RoleAssignments `
        -TargetIds    $targetPrincipalIds `
        -ExistingIds  $existingPrincipalIds `
        -PreservedIds $existingSpnIdsForRole
    $principalIdsToAdd    = $diff.ToAdd
    $principalIdsToRemove = $diff.ToRemove

    # 5) Perform additions (Users/Groups)
    foreach ($principalId in $principalIdsToAdd) {
        $resolvedEntry = $resolvedTargetsByUpn.GetEnumerator() |
                            Where-Object { $_.Value.Id -eq $principalId } |
                            Select-Object -First 1
        if ($null -eq $resolvedEntry) { continue }

        $principalType = $resolvedEntry.Value.Type  # "User" | "Group"
        $upnForLog     = $resolvedEntry.Name
        $displayForLog = $resolvedEntry.Value.DisplayName

        $addBody = @{
            principal = @{
                id   = $principalId
                type = $principalType
            }
            role = $workspaceRole
        } | ConvertTo-Json -Depth 4

        $addEndpoint = "/workspaces/$workspaceId/roleAssignments"
        $addResp     = Invoke-ApiEndpoint -endPoint $addEndpoint -method "POST" -body $addBody -Context $Context

        if ($addResp.responseObject.StatusCode -in @(200,201)) {
            $who = if ($displayForLog) { $displayForLog } elseif ($upnForLog) { $upnForLog } else { $principalId }
            Write-Message "Info" "Added '$who' ($principalType) as '$workspaceRole'."
        } else {
            throw (APIReturnedError -apiCallResponse $addResp -intendedAction "add role assignment")
        }
    }

    # 6) Perform removals (never remove SPNs)
    foreach ($principalId in $principalIdsToRemove) {
        $assignment = $assignmentByPrincipalId[$principalId]
        if ($null -eq $assignment) { continue }

        # Defensive guard: if somehow this is an SPN, preserve it
        $ctxType = $principalContextById[$principalId].Type
        if ($ctxType -eq 'ServicePrincipal') {
            Write-Message "Info" "Preserving Service Principal assignment (id '$principalId') for role '$workspaceRole'."
            continue
        }

        $roleAssignmentId = $assignment.id
        $deleteEndpoint   = "/workspaces/$workspaceId/roleAssignments/$roleAssignmentId"
        $delResp          = Invoke-ApiEndpoint -endPoint $deleteEndpoint -method "DELETE" -Context $Context

        $ctx = $principalContextById[$principalId]
        $who = if ($ctx.DisplayName) { $ctx.DisplayName } elseif ($ctx.UPN) { $ctx.UPN } else { $principalId }

        if ($delResp.responseObject.StatusCode -in @(200,204)) {
            Write-Message "Info" "Removed '$who' from '$workspaceRole'."
        } else {
            throw (APIReturnedError -apiCallResponse $delResp -intendedAction "remove role assignment")
        }
    }

    $preservedSpnCount = $existingSpnIdsForRole.Count
    Write-Message "Info" ("Sync complete for role '{0}': Added={1}, Removed={2}, PreservedSPNs={3}" -f `
                            $workspaceRole, $principalIdsToAdd.Count, $principalIdsToRemove.Count, $preservedSpnCount)

}



function Get-FabricWorkspace {
    param (
        [parameter(Mandatory = $true)]  [String]         $workspaceName,
        [parameter(Mandatory = $false)] [PSCustomObject] $Context = $null
    )

    $endPoint = "/workspaces" #https://learn.microsoft.com/en-us/rest/api/fabric/core/workspaces/list-workspaces
    $workspacesResponse = Invoke-ApiEndpoint -endPoint $endPoint -Context $Context
    if ($workspacesResponse.responseObject.StatusCode -eq 200) {
        return ($workspacesResponse.responseObject.Content | ConvertFrom-Json).value | Where-Object {$_.displayName -eq $workspaceName}
    }
    else {
        throw (APIReturnedError -apiCallResponse $workspacesResponse -intendedAction "list available workspaces")
    }

}

function Get-WorkspaceItems {
    param (
        [parameter(Mandatory = $true)]  [String]         $workspaceId,
        [parameter(Mandatory = $false)] [PSCustomObject] $Context = $null
    )

    $endPoint = "/workspaces/$($workspaceId)/items" #https://learn.microsoft.com/en-us/rest/api/fabric/core/items/list-items
    $workspaceItemsResponse = Invoke-ApiEndpoint -endPoint $endPoint -Context $Context
    if ($workspaceItemsResponse.responseObject.StatusCode -eq 200) {
        return ($workspaceItemsResponse.responseObject.Content | ConvertFrom-Json).value
    }
    else {
        throw (APIReturnedError -apiCallResponse $workspaceItemsResponse -intendedAction "list workspace items")
    }

}

function Wait-PrivateEndpoint {
  param (
      [parameter(Mandatory = $true)] [String] $location,
      [parameter(Mandatory = $false)] [int] $retryInterval = 5, # Retry interval in seconds
      [parameter(Mandatory = $false)] [int] $attempMax = 6 # Total timeout in seconds
  )
    $attempCount = 1          # Tracks the total elapsed time
    $endPoint = "/" + $location.Substring($script:fabricBaseUrl.Length).TrimStart('/')
    while ($attempCount -lt $attempMax) {
        Write-Message "Action" "Waiting $($retryInterval) secs for a private endpoint ($($location)) to succeeded (Attempt $($attempCount) out of $($attempMax))"
        Start-Sleep -Seconds $retryInterval
        $lroResponse = Invoke-ApiEndpoint -endPoint $endPoint -method "GET"
        if ($lroResponse.isException -eq $false) {
            $operationState  = $lroResponse.responseObject.Content | ConvertFrom-Json
            if ($operationState.provisioningState -eq "Succeeded") {
                Write-Message "Info" "($($location)) completed."
                return
            }
            elseif ($operationState.provisioningState -in @("Failed"))
            {
                $err = "Failed to provision the private endpoint"
                throw $err
            }
            $attempCount = $attempCount+1
        }
        else {
            throw (APIReturnedError -apiCallResponse $lroResponse -intendedAction "wait for private endpoint to succeeded '$location'")
        }
    }
}

function Get-PrivateEndpoint {
    param (
        
        [parameter(Mandatory = $true)] [String] $workspaceId,
        [parameter(Mandatory = $true)] [String] $privateEndpointName,
        [parameter(Mandatory = $true)] [String] $targetPrivateLinkResourceId
    )

    $endPoint = "/workspaces/$($workspaceId)/managedPrivateEndpoints" #https://learn.microsoft.com/en-us/rest/api/fabric/core/managed-private-endpoints/list-workspace-managed-private-endpoints
    $privateEndpointsResponse = Invoke-ApiEndpoint -endPoint $endPoint
    if ($privateEndpointsResponse.responseObject.StatusCode -eq 200) {
        return ($privateEndpointsResponse.responseObject.Content | ConvertFrom-Json).value | Where-Object {($_.name -eq $privateEndpointName) -or ($_.targetPrivateLinkResourceId -eq $targetPrivateLinkResourceId)}
    }
    else {
        throw (APIReturnedError -apiCallResponse $privateEndpointsResponse -intendedAction "get private endpoints by name ")
    }

}

function New-ManagedPrivateEndpoint {
    param (
        [parameter(Mandatory = $true)] [String] $workspaceId,
        [parameter(Mandatory = $true)] [String] $privateEndpointName,
        [parameter(Mandatory = $true)] [String] $targetPrivateLinkResourceId,
        [parameter(Mandatory = $true)] [String] $targetSubresourceType 
    )

    $privateEndpoint = Get-PrivateEndpoint -workspaceId $workspaceId -privateEndpointName $privateEndpointName -targetPrivateLinkResourceId $targetPrivateLinkResourceId
    if ($null -ne $privateEndpoint) {
        Write-Message "Info" "Endpoint $($privateEndpoint.name) or target resource already exist with provisioning state $($privateEndpoint.provisioningState)." 
        return 
    }
    Write-Message "Action" "Creating new managed private endpoint on $($privateEndpointName)."
    $requestBody = @{
        name = $privateEndpointName
        targetPrivateLinkResourceId = $targetPrivateLinkResourceId
        targetSubresourceType = $targetSubresourceType
        requestMessage = "Request via pipeline"
    } | ConvertTo-Json -Depth 4
    $endPoint = "/workspaces/$($workspaceId)/managedPrivateEndpoints" #https://learn.microsoft.com/en-us/rest/api/fabric/core/managed-private-endpoints/create-workspace-managed-private-endpoint
    $managedPrivateEndpointResponse = Invoke-ApiEndpoint -endPoint $endPoint -method "POST" -body $requestBody
    if ($managedPrivateEndpointResponse.responseObject.StatusCode -eq 201) {
        $location  = [string]($managedPrivateEndpointResponse.responseObject.Headers.'Location' | Select-Object -First 1)
        Write-Message "Info" "Request accepted (Location $($location))."
        Wait-PrivateEndpoint -location $location | Out-Null              
    }
    else {
        throw (APIReturnedError -apiCallResponse $managedPrivateEndpointResponse -intendedAction "create managed private endpoint")
    }

}

function Test-WorkspaceProcessed {
    param([Parameter(Mandatory)] [psobject]$Workspace)
    if (-not $script:fabricWorkspacesCatalog) { $script:fabricWorkspacesCatalog = @{} }
    return $script:fabricWorkspacesCatalog.ContainsKey([string]$Workspace.id)
}

function Register-WorkspaceAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [psobject] $Workspace,
        [Parameter(Mandatory)] [string]   $Action,   # Moved | Skipp | Error
        [Parameter()]          [string]   $RuleName,
        [Parameter()]          [string]   $DomainName,
        [Parameter()]          [string]   $SubDomainName,
        [Parameter()]          [string]   $Reason,
        [Parameter()]          [psobject] $Details
    )

    if (-not $script:fabricWorkspacesCatalog) { $script:fabricWorkspacesCatalog = @{} }

    $key = [string]$Workspace.id
    $script:fabricWorkspacesCatalog[$key] = [pscustomobject]@{
        workspaceId   = [string]$Workspace.id
        workspaceName = [string]$Workspace.name
        action        = $Action
        rule          = $RuleName
        domain        = $DomainName
        subDomain     = $SubDomainName
        reason        = $Reason
        timestampUtc  = (Get-Date).ToUniversalTime().ToString("o")
        details       = $Details
    }
}

function Test-GlobMatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$Pattern,
        [switch]$CaseSensitive
    )

    $options = if ($CaseSensitive) {
        [System.Management.Automation.WildcardOptions]::None
    } else {
        [System.Management.Automation.WildcardOptions]::IgnoreCase
    }

    return ([System.Management.Automation.WildcardPattern]::new($Pattern, $options)).IsMatch($Value)
}

function Select-WorkspacesByMatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Match,
        [Parameter(Mandatory)][object[]]$Workspaces,
        [switch]$CaseSensitive
    )

    $includePattern = if ($Match.nameGlob) { [string]$Match.nameGlob } else { "*" }

    $excludePatterns = @()
    if ($null -ne $Match.excludeGlob) {
        if ($Match.excludeGlob -is [string]) { $excludePatterns = @([string]$Match.excludeGlob) }
        else { $excludePatterns = @($Match.excludeGlob | ForEach-Object { [string]$_ }) }
    }

    $result = foreach ($ws in $Workspaces) {
        if ($null -eq $ws -or [string]::IsNullOrWhiteSpace([string]$ws.name)) { continue }

        # Skip if already processed by earlier rule
        if (Test-WorkspaceProcessed -Workspace $ws) { continue }

        $name = [string]$ws.name

        if (-not (Test-GlobMatch -Value $name -Pattern $includePattern -CaseSensitive:$CaseSensitive)) { continue }

        $excluded = $false
        foreach ($ex in $excludePatterns) {
            if ([string]::IsNullOrWhiteSpace($ex)) { continue }
            if (Test-GlobMatch -Value $name -Pattern $ex -CaseSensitive:$CaseSensitive) { $excluded = $true; break }
        }
        if ($excluded) { continue }

        $ws
    }

    return @($result)
}


function Remove-Workspace {
    param (
        [parameter(Mandatory = $true)] [String] $workspaceId
    )

    $endPoint = "/workspaces/$($workspaceId)" #https://learn.microsoft.com/en-us/rest/api/fabric/core/workspaces/delete-workspace?tabs=HTTP
    $workspacesResponse = Invoke-ApiEndpoint -endPoint $endPoint -method "DELETE"
    if ($workspacesResponse.responseObject.StatusCode -eq 200) {
        return $true
    }
    else {
        throw (APIReturnedError -apiCallResponse $workspacesResponse -intendedAction "list available workspaces")
    }

}

function ScanWorkspaceForSupportedItems {
    param (
        [parameter(Mandatory = $true)]  [String]         $workspaceId,
        [parameter(Mandatory = $false)] [PSCustomObject] $Context = $null
    )

    $supportedFabricItems = @(
        [PSCustomObject]@{ name = 'lakehouse'; active = 1; partsMandatory = 0; tier = "1"; priority = '101'; dfnFormat = ''; dfnParts = @([PSCustomObject]@{fileName = 'lakehouse.metadata.json'})}#,
        [PSCustomObject]@{ name = 'warehouse'; active = 1; partsMandatory = 0; tier = "1"; priority = '102'; dfnFormat = ''; dfnParts = @([PSCustomObject]@{fileName = 'warehouse.metadata.json'})},
        [PSCustomObject]@{ name = 'sqldatabase'; active = 1; partsMandatory = 0; tier = "1"; priority = '102'; dfnFormat = ''; dfnParts = @([PSCustomObject]@{fileName = 'database-content.json'})},
        [PSCustomObject]@{ name = 'mirroreddatabase'; active = 0; partsMandatory = 1; tier = "2"; priority = '201'; dfnFormat = ''; dfnParts = @([PSCustomObject]@{fileName = 'mirroredDatabase.json'; updateJsonValues = 1})},
        [PSCustomObject]@{ name = 'notebook'; active = 1; partsMandatory = 0; tier = "2"; priority = '201'; dfnFormat = ''; dfnParts = @([PSCustomObject]@{fileName = 'notebook-content.py'; updateJsonValues = 1},[PSCustomObject]@{ fileName = '.platform'})},
        [PSCustomObject]@{ name = 'semanticmodel';  active = 1; partsMandatory = 1; tier = "2"; priority = '202'; dfnFormat = 'TMSL'; dfnParts = @([PSCustomObject]@{fileName = 'model.bim'; updateJsonValues = 1},[PSCustomObject]@{ fileName = 'definition.pbism'},[PSCustomObject]@{ fileName = '.platform'})},
        #[PSCustomObject]@{ name = 'semanticmodel'; active = 0; partsMandatory = 1; tier = "2"; priority = '202'; dfnFormat = 'TMDL'; dfnParts = @([PSCustomObject]@{fileName = 'definition.pbism'},[PSCustomObject]@{fileName = '.platform'},[PSCustomObject]@{fileName = 'definition/expressions.tmdl'},[PSCustomObject]@{ fileName = 'definition/model.tmdl'},[PSCustomObject]@{ fileName = 'definition/database.tmdl'},[PSCustomObject]@{ fileName = 'definition/tables'; isFolder = 1 },[PSCustomObject]@{ fileName = 'definition/cultures'; isFolder = 1 })},
        [PSCustomObject]@{ name = 'datapipeline'; active = 1; partsMandatory = 0; tier = "2"; priority = '299'; dfnFormat = ''; dfnParts = @([PSCustomObject]@{fileName = 'pipeline-content.json'; updateJsonValues = 1})},
        [PSCustomObject]@{ name = 'report'; active = 1; partsMandatory = 1; tier = "3"; priority = '301'; dfnFormat = ''; dfnParts = @([PSCustomObject]@{fileName = 'definition.pbir'; updateJsonValues = 1},[PSCustomObject]@{ fileName = 'report.json'},[PSCustomObject]@{ fileName = '.platform'})}
    )

    $fabricItemsArray = @()
    $workspaceItems = Get-WorkspaceItems -workspaceId $workspaceId -Context $Context
    foreach ($workspaceItem in $workspaceItems) {
        $supportedFabricItem = $supportedFabricItems | Where-Object { $_.name -eq $workspaceItem.type.Tolower() -and $_.active -eq 1 }
        if ($supportedFabricItem -ne $null) {
            $itemFQN = "$($workspaceItem.displayName).$($workspaceItem.type)"
            $newfabricItem = [PSCustomObject]@{
                name = $workspaceItem.displayName
                type = $workspaceItem.type
                id = $workspaceItem.id
                directory = ".\temp\FabricItems\$($itemFQN)"
                itemFQN = $itemFQN
                tier = $supportedFabricItem.tier
                priority = $supportedFabricItem.priority
                dfnFormat = $supportedFabricItem.dfnFormat
                dfnParts = $supportedFabricItem.dfnParts
                partsMandatory = $supportedFabricItem.partsMandatory
            }
            $fabricItemsArray += $newfabricItem

            Write-Message "Action" "Getting Item Definition $($workspaceItem.type) $($workspaceItem.displayName)"
            $itemDefinition = Get-FabricItemDefinition `
                -ItemId $newfabricItem.id `
                -ItemType $newfabricItem.type `
                -workspaceId $workspaceId `
                -outputFileDirectory $newfabricItem.directory `
                -format $supportedFabricItem.dfnFormat `
                -Context $Context
        }
        else {
            Write-Message "Warning" "Skipping $($workspaceItem.displayName) ($($workspaceItem.type)), this Fabric Item is not yet supported." 
        }
    }        
    $script:fabricItemsLocation = "LocalDirectory"
    Write-Message "Info" "Scanning of Fabric items on directory completed ,found $($fabricItemsArray.Count) items "
    return $fabricItemsArray
}
