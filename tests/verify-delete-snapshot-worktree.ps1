[CmdletBinding()]
param(
    [string]$SnapshotScript = (Join-Path (Split-Path -Parent $PSScriptRoot) 'shadow-git.ps1')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Git {
    param(
        [string]$WorkingDirectory,
        [string[]]$Arguments
    )

    $output = & git -C $WorkingDirectory @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw (($output | Out-String).Trim())
    }
    return $output
}

$root = Join-Path ([System.IO.Path]::GetTempPath()) ("shadow-git-delete-worktree-" + [Guid]::NewGuid().ToString('N'))
$source = Join-Path $root 'source'
$store = Join-Path $root 'store'
$review = Join-Path $root 'review'
$shadowGit = Join-Path $store 'repo\.git'

try {
    New-Item -ItemType Directory -Force -Path $source | Out-Null
    Set-Content -LiteralPath (Join-Path $source 'temporary.txt') -Value 'remove this file'

    Invoke-Git -WorkingDirectory $source -Arguments @('init', '--quiet') | Out-Null
    Invoke-Git -WorkingDirectory $source -Arguments @('config', 'user.name', 'Shadow Git Test') | Out-Null
    Invoke-Git -WorkingDirectory $source -Arguments @('config', 'user.email', 'shadow-git-test@example.invalid') | Out-Null
    Invoke-Git -WorkingDirectory $source -Arguments @('add', '--all') | Out-Null
    Invoke-Git -WorkingDirectory $source -Arguments @('commit', '--quiet', '-m', 'source baseline') | Out-Null

    & $SnapshotScript init -Project $source -Store $store | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to create the shadow baseline.'
    }

    & git "--git-dir=$shadowGit" worktree add --quiet $review shadow
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to create the review worktree.'
    }

    Remove-Item -LiteralPath (Join-Path $source 'temporary.txt') -Force
    & $SnapshotScript snapshot -Project $source -Store $store -Message 'delete temporary file' | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to create the deletion snapshot.'
    }

    $changes = (Invoke-Git -WorkingDirectory $review -Arguments @('status', '--porcelain')) -join [Environment]::NewLine
    if (-not [string]::IsNullOrWhiteSpace($changes)) {
        throw "Expected the review worktree to be clean after the snapshot, got: $changes"
    }
    if (Test-Path -LiteralPath (Join-Path $review 'temporary.txt')) {
        throw 'Expected the deleted file to be removed from the review worktree.'
    }

    $diff = & git "--git-dir=$shadowGit" diff --name-status refs/turn/0001 refs/turn/0002
    if ($LASTEXITCODE -ne 0 -or ($diff -join [Environment]::NewLine) -notmatch '(?m)^D\s+temporary\.txt$') {
        throw 'Expected the second snapshot to record the deleted file.'
    }

    Write-Output 'PASS: deletion snapshot is committed and the review worktree is synchronized.'
}
finally {
    if (Test-Path -LiteralPath $root) {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}
