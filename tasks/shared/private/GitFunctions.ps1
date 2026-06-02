###############################################################################
# Script Name:  GitFunctions.ps1
# Description:  Temporal description
# Author:       Hector Lopez (Manager @Intelligent Platforms)
# Contact:      svenchio@techtacofriday.com
# Blog:         https://www.techtacofriday.com/
###############################################################################
function newBranchJsonBody {
    param (
        [parameter(Mandatory = $true)] [String] $newBranchName,
        [parameter(Mandatory = $true)] [String] $newObjectId
    )
$jsonBody = @"
[ { "name": "refs/heads/$newBranchName",
    "oldObjectId": "0000000000000000000000000000000000000000",
    "newObjectId": "$newObjectId" } ]
"@
return $jsonBody
}

function Remove-GitBranch {
    param (
        [parameter(Mandatory = $true)]  [String]         $branchName,
        [parameter(Mandatory = $false)] [PSCustomObject] $AzdoConfig = $null
    )
    $azdoBase = if ($null -ne $AzdoConfig) { $AzdoConfig.AzdoBaseUrl }      else { $script:azdoBaseUrl }
    $org      = if ($null -ne $AzdoConfig) { $AzdoConfig.OrganizationName } else { $script:organizationName }
    $project  = if ($null -ne $AzdoConfig) { $AzdoConfig.ProjectName }      else { $script:projectName }
    $repo     = if ($null -ne $AzdoConfig) { $AzdoConfig.RepositoryName }   else { $script:repositoryName }
    $resolvedPat      = if ($null -ne $AzdoConfig -and -not [string]::IsNullOrWhiteSpace($AzdoConfig.Pat))             { $AzdoConfig.Pat }             else { $null }
    $resolvedProvider = if ($null -ne $AzdoConfig -and -not [string]::IsNullOrWhiteSpace($AzdoConfig.GitProviderType)) { $AzdoConfig.GitProviderType } else { "AzureDevOps" }

    if ($resolvedProvider -eq "GitHub") {
        if ([string]::IsNullOrWhiteSpace($resolvedPat)) { throw "A PAT is required when gitProviderType is 'GitHub'." }
        $script:gitHubRequestHeader = New-RequestHeader -authType "Bearer" -accessToken $resolvedPat
        $script:gitHubRequestHeader['Accept'] = 'application/vnd.github+json'
        $script:gitHubRequestHeader['X-GitHub-Api-Version'] = '2022-11-28'
        $ghBase = "https://api.github.com"
        $deleteResponse = Invoke-ApiEndpoint -useRequestHeader "GitHub" -baseUrl $ghBase -endPoint "/repos/$($org)/$($repo)/git/refs/heads/$($branchName)" -method "DELETE"
        if ($deleteResponse.responseObject.StatusCode -ne 204) {
            throw (APIReturnedError -apiCallResponse $deleteResponse -intendedAction "deleting existing branch '$branchName' on GitHub")
        }
        return
    }

    $invokeHeader = if (-not [string]::IsNullOrWhiteSpace($resolvedPat)) { New-RequestHeader -authType "Basic" -accessToken $resolvedPat } else { $null }

    $endPoint = "/$($org)/$($project)/_apis/git/repositories/$($repo)/refs?filter=heads/$($branchName)&api-version=7.0"
    $refResponse = if ($null -ne $invokeHeader) {
        Invoke-ApiEndpoint -CustomHeader $invokeHeader -baseUrl $azdoBase -endPoint $endPoint
    } else {
        Invoke-ApiEndpoint -useRequestHeader "DevOps" -baseUrl $azdoBase -endPoint $endPoint
    }
    if ($refResponse.responseObject.StatusCode -ne 200) {
        throw (APIReturnedError -apiCallResponse $refResponse -intendedAction "getting SHA of branch '$branchName' before deletion")
    }
    $branchRef = ($refResponse.responseObject.Content | ConvertFrom-Json).value | Where-Object { $_.name -eq "refs/heads/$($branchName)" }
    if ($null -eq $branchRef) { return }

    $deleteBody = "[{`"name`":`"refs/heads/$($branchName)`",`"oldObjectId`":`"$($branchRef.objectId)`",`"newObjectId`":`"0000000000000000000000000000000000000000`"}]"
    $endPoint = "/$($org)/$($project)/_apis/git/repositories/$($repo)/refs?api-version=6.0"
    $deleteResponse = if ($null -ne $invokeHeader) {
        Invoke-ApiEndpoint -CustomHeader $invokeHeader -baseUrl $azdoBase -endPoint $endPoint -method "POST" -body $deleteBody
    } else {
        Invoke-ApiEndpoint -useRequestHeader "DevOps" -baseUrl $azdoBase -endPoint $endPoint -method "POST" -body $deleteBody
    }
    if ($deleteResponse.responseObject.StatusCode -ne 200) {
        throw (APIReturnedError -apiCallResponse $deleteResponse -intendedAction "deleting existing branch '$branchName'")
    }
}

