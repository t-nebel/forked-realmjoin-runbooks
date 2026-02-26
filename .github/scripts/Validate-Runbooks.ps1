<#
    .SYNOPSIS
    Validates changed RealmJoin PowerShell runbooks in a pull request.

    .DESCRIPTION
    This script detects PowerShell runbooks that were added or modified compared to a base ref and validates their comment-based help header and companion permissions JSON file. It also runs PSScriptAnalyzer and fails the check only on findings with severity Error.

    .PARAMETER BaseRef
    The git reference to diff against, for example "origin/master".

    .PARAMETER HeadRef
    The git reference that contains the changes to validate, for example "HEAD".
#>

param (
    [Parameter(Mandatory = $true)]
    [string]$BaseRef,

    [Parameter(Mandatory = $true)]
    [string]$HeadRef
)

Set-StrictMode -Version Latest

function Write-GitHubError {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [string]$FilePath
    )

    if ($FilePath) {
        # GitHub Actions annotation
        Write-Output "::error file=$FilePath,title=Runbook validation failed::$Message"
    }
    else {
        Write-Error $Message
    }
}

function Get-ChangedFiles {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Base,

        [Parameter(Mandatory = $true)]
        [string]$Head
    )

    # In pull_request workflows, HeadRef is typically a merge commit. To reliably get the PR
    # changes (and not an arbitrary base SHA from the payload), prefer diffing between the
    # merge commit parents: base-parent..pr-head-parent.
    $parentsLine = & git rev-list --parents -n 1 $Head 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to inspect HeadRef '$Head' via git rev-list. Error: $($parentsLine | Out-String)"
    }

    $parts = ($parentsLine -split '\s+' | Where-Object { $_ -and $_.Trim() -ne '' })
    $isMergeCommit = ($parts.Count -ge 3)

    if ($isMergeCommit) {
        $baseParent = $parts[1]
        $prParent = $parts[2]
        $diffArgs = @('diff', '--name-only', '--diff-filter=AM', "$baseParent..$prParent")
    }
    else {
        $diffArgs = @('diff', '--name-only', '--diff-filter=AM', "$Base..$Head")
    }

    try {
        $output = & git @diffArgs 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw ($output | Out-String)
        }
    }
    catch {
        throw "Failed to determine changed files via git diff. BaseRef='$Base', HeadRef='$Head'. Error: $($_.Exception.Message)"
    }

    return ($output | Where-Object { $_ -and $_.Trim() -ne '' } | ForEach-Object { $_.Trim() })
}

function Shorten-Text {
    param(
        [Parameter(Mandatory = $false)]
        [string]$Text,

        [Parameter(Mandatory = $false)]
        [int]$MaxLength = 240
    )

    $t = ($Text ?? '').Trim()
    if ($t.Length -le $MaxLength) {
        return $t
    }

    return ($t.Substring(0, $MaxLength) + '…')
}

function Get-TopCommentBasedHelpBlock {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content,

        [Parameter(Mandatory = $true)]
        [string]$PathForErrors
    )

    $contentNoBom = $Content -replace '^\uFEFF', ''
    $firstNonWs = [regex]::Match($contentNoBom, '(?s)\S')
    if (-not $firstNonWs.Success) {
        throw "File is empty."
    }

    if ($firstNonWs.Index -ne 0) {
        # allow leading whitespace/newlines, but require the first non-whitespace token to start the help block
        $contentNoBom = $contentNoBom.Substring($firstNonWs.Index)
    }

    if (-not $contentNoBom.StartsWith('<#')) {
        throw "Missing comment-based help header. The file must start with '<#' as the first non-whitespace content."
    }

    $endIndex = $contentNoBom.IndexOf('#>')
    if ($endIndex -lt 0) {
        throw "Comment-based help header is not closed. Missing '#>'."
    }

    return $contentNoBom.Substring(0, $endIndex + 2)
}

function Convert-HelpTextToString {
    param(
        [Parameter(Mandatory = $false)]
        $HelpText
    )

    if ($null -eq $HelpText) {
        return ''
    }

    if ($HelpText -is [string]) {
        return $HelpText
    }

    if ($HelpText.PSObject.Properties.Match('Text').Count -gt 0) {
        $textValue = $HelpText.Text
        if ($textValue -is [System.Array]) {
            return ($textValue -join ' ')
        }

        return [string]$textValue
    }

    return [string]$HelpText
}

function Get-DeclaredParameterNames {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($FilePath, [ref]$tokens, [ref]$errors)

    if ($errors -and $errors.Count -gt 0) {
        $first = $errors | Select-Object -First 1
        throw "PowerShell parse error: $($first.Message)"
    }

    $paramBlock = $ast.ParamBlock
    if (-not $paramBlock) {
        return @()
    }

    return @(
        $paramBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }
    )
}

function Assert-RunbookHasPermissionsFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RunbookPath
    )

    $dir = Split-Path -Parent $RunbookPath
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($RunbookPath)

    $primary = Join-Path $dir "$baseName.permissions.json"
    $alt = Join-Path $dir "$baseName.permission.json"

    if (Test-Path -LiteralPath $primary) {
        return
    }

    if (Test-Path -LiteralPath $alt) {
        return
    }

    throw "Missing permissions JSON. Expected '$primary' (preferred) or '$alt'."
}

