###############################################################################
# Script Name:  ItemFunctions.ps1
# Description:  Temporal description
# Author:       Hector Lopez (Manager @Intelligent Platforms)
# Contact:      svenchio@techtacofriday.com
# Blog:         https://www.techtacofriday.com/
###############################################################################
function Wait-FabricNotebookJob {
  param (
      [parameter(Mandatory = $true)]  [String] $location,
      [parameter(Mandatory = $false)] [int]    $retryInterval = 5,
      [parameter(Mandatory = $false)] [int]    $attempMax = 6
  )
    $attempCount = 1
    $endPoint = "/" + $location.Substring(($script:fabricBaseUrl + "/v1").Length).TrimStart('/')
    while ($attempCount -lt $attempMax) {
        Write-Message "Action" "Waiting $($retryInterval) secs for notebook job to complete (attempt $($attempCount)/$($attempMax))"
        Start-Sleep -Seconds $retryInterval
        $lroResponse = Invoke-ApiEndpoint -endPoint $endPoint -method "GET"
        if ($lroResponse.isException -eq $false) {
            $operationState = $lroResponse.responseObject.Content | ConvertFrom-Json
            if ($operationState.status -eq "Completed") {
                Write-Message "Info" "Notebook job completed."
                return
            }
            elseif ($operationState.status -in @("Failed", "Cancelled", "Dedup")) {
                throw ($operationState.failureReason)
            }
            $attempCount++
        }
        else {
            throw (APIReturnedError -apiCallResponse $lroResponse -intendedAction "polling notebook job status '$location'")
        }
    }
    throw "Notebook job at '$location' did not complete within $($attempMax) attempts."
}

function Get-FabricFolders {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [ValidatePattern('\S')]
        [string] $workspaceId
    )
    try {
        $endPoint = "/workspaces/$workspaceId/folders"
        $resp = Invoke-ApiEndpoint -endPoint $endPoint
        if ($resp.responseObject.StatusCode -eq 200) {
            $json = ($resp.responseObject.Content | ConvertFrom-Json)
            $folders = @()
            if ($null -ne $json.value) { $folders = $json.value }
            Write-Message "Info" "Retrieved $($folders.Count) folder(s) from workspace $workspaceId."
            return $folders
        } else {
            Write-Message "Error" (APIReturnedError -apiCallResponse $resp -intendedAction "listing Fabric folders")
            return @()
        }
    }
    catch {
        Write-Message "Error" "$(Get-ErrorResponse($_)). Function Get-FabricFolders failed."
        return @()
    }
}

function Invoke-FabricNotebook {
    <#
      POST /workspaces/{workspaceId}/items/{itemId}/jobs/instances?jobType=RunNotebook
      Body: minimal -> { "executionData": {} }
    #>
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [ValidatePattern('\S')]
        [string] $workspaceId,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [ValidatePattern('\S')]
        [string] $notebookItemId,
        [Bool] $whatIf = $true
    )
    try {
        $body = @{ executionData = @{} } | ConvertTo-Json -Depth 10
        $endPoint = "/workspaces/$workspaceId/items/$notebookItemId/jobs/instances?jobType=RunNotebook"
        if ($whatIf) {
            Write-Message "Info" "What If flag is active, only showing the $($endPoint) to be executed."
            return
        }
        $resp = Invoke-ApiEndpoint -endPoint $endPoint -method "POST" -body $body
        if ($resp.isException -eq $false) {
            if ($resp.responseObject.StatusCode -in 202) {
                $location      = [string]($resp.responseObject.Headers.'Location'    | Select-Object -First 1)
                $retryInterval = [int]($resp.responseObject.Headers.'Retry-After' | Select-Object -First 1)
                Write-Message "Info" "Request accepted (Location $($location)), waiting for notebook to complete."
                Wait-FabricNotebookJob -location $location -retryInterval $retryInterval | Out-Null
            }
        }
        else {
            throw (APIReturnedError -apiCallResponse $resp -intendedAction "triggering notebook run for item '$notebookItemId'")
        }
    }
    catch {
        Write-Message "Error" "$(Get-ErrorResponse($_)). Function Invoke-FabricNotebook failed."
        throw
    }
}

