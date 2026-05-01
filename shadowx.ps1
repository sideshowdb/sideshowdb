#requires -Version 5.1
<#
.SYNOPSIS
  Acquire (if missing) and run the sideshow CLI, Gradle-style wrapper for Windows hosts.

.NOTES
  User-facing summaries print to stderr; stdout is reserved for tool output (piping-safe).
  --help/--wrapper-version use stdout by design.

  Environment knobs:
    SIDESHOWDB_HOME               Cache root (~/.sideshowdb/wrapper).
    SIDESHOWDB_CLI_VERSION        Default pinned version (semver, v-prefix, or "latest").
    SIDESHOWDB_DISABLE_TLS12      Set to non-empty to skip forcing TLS 1.2 early (not recommended).

  Project pin files beside this script:
    .sideshowdb-version, sideshowdb.version (first non-empty line)
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:WrapperScriptVersion = '1.0.0'
$script:GithubRepo = 'sideshowdb/sideshowdb'

function Write-Diagnostics {
	param(
		[Parameter(Mandatory)][AllowEmptyString()][string] $Message
	)

	[System.Console]::Error.WriteLine($Message)
}

function Write-VerboseDiagnostics {
	param([Parameter(Mandatory)][string] $Message)

	if (-not ($script:SideshowVerbose -or $script:SideshowTrace)) {
		return
	}

	Write-Diagnostics $Message
}

function Write-Stdout {
	param([Parameter(Mandatory)][string] $Message)

	Write-Output $Message
}

function Exit-Usage {
	Write-Stdout "$($script:ProgName) $($script:WrapperScriptVersion) — acquire and run the sideshow CLI (${script:GithubRepo})"
	Write-Stdout ''
	Write-Stdout "Usage: $($script:ProgName) [wrapper options] [--] [sideshow arguments…]"
	Write-Stdout ''
	Write-Stdout 'Wrapper options (wrapper diagnostics → stderr unless noted):'
	Write-Stdout '  -?, -h, /h, --help           Show wrapper help on stdout'
	Write-Stdout '  --wrapper-version            Wrapper script semver on stdout'
	Write-Stdout '  -V, --cli-version VER       Pin CLI semver (v-prefix OK) or "latest"'
	Write-Stdout '  -f, --force                 Force re-download of the pinned release asset'
	Write-Stdout '      --install-only          Download/extract only; skip launching the CLI'
	Write-Stdout '      --print-path            Print resolved exe path on stdout'
	Write-Stdout '  -v, --verbose               Extra wrapper logging on stderr'
	Write-Stdout '  -q, --quiet                 Quieter stderr output'
	Write-Stdout '      --trace                 Verbose interpreter tracing via Set-PSDebug'
	Write-Stdout ''
	Write-Stdout 'Environment:'
	Write-Stdout '  SIDESHOWDB_HOME               Cache root (defaults to ~/.sideshowdb/wrapper)'
	Write-Stdout '  SIDESHOWDB_CLI_VERSION        Mirrors -V/--cli-version when unspecified'
	Write-Stdout ''
	Write-Stdout 'Resolution order:'
	Write-Stdout '    explicit flags, SIDESHOWDB_CLI_VERSION,' `
		' project pin files beside the script (.sideshowdb-version / sideshowdb.version),' `
		' otherwise latest.'
	exit 0
}

function Normalize-CliVersionTag {
	param([Parameter(Mandatory)][string] $Raw)

	$v = $Raw.Trim()
	if ($v.StartsWith('v', [System.StringComparison]::OrdinalIgnoreCase)) {
		$v = $v.Substring(1)
	}

	return $v
}

function Format-GitTag {
	param([Parameter(Mandatory)][string] $Version)

	if ($Version.StartsWith('v', [System.StringComparison]::OrdinalIgnoreCase)) {
		return $Version
	}

	return "v$Version"
}

function Get-DefaultWrapperHome {
	$homeRoot = $env:USERPROFILE
	if ([string]::IsNullOrWhiteSpace($homeRoot)) {
		return (Join-Path $env:TEMP 'sideshowdb-wrapper')
	}

	return (Join-Path $homeRoot '.sideshowdb/wrapper')
}

function Get-ArchiveArchitecture {
	$arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
	switch ($arch) {
		([System.Runtime.InteropServices.Architecture]::X64) { return 'amd64' }
		([System.Runtime.InteropServices.Architecture]::Arm64) { return 'arm64' }
		default {
			throw "unsupported Windows architecture: $arch"
		}
	}
}