function New-GitBranchFromExisting {
    param (
        [parameter(Mandatory = $true)]  [String]         $newBranchName,
        [parameter(Mandatory = $false)] [PSCustomObject] $AzdoConfig = $null
    )
    $azdoBase      = if ($null -ne $AzdoConfig) { $AzdoConfig.AzdoBaseUrl }      else { $script:azdoBaseUrl }
    $org           = if ($null -ne $AzdoConfig) { $AzdoConfig.OrganizationName } else { $script:organizationName }
    $project       = if ($null -ne $AzdoConfig) { $AzdoConfig.ProjectName }      else { $script:projectName }
    $repo          = if ($null -ne $AzdoConfig) { $AzdoConfig.RepositoryName }   else { $script:repositoryName }
    $sourceBranch  = if ($null -ne $AzdoConfig) { $AzdoConfig.SourceBranchName } else { $script:sourceBranchName }
    $resolvedPat      = if ($null -ne $AzdoConfig -and -not [string]::IsNullOrWhiteSpace($AzdoConfig.Pat))             { $AzdoConfig.Pat }             else { $null }
    $resolvedProvider = if ($null -ne $AzdoConfig -and -not [string]::IsNullOrWhiteSpace($AzdoConfig.GitProviderType)) { $AzdoConfig.GitProviderType } else { "AzureDevOps" }

    if ($resolvedProvider -eq "GitHub") {
        if ([string]::IsNullOrWhiteSpace($resolvedPat)) { throw "A PAT is required when gitProviderType is 'GitHub'." }
        $script:gitHubRequestHeader = New-RequestHeader -authType "Bearer" -accessToken $resolvedPat
        $script:gitHubRequestHeader['Accept'] = 'application/vnd.github+json'
        $script:gitHubRequestHeader['X-GitHub-Api-Version'] = '2022-11-28'
        $ghBase = "https://api.github.com"
        $refResponse = Invoke-ApiEndpoint -useRequestHeader "GitHub" -baseUrl $ghBase -endPoint "/repos/$($org)/$($repo)/git/ref/heads/$($sourceBranch)"
        if ($refResponse.responseObject.StatusCode -eq 200) {
            $sha = ($refResponse.responseObject.Content | ConvertFrom-Json).object.sha
            $jsonBody = "{`"ref`":`"refs/heads/$($newBranchName)`",`"sha`":`"$($sha)`"}"
            $createResponse = Invoke-ApiEndpoint -useRequestHeader "GitHub" -baseUrl $ghBase -endPoint "/repos/$($org)/$($repo)/git/refs" -method "POST" -body $jsonBody
            if ($createResponse.responseObject.StatusCode -eq 422) {
                Write-Message "Warning" "Branch $($newBranchName) already existed from a previous failed run - deleting and recreating."
                Remove-GitBranch -branchName $newBranchName -AzdoConfig $AzdoConfig
                $createResponse = Invoke-ApiEndpoint -useRequestHeader "GitHub" -baseUrl $ghBase -endPoint "/repos/$($org)/$($repo)/git/refs" -method "POST" -body $jsonBody
            }
            if ($createResponse.responseObject.StatusCode -eq 201) {
                Write-Message "Info" "Branch $($newBranchName) was successfully branched out of $($sourceBranch) on GitHub."
                return $repo
            }
            else {
                throw (APIReturnedError -apiCallResponse $createResponse -intendedAction "creating a new git branch on GitHub")
            }
        }
        else {
            throw (APIReturnedError -apiCallResponse $refResponse -intendedAction "getting source branch SHA from GitHub")
        }
    }

    $invokeHeader = if (-not [string]::IsNullOrWhiteSpace($resolvedPat)) { New-RequestHeader -authType "Basic" -accessToken $resolvedPat } else { $null }

    $endPoint = "/$($org)/$($project)/_apis/git/repositories/$($repo)/refs?filter=heads/$($sourceBranch)&api-version=7.0"
    $gitRepositoriesResponse = if ($null -ne $invokeHeader) {
        Invoke-ApiEndpoint -CustomHeader $invokeHeader -baseUrl $azdoBase -endPoint $endPoint
    } else {
        Invoke-ApiEndpoint -useRequestHeader "DevOps" -baseUrl $azdoBase -endPoint $endPoint
    }
    if ($gitRepositoriesResponse.responseObject.StatusCode -eq 200) {
        $refSourceBranchName = "refs/heads/$($sourceBranch)"
        $gitRepository = ($gitRepositoriesResponse.responseObject.Content | ConvertFrom-Json).value | Where-Object {$_.name -eq $refSourceBranchName}
        if ($null -ne $gitRepository) {
            $targetEndPoint = "/$($org)/$($project)/_apis/git/repositories/$($repo)/refs?filter=heads/$($newBranchName)&api-version=7.0"
            $targetRefResponse = if ($null -ne $invokeHeader) {
                Invoke-ApiEndpoint -CustomHeader $invokeHeader -baseUrl $azdoBase -endPoint $targetEndPoint
            } else {
                Invoke-ApiEndpoint -useRequestHeader "DevOps" -baseUrl $azdoBase -endPoint $targetEndPoint
            }
            if ($targetRefResponse.responseObject.StatusCode -eq 200) {
                $existingRef = ($targetRefResponse.responseObject.Content | ConvertFrom-Json).value | Where-Object { $_.name -eq "refs/heads/$($newBranchName)" }
                if ($null -ne $existingRef) {
                    Write-Message "Warning" "Branch $($newBranchName) already existed from a previous failed run - deleting and recreating."
                    Remove-GitBranch -branchName $newBranchName -AzdoConfig $AzdoConfig
                }
            }
            $jsonBody = newBranchJsonBody -newBranchName $newBranchName -newObjectId $gitRepository.objectid
            $endPoint = "/$($org)/$($project)/_apis/git/repositories/$($repo)/refs?api-version=6.0"
            $newGitBranchReponse = if ($null -ne $invokeHeader) {
                Invoke-ApiEndpoint -CustomHeader $invokeHeader -baseUrl $azdoBase -endPoint $endPoint -method "POST" -body $jsonBody
            } else {
                Invoke-ApiEndpoint -useRequestHeader "DevOps" -baseUrl $azdoBase -endPoint $endPoint -method "POST" -body $jsonBody
            }
            if ($newGitBranchReponse.responseObject.StatusCode -eq 200) {
                $newGitBranch = ($newGitBranchReponse.responseObject.Content | ConvertFrom-Json).value
                Write-Message "Info" "Branch $($newBranchName) ($($newGitBranch.repositoryId)) was successfully branched out of $($sourceBranch)."
                return $newGitBranch.repositoryId
            }
            else {
                throw (APIReturnedError -apiCallResponse $newGitBranchReponse -intendedAction "creating a new git branch")
            }
        }
        else {
            throw "Specified source branch ($($sourceBranch)) wasn't found, therefore, can't branch a new one."
        }
    }
    else {
        throw (APIReturnedError -apiCallResponse $gitRepositoriesResponse -intendedAction "list available branches")
    }
}

function New-GitBranchFromScratch {
    param (
        [parameter(Mandatory = $true)]  [String]         $newBranchName,
        [parameter(Mandatory = $false)] [String]         $itemsGitFolder = "/fabric",
        [parameter(Mandatory = $false)] [PSCustomObject] $AzdoConfig = $null
    )
    $azdoBase     = if ($null -ne $AzdoConfig) { $AzdoConfig.AzdoBaseUrl }      else { $script:azdoBaseUrl }
    $org          = if ($null -ne $AzdoConfig) { $AzdoConfig.OrganizationName } else { $script:organizationName }
    $project      = if ($null -ne $AzdoConfig) { $AzdoConfig.ProjectName }      else { $script:projectName }
    $repo         = if ($null -ne $AzdoConfig) { $AzdoConfig.RepositoryName }   else { $script:repositoryName }
    $gitkeepPath  = $itemsGitFolder.TrimEnd('/') + '/.gitkeep'
    $resolvedPat      = if ($null -ne $AzdoConfig -and -not [string]::IsNullOrWhiteSpace($AzdoConfig.Pat))             { $AzdoConfig.Pat }             else { $null }
    $resolvedProvider = if ($null -ne $AzdoConfig -and -not [string]::IsNullOrWhiteSpace($AzdoConfig.GitProviderType)) { $AzdoConfig.GitProviderType } else { "AzureDevOps" }

    if ($resolvedProvider -eq "GitHub") {
        if ([string]::IsNullOrWhiteSpace($resolvedPat)) { throw "A PAT is required when gitProviderType is 'GitHub'." }
        $script:gitHubRequestHeader = New-RequestHeader -authType "Bearer" -accessToken $resolvedPat
        $script:gitHubRequestHeader['Accept'] = 'application/vnd.github+json'
        $script:gitHubRequestHeader['X-GitHub-Api-Version'] = '2022-11-28'
        $ghBase = "https://api.github.com"

        $blobResp = Invoke-ApiEndpoint -useRequestHeader "GitHub" -baseUrl $ghBase -endPoint "/repos/$($org)/$($repo)/git/blobs" -method "POST" -body '{"content":"","encoding":"utf-8"}'
        if ($blobResp.responseObject.StatusCode -ne 201) { throw (APIReturnedError -apiCallResponse $blobResp -intendedAction "creating blob on GitHub") }
        $blobSha = ($blobResp.responseObject.Content | ConvertFrom-Json).sha

        $normalizedKeep = $gitkeepPath.TrimStart('/')
        $treeBody = "{`"tree`":[{`"path`":`"$($normalizedKeep)`",`"mode`":`"100644`",`"type`":`"blob`",`"sha`":`"$($blobSha)`"}]}"
        $treeResp = Invoke-ApiEndpoint -useRequestHeader "GitHub" -baseUrl $ghBase -endPoint "/repos/$($org)/$($repo)/git/trees" -method "POST" -body $treeBody
        if ($treeResp.responseObject.StatusCode -ne 201) { throw (APIReturnedError -apiCallResponse $treeResp -intendedAction "creating tree on GitHub") }
        $treeSha = ($treeResp.responseObject.Content | ConvertFrom-Json).sha

        $commitBody = "{`"message`":`"Initialize empty branch`",`"tree`":`"$($treeSha)`",`"parents`":[]}"
        $commitResp = Invoke-ApiEndpoint -useRequestHeader "GitHub" -baseUrl $ghBase -endPoint "/repos/$($org)/$($repo)/git/commits" -method "POST" -body $commitBody
        if ($commitResp.responseObject.StatusCode -ne 201) { throw (APIReturnedError -apiCallResponse $commitResp -intendedAction "creating commit on GitHub") }
        $commitSha = ($commitResp.responseObject.Content | ConvertFrom-Json).sha

        $refBody = "{`"ref`":`"refs/heads/$($newBranchName)`",`"sha`":`"$($commitSha)`"}"
        $refResp = Invoke-ApiEndpoint -useRequestHeader "GitHub" -baseUrl $ghBase -endPoint "/repos/$($org)/$($repo)/git/refs" -method "POST" -body $refBody
        if ($refResp.responseObject.StatusCode -eq 201) {
            Write-Message "Info" "Branch $($newBranchName) created as an independent root on GitHub."
            return $newBranchName
        }
        else {
            throw (APIReturnedError -apiCallResponse $refResp -intendedAction "creating orphan branch on GitHub")
        }
    }

    $invokeHeader = if (-not [string]::IsNullOrWhiteSpace($resolvedPat)) { New-RequestHeader -authType "Basic" -accessToken $resolvedPat } else { $null }

    $jsonBody = @"
{
  "refUpdates": [ { "name": "refs/heads/$newBranchName", "oldObjectId": "0000000000000000000000000000000000000000" } ],
  "commits": [
    {
      "comment": "Initialize empty branch",
      "changes": [
        {
          "changeType": "add",
          "item": { "path": "$gitkeepPath" },
          "newContent": { "content": "", "contentType": "rawtext" }
        }
      ]
    }
  ]
}
"@

    $endPoint = "/$($org)/$($project)/_apis/git/repositories/$($repo)/pushes?api-version=7.1"
    $response = if ($null -ne $invokeHeader) {
        Invoke-ApiEndpoint -CustomHeader $invokeHeader -baseUrl $azdoBase -endPoint $endPoint -method "POST" -body $jsonBody
    } else {
        Invoke-ApiEndpoint -useRequestHeader "DevOps" -baseUrl $azdoBase -endPoint $endPoint -method "POST" -body $jsonBody
    }
    if ($response.responseObject.StatusCode -eq 201) {
        Write-Message "Info" "Branch $($newBranchName) created as an independent root."
        return $newBranchName
    }
    else {
        throw (APIReturnedError -apiCallResponse $response -intendedAction "creating orphan branch")
    }
}

# Define a helper function to download a file using REST API
function Get-RemoteFile {
    param (
        [string]    $FilePath,
        [string]    $DownloadUrl,
        [string]    $localFolder,
        [parameter(Mandatory = $false)] [hashtable] $Headers = $null
    )
    $resolvedHeaders = if ($null -ne $Headers) { $Headers } else { $script:devOpsRequestHeader }
    $targetPath = Join-Path -Path $localFolder -ChildPath $FilePath
    $directory = Split-Path -Path $targetPath
    if (!(Test-Path -Path $directory)) {
        New-Item -ItemType Directory -Path $directory | Out-Null
    }
    Invoke-WebRequest -Uri $DownloadUrl -Headers $resolvedHeaders -OutFile $targetPath -UseBasicParsing
    return $targetPath
}

function Test-DevOpsRepoPath {
    param (
        [parameter(Mandatory = $true)]  [String]         $gitPath,
        [parameter(Mandatory = $false)] [String]         $branchName = $null,
        [parameter(Mandatory = $false)] [PSCustomObject] $AzdoConfig = $null,
        [parameter(Mandatory = $false)]
        [ValidateSet("AzureDevOps","GitHub")]
        [String] $gitProviderType = "AzureDevOps",
        [parameter(Mandatory = $false)] [String]         $Pat = $null
    )

    if (Test-Path $gitPath) { return $true }

    $azdoBase     = if ($null -ne $AzdoConfig) { $AzdoConfig.AzdoBaseUrl }      else { $script:azdoBaseUrl }
    $org          = if ($null -ne $AzdoConfig) { $AzdoConfig.OrganizationName } else { $script:organizationName }
    $project      = if ($null -ne $AzdoConfig) { $AzdoConfig.ProjectName }      else { $script:projectName }
    $repo         = if ($null -ne $AzdoConfig) { $AzdoConfig.RepositoryName }   else { $script:repositoryName }
    $resolvedBranch = if (-not [string]::IsNullOrWhiteSpace($branchName)) { $branchName }
                      elseif ($null -ne $AzdoConfig)                       { $AzdoConfig.SourceBranchName }
                      else                                                  { $script:sourceBranchName }

    $resolvedPat      = if (-not [string]::IsNullOrWhiteSpace($Pat))                                                         { $Pat }
                        elseif ($null -ne $AzdoConfig -and -not [string]::IsNullOrWhiteSpace($AzdoConfig.Pat))              { $AzdoConfig.Pat }
                        else                                                                                                   { $null }
    $resolvedProvider = if ($null -ne $AzdoConfig -and -not [string]::IsNullOrWhiteSpace($AzdoConfig.GitProviderType))      { $AzdoConfig.GitProviderType }
                        else                                                                                                   { $gitProviderType }
    if ($PSBoundParameters.ContainsKey('gitProviderType')) { $resolvedProvider = $gitProviderType }

    $refSourceBranchName = $resolvedBranch
    if ($resolvedBranch -match "^refs/heads/") {
        $refSourceBranchName = $resolvedBranch -replace "^refs/heads/", ""
    }

    if ($resolvedProvider -eq "GitHub") {
        if ([string]::IsNullOrWhiteSpace($resolvedPat)) { throw "A PAT is required when gitProviderType is 'GitHub'." }
        $script:gitHubRequestHeader = New-RequestHeader -authType "Bearer" -accessToken $resolvedPat
        $script:gitHubRequestHeader['Accept'] = 'application/vnd.github+json'
        $script:gitHubRequestHeader['X-GitHub-Api-Version'] = '2022-11-28'
        $normalizedPath = $gitPath.TrimStart("/")
        $endPoint = "/repos/$($org)/$($repo)/contents/$($normalizedPath)?ref=$($refSourceBranchName)"
        $response = Invoke-ApiEndpoint -useRequestHeader "GitHub" -baseUrl "https://api.github.com" -endPoint $endPoint
    }
    elseif (-not [string]::IsNullOrWhiteSpace($resolvedPat)) {
        $patHeader = New-RequestHeader -authType "Basic" -accessToken $resolvedPat
        $endPoint = "/$($org)/$($project)/_apis/git/repositories/$($repo)/items?scopePath=$($gitPath)&versionDescriptor.versionType=branch&versionDescriptor.version=$($refSourceBranchName)&api-version=7.1-preview.1"
        $response = Invoke-ApiEndpoint -CustomHeader $patHeader -baseUrl $azdoBase -endPoint $endPoint
    }
    else {
        $endPoint = "/$($org)/$($project)/_apis/git/repositories/$($repo)/items?scopePath=$($gitPath)&versionDescriptor.versionType=branch&versionDescriptor.version=$($refSourceBranchName)&api-version=7.1-preview.1"
        $response = Invoke-ApiEndpoint -useRequestHeader "DevOps" -baseUrl $azdoBase -endPoint $endPoint
    }

    if ($response.responseObject.StatusCode -eq 200) {
        return $true
    }
    elseif ($response.responseObject.StatusCode -eq 404) {
        return $false
    }
    else {
        throw (APIReturnedError -apiCallResponse $response -intendedAction "checking if path '$gitPath' exists in the repository")
    }
}

function Copy-DevOpsRepoBranchRestAPI {
    param (
        [parameter(Mandatory = $true)]  [String]         $gitPath,
        [parameter(Mandatory = $true)]  [String]         $localFolder,
        [parameter(Mandatory = $false)] [Bool]           $cleanFirst = $true,
        [parameter(Mandatory = $false)] [PSCustomObject] $AzdoConfig = $null,
        [parameter(Mandatory = $false)]
        [ValidateSet("AzureDevOps","GitHub")]
        [String] $gitProviderType = "AzureDevOps",
        [parameter(Mandatory = $false)] [String]         $Pat = $null
    )

    $azdoBase     = if ($null -ne $AzdoConfig) { $AzdoConfig.AzdoBaseUrl }         else { $script:azdoBaseUrl }
    $org          = if ($null -ne $AzdoConfig) { $AzdoConfig.OrganizationName }    else { $script:organizationName }
    $project      = if ($null -ne $AzdoConfig) { $AzdoConfig.ProjectName }         else { $script:projectName }
    $repo         = if ($null -ne $AzdoConfig) { $AzdoConfig.RepositoryName }      else { $script:repositoryName }
    $sourceBranch = if ($null -ne $AzdoConfig) { $AzdoConfig.SourceBranchName }    else { $script:sourceBranchName }
    $sameTenatHeaders = if ($null -ne $AzdoConfig) { $AzdoConfig.DevOpsRequestHeader } else { $null }

    $resolvedPat      = if (-not [string]::IsNullOrWhiteSpace($Pat))                                                         { $Pat }
                        elseif ($null -ne $AzdoConfig -and -not [string]::IsNullOrWhiteSpace($AzdoConfig.Pat))              { $AzdoConfig.Pat }
                        else                                                                                                   { $null }
    $resolvedProvider = if ($null -ne $AzdoConfig -and -not [string]::IsNullOrWhiteSpace($AzdoConfig.GitProviderType))      { $AzdoConfig.GitProviderType }
                        else                                                                                                   { $gitProviderType }
    if ($PSBoundParameters.ContainsKey('gitProviderType')) { $resolvedProvider = $gitProviderType }

    $refSourceBranchName = $sourceBranch
    if ($sourceBranch -match "^refs/heads/") {
        $refSourceBranchName = $sourceBranch -replace "^refs/heads/", ""
    }

    if ($resolvedProvider -eq "GitHub") {
        if ([string]::IsNullOrWhiteSpace($resolvedPat)) { throw "A PAT is required when gitProviderType is 'GitHub'." }

        $script:gitHubRequestHeader = New-RequestHeader -authType "Bearer" -accessToken $resolvedPat
        $script:gitHubRequestHeader['Accept'] = 'application/vnd.github+json'
        $script:gitHubRequestHeader['X-GitHub-Api-Version'] = '2022-11-28'
        $ghDownloadHeaders = @{
            Authorization          = "Bearer $resolvedPat"
            Accept                 = 'application/vnd.github.raw'
            'X-GitHub-Api-Version' = '2022-11-28'
        }
        $ghBase = "https://api.github.com"

        $endPoint = "/repos/$($org)/$($repo)/git/trees/$($refSourceBranchName)?recursive=1"
        $treeResponse = Invoke-ApiEndpoint -useRequestHeader "GitHub" -baseUrl $ghBase -endPoint $endPoint
        if ($treeResponse.responseObject.StatusCode -eq 200) {
            if ((Test-Path $localFolder) -and $cleanFirst) { Remove-Item -Recurse -Force -Path $localFolder }
            New-Item -ItemType Directory -Path $localFolder | Out-Null
            $treeItems = ($treeResponse.responseObject.Content | ConvertFrom-Json).tree
            $normalizedPath = $gitPath.TrimStart("/").TrimEnd("/")
            $pathPrefix = if ([string]::IsNullOrWhiteSpace($normalizedPath)) { "" } else { "$normalizedPath/" }
            $filteredItems = $treeItems | Where-Object {
                $_.type -eq "blob" -and ([string]::IsNullOrWhiteSpace($pathPrefix) -or $_.path.StartsWith($pathPrefix))
            }
            foreach ($item in $filteredItems) {
                $downloadUrl = "$($ghBase)/repos/$($org)/$($repo)/contents/$($item.path)?ref=$($refSourceBranchName)"
                Write-Message "Develop" "Downloading $($downloadUrl)"
                Get-RemoteFile -FilePath $item.path -DownloadUrl $downloadUrl -localFolder $localFolder -Headers $ghDownloadHeaders
            }
            return $true
        }
        else {
            throw (APIReturnedError -apiCallResponse $treeResponse -intendedAction "fetching items in the GitHub branch")
        }
    }
    else {
        $invokeHeader  = if (-not [string]::IsNullOrWhiteSpace($resolvedPat)) { New-RequestHeader -authType "Basic" -accessToken $resolvedPat } else { $null }
        $downloadHeaders = if ($null -ne $invokeHeader) { $invokeHeader } else { $sameTenatHeaders }

        $endPoint = "/$($org)/$($project)/_apis/git/repositories/$($repo)/items?scopePath=$($gitPath)&recursionLevel=Full&versionDescriptor.versionType=branch&versionDescriptor.version=$($refSourceBranchName)&api-version=7.1-preview.1"
        $listResponse = if ($null -ne $invokeHeader) {
            Invoke-ApiEndpoint -CustomHeader $invokeHeader -baseUrl $azdoBase -endPoint $endPoint
        } else {
            Invoke-ApiEndpoint -useRequestHeader "DevOps" -baseUrl $azdoBase -endPoint $endPoint
        }

        if ($listResponse.responseObject.StatusCode -eq 200) {
            if ((Test-Path $localFolder) -and $cleanFirst) { Remove-Item -Recurse -Force -Path $localFolder }
            New-Item -ItemType Directory -Path $localFolder | Out-Null
            $branchItems = ($listResponse.responseObject.Content | ConvertFrom-Json).value
            foreach ($item in $branchItems) {
                if ($item.isFolder -ne $true) {
                    $downloadUrl = "$($azdoBase)/$($org)/$($project)/_apis/git/repositories/$($repo)/items?path=$($item.path)&versionDescriptor.versionType=branch&versionDescriptor.version=$($refSourceBranchName)&resolveLfs=true&api-version=7.1-preview.1"
                    Write-Message "Develop" "Downloading $($downloadUrl)"
                    Get-RemoteFile -FilePath $item.path.TrimStart("/") -DownloadUrl $downloadUrl -localFolder $localFolder -Headers $downloadHeaders
                }
            }
            return $true
        }
        else {
            throw (APIReturnedError -apiCallResponse $listResponse -intendedAction "fetching items in the branch")
        }
    }
}