function Assert-RunbookHelpIsComplete {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RunbookPath,

        [Parameter(Mandatory = $true)]
        [string]$RunbookRelativePath
    )

    $content = Get-Content -LiteralPath $RunbookPath -Raw
    $null = Get-TopCommentBasedHelpBlock -Content $content -PathForErrors $RunbookPath

    $resolvedPath = (Resolve-Path -LiteralPath $RunbookPath -ErrorAction Stop).Path
    $helpTarget = $RunbookRelativePath -replace '\\', '/'
    if (-not ($helpTarget.StartsWith('./') -or $helpTarget.StartsWith('.\\'))) {
        $helpTarget = "./$helpTarget"
    }
    try {
        $help = Get-Help -Full $helpTarget -ErrorAction Stop
    }
    catch {
        throw "Get-Help failed to read comment-based help for '$helpTarget' ('$resolvedPath'). Error: $($_.Exception.Message)"
    }

    $synopsis = (Convert-HelpTextToString -HelpText $help.Synopsis).Trim()
    if (-not $synopsis) {
        throw "Missing or empty .SYNOPSIS section in comment-based help."
    }

    $description = (Convert-HelpTextToString -HelpText $help.Description.Text).Trim()
    if (-not $description) {
        throw "Missing or empty .DESCRIPTION section in comment-based help."
    }

    $normalize = {
        param([string]$s)
        return (($s ?? '') -replace '\s+', ' ').Trim().ToLowerInvariant()
    }

    if (& $normalize $synopsis -eq (& $normalize $description)) {
        $synShort = Shorten-Text -Text $synopsis
        $descShort = Shorten-Text -Text $description
        throw "Synopsis and Description must not be identical. Make .DESCRIPTION more detailed than .SYNOPSIS. Seen Synopsis='$synShort' Description='$descShort'"
    }

    $declaredParams = Get-DeclaredParameterNames -FilePath $RunbookPath
    $helpParamMap = @{}
    if ($help.Parameters -and $help.Parameters.Parameter) {
        foreach ($hp in $help.Parameters.Parameter) {
            if ($hp -and $hp.Name) {
                $helpParamMap[$hp.Name.ToString().ToLowerInvariant()] = $hp
            }
        }
    }

    foreach ($p in $declaredParams) {
        $key = $p.ToLowerInvariant()

        if (-not $helpParamMap.ContainsKey($key)) {
            throw "Missing .PARAMETER section for parameter '$p'."
        }

        $hp = $helpParamMap[$key]
        $paramDesc = (Convert-HelpTextToString -HelpText $hp.Description).Trim()
        if (-not $paramDesc) {
            throw "Empty .PARAMETER description for parameter '$p'."
        }
    }
}

function Assert-RunbookPassesScriptAnalyzer {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RunbookPath
    )

    if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
        throw "PSScriptAnalyzer module is not available. Install it (e.g. Install-Module PSScriptAnalyzer) before running this check."
    }

    try {
        # Do not filter by -Severity here.
        # PSScriptAnalyzer reports syntax issues as Severity 'ParseError', which would be missed
        # when only requesting 'Error'. We filter below to block on both.
        $results = Invoke-ScriptAnalyzer -Path $RunbookPath
    }
    catch {
        throw "PSScriptAnalyzer failed to analyze '$RunbookPath'. Error: $($_.Exception.Message)"
    }

    $blocking = @()
    if ($results) {
        $blocking = $results | Where-Object { $_.Severity -in @('Error', 'ParseError') }
    }

    if ($blocking -and $blocking.Count -gt 0) {
        $messages = $blocking | ForEach-Object {
            $line = if ($_.Line) { "Line $($_.Line)" } else { "" }
            "[$($_.Severity)] $($_.RuleName) $($line): $($_.Message)"
        }

        throw ("PSScriptAnalyzer findings:`n" + ($messages -join "`n"))
    }
}

$changed = Get-ChangedFiles -Base $BaseRef -Head $HeadRef
$changedPs1 = $changed | Where-Object {
    $_.ToLowerInvariant().EndsWith('.ps1') -and
    -not $_.ToLowerInvariant().StartsWith('.github/')
}

if (-not $changedPs1 -or $changedPs1.Count -eq 0) {
    Write-Output "No changed runbooks (*.ps1) detected. Skipping validation."
    exit 0
}

$failures = 0
$failureList = @()

foreach ($relPath in $changedPs1) {
    $path = Join-Path (Get-Location).Path $relPath

    if (-not (Test-Path -LiteralPath $path)) {
        continue
    }

    Write-Output "::group::Validate runbook: $relPath"

    try {
        Assert-RunbookHasPermissionsFile -RunbookPath $path
        Assert-RunbookPassesScriptAnalyzer -RunbookPath $path
        Assert-RunbookHelpIsComplete -RunbookPath $path -RunbookRelativePath $relPath
    }
    catch {
        $failures++
        $message = $($_.Exception.Message)
        $failureList += [PSCustomObject]@{ Runbook = $relPath; Message = $message }
        Write-Output "FAILED: $relPath - $message"
        Write-GitHubError -Message $message -FilePath $relPath
    }

    Write-Output "::endgroup::"
}

if ($failures -gt 0) {
    Write-Output ""
    Write-Output "Validation summary"
    Write-Output "------------------"
    $failureList | Select-Object Runbook, Message | Format-Table -AutoSize | Out-String | Write-Output
    throw "Runbook validation failed for $failures file(s)."
}

Write-Output "Runbook validation passed for $($changedPs1.Count) file(s)."
