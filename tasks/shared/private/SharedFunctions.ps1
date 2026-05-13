###############################################################################
# Script Name:  SharedFunctions.ps1
# Description:  Temporal description
# Author:       Hector Lopez (Manager @Intelligent Platforms)
# Contact:      svenchio@techtacofriday.com
# Blog:         https://www.techtacofriday.com/
###############################################################################

function Convert-ToBoolean {
    param([Parameter(Mandatory=$true)][string]$Value)
    switch -Regex ($Value.Trim()) {
        '^(true|1|yes)$'  { return $true }
        '^(false|0|no)$'  { return $false }
        default { throw "Invalid boolean string: '$Value'. Expected True/False." }
    }
}

function Get-ErrorResponse($exception) {
    # Relevant only for PowerShell Core
    if ($exception.Exception.Response) {
        return $exception.Exception.Message
    }
    else {
        $errorResponse = $_
    }

    if ([string]::IsNullOrWhiteSpace($errorResponse)) {
        # This is needed to support Windows PowerShell
        $result = $exception.Response.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($result)
        $reader.BaseStream.Position = 0
        $reader.DiscardBufferedData()
        $errorResponse = $reader.ReadToEnd();
    }

    return $errorResponse
}

function New-FabricContext {
    # Constructor for a plain-object that carries all runtime configuration needed
    # by Invoke-ApiEndpoint and friends.  Passing a context object instead of relying on
    # $script: variables makes callers fully testable — inject a context in tests and
    # no $script: state needs to be set up.
    #
    # Backward compatibility: all $script: variables continue to work; pass -Context
    # only when you want explicit control (e.g. in Pester tests or multi-tenant calls).
    param(
        [parameter(Mandatory = $false)] [string]    $FabricBaseUrl       = 'https://api.fabric.microsoft.com',
        [parameter(Mandatory = $false)] [string]    $AzdoBaseUrl         = 'https://dev.azure.com',
        [parameter(Mandatory = $false)] [string]    $GraphBaseUrl        = 'https://graph.microsoft.com/v1.0',
        [parameter(Mandatory = $false)] [hashtable] $FabricRequestHeader = @{},
        [parameter(Mandatory = $false)] [hashtable] $DevOpsRequestHeader = @{},
        [parameter(Mandatory = $false)] [hashtable] $GraphRequestHeader  = @{},
        [parameter(Mandatory = $false)] [string]    $EnableDiagnostics   = 'False',
        [parameter(Mandatory = $false)] [bool]      $DeveloperView       = $false
    )
    return [PSCustomObject]@{
        FabricBaseUrl       = $FabricBaseUrl
        AzdoBaseUrl         = $AzdoBaseUrl
        GraphBaseUrl        = $GraphBaseUrl
        FabricRequestHeader = $FabricRequestHeader
        DevOpsRequestHeader = $DevOpsRequestHeader
        GraphRequestHeader  = $GraphRequestHeader
        EnableDiagnostics   = $EnableDiagnostics
        DeveloperView       = $DeveloperView
    }
}

function New-GitConfig {
    # Constructor for git connection settings consumed by Connect-WorkspaceToGit.
    # Mirrors the New-FabricContext pattern: pass a GitConfig in tests to avoid
    # $script: ambient state; omit it in production and the function falls back to
    # $script: variables as before.
    param(
        [parameter(Mandatory = $false)] [string] $GitProviderType       = $null,
        [parameter(Mandatory = $false)] [string] $OrganizationName      = $null,
        [parameter(Mandatory = $false)] [string] $ProjectName           = $null,
        [parameter(Mandatory = $false)] [string] $RepositoryName        = $null,
        [parameter(Mandatory = $false)] [string] $NewBranchName         = $null,
        [parameter(Mandatory = $false)] [string] $ItemsGitFolder        = $null,
        [parameter(Mandatory = $false)] [string] $FabricGitConnectionId = $null
    )
    return [PSCustomObject]@{
        GitProviderType       = $GitProviderType
        OrganizationName      = $OrganizationName
        ProjectName           = $ProjectName
        RepositoryName        = $RepositoryName
        NewBranchName         = $NewBranchName
        ItemsGitFolder        = $ItemsGitFolder
        FabricGitConnectionId = $FabricGitConnectionId
    }
}

function New-AzdoConfig {
    # Constructor for Azure DevOps connection settings consumed by Get-DeploymentCsvContent,
    # New-GitBranchFromExisting, New-GitBranchFromScratch, Test-DevOpsRepoPath, and Copy-DevOpsRepoBranchRestAPI.
    # Mirrors the New-GitConfig pattern: pass an AzdoConfig in tests to avoid
    # $script: ambient state; omit it in production and the function falls back to
    # $script: variables as before.
    param(
        [parameter(Mandatory = $false)] [string]    $AzdoBaseUrl         = $null,
        [parameter(Mandatory = $false)] [string]    $OrganizationName    = $null,
        [parameter(Mandatory = $false)] [string]    $ProjectName         = $null,
        [parameter(Mandatory = $false)] [string]    $RepositoryName      = $null,
        [parameter(Mandatory = $false)] [string]    $SourceBranchName    = $null,
        [parameter(Mandatory = $false)] [hashtable] $DevOpsRequestHeader = $null
    )
    return [PSCustomObject]@{
        AzdoBaseUrl         = $AzdoBaseUrl
        OrganizationName    = $OrganizationName
        ProjectName         = $ProjectName
        RepositoryName      = $RepositoryName
        SourceBranchName    = $SourceBranchName
        DevOpsRequestHeader = $DevOpsRequestHeader
    }
}

