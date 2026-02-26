<#
	.SYNOPSIS
	Validates that each runbook has a companion permissions JSON

	.DESCRIPTION
	This script recursively scans one or more runbook root folders for PowerShell runbooks (*.ps1) and verifies that each runbook has a companion permissions JSON file in the same directory. A companion file is considered present if either <runbook>.permissions.json or <runbook>.permission.json exists. The script prints a clear summary and exits with code 1 when any runbook is missing its companion permissions JSON.

	.PARAMETER IncludedScope
	One or more root folders that contain runbooks, for example @('device','group','org','user'). Each scope is scanned recursively.
#>

param (
	[Parameter(Mandatory = $true)]
	[string[]]$IncludedScope
)

Set-StrictMode -Version Latest

############################################################
#region Functions
#
############################################################

function Write-GitHubError {
	<#
		.SYNOPSIS
		Emits a GitHub Actions error annotation
	#>
	param(
		[Parameter(Mandatory = $true)]
		[string]$Message,

		[Parameter(Mandatory = $false)]
		[string]$FilePath
	)

	if ($FilePath) {
		Write-Output "::error file=$FilePath,title=Permissions JSON validation failed::$Message"
		return
	}

	Write-Output "::error title=Permissions JSON validation failed::$Message"
}

function Get-RunbookFiles {
	<#
		.SYNOPSIS
		Finds all runbook .ps1 files in the included scopes
	#>
	param(
		[Parameter(Mandatory = $true)]
		[string[]]$Scopes
	)

	$all = @()
	foreach ($scope in $Scopes) {
		if (-not $scope) {
			continue
		}

		$scopePath = Join-Path (Get-Location).Path $scope
		if (-not (Test-Path -LiteralPath $scopePath)) {
			continue
		}

		$all += Get-ChildItem -LiteralPath $scopePath -Recurse -File -Filter '*.ps1' -ErrorAction Stop
	}

	# Exclude non-runbook scripts if they are inside scopes for some reason
	return @(
		$all
		| Where-Object { $_.FullName -notmatch '[\\/](\.github|docs)[\\/]' }
		| Sort-Object FullName
	)
}

function Get-CompanionPermissionsCandidates {
	<#
		.SYNOPSIS
		Builds the expected permissions JSON file paths for a runbook
	#>
	param(
		[Parameter(Mandatory = $true)]
		[string]$RunbookPath
	)

	$dir = Split-Path -Parent $RunbookPath
	$base = [System.IO.Path]::GetFileNameWithoutExtension($RunbookPath)
	return @(
		(Join-Path $dir "$base.permissions.json"),
		(Join-Path $dir "$base.permission.json")
	)
}

function Get-RelativePath {
	<#
		.SYNOPSIS
		Returns a workspace-relative, forward-slash path for GitHub annotations
	#>
	param(
		[Parameter(Mandatory = $true)]
		[string]$Path
	)

	$full = (Resolve-Path -LiteralPath $Path).Path
	$root = (Resolve-Path -LiteralPath (Get-Location).Path).Path
	$rel = $full.Substring($root.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
	return ($rel -replace '\\', '/')
}

#endregion Functions

############################################################
#region Main Logic
#
############################################################

try {
	$runbooks = @(Get-RunbookFiles -Scopes $IncludedScope)
	if ($runbooks.Count -eq 0) {
		Write-Output "No runbooks (*.ps1) found in included scopes. Skipping permissions JSON validation."
		exit 0
	}

	$missing = @()
	foreach ($rb in $runbooks) {
		$rbRel = Get-RelativePath -Path $rb.FullName
		$candidates = Get-CompanionPermissionsCandidates -RunbookPath $rb.FullName
		$found = $false
		foreach ($c in $candidates) {
			if (Test-Path -LiteralPath $c) {
				$found = $true
				break
			}
		}

		if (-not $found) {
			$dirRel = (Split-Path -Parent $rbRel) -replace '\\', '/'
			$base = [System.IO.Path]::GetFileNameWithoutExtension($rbRel)
			$expectedPreferred = if ($dirRel) { "$dirRel/$base.permissions.json" } else { "$base.permissions.json" }
			$expectedAlt = if ($dirRel) { "$dirRel/$base.permission.json" } else { "$base.permission.json" }

			$msg = "Missing companion permissions JSON. Expected '$expectedPreferred' (preferred) or '$expectedAlt'."
			$missing += [PSCustomObject]@{ Runbook = $rbRel; Message = $msg }
			Write-Output "::group::Missing permissions JSON: $rbRel"
			Write-Output "FAILED: $rbRel"
			Write-GitHubError -Message $msg -FilePath $rbRel
			Write-Output "::endgroup::"
		}
	}

	Write-Output ""
	Write-Output "Permissions JSON validation summary"
	Write-Output "----------------------------------"
	Write-Output ("Total runbooks scanned: {0}" -f $runbooks.Count)
	Write-Output ("Missing permissions JSON: {0}" -f $missing.Count)

	if ($missing.Count -gt 0) {
		Write-Output ""
		Write-Output "Missing permissions JSON (details)"
		Write-Output "---------------------------------"
		foreach ($m in $missing) {
			Write-Output ""
			Write-Output $m.Runbook
			Write-Output ("-" * [Math]::Min(120, [Math]::Max(3, $m.Runbook.Length)))
			Write-Output ("  " + $m.Message)
		}

		Write-Output ""
		Write-Output ("Permissions JSON validation failed for {0} runbook(s)." -f $missing.Count)
		exit 1
	}

	Write-Output ""
	Write-Output "Permissions JSON validation passed."
	exit 0
}
catch {
	$message = "Permissions JSON validator failed unexpectedly. Error: $($_.Exception.Message)"
	Write-Output $message
	Write-GitHubError -Message $message
	exit 1
}

#endregion Main Logic
