###############################################################################
# Test Runner — FabricCatalyst extension
#
# Usage (from repo root):
#   powershell -NoProfile -File .\tasks\shared\tests\Invoke-Tests.ps1
#
# Optional parameters:
#   -Output   Pester output level: Detailed | Normal | Minimal | None  (default: Detailed)
#   -Filter   Tag or test name filter string
#
# Examples:
#   .\tasks\shared\tests\Invoke-Tests.ps1
#   .\tasks\shared\tests\Invoke-Tests.ps1 -Output Normal
#   .\tasks\shared\tests\Invoke-Tests.ps1 -Filter 'Compare-RoleAssignments'
###############################################################################
[CmdletBinding()]
param(
    [ValidateSet('Detailed', 'Normal', 'Minimal', 'None')]
    [string] $Output = 'Detailed',
    [string] $Filter = ''
)

$ErrorActionPreference = 'Stop'

# Ensure Pester 5 is loaded (not the inbox v3 that ships with Windows)
$pester = Get-Module -Name Pester -ListAvailable |
          Where-Object { $_.Version -ge [version]'5.0.0' } |
          Sort-Object Version -Descending |
          Select-Object -First 1

if ($null -eq $pester) {
    throw "Pester 5.0.0 or higher is required. Run: Install-Module Pester -MinimumVersion 5.0.0 -Force"
}

Import-Module $pester.Path -Force

$config = New-PesterConfiguration
$config.Run.Path        = "$PSScriptRoot"           # discover all *.Tests.ps1 here
$config.Output.Verbosity = $Output
$config.Run.PassThru    = $true                     # return result object

if (-not [string]::IsNullOrWhiteSpace($Filter)) {
    $config.Filter.FullName = "*$Filter*"
}

$result = Invoke-Pester -Configuration $config

# Surface a non-zero exit code so CI pipelines detect failures
if ($result.FailedCount -gt 0) {
    Write-Host "##[error]$($result.FailedCount) test(s) failed." -ForegroundColor Red
    exit 1
}

Write-Host "All $($result.PassedCount) test(s) passed." -ForegroundColor Green
exit 0