function Get-FabricFolder {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [ValidatePattern('\S')]
        [string] $workspaceId,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [ValidatePattern('\S')]
        [string] $displayName
    )
    try {
        $folders = Get-FabricFolders -workspaceId $workspaceId
        if (-not $folders -or $folders.Count -eq 0) {
            Write-Message "Warning" "No folders found in workspace $workspaceId."
            return $null
        }
        $match = $folders | Where-Object { $_.displayName -and ($_.displayName -eq $displayName) } | Select-Object -First 1
        if ($null -eq $match) {
            $match = $folders | Where-Object { $_.displayName -and ($_.displayName.ToLower() -eq $displayName.ToLower()) } | Select-Object -First 1
        }
        if ($null -eq $match) {
            Write-Message "Warning" "Folder '$displayName' not found in workspace $workspaceId."
            return $null
        }
        Write-Message "Info" "Folder '$displayName' found: id=$($match.id)"
        return [string]$match.id
    }
    catch {
        Write-Message "Error" "$(Get-ErrorResponse($_)). Function Get-FabricFolder failed."
        return $null
    }
}

function Get-FabricItemsByFolder {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [ValidatePattern('\S')]
        [string] $workspaceId,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [ValidatePattern('\S')]
        [string] $type,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [ValidatePattern('\S')]
        [string] $rootFolderId
    )
    try {
        $encodedType     = [System.Uri]::EscapeDataString($type)
        $encodedFolderId = [System.Uri]::EscapeDataString($rootFolderId)
        $endPoint = "/workspaces/$workspaceId/items?type=$encodedType&rootFolderId=$encodedFolderId"
        $resp = Invoke-ApiEndpoint -endPoint $endPoint
        if ($resp.responseObject.StatusCode -eq 200) {
            $items = @()
            $json = ($resp.responseObject.Content | ConvertFrom-Json)
            if ($null -ne $json.value) { $items = $json.value }
            Write-Message "Info" "Retrieved $($items.Count) item(s) of type '$type' under folderId=$rootFolderId."
            return $items
        } else {
            Write-Message "Error" (APIReturnedError -apiCallResponse $resp -intendedAction "listing Fabric items of type '$type' for folder '$rootFolderId'")
            return @()
        }
    }
    catch {
        Write-Message "Error" "$(Get-ErrorResponse($_)). Function Get-FabricItemsByFolder failed."
        return @()
    }
}

function Set-SemanticModelConnection {
    param (
        [parameter(Mandatory = $true)] [String] $workspaceId,
        [parameter(Mandatory = $true)] [String] $semanticModelId,
        [parameter(Mandatory = $true)] [String] $connectionId,
        [parameter(Mandatory = $true)] [String] $connectivityType,
        [parameter(Mandatory = $true)] [String] $connectionDetailsType,
        [parameter(Mandatory = $true)] [String] $connectionDetailsPath
    )
    try {
        Write-Message "Action" "Binding semantic model $($semanticModelId) on workspace $($workspaceId)."
        $requestBody = @{
            connectionBinding = @{
                id               = $connectionId
                connectivityType = $connectivityType
                connectionDetails = @{
                    type = $connectionDetailsType
                    path = $connectionDetailsPath
                }
            }
        } | ConvertTo-Json -Depth 4
        $endPoint = "/workspaces/$($workspaceId)/semanticModels/$($semanticModelId)/bindConnection"
        $bindingResponse = Invoke-ApiEndpoint -endPoint $endPoint -method "POST" -body $requestBody
        if ($bindingResponse.isException) {
            throw (APIReturnedError -apiCallResponse $bindingResponse -intendedAction "binding semantic model")
        }
    }
    catch {
        Write-Message "Error" "$(Get-ErrorResponse($_)). Function Set-SemanticModelConnection failed."
        throw
    }
}

