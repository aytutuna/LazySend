<#
Stops a local package build unless HEAD is a clean checkout of a commit on main whose ci.yml run passed.

  pwsh scripts/require_green_main.ps1 [-Repo owner/name]

Needs git and the gh CLI signed in.
#>
param([string] $Repo = 'aytutuna/LazySend')

$ErrorActionPreference = 'Stop'

if (git status --porcelain) { throw "Refusing to build: the working tree has changes, so the package would not be the commit." }
$sha = (git rev-parse HEAD).Trim()
$state = (gh api "repos/$Repo/compare/main...$sha" --jq .status).Trim()
if ($state -ne 'identical' -and $state -ne 'behind') { throw "Refusing to build: $($sha.Substring(0, 7)) is not on main ($state)." }
$run = (gh run list -R $Repo --workflow ci.yml --commit $sha --limit 1 --json status,conclusion --jq '.[0] | "\(.status) \(.conclusion)"')
if (-not $run -or $run -eq 'null null') { throw "Refusing to build: ci.yml has not run for $($sha.Substring(0, 7))." }
if ($run.Trim() -ne 'completed success') { throw "Refusing to build: the ci.yml run for $($sha.Substring(0, 7)) is not green ($run)." }
Write-Host "$($sha.Substring(0, 7)) is on main and its ci.yml run is green."
