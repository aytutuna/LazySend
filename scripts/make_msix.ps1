<#
Packs the self-contained publish folders of Lazy Send as Store packages with the Windows SDK's tools and
writes LazySend_<version>.msixupload to -Out. With both folders the upload holds a bundle of the two
packages, with one just that package.

  pwsh scripts/make_msix.ps1 -X64 <folder> [-Arm64 <folder>] -Out <folder>
       [-IdentityName <name> -Publisher <CN=...> -PublisherDisplayName <text>]

The identity values come from Partner Center. Without them the manifest keeps its PartnerCenter...
names, which is enough to check that the package builds but not to submit it.
#>
param(
    [string] $X64,
    [string] $Arm64,
    [Parameter(Mandatory)] [string] $Out,
    [string] $IdentityName,
    [string] $Publisher,
    [string] $PublisherDisplayName
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$store = Join-Path $root 'store\windows'
$props = [xml](Get-Content (Join-Path $root 'windows\Directory.Build.props'))
$version = $props.Project.PropertyGroup.Version
$packageVersion = "$version.0"

function Find-SdkTool([string] $name) {
    $kits = Join-Path ([Environment]::GetFolderPath('ProgramFilesX86')) 'Windows Kits\10\bin'
    $found = Get-ChildItem (Join-Path $kits "*\x64\$name") -ErrorAction SilentlyContinue |
        Sort-Object { [version]$_.Directory.Parent.Name } -Descending | Select-Object -First 1
    if (-not $found) { throw "$name is not in the Windows SDK under $kits" }
    $found.FullName
}

$makeappx = Find-SdkTool 'makeappx.exe'
$makepri = Find-SdkTool 'makepri.exe'
$nuget = if ($env:NUGET_PACKAGES) { $env:NUGET_PACKAGES } else { Join-Path $HOME '.nuget\packages' }
$work = Join-Path ([IO.Path]::GetTempPath()) ('lazysend-msix-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work, $Out -Force | Out-Null

function Invoke-Tool([string] $tool, [string[]] $arguments) {
    & $tool @arguments | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "$(Split-Path $tool -Leaf) failed with exit code $LASTEXITCODE" }
}

function New-Package([string] $publish, [string] $arch) {
    if (-not (Test-Path (Join-Path $publish 'LazySend.exe'))) { throw "LazySend.exe is not in $publish" }
    $stage = Join-Path $work "stage-$arch"
    robocopy $publish $stage /E /XF *.pdb /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed with exit code $LASTEXITCODE" }
    Copy-Item (Join-Path $store 'Assets') (Join-Path $stage 'Assets') -Recurse

    # The runtime's own third-party notices, from the runtime pack named in the publish's deps.json.
    $deps = Get-Content (Join-Path $publish 'LazySend.deps.json') -Raw | ConvertFrom-Json
    $runtime = @($deps.libraries.PSObject.Properties.Name) | Where-Object { $_ -like "runtimepack.Microsoft.NETCore.App.Runtime.win-$arch/*" } | Select-Object -First 1
    if (-not $runtime) { throw "LazySend.deps.json in $publish names no runtime pack for win-$arch" }
    $pack = Join-Path $nuget "microsoft.netcore.app.runtime.win-$arch\$($runtime.Split('/')[1])\THIRD-PARTY-NOTICES.TXT"
    if (-not (Test-Path $pack)) { throw "$pack is missing" }
    Copy-Item $pack (Join-Path $stage 'DOTNET-THIRD-PARTY-NOTICES.txt')

    $manifest = Get-Content (Join-Path $store 'Package.appxmanifest') -Raw
    $manifest = $manifest.Replace('Version="1.0.0.0"', "Version=`"$packageVersion`"").Replace('ProcessorArchitecture="x64"', "ProcessorArchitecture=`"$arch`"")
    if ($IdentityName) { $manifest = $manifest.Replace('PartnerCenterIdentityName', $IdentityName) }
    if ($Publisher) { $manifest = $manifest.Replace('CN=PartnerCenterPublisher', $Publisher) }
    if ($PublisherDisplayName) { $manifest = $manifest.Replace('PartnerCenterPublisherDisplayName', $PublisherDisplayName) }
    [IO.File]::WriteAllText((Join-Path $stage 'AppxManifest.xml'), $manifest, (New-Object Text.UTF8Encoding $false))

    # The scale and target size variants of the logos are found through resources.pri. It is built from the
    # assets alone, so the runtime's files and its tr folder are not indexed as resources.
    $index = Join-Path $work "index-$arch"
    New-Item -ItemType Directory -Path $index | Out-Null
    Copy-Item (Join-Path $stage 'Assets') (Join-Path $index 'Assets') -Recurse
    Copy-Item (Join-Path $stage 'AppxManifest.xml') $index
    $config = Join-Path $work "priconfig-$arch.xml"
    Invoke-Tool $makepri @('createconfig', '/cf', $config, '/dq', 'en-US', '/o')
    # One package: the config would otherwise split the PRI by language and scale into resource packs.
    $xml = [xml](Get-Content $config)
    if ($xml.resources.packaging) { [void]$xml.resources.RemoveChild($xml.resources.packaging); $xml.Save($config) }
    Invoke-Tool $makepri @('new', '/pr', $index, '/cf', $config, '/mn', (Join-Path $index 'AppxManifest.xml'), '/of', (Join-Path $stage 'resources.pri'), '/o')

    $msix = Join-Path $work "LazySend_${version}_$arch.msix"
    Invoke-Tool $makeappx @('pack', '/d', $stage, '/p', $msix, '/o')
    $msix
}

$packages = @()
if ($X64) { $packages += New-Package $X64 'x64' }
if ($Arm64) { $packages += New-Package $Arm64 'arm64' }
if (-not $packages) { throw 'Give -X64, -Arm64 or both.' }

$upload = Join-Path $work 'upload'
New-Item -ItemType Directory -Path $upload | Out-Null
if ($packages.Count -eq 1) {
    Copy-Item $packages[0] $upload
} else {
    $parts = Join-Path $work 'parts'
    New-Item -ItemType Directory -Path $parts | Out-Null
    Copy-Item $packages $parts
    Invoke-Tool $makeappx @('bundle', '/d', $parts, '/bv', $packageVersion, '/p', (Join-Path $upload "LazySend_$version.msixbundle"), '/o')
}
$zip = Join-Path $work "LazySend_$version.zip"
Compress-Archive -Path (Join-Path $upload '*') -DestinationPath $zip
$target = Join-Path $Out "LazySend_$version.msixupload"
Move-Item $zip $target -Force
Copy-Item $packages $Out -Force
Remove-Item $work -Recurse -Force
Write-Host "wrote $target"