function New-ItemDefinitionParts {
    param (
        [parameter(Mandatory = $true)] [string] $itemName,
        [parameter(Mandatory = $true)] [string] $itemType,
        [parameter(Mandatory = $false)] [String] $csvFilePath = $null,
        [parameter(Mandatory = $false)] [String] $dfnDirectory = $null,
        [parameter(Mandatory = $true)] [PSCustomObject] $dfnParts,
        [parameter(Mandatory = $false)]
        [ValidateSet("True", "False")] [String] $enableDiagnostics = "False"
    )

    $requestDfnParts = [PSCustomObject]@()

    foreach ($dfnPart in $dfnParts) {

            $dfnFilePath = "$($dfnDirectory)/$($dfnPart.fileName)"

            if ([bool]$dfnPart.isFolder -eq $true) {
                # Fetch folder content recursively
                if (Test-Path $dfnFilePath -PathType Container) {
                    $folderContents = Get-ChildItem -Path $dfnFilePath -Recurse | ForEach-Object {
                        [PSCustomObject]@{
                            fileName = $_.FullName.Substring($dfnDirectory.Length + 1)  # Relative path
                        }
                    }

                    # Recursively call the function for each discovered file
                    $requestDfnParts += New-ItemDefinitionParts `
                        -itemName $itemName `
                        -itemType $itemType `
                        -csvFilePath $csvFilePath `
                        -dfnDirectory $dfnDirectory `
                        -dfnParts $folderContents `
                        -enableDiagnostics $enableDiagnostics
                }
                continue
            }

            if (-not (Test-Path -Path $dfnFilePath)) {
                throw "Cannot create '$($itemName)': required definition file '$($dfnFilePath)' was not found."
            }
            $partFileContent = Get-FileContent -filePath $dfnFilePath

            # Load CSV data if applicable
            $csvData = @{}
            if (![String]::IsNullOrEmpty($csvFilePath)) {
                Import-Csv -Path $csvFilePath | Where-Object {
                    ($itemName -like $_.name) -and ($_.'type' -eq $itemType) -and ($_.'token' -notmatch '^#\{.*\}#$')
                } | ForEach-Object {
                    $key = $_.'jsonPath'
                    $value = $_.'token'
                    if (-not $csvData.ContainsKey($key)) {
                        $csvData[$key] = $value
                    }
                }
            }
            else {
                foreach ($detokanizedJsonValue in $dfnPart.csvData) {
                    $csvData[$detokanizedJsonValue.jsonPath] = $detokanizedJsonValue.token
                }
            }

            # If updateJsonValues is true, modify the JSON
            if ([bool]$dfnPart.updateJsonValues) {
                $dfnFileExtension = [System.IO.Path]::GetExtension($dfnFilePath)
                if ($dfnFileExtension -eq ".py") {
                    $metadataPattern = [regex]::new('# METADATA \*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*(.*?)# CELL \*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*', 'Singleline')
                    $metadataMatch = $metadataPattern.Match($partFileContent)
                    if ($metadataMatch.Success) {
                        $metadataJsonStr = ($metadataMatch.Groups[1].Value.Trim()) -replace '# META\s+', ''
                        $jsonObject = $metadataJsonStr | ConvertFrom-Json
                    } else {
                        Write-Message "Warning" "No metadata block found in '$dfnFilePath' - skipping JSON update."
                        continue
                    }
                }
                else {
                    $jsonObject = $partFileContent | ConvertFrom-Json
                }

                Write-Message "Develop" "jsonObject(Current)>$($jsonObject | ConvertTo-Json -Depth 10 -Compress)"
                $updatedJsonObject = Update-JsonValues -csvData $csvData -jsonObject $jsonObject
                Write-Message "Develop" "jsonObject(Updated)>$($updatedJsonObject | ConvertTo-Json -Depth 10 -Compress)"

                if ($dfnFileExtension -eq ".py") {
                    $lineEnding      = if ($partFileContent -match '\r\n') { "`r`n" } else { "`n" }
                    $updatedJsonPretty = $updatedJsonObject | ConvertTo-Json -Depth 20
                    $updatedJsonBlock  = ($updatedJsonPretty -split '\r?\n' | ForEach-Object { "# META $_" }) -join $lineEnding
                    $originalBlock     = $metadataMatch.Groups[1].Value.Trim()
                    $updatedJson       = $partFileContent.Replace($originalBlock, $updatedJsonBlock)
                }
                else {
                    $updatedJson = $updatedJsonObject | ConvertTo-Json -Depth 20
                }

                $payLoadContentForDiagnostics = $updatedJson
                $partPayload = ConvertTo-Payload -content $updatedJson
                $requestDfnParts += [PSCustomObject]@{
                    path = $dfnPart.fileName
                    payload = $partPayload
                    payloadType = "InlineBase64"
                }
            }
            elseif ($dfnPart.fileName -eq 'definition/expressions.tmdl') {
                foreach ($key in $csvData.Keys) {
                    $updatedYamlContent = $partFileContent
                    if ($key -eq "expression.DatabaseQuery") {
                        $pattern = 'let\s+database\s*=\s*Sql\.Database\(\s*"[^"]+"\s*,\s*"[^"]+"\s*\)\s*in\s+database'
                        $updatedYamlContent = $partFileContent -replace $pattern, $csvData[$key]
                    }
                    $payLoadContentForDiagnostics = $updatedYamlContent
                    $partPayload = ConvertTo-Payload -content $updatedYamlContent
                    $requestDfnParts += [PSCustomObject]@{
                        path = $dfnPart.fileName
                        payload = $partPayload
                        payloadType = "InlineBase64"
                    }
                }
            }
            else {
                $payLoadContentForDiagnostics = $partFileContent
                $partPayload = ConvertTo-Payload -content $partFileContent
                $requestDfnParts += [PSCustomObject]@{
                    path = $dfnPart.fileName
                    payload = $partPayload
                    payloadType = "InlineBase64"
                }
            }

            if ([Convert]::ToBoolean($enableDiagnostics)) {
                Export-ContentToFile -content $payLoadContentForDiagnostics -filePath "$($dfnDirectory)\diag\$($dfnPart.fileName)" | Out-Null
            }
        }
        return $requestDfnParts
}

