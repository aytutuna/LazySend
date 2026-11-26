<#
Stops a local package build unless the checkout is clean at a commit on main whose ci.yml run passed.
Returns the commit's sha.

  powershell scripts/require_green_main.ps1 [-Repo owner/name]

Needs git and the gh CLI signed in.
#>
param([string] $Repo = 'aytutuna/LazySend')

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot

if (git -C $root status --porcelain) { throw "Refusing to build: the working tree has changes, so the package would not be the commit." }
$sha = (git -C $root rev-parse HEAD).Trim()
$short = $sha.Substring(0, 7)
$state = (gh api "repos/$Repo/compare/main...$sha" --jq .status).Trim()
if ($state -ne 'identical' -and $state -ne 'behind') { throw "Refusing to build: $short is not on main ($state)." }
# Windows PowerShell 5.1 drops the quotes inside a --jq filter, so the JSON is read here instead.
$runs = @(gh run list -R $Repo --workflow ci.yml --commit $sha --limit 1 --json status,conclusion | ConvertFrom-Json)
if (-not $runs) { throw "Refusing to build: ci.yml has not run for $short." }
if ($runs[0].status -ne 'completed' -or $runs[0].conclusion -ne 'success') {
    throw "Refusing to build: the ci.yml run for $short is not green ($($runs[0].status) $($runs[0].conclusion))."
}
Write-Host "$short is on main and its ci.yml run is green."
$sha