function Invoke-FabricApiRequest {
    # Thin wrapper around Invoke-WebRequest.
    # Keeping it as a named function creates a mockable seam for unit tests —
    # replace this function in test scope and Invoke-ApiEndpoint never touches the network.
    #
    # Note: -SkipHttpErrorCheck was added in PowerShell 7. On Windows PowerShell 5.x
    # it is omitted and non-2xx responses will throw; callers should target PS7 in CI.
    param(
        [parameter(Mandatory = $true)]  [string]    $Uri,
        [parameter(Mandatory = $true)]  [string]    $Method,
        [parameter(Mandatory = $false)] [string]    $ContentType = "application/json",
        [parameter(Mandatory = $false)] [hashtable] $Headers     = @{},
        [parameter(Mandatory = $false)]
        [AllowEmptyString()]            [string]    $Body        = ""
    )
    $params = @{
        Uri              = $Uri
        Method           = $Method
        ContentType      = $ContentType
        Headers          = $Headers
        ErrorAction      = 'Stop'
        UseBasicParsing  = $true
    }
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        $params.SkipHttpErrorCheck = $true
    }
    if ($Method -ne "GET") {
        $params.Body = $Body
    }
    return Invoke-WebRequest @params
}

function Invoke-ApiEndpoint {
    param (
        [parameter(Mandatory = $false)]
        [ValidateSet("Fabric", "DevOps", "Graph")] [String] $useRequestHeader = "Fabric",
        [parameter(Mandatory = $false)] [String] $contentType = "application/json",
        [parameter(Mandatory = $false)] [String] $baseUrl,
        [parameter(Mandatory = $true)] [String] $endPoint,
        [parameter(Mandatory = $false)] [String] $method = "GET",
        [parameter(Mandatory = $false)] [String] $body,
        # API version injected between the Fabric base URL and the endpoint path.
        # Ignored when an explicit -baseUrl is supplied (caller owns the full URL).
        [parameter(Mandatory = $false)] [String] $FabricApiVersion = "v1",
        # Optional context object (from New-FabricContext). When provided, its URLs and
        # headers are used instead of the $script: variables, making callers testable
        # without setting up global state.  When omitted, $script: fallback is used so
        # existing callers continue to work without any changes.
        [parameter(Mandatory = $false)] [PSCustomObject] $Context
    )

    switch ($useRequestHeader) {
        "Fabric" { $requestHeader = if ($null -ne $Context) { $Context.FabricRequestHeader } else { $script:fabricRequestHeader } }
        "DevOps" { $requestHeader = if ($null -ne $Context) { $Context.DevOpsRequestHeader } else { $script:devopsRequestHeader } }
        "Graph"  { $requestHeader = if ($null -ne $Context) { $Context.GraphRequestHeader }  else { $script:graphRequestHeader } }
        default  { throw "Request header type $($useRequestHeader) is not supported" }
    }

    $resolvedBaseUrl = if ($null -ne $Context) { $Context.FabricBaseUrl } else { $script:fabricBaseUrl }
    $URI = if (![string]::IsNullOrWhiteSpace($baseUrl)) {
        # Explicit override: caller owns the full URL including any version segment
        $baseUrl + $endPoint
    } else {
        # Fabric default: inject the API version between base URL and endpoint
        $resolvedBaseUrl + "/$FabricApiVersion" + $endPoint
    }

    Write-Message "Debug" "Header   : $($useRequestHeader)"
    Write-Message "Debug" "URI      : $($URI)"
    Write-Message "Debug" "Method   : $($method)"
    Write-Message "Develop" "Content  : $($contentType)"
    Write-Message "Develop" "Body     : $($body)"

    try {
        $restMethodResponse = Invoke-FabricApiRequest `
            -Uri         $URI `
            -Method      $method `
            -ContentType $contentType `
            -Headers     $requestHeader `
            -Body        $body

        $parsedContent = $null
        $parsedContent = $restMethodResponse.Content | ConvertFrom-Json -ErrorAction Stop

        if ($parsedContent -and $parsedContent.PSObject.Properties["errorCode"]) {
            # Detected an API-level error in the response body
            return [PSCustomObject]@{
                responseObject = [PSCustomObject]@{
                    Message     = $parsedContent.message
                    ErrorCode   = $parsedContent.errorCode
                    StatusCode  = $restMethodResponse.StatusCode 
                    Body        = $restMethodResponse.Content
                }
                isException = $true
            }
        } 
        
        return [PSCustomObject]@{
            responseObject = [PSCustomObject]@{
                StatusCode = $restMethodResponse.StatusCode
                Content    = $restMethodResponse.Content 
                Headers    = $restMethodResponse.Headers
            }
            isException = $false
        }

    }
    catch {
        # PS5 throws a WebException for non-2xx responses (no -SkipHttpErrorCheck).
        # Extract the real HTTP status code when available so callers can branch on it.
        $statusCode = "Unknown"
        try { if ($null -ne $_.Exception.Response) { $statusCode = [int]$_.Exception.Response.StatusCode } } catch {}
        return [PSCustomObject]@{
            responseObject = [PSCustomObject]@{
                Message    = $_.Exception.Message
                ErrorCode  = "non-HTTP exception"
                StatusCode = $statusCode
                Body       = "Error occurred during Invoke-WebRequest execution"
            }
            isException = $true
        }
    }
}

function Write-Message {
    param (
        [parameter(Mandatory = $true)]
        [ValidateSet("Info", "Action", "Warning", "Error", "Debug", "Develop")] [string] $msgType,
        [parameter(Mandatory = $true)] [String] $msgText
    )
    switch ($msgType) {
        "Info" {
            Write-Host "##[command]Info: $($msgText)" -ForegroundColor Blue
        }
        "Action" {
            Write-Host "##[command]Action: $($msgText)" -ForegroundColor Green
        }
        "Warning" {
            Write-Host "##[warning]Warning: $($msgText)" -ForegroundColor Yellow
        }
        "Error" {
            Write-Host "##[error]Error: $($msgText)" -ForegroundColor Red
        }
        "Debug" {
            if ([Convert]::ToBoolean($script:enableDiagnostics)) {
                Write-Host "##[debug]Debug: $($msgText)" -ForegroundColor Magenta
            }
        }
        "Develop" {
            if ([Convert]::ToBoolean($script:enableDiagnostics) -and $script:developerView) {
                Write-Host "##[debug]Debug: $($msgText)" -ForegroundColor Magenta
            }
        }
    }
}

function APIReturnedError {
    param (
        [parameter(Mandatory = $true)] [PSCustomObject] $apiCallResponse,
        [parameter(Mandatory = $true)] [String] $intendedAction
    )
    return "API Call returned error '$($apiCallResponse.responseObject.Message)' while $($intendedAction).`nStatus Code '$($apiCallResponse.responseObject.StatusCode)' Error details '$($apiCallResponse.responseObject.Body)'"
}

function New-RequestHeader {
    param (
        [parameter(Mandatory = $false)] [String] $authType = "Bearer",
        [parameter(Mandatory = $false)] [String] $accessToken
    )
    Write-Message "Debug" "Auth Type     : $($authType)"
    Write-Message "Debug" "Access Token  : $($accessToken.Substring(0, 4)+'********')"
    if ($authType -eq "Bearer" -and ![string]::IsNullOrWhiteSpace($accessToken)) {
        return @{
            Authorization = "$($authType) $($accessToken)"
        }
    }
    else {
        throw ("Unsupported Authentication Type provided: $($authType)")
    }
}

function Resolve-NormalizedUpnList {
    param(
        [parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string] $upnList = ""
    )
    if ([string]::IsNullOrWhiteSpace($upnList)) { return [string[]]@() }
    [string[]] $normalized = $upnList -split ';' |
        ForEach-Object { $_.Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_.ToLowerInvariant() } |
        Select-Object -Unique
    return $normalized
}

function Compare-RoleAssignments {
    param(
        [parameter(Mandatory = $true)]  [AllowEmptyCollection()] [string[]] $TargetIds,
        [parameter(Mandatory = $true)]  [AllowEmptyCollection()] [string[]] $ExistingIds,
        [parameter(Mandatory = $false)] [AllowEmptyCollection()] [string[]] $PreservedIds = @()
    )
    $toAdd    = @($TargetIds   | Where-Object { $_ -notin $ExistingIds })
    $toRemove = @($ExistingIds | Where-Object { ($_ -notin $TargetIds) -and ($_ -notin $PreservedIds) })
    return [PSCustomObject]@{
        ToAdd    = $toAdd
        ToRemove = $toRemove
    }
}

function Resolve-UpnToId {
    param (
        [parameter(Mandatory = $true)]  [String]      $upn,
        [parameter(Mandatory = $false)] [bool]        $returnUpn    = $false,
        [parameter(Mandatory = $false)] [bool]        $useMsftGraph = $false,
        [parameter(Mandatory = $false)] [PSCustomObject] $Context
    )
    # Get the user object using the UPN
    if ($useMsftGraph -eq $false) {
        $user = Get-AzADUser -UserPrincipalName $upn
        if ($user) {
            $result = @{
                Id   = if ($returnUpn) { $upn } else { $user.Id }
                Type = "User"
            }
            return $result
        }
        else {
            $secgroup = Get-AzADGroup -Filter "DisplayName eq '$upn' and SecurityEnabled eq true"
            if ($secgroup) {
                $result = @{
                    Id   = $secgroup.Id
                    Type = "Group"
                }
                return $result
            }
        }
    }
    else {
        $graphBaseUrl = if ($null -ne $Context) { $Context.GraphBaseUrl } else { $script:graphBaseUrl }
        $endPoint = "/users/$($upn)?`$select=id" #https://learn.microsoft.com/en-us/graph/api/user-get?view=graph-rest-1.0&tabs=http
        $lookUpnAsUserResponse = Invoke-ApiEndpoint -baseUrl $graphBaseUrl -endPoint $endPoint -useRequestHeader "Graph" -Context $Context
        if ($lookUpnAsUserResponse.isException -eq $false) {
            $user = $lookUpnAsUserResponse.responseObject.Content | ConvertFrom-Json
            $result = @{
                Id   = if ($returnUpn) { $upn } else { $user.Id }
                Type = "User"
            }
            return $result
        }
        elseif ($lookUpnAsUserResponse.responseObject.StatusCode -eq 404) {
            #I could not found the UPN as a user
            $endPoint = "/groups?`$filter=displayName eq '$($upn)' and securityEnabled eq true" #https://learn.microsoft.com/en-us/graph/api/user-get?view=graph-rest-1.0&tabs=http
            $lookUpnAsGroupResponse = Invoke-ApiEndpoint -baseUrl $graphBaseUrl -endPoint $endPoint -useRequestHeader "Graph" -Context $Context
            if ($lookUpnAsGroupResponse.isException -eq $false) {
                $secgroup = ($lookUpnAsGroupResponse.responseObject.Content | ConvertFrom-Json).value | Where-Object {$_.displayName -eq $upn}
                if ($null -ne $secgroup) {
                    $result = @{
                        Id   = $secgroup.Id
                        Type = "Group"
                    }
                    return $result
                }
                else {
                    Write-Message "Info" "The UPN provided $($upn) could not be found as user nor as security group"
                }
            }
            else {
                throw (APIReturnedError -apiCallResponse $lookUpnAsGroupResponse -intendedAction "get security group information")
            }
        }
        else {
            throw (APIReturnedError -apiCallResponse $lookUpnAsUserResponse -intendedAction "get user information")
        }
    }
}

function Wait-FabricLRO {
  param (
      [parameter(Mandatory = $true)]  [String]         $operationId,
      [parameter(Mandatory = $false)] [int]            $retryInterval = 5,
      [parameter(Mandatory = $false)] [int]            $attempMax = 6,
      [parameter(Mandatory = $false)] [PSCustomObject] $Context = $null
  )
    $attempCount = 1
    while ($true) {
        Write-Message "Action" "Waiting $($retryInterval) secs for a long running operation ($($operationId)) to complete (Attempt $($attempCount) out of $($attempMax))"
        Start-Sleep -Seconds $retryInterval
        $endPoint = "/operations/$($operationId)" #https://learn.microsoft.com/en-us/rest/api/fabric/core/long-running-operations/get-operation-state
        $lroResponse = Invoke-ApiEndpoint -endPoint $endPoint -method "GET" -Context $Context
        if ($lroResponse.isException -eq $false) {
            $operationState  = $lroResponse.responseObject.Content | ConvertFrom-Json
            if ($operationState.status -eq "Succeeded") {
                Write-Message "Info" "Operation ($($operationId)) completed."
                $endPoint = "/operations/$($operationId)/result"
                $lroResultResponse = Invoke-ApiEndpoint -endPoint $endPoint -Context $Context
                if ($null -ne $lroResultResponse.responseObject.Content) {
                    return $lroResultResponse.responseObject.Content | ConvertFrom-Json
                }
                return $true
            }
            elseif ($operationState.status -eq "Failed") {
                throw ($operationState.error.message)
            }
            if ($attempCount -ge $attempMax) {
                throw "Operation ($($operationId)) did not complete after $($attempMax) attempts."
            }
            $attempCount = $attempCount + 1
        }
        else {
            $errorResponse = Get-ErrorResponse($lroResponse.responseObject)
            throw ($errorResponse)
        }
    }

}

function Invoke-DetokenizeConfigFile() {
    param (
        [parameter(Mandatory = $true)]  [string[]]       $csvContent,
        [parameter(Mandatory = $true)]  [int]            $customFabricItemsTier,
        [parameter(Mandatory = $true)]  [string]         $deploymentConfigFileName,
        [parameter(Mandatory = $false)] [PSCustomObject] $catalog = $null
    )
    $resolvedCatalog = if ($null -ne $catalog) { $catalog } else { $script:fabricItemsPropertiesCatalog }
    $newCsvFilePath = ".\temp\fabricItemsTier$($customFabricItemsTier)\$($deploymentConfigFileName)"
    $updatedCsvContent = Resolve-DeploymentCsvContent -content $csvContent -tokens $resolvedCatalog # Replace tokens in the CSV content
    $fncResult = Export-ContentToFile -content $updatedCsvContent -filePath $newCsvFilePath
    if ($fncResult) {
        return $newCsvFilePath
    }
}

function Invoke-TokenSubstitution {
    param(
        [parameter(Mandatory = $true)] [AllowEmptyString()] [string]       $line,
        [parameter(Mandatory = $true)]                      [PSCustomObject] $tokens
    )
    foreach ($property in $tokens.PSObject.Properties) {
        $token   = "#{$($property.Name)}#"
        $value   = $property.Value
        $updated = $line -replace [regex]::Escape($token), $value
        if ($updated -ne $line) {
            # Exact named token matched — use the result and move on
            $line = $updated
        } else {
            # No exact match — try the Default.* fallback variant
            $defaultName  = $property.Name -replace '^[^.]+', 'Default'
            $defaultToken = "#{$defaultName}#"
            $line = $line -replace [regex]::Escape($defaultToken), $value
        }
    }
    return $line
}

function Resolve-DeploymentCsvContent {
    param (
        [string[]]$content,          # Content of the CSV file
        [PSCustomObject]$tokens      # Object containing token keys and values
    )
    # Append default catalog rows so callers never need to hard-code them in their CSV
    $defaultRows = @(
        "*,Notebook,dependencies.environment.workspaceId,""#{HomeWorkspace.Id}#"""
        "*,Notebook,dependencies.lakehouse.default_lakehouse,""#{Default.Lakehouse.Id}#"""
        "*,Notebook,dependencies.lakehouse.default_lakehouse_name,""#{Default.Lakehouse.Name}#"""
        "*,Notebook,dependencies.lakehouse.default_lakehouse_workspace_id,""#{HomeWorkspace.Id}#"""
        "*,SemanticModel,model.expressions[0].expression,""#{Default.Lakehouse.MConnectionExpresion}#"""
        "*,Report,datasetReference,""#{Default.SemanticModel.DatasetReference}#"""
    )
    $content = $content + $defaultRows

    $updatedContent = $content | ForEach-Object {
        Invoke-TokenSubstitution -line $_ -tokens $tokens
    }
    return $updatedContent -join "`r`n"
}

function Update-JsonValues {
    param (
        [Parameter(Mandatory=$true)] [hashtable]$csvData,
        [Parameter(Mandatory=$true)] [psobject]$jsonObject
    )

    foreach ($key in $csvData.Keys) {
        $pathParts   = $key -split '\.'
        $newValue    = $csvData[$key]
        $currentNode = $jsonObject
        $skip        = $false

        for ($i = 0; $i -lt ($pathParts.Length - 1); $i++) {
            $part = $pathParts[$i]

            if ($part -match "(.+)\[(\*|'[^']+'|\d+)\]") {
                $arrayName = $matches[1]
                $itemRef   = $matches[2]

                if ($currentNode.PSObject -and $currentNode.PSObject.Properties[$arrayName]) {
                    $array = $currentNode.$arrayName

                    if ($itemRef -eq '*') {
                        $remainingRange = ($i + 1)..($pathParts.Length - 1)
                        $remainingPath  = ($pathParts[$remainingRange] -join '.')
                        foreach ($item in $array) {
                            Set-PropertyPath -node $item -remainingPath $remainingPath -value $newValue
                        }
                        $skip = $true
                        break
                    } elseif ($itemRef -match "'(.+)'") {
                        $itemKey = $matches[1]
                        if ($itemKey -match '^([^=]+)=(.+)$') {
                            $matchProp  = $matches[1]
                            $matchValue = $matches[2]
                            $foundItem  = @($array | Where-Object { $_.$matchProp -eq $matchValue }) | Select-Object -First 1
                        } else {
                            $foundItem = @($array | Where-Object { $_.name -eq $itemKey }) | Select-Object -First 1
                        }

                        if ($foundItem) {
                            $currentNode = $foundItem
                        } else {
                            Write-Message "Debug" "No item matching '$itemKey' found in '$arrayName'"
                            $skip = $true
                            break
                        }
                    } elseif ($itemRef -match '\d+') {
                        $index = [int]$itemRef
                        if ($index -lt $array.Count) {
                            $currentNode = $array[$index]
                        } else {
                            Write-Message "Debug" "Index '$index' out of bounds in '$arrayName'"
                            $skip = $true
                            break
                        }
                    }
                } else {
                    Write-Message "Debug" "Array '$arrayName' not found in JSON."
                    $skip = $true
                    break
                }
            } elseif ($currentNode.PSObject -and $currentNode.PSObject.Properties[$part]) {
                $currentNode = $currentNode.$part
            } else {
                Write-Message "Debug" "Path '$key' not found in JSON."
                $skip = $true
                break
            }
        }

        if ($skip) { continue }

        $finalPart = $pathParts[-1]
        if ($finalPart -match "^(.+)\[(\*|'[^']+'|\d+)\]$") {
            $arrayName   = $matches[1]
            $itemRef     = $matches[2]
            if ($currentNode.PSObject -and $currentNode.PSObject.Properties[$arrayName]) {
                $array       = $currentNode.$arrayName
                $parsedValue = if ($newValue -match '^\s*[\[{]') {
                    try { $newValue | ConvertFrom-Json -ErrorAction Stop } catch { $newValue }
                } else { $newValue }

                if ($itemRef -eq '*') {
                    for ($j = 0; $j -lt $array.Count; $j++) { $array[$j] = $parsedValue }
                    Write-Message "Debug" "Updated all elements of '$arrayName' in '$key'."
                } elseif ($itemRef -match "'(.+)'") {
                    $itemKey = $matches[1]
                    if ($itemKey -match '^([^=]+)=(.+)$') {
                        $matchProp = $matches[1]; $matchValue = $matches[2]
                        for ($j = 0; $j -lt $array.Count; $j++) {
                            if ($array[$j].$matchProp -eq $matchValue) { $array[$j] = $parsedValue; break }
                        }
                    } else {
                        for ($j = 0; $j -lt $array.Count; $j++) {
                            if ($array[$j].name -eq $itemKey) { $array[$j] = $parsedValue; break }
                        }
                    }
                    Write-Message "Debug" "Updated named element in '$arrayName' for '$key'."
                } elseif ($itemRef -match '^\d+$') {
                    $index = [int]$itemRef
                    if ($index -lt $array.Count) {
                        $array[$index] = $parsedValue
                        Write-Message "Debug" "Updated index $index in '$arrayName' for '$key'."
                    } else {
                        Write-Message "Debug" "Index '$index' out of bounds in '$arrayName'."
                    }
                }
            } else {
                Write-Message "Debug" "Array '$arrayName' not found for final target '$finalPart'."
            }
        } elseif ($currentNode.PSObject -and $currentNode.PSObject.Properties[$finalPart]) {
            if ($newValue -match '^\s*[\[{]') {
                try {
                    $parsedJson = $newValue | ConvertFrom-Json -ErrorAction Stop
                    $currentNode.$finalPart = $parsedJson
                    Write-Message "Debug" "Updated '$key' to a JSON object."
                }
                catch {
                    $currentNode.$finalPart = $newValue
                    Write-Message "Debug" "Updated '$key' to '$newValue'."
                }
            } else {
                $currentNode.$finalPart = $newValue
                Write-Message "Debug" "Updated '$key' to '$newValue'."
            }
        } else {
            Write-Message "Debug" "Final path '$finalPart' not found in JSON."
        }
    }

    return $jsonObject
}

function Set-PropertyPath {
    param (
        [Parameter(Mandatory=$true)] [psobject]$node,
        [Parameter(Mandatory=$true)] [string]$remainingPath,
        [Parameter(Mandatory=$true)] [string]$value
    )

    $pathParts   = $remainingPath -split '\.'
    $currentNode = $node
    $skip        = $false

    for ($i = 0; $i -lt ($pathParts.Length - 1); $i++) {
        $part = $pathParts[$i]

        if ($part -match "(.+)\[(\*|'[^']+'|\d+)\]") {
            $arrayName = $matches[1]
            $itemRef   = $matches[2]

            if ($currentNode.PSObject -and $currentNode.PSObject.Properties[$arrayName]) {
                $array = $currentNode.$arrayName

                if ($itemRef -eq '*') {
                    $remainingTail = ($pathParts[($i + 1)..($pathParts.Length - 1)] -join '.')
                    foreach ($item in $array) {
                        Set-PropertyPath -node $item -remainingPath $remainingTail -value $value
                    }
                    $skip = $true
                    break
                } elseif ($itemRef -match "'(.+)'") {
                    $itemKey = $matches[1]
                    if ($itemKey -match '^([^=]+)=(.+)$') {
                        $matchProp  = $matches[1]
                        $matchValue = $matches[2]
                        $foundItem  = @($array | Where-Object { $_.$matchProp -eq $matchValue }) | Select-Object -First 1
                    } else {
                        $foundItem = @($array | Where-Object { $_.name -eq $itemKey }) | Select-Object -First 1
                    }
                    if ($foundItem) {
                        $currentNode = $foundItem
                    } else {
                        Write-Message "Debug" "No item matching '$itemKey' found in '$arrayName'"
                        $skip = $true
                        break
                    }
                } elseif ($itemRef -match '\d+') {
                    $index = [int]$itemRef
                    if ($index -lt $array.Count) {
                        $currentNode = $array[$index]
                    } else {
                        Write-Message "Debug" "Index '$index' out of bounds in '$arrayName'"
                        $skip = $true
                        break
                    }
                }
            } else {
                Write-Message "Debug" "Array '$arrayName' not found in JSON."
                $skip = $true
                break
            }
        } elseif ($currentNode.PSObject -and $currentNode.PSObject.Properties[$part]) {
            $currentNode = $currentNode.$part
        } else {
            Write-Message "Debug" "Path '$remainingPath' not found in JSON."
            $skip = $true
            break
        }
    }

    if ($skip) { return }

    $finalPart = $pathParts[-1]
    if ($finalPart -match "^(.+)\[(\*|'[^']+'|\d+)\]$") {
        $arrayName   = $matches[1]
        $itemRef     = $matches[2]
        if ($currentNode.PSObject -and $currentNode.PSObject.Properties[$arrayName]) {
            $array       = $currentNode.$arrayName
            $parsedValue = if ($value -match '^\s*[\[{]') {
                try { $value | ConvertFrom-Json -ErrorAction Stop } catch { $value }
            } else { $value }

            if ($itemRef -eq '*') {
                for ($j = 0; $j -lt $array.Count; $j++) { $array[$j] = $parsedValue }
                Write-Message "Debug" "Updated all elements of '$arrayName' in '$remainingPath'."
            } elseif ($itemRef -match "'(.+)'") {
                $itemKey = $matches[1]
                if ($itemKey -match '^([^=]+)=(.+)$') {
                    $matchProp = $matches[1]; $matchValue = $matches[2]
                    for ($j = 0; $j -lt $array.Count; $j++) {
                        if ($array[$j].$matchProp -eq $matchValue) { $array[$j] = $parsedValue; break }
                    }
                } else {
                    for ($j = 0; $j -lt $array.Count; $j++) {
                        if ($array[$j].name -eq $itemKey) { $array[$j] = $parsedValue; break }
                    }
                }
                Write-Message "Debug" "Updated named element in '$arrayName' for '$remainingPath'."
            } elseif ($itemRef -match '^\d+$') {
                $index = [int]$itemRef
                if ($index -lt $array.Count) {
                    $array[$index] = $parsedValue
                    Write-Message "Debug" "Updated index $index in '$arrayName' for '$remainingPath'."
                } else {
                    Write-Message "Debug" "Index '$index' out of bounds in '$arrayName'."
                }
            }
        } else {
            Write-Message "Debug" "Array '$arrayName' not found for final target '$finalPart'."
        }
    } elseif ($currentNode.PSObject -and $currentNode.PSObject.Properties[$finalPart]) {
        if ($value -match '^\s*[\[{]') {
            try {
                $parsedJson = $value | ConvertFrom-Json -ErrorAction Stop
                $currentNode.$finalPart = $parsedJson
                Write-Message "Debug" "Updated '$remainingPath' to a JSON object."
            }
            catch {
                $currentNode.$finalPart = $value
                Write-Message "Debug" "Updated '$remainingPath' to '$value'."
            }
        } else {
            $currentNode.$finalPart = $value
            Write-Message "Debug" "Updated '$remainingPath' to '$value'."
        }
    } else {
        Write-Message "Debug" "Final path '$finalPart' not found in JSON."
    }
}

function ConvertFrom-Payload {
    param (
        [Parameter(Mandatory=$true)] [string]$content
    )
    # Convert the Base64 string back to bytes
    $fileBytes = [Convert]::FromBase64String($content)
    # Convert the bytes back to a UTF-8 string
    return [System.Text.Encoding]::UTF8.GetString($fileBytes)
}

function ConvertTo-Payload {
    param (
        [Parameter(Mandatory=$true)] [string]$content
    )
    # Convert the UTF-8 string to bytes
    $fileBytes = [System.Text.Encoding]::UTF8.GetBytes($content)
    # Convert the bytes to a Base64 string
    return [Convert]::ToBase64String($fileBytes)
}


function Get-FileContent {
    param (
        [Parameter(Mandatory=$true)] [string]$filePath,
        [Parameter(Mandatory=$false)] [string]$outputFormat = "Raw"
    )
    # Read the file as a UTF-8 string
    $fileContent = Get-Content -Path $filePath -Raw -Encoding UTF8
    if ($outputFormat -eq "ConvertTo-Payload") {
        return ConvertTo-Payload -content $fileContent
    }
    else {
        return $fileContent
    }
}

function Export-ContentToFile {
    param (
        [Parameter(Mandatory=$true)] [string]$content,
        [Parameter(Mandatory=$true)] [string]$filePath
    )
    # Extract the directory from the file path
    $directory = Split-Path -Path $filePath -Parent
    # Check if the directory exists, if not create it
    if (-not (Test-Path -Path $directory)) {
        New-Item -Path $directory -ItemType Directory -Force | Out-Null
    }

    # Write the content to the file
    Set-Content -Path $filePath -Value $content
    return $true
}

function Update-CatalogTokens {
    param (
        [Parameter(Mandatory = $true)] [psobject]$jsonData,
        [Parameter(Mandatory = $true)] [psobject]$propertiesCatalog,
        [Parameter(Mandatory = $false)] [string]$targetPropertyName = $null
    )
    # Recursive function to traverse the JSON structure
    function TraverseAndReplace($node) {
        # If the node is an array, process each element
        if ($node -is [System.Collections.IEnumerable] -and $node -isnot [string]) {
            foreach ($item in $node) {
                TraverseAndReplace $item
            }
        }
        # If the node is an object, look for "token" properties
        elseif ($node -is [PSCustomObject]) {
            foreach ($property in $node.PSObject.Properties) {
                # If a "token" property is found, check if it matches any key in the catalog
                if (($property.Name -eq "token") -or ($property.Name -eq $targetPropertyName)) {
                    $tokenValue =  $property.Value -replace '#{', '' -replace '}#', ''
                    if ($propertiesCatalog.PSObject.Properties[$tokenValue]) {
                        # Replace the token value with the value from the catalog
                        $node.$($property.Name) = $propertiesCatalog.PSObject.Properties[$tokenValue].Value
                    }
                }
                else {
                    # Recursively check any objects/arrays within the current node
                    TraverseAndReplace $property.Value
                }
            }
        }
    }

    # Start the recursion from the root of the JSON data
    TraverseAndReplace $jsonData
    return $jsonData
}

function Get-BlobFromStorage {
    param (
        [Parameter(Mandatory=$true)] [string]$resourceGroupName,
        [Parameter(Mandatory=$true)] [string]$storageAccountName,
        [Parameter(Mandatory=$true)] [string]$containerName,
        [Parameter(Mandatory=$true)] [string]$blobName
    )
    # Get the storage account key (assuming you have RBAC permissions)
    $storageAccountKey = (Get-AzStorageAccountKey -ResourceGroupName $resourceGroupName -AccountName $storageAccountName)[0].Value
    # Create a storage context
    $storageContext = New-AzStorageContext -StorageAccountName $storageAccountName -StorageAccountKey $storageAccountKey
    # Define the destination path
    $destinationFilePath = ".\$($blobName)"
    # Download the JSON blob to a file
    $blob = Get-AzStorageBlobContent -Blob $blobName -Container $containerName -Context $storageContext -ErrorAction SilentlyContinue
    if ($null -ne $blob) {
        # Extract the directory from the file path
        $directory = Split-Path -Path $blobName -Parent
        # Check if the directory exists, if not create it
        if (-not (Test-Path -Path $directory)) {
            New-Item -Path $directory -ItemType Directory -Force | Out-Null
        }
        $blob = Get-AzStorageBlobContent -Blob $blobName -Container $containerName -Context $storageContext -Destination $destinationFilePath -Force
        return Get-FileContent $destinationFilePath
    }
    return $null
}

function Get-BlobStorageFolders {
    param (
        [Parameter(Mandatory=$true)] [string]$resourceGroupName,
        [Parameter(Mandatory=$true)] [string]$storageAccountName,
        [Parameter(Mandatory=$true)] [string]$containerName,
        [Parameter(Mandatory=$false)] [string]$prefix = ""  # Optional prefix to filter blobs by "folder"
    )

    # Get the storage account key and create a storage context
    $storageAccountKey = (Get-AzStorageAccountKey -ResourceGroupName $resourceGroupName -AccountName $storageAccountName)[0].Value
    $storageContext = New-AzStorageContext -StorageAccountName $storageAccountName -StorageAccountKey $storageAccountKey

    # Get all blobs in the container, optionally filtered by a prefix (acting as a folder)
    $blobs = Get-AzStorageBlob -Container $containerName -Context $storageContext -Prefix $prefix

    # Extract the folder structure by splitting blob paths
    $folders = $blobs | ForEach-Object {
        $blobName = $_.Name
        $folder = Split-Path -Path $blobName -Parent  # Get the "folder" part of the blob path
        if ($folder -ne "") {
            [PSCustomObject]@{
                FullName = $folder
            }
        }
    } | Sort-Object -Property FullName -Unique  # Get unique folder paths
    return $folders
}

function Initialize-AuthContext {
    param (
        [parameter(Mandatory = $false)] [String] $TenantId,
        [parameter(Mandatory = $false)] [String] $ServicePrincipalId,
        [parameter(Mandatory = $false)] [String] $ServicePrincipalSecret
    )

    $isRunningInPipeline = $env:TF_BUILD -eq 'True'

    if (-not $isRunningInPipeline) {
        $hasCredentials     = -not [string]::IsNullOrWhiteSpace($TenantId) -and -not [string]::IsNullOrWhiteSpace($ServicePrincipalId)
        $hasExistingContext = $null -ne (Get-AzContext -ErrorAction SilentlyContinue)

        if ($hasCredentials) {
            # Explicit credentials supplied — always connect with them so the correct tenant is used,
            # even if there is already an active context pointing at a different tenant.
            if ([string]::IsNullOrWhiteSpace($ServicePrincipalSecret)) {
                $secureSecret = Read-Host -AsSecureString "Enter Service Principal Secret"
            }
            else {
                $secureSecret = ConvertTo-SecureString $ServicePrincipalSecret -AsPlainText -Force
            }
            $credential = New-Object System.Management.Automation.PSCredential($ServicePrincipalId, $secureSecret)
            Write-Message "Action" "Connecting to Azure using Service Principal '$($ServicePrincipalId)' on tenant '$($TenantId)'"
            Connect-AzAccount -ServicePrincipal -Credential $credential -Tenant $TenantId | Out-Null
        }
        elseif (-not $hasExistingContext) {
            # No credentials provided and no existing context — prompt interactively.
            $TenantId           = Read-Host "Enter Tenant ID"
            $ServicePrincipalId = Read-Host "Enter Service Principal (Client) ID"
            $secureSecret       = Read-Host -AsSecureString "Enter Service Principal Secret"
            $credential = New-Object System.Management.Automation.PSCredential($ServicePrincipalId, $secureSecret)
            Write-Message "Action" "Connecting to Azure using Service Principal '$($ServicePrincipalId)' on tenant '$($TenantId)'"
            Connect-AzAccount -ServicePrincipal -Credential $credential -Tenant $TenantId | Out-Null
        }
        # else: no credentials provided but an existing context is present — reuse it as-is.
    }

    #Resource use to authenticate and get the tokens
    $fabricTokenResourceUrl = "https://api.fabric.microsoft.com"
    $appIdForAzureDevOps = "499b84ac-1321-427f-aa17-267ca6975798"
    $graphTokenResourceUrl = "https://graph.microsoft.com/"

    Write-Message "Action" "Getting access token for Fabric from $($fabricTokenResourceUrl)"
    $secureFabricToken = (Get-AzAccessToken -ResourceUrl $fabricTokenResourceUrl -AsSecureString).Token
    $fabricToken = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureFabricToken))
    $script:fabricRequestHeader = New-RequestHeader -accessToken $fabricToken

    Write-Message "Action" "Getting access token for DevOps from App ID $($appIdForAzureDevOps)"
    $secureAzdoToken = (Get-AzAccessToken -ResourceUrl $appIdForAzureDevOps -AsSecureString).Token
    $azdoToken = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureAzdoToken))
    $script:devOpsRequestHeader = New-RequestHeader -accessToken $azdoToken

    Write-Message "Action" "Getting access token for MSFT Graph from $($graphTokenResourceUrl)"
    $secureGraphToken = (Get-AzAccessToken -ResourceUrl $graphTokenResourceUrl -AsSecureString).Token
    $graphToken = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureGraphToken))
    $script:graphRequestHeader = New-RequestHeader -accessToken $graphToken

}