function New-FabricItem {
    param (
        [parameter(Mandatory = $true)]  [String]         $itemName,
        [parameter(Mandatory = $true)]  [string]         $itemType,
        [parameter(Mandatory = $false)] [PSCustomObject] $itemDefinitionParts = $null,
        [parameter(Mandatory = $false)] [int]            $partsMandatory = 0,
        [parameter(Mandatory = $true)]  [String]         $workspaceId,
        [parameter(Mandatory = $false)] [bool]           $updateDefinition = $false,
        [parameter(Mandatory = $false)] [int]            $randomizeItemName = 0,
        [parameter(Mandatory = $false)] [PSCustomObject] $Context = $null
    )

    <#FOR TEST PURPOSES ONLY#>
    if ([bool]$randomizeItemName -and $updateDefinition -eq $false) {
        $randomNumber = Get-Random -Minimum 100 -Maximum 1000
        $itemName = "$($itemName)_$($randomNumber)"
    }
    <##>
    $itemApiInterface = ConvertTo-FabricItemSegment -ItemType $itemType
    $endPoint = "/workspaces/$($workspaceId)/$($itemApiInterface)"
    $itemsResponse = Invoke-ApiEndpoint -endPoint $endPoint -Context $Context
    if ($itemsResponse.responseObject.StatusCode -eq 200) {
        $item = ($itemsResponse.responseObject.Content | ConvertFrom-Json).value | Where-Object {$_.displayName -eq $itemName}
        if (($null -ne $item) -and ($null -ne $itemDefinitionParts) -and $updateDefinition) {
            Write-Message "Action" "Updating existing $($itemType) $($itemName)."
            $requestBody = @{
                definition = @{
                    parts = @(
                        $itemDefinitionParts
                    )
                }
            } | ConvertTo-Json -Depth 4
            $endPoint = "/workspaces/$($workspaceId)/$($itemApiInterface)/$($item.id)/updateDefinition"
        }
        elseif (($null -eq $item) -and ($null -ne $itemDefinitionParts)) {
            Write-Message "Action" "Creating new $($itemType) $($itemName) with definition."
            $requestBody = @{
                displayName = $itemName
                description = $itemName
                definition = @{
                    parts = @(
                        $itemDefinitionParts
                    )
                }
            } | ConvertTo-Json -Depth 4
            $endPoint = "/workspaces/$($workspaceId)/$($itemApiInterface)"
        }
        elseif ($null -eq $item) {
            if([bool]$partsMandatory -eq $false){
                Write-Message "Action" "Creating new empty $($itemType) $($itemName)."
                $requestBody = @{
                    displayName = $itemName
                    description = $itemName
                } | ConvertTo-Json -Depth 4
                $endPoint = "/workspaces/$($workspaceId)/$($itemApiInterface)"
            }
            else {
                throw "Cannot create $($itemType) '$($itemName)': item definition parts are mandatory but were not provided."
            }
        }
        else {
            Write-Message "Info" "$($itemType) $($itemName) ($($item.id)) was found."
            return $item.id
        }
        #Starts long running operations (LRO).
        $itemResponse = Invoke-ApiEndpoint -endPoint $endPoint -method "POST" -body $requestBody -Context $Context
        if ($itemResponse.isException) {
            throw (APIReturnedError -apiCallResponse $itemResponse -intendedAction "create a $($itemName)")
        }
        elseif ($itemResponse.isException -eq $false -and $itemResponse.responseObject.StatusCode -eq 202) {
            $operationId  = [string]($itemResponse.responseObject.Headers.'x-ms-operation-id' | Select-Object -First 1)
            $retryInterval = [int]($itemResponse.responseObject.Headers.'Retry-After' | Select-Object -First 1)
            Write-Message "Info" "Request accepted (operation id $($operationId)), deployment in progress."
            Wait-FabricLRO -operationId $operationId -retryInterval $retryInterval -attempMax 20 -Context $Context | Out-Null
            $item = Get-FabricItem -itemName $itemName -itemType $itemType -workspaceId $workspaceId -Context $Context
            Write-Message "Info" "$($itemName) has been deployed successfully"
        }
        else {
            $item = $itemResponse.responseObject.Content | ConvertFrom-Json
            Write-Message "Info" "$($itemName) has been deployed successfully"
        }
        return $item.id
    }
    else {
        throw (APIReturnedError -apiCallResponse $itemsResponse -intendedAction "list items")
    }
}

