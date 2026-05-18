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

    $endPoint = "/$($org)/$($project)/_apis/git/repositories/$($repo)/refs?filter=heads/$($sourceBranch)&api-version=7.0"
    $gitRepositoriesResponse = Invoke-ApiEndpoint -useRequestHeader "DevOps" -baseUrl $azdoBase -endPoint $endPoint
    if ($gitRepositoriesResponse.responseObject.StatusCode -eq 200) {
        $refSourceBranchName = "refs/heads/$($sourceBranch)"
        $gitRepository = ($gitRepositoriesResponse.responseObject.Content | ConvertFrom-Json).value | Where-Object {$_.name -eq $refSourceBranchName}
        if ($null -ne $gitRepository) {
            $jsonBody = newBranchJsonBody -newBranchName $newBranchName -newObjectId $gitRepository.objectid
            $endPoint = "/$($org)/$($project)/_apis/git/repositories/$($repo)/refs?api-version=6.0"
            $newGitBranchReponse = Invoke-ApiEndpoint -useRequestHeader "DevOps" -baseUrl $azdoBase -endPoint $endPoint -method "POST" -body $jsonBody
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
    $response = Invoke-ApiEndpoint -useRequestHeader "DevOps" -baseUrl $azdoBase -endPoint $endPoint -method "POST" -body $jsonBody
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