function Assert-WindowsHost {
	if ([string]::IsNullOrWhiteSpace($env:WINDIR)) {
		throw 'shadowx.ps1 targets Windows hosts with %WINDIR% present; use ./shadowx on macOS or Linux.'
	}
}

function Initialize-Tls {
	if ([string]::IsNullOrWhiteSpace($env:SIDESHOWDB_DISABLE_TLS12)) {
		[Net.ServicePointManager]::SecurityProtocol = (
			[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
		)
	}
}

function Invoke-GitHubDownload {
	param(
		[Parameter(Mandatory)][string] $Uri,
		[Parameter(Mandatory)][string] $Destination
	)

	$part = "$Destination.part"
	if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
		& curl.exe -fsSL $Uri -o $part
	}
	else {
		Invoke-WebRequest -Uri $Uri -OutFile $part -UseBasicParsing
	}

	Move-Item -Force -Path $part -DestinationPath $Destination
}

function Resolve-LatestCliVersion {
	Initialize-Tls

	$url = "https://api.github.com/repos/$script:GithubRepo/releases/latest"
	Write-Diagnostics "Resolving latest $script:GithubRepo release via GitHub API…"

	$response = Invoke-RestMethod -Uri $url -Headers @{
		'Accept' = 'application/vnd.github+json'
		'User-Agent' = 'sideshow-launcher-windows'
	}

	if (-not $response.tag_name) {
		throw 'GitHub API response missing tag_name.'
	}

	return (Normalize-CliVersionTag ([string]$response.tag_name))
}

function Read-PinnedVersionFromProject {
	param([Parameter(Mandatory)][string] $ScriptRoot)

	foreach ($file in '.sideshowdb-version', 'sideshowdb.version') {
		$path = Join-Path $ScriptRoot $file
		if (-not (Test-Path -LiteralPath $path)) {
			continue
		}

		$lines = @(Get-Content -LiteralPath $path -ReadCount 0 | ForEach-Object { $_.Trim() } |
			Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

		if ($lines.Count -ge 1) {
			return $lines[0]
		}
	}

	return $null
}

function Get-Sha256FromSumsFile {
	param(
		[Parameter(Mandatory)][string] $SumsPath,
		[Parameter(Mandatory)][string] $ArtifactName
	)

	$lines = Get-Content -LiteralPath $SumsPath
	foreach ($line in $lines) {
		if ([string]::IsNullOrWhiteSpace($line)) {
			continue
		}

		$parts = $line -split '\s+', 2
		if ($parts.Count -ne 2) {
			continue
		}

		if ($parts[1] -eq $ArtifactName) {
			return $parts[0]
		}
	}

	throw "no SHA256 entry for $ArtifactName in checksum file"
}

function Test-ArtifactSha256 {
	param(
		[Parameter(Mandatory)][string] $SumsPath,
		[Parameter(Mandatory)][string] $WorkDir,
		[Parameter(Mandatory)][string] $ArtifactName
	)

	$expected = Get-Sha256FromSumsFile -SumsPath $SumsPath -ArtifactName $ArtifactName
	$target = Join-Path $WorkDir $ArtifactName

	$actual = Get-FileHash -LiteralPath $target -Algorithm SHA256
	if ($actual.Hash.ToLowerInvariant() -ne $expected.ToLowerInvariant()) {
		throw "SHA256 mismatch for $ArtifactName (expected $expected, got $($actual.Hash))"
	}
}

function Expand-StagedCliArchive {
	param(
		[Parameter(Mandatory)][string] $Archive,
		[Parameter(Mandatory)][string] $StagingRoot
	)

	$expanded = Join-Path $StagingRoot 'extract'
	New-Item -ItemType Directory -Force -Path $expanded | Out-Null

	if ($Archive.EndsWith('.tar.gz', [System.StringComparison]::OrdinalIgnoreCase)) {
		& tar.exe -xzf $Archive -C $expanded
	}
	elseif ($Archive.EndsWith('.zip', [System.StringComparison]::OrdinalIgnoreCase)) {
		Expand-Archive -LiteralPath $Archive -DestinationPath $expanded -Force
	}
	else {
		throw "unknown archive type: $Archive"
	}

	return $expanded
}

function Move-ResolvedExe {
	param(
		[Parameter(Mandatory)][string] $SearchRoot,
		[Parameter(Mandatory)][string] $Destination
	)

	$hits = @(Get-ChildItem -LiteralPath $SearchRoot -Recurse -File -Filter 'sideshow.exe' -ErrorAction SilentlyContinue)
	if ($hits.Count -lt 1) {
		throw "could not locate sideshow.exe under $SearchRoot"
	}

	[System.IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Destination)) | Out-Null

	$file = $hits[0].FullName
	if ($file -ne $Destination) {
		Move-Item -Force -Path $file -Destination $Destination
	}
}

