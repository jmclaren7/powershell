<#[
.SYNOPSIS
Registers and runs .scapp package files.

.DESCRIPTION
Run without arguments to copy this script to the current user's local
application data and register that copy as the default handler for .scapp
files. When passed a .scapp file, the script extracts the archive and runs the
alphabetically first top-level .bat file.
#>
[CmdletBinding()]
param(
	[Parameter(Position = 0)]
	[string]$ScappPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Install-ScappHandlerScript {
	$installDirectory = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'SCApp'
	$installedScriptPath = Join-Path $installDirectory 'Register-SCApp.ps1'
	$sourceScriptPath = [System.IO.Path]::GetFullPath($PSCommandPath)

	New-Item -Path $installDirectory -ItemType Directory -Force | Out-Null

	if (-not $sourceScriptPath.Equals($installedScriptPath, [StringComparison]::OrdinalIgnoreCase)) {
		Copy-Item -LiteralPath $sourceScriptPath -Destination $installedScriptPath -Force
	}

	return $installedScriptPath
}

function Register-ScappHandler {
	$progId = 'ScappFile'
	$classesRoot = 'HKCU:\Software\Classes'
	$extensionKey = Join-Path $classesRoot '.scapp'
	$progIdKey = Join-Path $classesRoot $progId
	$defaultIconKey = Join-Path $progIdKey 'DefaultIcon'
	$shellKey = Join-Path $progIdKey 'shell'
	$runKey = Join-Path $shellKey 'Run'
	$commandKey = Join-Path $runKey 'command'
	$scriptPath = Install-ScappHandlerScript
	$powerShellPath = (Get-Process -Id $PID).Path
	$command = '"{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}" "%1"' -f $powerShellPath, $scriptPath
	$icon = "$env:SystemRoot\System32\shell32.dll,24" # off by one? #25 is what i see in the icon viewer

	New-Item -Path $extensionKey -Force | Out-Null
	Set-Item -Path $extensionKey -Value $progId

	New-Item -Path $progIdKey -Force | Out-Null
	Set-Item -Path $progIdKey -Value 'SCAPP Package'

	New-Item -Path $defaultIconKey -Force | Out-Null
	Set-Item -Path $defaultIconKey -Value $icon

	New-Item -Path $shellKey -Force | Out-Null
	Set-Item -Path $shellKey -Value 'Run'

	New-Item -Path $runKey -Force | Out-Null
	Set-Item -Path $runKey -Value 'Run'

	New-Item -Path $commandKey -Force | Out-Null
	Set-Item -Path $commandKey -Value $command

	Write-Host "Registered .scapp files to run with $scriptPath"
}

function Invoke-ScappPackage {
	param(
		[Parameter(Mandatory)]
		[string]$Path
	)

	$resolvedPath = (Resolve-Path -LiteralPath $Path).ProviderPath
	if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
		throw "SCAPP file not found: $Path"
	}

	$tempDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("scapp-{0}" -f [guid]::NewGuid().ToString('N'))
	New-Item -Path $tempDirectory -ItemType Directory | Out-Null

	try {
		Add-Type -AssemblyName System.IO.Compression.FileSystem
		[System.IO.Compression.ZipFile]::ExtractToDirectory($resolvedPath, $tempDirectory)

		$batchFile = Get-ChildItem -LiteralPath $tempDirectory -Filter '*.bat' -File |
			Sort-Object -Property Name |
			Select-Object -First 1

		if (-not $batchFile) {
			throw "No top-level .bat file was found in $resolvedPath"
		}

		$process = Start-Process -FilePath $env:ComSpec `
			-ArgumentList @('/d', '/s', '/c', ('call "{0}"' -f $batchFile.FullName)) `
			-WorkingDirectory $tempDirectory `
			-Wait `
			-PassThru

		return $process.ExitCode
	}
	finally {
		Remove-Item -LiteralPath $tempDirectory -Recurse -Force -ErrorAction SilentlyContinue
	}
}

try {
	if ([string]::IsNullOrWhiteSpace($ScappPath)) {
		Register-ScappHandler
		exit 0
	}

	$exitCode = Invoke-ScappPackage -Path $ScappPath
	exit $exitCode
}
catch {
	Write-Error $_
	exit 1
}
