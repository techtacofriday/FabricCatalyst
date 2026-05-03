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

function New-GitBranch  {
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
        [parameter(Mandatory = $false)] [PSCustomObject] $AzdoConfig = $null
    )

    if (Test-Path $gitPath) { return $true }

    $azdoBase     = if ($null -ne $AzdoConfig) { $AzdoConfig.AzdoBaseUrl }      else { $script:azdoBaseUrl }
    $org          = if ($null -ne $AzdoConfig) { $AzdoConfig.OrganizationName } else { $script:organizationName }
    $project      = if ($null -ne $AzdoConfig) { $AzdoConfig.ProjectName }      else { $script:projectName }
    $repo         = if ($null -ne $AzdoConfig) { $AzdoConfig.RepositoryName }   else { $script:repositoryName }
    $resolvedBranch = if (-not [string]::IsNullOrWhiteSpace($branchName)) { $branchName }
                      elseif ($null -ne $AzdoConfig)                       { $AzdoConfig.SourceBranchName }
                      else                                                  { $script:sourceBranchName }

    $refSourceBranchName = $resolvedBranch
    if ($resolvedBranch -match "^refs/heads/") {
        $refSourceBranchName = $resolvedBranch -replace "^refs/heads/", ""
    }

    $endPoint = "/$($org)/$($project)/_apis/git/repositories/$($repo)/items?scopePath=$($gitPath)&versionDescriptor.versionType=branch&versionDescriptor.version=$($refSourceBranchName)&api-version=7.1-preview.1"
    $response = Invoke-ApiEndpoint -useRequestHeader "DevOps" -baseUrl $azdoBase -endPoint $endPoint
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
        [parameter(Mandatory = $false)] [PSCustomObject] $AzdoConfig = $null
    )

    $azdoBase     = if ($null -ne $AzdoConfig) { $AzdoConfig.AzdoBaseUrl }         else { $script:azdoBaseUrl }
    $org          = if ($null -ne $AzdoConfig) { $AzdoConfig.OrganizationName }    else { $script:organizationName }
    $project      = if ($null -ne $AzdoConfig) { $AzdoConfig.ProjectName }         else { $script:projectName }
    $repo         = if ($null -ne $AzdoConfig) { $AzdoConfig.RepositoryName }      else { $script:repositoryName }
    $sourceBranch = if ($null -ne $AzdoConfig) { $AzdoConfig.SourceBranchName }    else { $script:sourceBranchName }
    $headers      = if ($null -ne $AzdoConfig) { $AzdoConfig.DevOpsRequestHeader } else { $null }

    $refSourceBranchName = $sourceBranch
    if ($sourceBranch -match "^refs/heads/") {
        $refSourceBranchName = $sourceBranch -replace "^refs/heads/", ""
    }

    $endPoint = "/$($org)/$($project)/_apis/git/repositories/$($repo)/items?scopePath=$($gitPath)&recursionLevel=Full&versionDescriptor.versionType=branch&versionDescriptor.version=$($refSourceBranchName)&api-version=7.1-preview.1"
    $gitRepositoriesResponse = Invoke-ApiEndpoint -useRequestHeader "DevOps" -baseUrl $azdoBase -endPoint $endPoint
    if ($gitRepositoriesResponse.responseObject.StatusCode -eq 200) {
        if ((Test-Path $localFolder) -and $cleanFirst) {
            Remove-Item -Recurse -Force -Path $localFolder
        }
        New-Item -ItemType Directory -Path $localFolder | Out-Null
        $branchItems = ($gitRepositoriesResponse.responseObject.Content | ConvertFrom-Json).value
        foreach ($item in $branchItems) {
            if ($item.isFolder -ne $true) {
                $downloadUrl = "$($azdoBase)/$($org)/$($project)/_apis/git/repositories/$($repo)/items?path=$($item.path)&versionDescriptor.versionType=branch&versionDescriptor.version=$($refSourceBranchName)&resolveLfs=true&api-version=7.1-preview.1"
                Write-Message "Develop" "Downloading $($downloadUrl)"
                Get-RemoteFile -FilePath $item.path.TrimStart("/") -DownloadUrl $downloadUrl -localFolder $localFolder -Headers $headers
            }
        }
        return $true
    }
    else {
        throw (APIReturnedError -apiCallResponse $gitRepositoriesResponse -intendedAction "fetching items in the branch")
    }
}