function Get-CliLayout {
	param([Parameter(Mandatory)][string] $FileVersion)

	$base = Join-Path $env:SIDESHOWDB_HOME ('cli\{0}' -f $FileVersion)

	return [ordered]@{
		Root        = $base
		BinaryPath  = Join-Path $base 'dist\sideshow.exe'
		HashesPath  = Join-Path $base 'SHA256SUMS'
		ReadyMarker = Join-Path $base '.ready'
	}
}

function Ensure-SideshowCliInstallation {
	param(
		[Parameter(Mandatory)][string] $ScriptRoot,
		[Parameter(Mandatory)][bool] $Force
	)

	Initialize-Tls

	$chosen = ''
	if (-not [string]::IsNullOrWhiteSpace($script:SideshowCliPin)) {
		$chosen = $script:SideshowCliPin.Trim()
	}
	elseif (-not [string]::IsNullOrWhiteSpace($env:SIDESHOWDB_CLI_VERSION)) {
		$chosen = $env:SIDESHOWDB_CLI_VERSION.Trim()
		Write-VerboseDiagnostics "using SIDESHOWDB_CLI_VERSION=$chosen"
	}
	else {
		$fromFile = Read-PinnedVersionFromProject -ScriptRoot $ScriptRoot
		if (-not [string]::IsNullOrWhiteSpace($fromFile)) {
			$chosen = $fromFile.Trim()
			Write-VerboseDiagnostics "using project pin file=$chosen"
		}
	}

	if ([string]::IsNullOrWhiteSpace($chosen) -or ($chosen -ieq 'latest')) {
		$fileVersion = Resolve-LatestCliVersion
	}
	else {
		$fileVersion = (Normalize-CliVersionTag $chosen)
	}

	$archiveArch = Get-ArchiveArchitecture
	$artifactName = "sideshow-$fileVersion-windows-$archiveArch.zip"
	$tag = (Format-GitTag $fileVersion)

	$layout = Get-CliLayout -FileVersion $fileVersion
	$exePath = [string]$layout.BinaryPath

	if ($Force -and (Test-Path -LiteralPath $layout.Root)) {
		Remove-Item -LiteralPath $layout.Root -Recurse -Force
		Write-Diagnostics "Cache cleared for $fileVersion (-Force)."
	}

	if ((Test-Path -LiteralPath $layout.ReadyMarker) -and (Test-Path -LiteralPath $exePath)) {
		Write-VerboseDiagnostics "using cached CLI: $exePath"
		return [pscustomobject]@{
			ExePath             = $exePath
			ArtifactName        = $artifactName
			TagName             = $tag
			ArchiveArchitecture = $archiveArch
		}
	}

	if (Test-Path -LiteralPath $layout.ReadyMarker) {
		Remove-Item -LiteralPath $layout.ReadyMarker -Force -ErrorAction SilentlyContinue
	}

	New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($exePath)) | Out-Null

	$staging = Join-Path ([IO.Path]::GetTempPath()) ("sideshow_launcher_" + [IO.Path]::GetRandomFileName())
	New-Item -ItemType Directory -Force -Path $staging | Out-Null

	try {
		$sumsPath = Join-Path $staging 'SHA256SUMS'
		$archivePath = Join-Path $staging $artifactName
		$downloadBase = "https://github.com/$script:GithubRepo/releases/download/$tag"

		Write-Diagnostics "Downloading $artifactName …"
		Invoke-GitHubDownload -Uri ("$downloadBase/$artifactName") -Destination $archivePath

		Write-Diagnostics 'Downloading SHA256SUMS …'
		Invoke-GitHubDownload -Uri ("$downloadBase/SHA256SUMS") -Destination $sumsPath

		Test-ArtifactSha256 -SumsPath $sumsPath -WorkDir $staging -ArtifactName $artifactName

		$newRoot = Expand-StagedCliArchive -Archive $archivePath -StagingRoot $staging

		try {
			Move-ResolvedExe -SearchRoot $newRoot -Destination $exePath
		}
		finally {
			if (Test-Path -LiteralPath $newRoot) {
				Remove-Item -LiteralPath $newRoot -Recurse -Force -ErrorAction SilentlyContinue
			}
		}

		Copy-Item -Force -LiteralPath $sumsPath -Destination $layout.HashesPath

		[System.IO.File]::WriteAllText(
			([string]$layout.ReadyMarker),
			(Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'),
			(New-Object System.Text.UTF8Encoding $false))

		Write-Diagnostics "Installed sideshow $tag (windows-$archiveArch) at $exePath"
	}
	finally {
		if (Test-Path -LiteralPath $staging) {
			Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
		}
	}

	return [pscustomobject]@{
		ExePath             = $exePath
		ArtifactName        = $artifactName
		TagName             = $tag
		ArchiveArchitecture = $archiveArch
	}
}