function Get-FabricItem {
    param (
        [parameter(Mandatory = $true)]  [String]         $itemName,
        [parameter(Mandatory = $true)]  [string]         $itemType,
        [parameter(Mandatory = $true)]  [String]         $workspaceId,
        [parameter(Mandatory = $false)] [PSCustomObject] $Context = $null
    )
    $itemApiInterface = ConvertTo-FabricItemSegment -ItemType $itemType
    $endPoint = "/workspaces/$($workspaceId)/$($itemApiInterface)"
    $itemsResponse = Invoke-ApiEndpoint -endPoint $endPoint -Context $Context
    if ($itemsResponse.responseObject.StatusCode -eq 200) {
        return ($itemsResponse.responseObject.Content | ConvertFrom-Json).value | Where-Object {$_.displayName -eq $itemName}
    }
    else {
        throw (APIReturnedError -apiCallResponse $itemsResponse -intendedAction "list items")
    }
}

function Get-FabricItemsByType {
    param(
        [Parameter(Mandatory = $true)] [string] $workspaceId,
        [Parameter(Mandatory = $true)] [string] $itemType
    )
    $itemApiInterface = ConvertTo-FabricItemSegment -ItemType $itemType
    $endPoint = "/workspaces/$workspaceId/$itemApiInterface"
    $resp = Invoke-ApiEndpoint -endPoint $endPoint
    if ($resp.responseObject.StatusCode -eq 200) {
        $items = @()
        $json  = ($resp.responseObject.Content | ConvertFrom-Json)
        if ($null -ne $json.value) { $items = $json.value }
        return $items
    } else {
        throw (APIReturnedError -apiCallResponse $resp -intendedAction "listing Fabric items of type '$itemType'")
    }
}

function Get-FabricItemDefinition {
    param (
        [parameter(Mandatory = $true)]  [String]         $itemId,
        [parameter(Mandatory = $true)]  [string]         $itemType,
        [parameter(Mandatory = $true)]  [String]         $workspaceId,
        [parameter(Mandatory = $false)] [int]            $outputPartsAsFiles = 0,
        [parameter(Mandatory = $false)] [String]         $outputFileDirectory = $null,
        [parameter(Mandatory = $false)] [String]         $format = $null,
        [parameter(Mandatory = $false)] [PSCustomObject] $Context = $null
    )

    if (![string]::IsNullOrWhiteSpace($format)) {
        $format = "?format=$($format)"
    }
    $itemApiInterface = ConvertTo-FabricItemSegment -ItemType $itemType
    $endPoint = "/workspaces/$($workspaceId)/$($itemApiInterface)/$($itemId)/getDefinition"+$format
    $getDefinitionResponse = Invoke-ApiEndpoint -endPoint $endPoint -method "POST" -Context $Context
    if ($getDefinitionResponse.isException) {
        throw (APIReturnedError -apiCallResponse $getDefinitionResponse -intendedAction "fetch item defintion for $($itemType) ($($itemId))")
    }
    elseif ($getDefinitionResponse.isException -eq $false -and $getDefinitionResponse.responseObject.StatusCode -eq 202) {
        $operationId   = [string]($getDefinitionResponse.responseObject.Headers.'x-ms-operation-id' | Select-Object -First 1)
        $retryInterval = [int]($getDefinitionResponse.responseObject.Headers.'Retry-After'          | Select-Object -First 1)
        Write-Message "Info" "Request accepted (operation id $($operationId)), deployment in progress."
        $itemDefinition = Wait-FabricLRO -operationId $operationId -retryInterval $retryInterval -attempMax 20 -Context $Context
        Write-Message "Info" "LRO operation returned as successfull"
    }
    else {
        $itemDefinition = $getDefinitionResponse.responseObject.Content | ConvertFrom-Json
    }
    if ([bool]$outputPartsAsFiles) {
        foreach ($itemDefinitionPart in $itemDefinition.definition.parts) {
            $decodedPartContent = ConvertFrom-Payload -content $itemDefinitionPart.payload
            Export-ContentToFile `
                -content $decodedPartContent `
                -filePath "$($outputFileDirectory)\$($itemDefinitionPart.path)" | Out-Null
        }
    }
    return $itemDefinition
}