function ConvertTo-FabricItemSegment {
    param (
        [Parameter(Mandatory = $true)] [string] $ItemType
    )
    switch ($ItemType.ToLower()) {
        'item'  { return 'items'    } # Core/Items API https://learn.microsoft.com/en-us/rest/api/fabric/core/items
        'child' { return 'children' } # irregular plural (this is an example)
        default { return "$($ItemType.ToLower())s" }
    }
}

function Get-DeploymentCsvContent {
    param (
        [parameter(Mandatory = $true)]  [String]         $configFilePath,
        [parameter(Mandatory = $true)]  [String]         $branchName,
        [parameter(Mandatory = $false)] [PSCustomObject] $AzdoConfig = $null
    )

    if (Test-Path $configFilePath) {
        $csvContent = Get-FileContent -filePath $configFilePath
        if ([string]::IsNullOrWhiteSpace($csvContent)) { return @("name,type,jsonPath,token") }
        return ($csvContent -split "`r?`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    }

    $azdoBase = if ($null -ne $AzdoConfig) { $AzdoConfig.AzdoBaseUrl }         else { $script:azdoBaseUrl }
    $org      = if ($null -ne $AzdoConfig) { $AzdoConfig.OrganizationName }    else { $script:organizationName }
    $project  = if ($null -ne $AzdoConfig) { $AzdoConfig.ProjectName }         else { $script:projectName }
    $repo     = if ($null -ne $AzdoConfig) { $AzdoConfig.RepositoryName }      else { $script:repositoryName }
    $headers  = if ($null -ne $AzdoConfig) { $AzdoConfig.DevOpsRequestHeader } else { $script:devOpsRequestHeader }

    $refSourceBranchName = $branchName
    if ($branchName -match "^refs/heads/") {
        $refSourceBranchName = $branchName -replace "^refs/heads/", ""
    }

    $downloadUrl = "$($azdoBase)/$($org)/$($project)/_apis/git/repositories/$($repo)/items?path=$($configFilePath)&versionDescriptor.versionType=branch&versionDescriptor.version=$($refSourceBranchName)&resolveLfs=true&api-version=7.1-preview.1"

    $targetPath = Get-RemoteFile `
        -FilePath $configFilePath.TrimStart("/") `
        -DownloadUrl $downloadUrl `
        -localFolder ".\temp" `
        -Headers $headers

    $csvContent = Get-FileContent -filePath $targetPath
    if ([string]::IsNullOrWhiteSpace($csvContent)) {
        return @("name,type,jsonPath,token")
    }
    return ($csvContent -split "`r?`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
}

function Get-JsonMapContent {
    param (
        [parameter(Mandatory = $true)]  [String]         $mapFilePath,
        [parameter(Mandatory = $true)]  [String]         $branchName,
        [parameter(Mandatory = $false)] [PSCustomObject] $AzdoConfig = $null
    )

    if (Test-Path $mapFilePath) {
        return Get-FileContent -filePath $mapFilePath | ConvertFrom-Json
    }

    $azdoBase = if ($null -ne $AzdoConfig) { $AzdoConfig.AzdoBaseUrl }         else { $script:azdoBaseUrl }
    $org      = if ($null -ne $AzdoConfig) { $AzdoConfig.OrganizationName }    else { $script:organizationName }
    $project  = if ($null -ne $AzdoConfig) { $AzdoConfig.ProjectName }         else { $script:projectName }
    $repo     = if ($null -ne $AzdoConfig) { $AzdoConfig.RepositoryName }      else { $script:repositoryName }
    $headers  = if ($null -ne $AzdoConfig) { $AzdoConfig.DevOpsRequestHeader } else { $script:devOpsRequestHeader }

    $refSourceBranchName = $branchName
    if ($branchName -match "^refs/heads/") {
        $refSourceBranchName = $branchName -replace "^refs/heads/", ""
    }

    $downloadUrl = "$($azdoBase)/$($org)/$($project)/_apis/git/repositories/$($repo)/items?path=$($mapFilePath)&versionDescriptor.versionType=branch&versionDescriptor.version=$($refSourceBranchName)&resolveLfs=true&api-version=7.1-preview.1"

    $targetPath = Get-RemoteFile `
        -FilePath $mapFilePath.TrimStart("/") `
        -DownloadUrl $downloadUrl `
        -localFolder ".\temp" `
        -Headers $headers

    return Get-FileContent -filePath $targetPath | ConvertFrom-Json
}