function Resolve-WrapperArguments {
	param(
		[Parameter(Mandatory)][AllowEmptyCollection()][string[]] $ScriptArgs
	)

	$extras = New-Object System.Collections.Generic.List[string]

	$i = 0
	while ($i -lt $ScriptArgs.Count) {
		$tok = [string]$ScriptArgs[$i]

		if ($tok -eq '--') {
			$i++
			while ($i -lt $ScriptArgs.Count) {
				$extras.Add($ScriptArgs[$i])
				$i++
			}

			break
		}

		$lower = $tok.ToLowerInvariant()
		if ($lower -eq '-h' -or $lower -eq '-?' -or $lower -eq '/h' -or $lower -eq '/?' -or $lower -eq '--help') {
			Exit-Usage
		}

		if ($lower -eq '--wrapper-version') {
			Write-Stdout $script:WrapperScriptVersion
			exit 0
		}

		if ($tok -eq '-V' -or $lower -eq '--cli-version' -or $lower -eq '-cliversion') {
			$i++
			if ($i -ge $ScriptArgs.Count) {
				throw 'The -V/--cli-version switch requires a value (examples: 0.1.0, v0.1.0, or latest).'
			}

			$script:SideshowCliPin = [string]$ScriptArgs[$i]
			$i++
			continue
		}

		if ($lower -eq '-f' -or $lower -eq '--force') {
			$script:SideshowForce = $true
			$i++
			continue
		}

		if ($lower -eq '--install-only' -or $lower -eq '-installonly') {
			$script:SideshowInstallOnly = $true
			$i++
			continue
		}

		if ($lower -eq '--print-path' -or $lower -eq '-printpath') {
			$script:SideshowPrintPath = $true
			$i++
			continue
		}

		if ($lower -eq '-v' -or $lower -eq '--verbose') {
			$script:SideshowVerbose = $true
			$i++
			continue
		}

		if ($lower -eq '-q' -or $lower -eq '--quiet') {
			$script:SideshowQuiet = $true
			$i++
			continue
		}

		if ($lower -eq '--trace' -or $lower -eq '-trace') {
			$script:SideshowTrace = $true
			$i++
			continue
		}

		$extras.Add($tok)
		$i++
	}

	if ($script:SideshowQuiet -and $script:SideshowVerbose) {
		throw 'Quiet and Verbose cannot be combined.'
	}

	if ($script:SideshowQuiet -and $script:SideshowTrace) {
		throw 'Quiet and Trace cannot be combined.'
	}

	return $extras.ToArray()
}

$script:ProgName = [IO.Path]::GetFileName($MyInvocation.MyCommand.Name)
$script:SideshowVerbose = $false
$script:SideshowTrace = $false
$script:SideshowQuiet = $false
$script:SideshowForce = $false
$script:SideshowInstallOnly = $false
$script:SideshowPrintPath = $false
$script:SideshowCliPin = ''

if ([string]::IsNullOrWhiteSpace($env:SIDESHOWDB_HOME)) {
	$env:SIDESHOWDB_HOME = Get-DefaultWrapperHome
}

Assert-WindowsHost

$forwardArgs = Resolve-WrapperArguments -ScriptArgs $args

if ($script:SideshowTrace) {
	Set-PSDebug -Trace 1
}

try {
	$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
	$install = Ensure-SideshowCliInstallation -ScriptRoot $scriptRoot -Force $script:SideshowForce

	if ($script:SideshowPrintPath) {
		Write-Stdout $install.ExePath
		exit 0
	}

	if ($script:SideshowInstallOnly) {
		Write-Diagnostics 'Install-only mode; skipping launch.'
		exit 0
	}

	if ($forwardArgs.Count -gt 0) {
		if ($install.ExePath -match '\s') {
			throw 'spaces in installation path unsupported for argument forwarding.'
		}

		& $install.ExePath @forwardArgs
		exit $LASTEXITCODE
	}

	if ($install.ExePath -match '\s') {
		throw 'spaces in installation path unsupported.'
	}

	& $install.ExePath

	exit $LASTEXITCODE
}
catch {
	Write-Diagnostics ($_.Exception.Message)
	exit 1
}
finally {
	if ($script:SideshowTrace) {
		Set-PSDebug -Trace 0
	}
}
