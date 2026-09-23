[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$HistoryRoot = 'E:\codex-session-history',
    [string]$Workspace = '',
    [switch]$RenderMarkdown
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-SafeName {
    param([string]$Value)

    return ($Value -replace '[^A-Za-z0-9._-]', '_')
}

function Get-WorkspaceFolderName {
    param([string]$Workspace)

    $name = [System.IO.Path]::GetFileName($Workspace.TrimEnd('\'))
    if ([string]::IsNullOrWhiteSpace($name)) {
        $name = 'workspace'
    }
    return ($name -replace '[\\/:*?"<>|]', '_')
}

function Get-CodeBlock {
    param(
        [string]$Text,
        [int]$StartAt = 0
    )

    $segment = $Text.Substring($StartAt)
    $openMatch = [regex]::Match($segment, '(?m)^(?<fence>`{3,}|~{3,})[^\r\n]*\r?\n')
    if (-not $openMatch.Success -or -not [string]::IsNullOrWhiteSpace($segment.Substring(0, $openMatch.Index))) {
        return $null
    }

    $blockStart = $StartAt + $openMatch.Index
    $contentStart = $StartAt + $openMatch.Index + $openMatch.Length
    $remainder = $Text.Substring($contentStart)
    $fence = $openMatch.Groups['fence'].Value
    $closePattern = '(?m)^[ \t]*' + [regex]::Escape($fence.Substring(0, 1)) + '{' + $fence.Length + ',}[ \t]*\r?$'
    $closeMatch = [regex]::Match($remainder, $closePattern)
    if (-not $closeMatch.Success) {
        return $null
    }

    $content = $remainder.Substring(0, $closeMatch.Index)
    if ($content.EndsWith("`r`n")) {
        $content = $content.Substring(0, $content.Length - 2)
    }
    elseif ($content.EndsWith("`n")) {
        $content = $content.Substring(0, $content.Length - 1)
    }
    return [PSCustomObject]@{
        Format = 'legacy'
        Text = $content
        StartIndex = $blockStart
        EndIndex = $contentStart + $closeMatch.Index + $closeMatch.Length
    }
}

function Get-ContentBlock {
    param(
        [string]$Text,
        [string]$Role,
        [int]$StartAt = 0
    )

    $segment = $Text.Substring($StartAt)
    $startPattern = '(?m)^<!-- codex-session-history:content-start role=' + [regex]::Escape($Role) + ' token=(?<token>[^ >]+) -->\r?$'
    $startMatch = [regex]::Match($segment, $startPattern)
    if (-not $startMatch.Success -or -not [string]::IsNullOrWhiteSpace($segment.Substring(0, $startMatch.Index))) {
        return $null
    }

    $blockStart = $StartAt + $startMatch.Index
    $contentStart = $blockStart + $startMatch.Length
    if ($Text.Substring($contentStart).StartsWith("`r`n")) {
        $contentStart += 2
    }
    elseif ($contentStart -lt $Text.Length -and $Text[$contentStart] -eq "`n") {
        $contentStart++
    }
    else {
        return $null
    }

    $remainder = $Text.Substring($contentStart)
    $endPattern = '(?m)^<!-- codex-session-history:content-end token=' + [regex]::Escape($startMatch.Groups['token'].Value) + ' -->\r?$'
    $endMatch = [regex]::Match($remainder, $endPattern)
    if (-not $endMatch.Success) {
        return $null
    }

    $content = $remainder.Substring(0, $endMatch.Index)
    if ($content.EndsWith("`r`n")) {
        $content = $content.Substring(0, $content.Length - 2)
    }
    elseif ($content.EndsWith("`n")) {
        $content = $content.Substring(0, $content.Length - 1)
    }
    return [PSCustomObject]@{
        Format = 'renderable'
        Text = $content
        StartIndex = $blockStart
        EndIndex = $contentStart + $endMatch.Index + $endMatch.Length
    }
}

function Get-MessageBlock {
    param(
        [string]$Text,
        [string]$Role,
        [int]$StartAt
    )

    $segment = $Text.Substring($StartAt)
    $startPattern = '(?m)^<!-- codex-session-history:content-start role=' + [regex]::Escape($Role) + ' token=[^ >]+ -->\r?$'
    $startMatch = [regex]::Match($segment, $startPattern)
    if ($startMatch.Success -and [string]::IsNullOrWhiteSpace($segment.Substring(0, $startMatch.Index))) {
        return Get-ContentBlock -Text $Text -Role $Role -StartAt $StartAt
    }
    return Get-CodeBlock -Text $Text -StartAt $StartAt
}

function Get-StructuralTurnMarkers {
    param([string]$Text)

    $markers = @()
    $lineStart = 0
    $fenceCharacter = ''
    $fenceLength = 0
    $contentToken = ''
    while ($lineStart -lt $Text.Length) {
        $newlineIndex = $Text.IndexOf("`n", $lineStart)
        if ($newlineIndex -lt 0) {
            $lineEnd = $Text.Length
            $nextLineStart = $Text.Length
        }
        else {
            $lineEnd = $newlineIndex
            if ($lineEnd -gt $lineStart -and $Text[$lineEnd - 1] -eq "`r") {
                $lineEnd--
            }
            $nextLineStart = $newlineIndex + 1
        }
        $line = $Text.Substring($lineStart, $lineEnd - $lineStart)

        if ($contentToken) {
            if ($line -eq "<!-- codex-session-history:content-end token=$contentToken -->") {
                $contentToken = ''
            }
        }
        elseif ($fenceCharacter) {
            $closePattern = '^[ \t]*' + [regex]::Escape($fenceCharacter) + '{' + $fenceLength + ',}[ \t]*$'
            if ($line -match $closePattern) {
                $fenceCharacter = ''
                $fenceLength = 0
            }
        }
        else {
            $contentMatch = [regex]::Match($line, '^<!-- codex-session-history:content-start role=(?:user|agent) token=(?<token>[^ >]+) -->$')
            if ($contentMatch.Success) {
                $contentToken = $contentMatch.Groups['token'].Value
            }
            else {
                $markerMatch = [regex]::Match($line, '^<!-- codex-session-history:turn=(?<turn>[^>\r\n]+) -->$')
                if ($markerMatch.Success) {
                    $markers += [PSCustomObject]@{
                        Index = $lineStart
                        TurnId = $markerMatch.Groups['turn'].Value
                    }
                }

                $openFenceMatch = [regex]::Match($line, '^[ \t]*(?<fence>`{3,}|~{3,})')
                if ($openFenceMatch.Success) {
                    $fenceCharacter = $openFenceMatch.Groups['fence'].Value.Substring(0, 1)
                    $fenceLength = $openFenceMatch.Groups['fence'].Value.Length
                }
            }
        }

        $lineStart = $nextLineStart
    }
    return $markers
}

function Get-MarkdownTurns {
    param([string]$Content)

    $turns = @()
    $markers = @(Get-StructuralTurnMarkers -Text $Content)
    for ($markerIndex = 0; $markerIndex -lt $markers.Count; $markerIndex++) {
        $marker = $markers[$markerIndex]
        $segmentEnd = if ($markerIndex + 1 -lt $markers.Count) { $markers[$markerIndex + 1].Index } else { $Content.Length }
        $segment = $Content.Substring($marker.Index, $segmentEnd - $marker.Index)
        $segmentPattern = '(?ms)^<!-- codex-session-history:turn=' + [regex]::Escape($marker.TurnId) + ' -->\r?\n\s*^## Turn ' + [regex]::Escape($marker.TurnId) + '\r?\n(?<body>.*)\z'
        $match = [regex]::Match($segment, $segmentPattern)
        if (-not $match.Success) {
            continue
        }
        $body = $match.Groups['body'].Value
        $userHeading = [regex]::Match($body, '(?m)^### User\r?$')
        if (-not $userHeading.Success) {
            continue
        }
        $userBlock = Get-MessageBlock -Text $body -Role 'user' -StartAt ($userHeading.Index + $userHeading.Length)
        if ($null -eq $userBlock) {
            continue
        }

        $agentSegment = $body.Substring($userBlock.EndIndex)
        $agentHeading = [regex]::Match($agentSegment, '(?m)^### Agent\r?$')
        if (-not $agentHeading.Success) {
            continue
        }
        $agentStart = $userBlock.EndIndex + $agentHeading.Index + $agentHeading.Length
        $agentBlock = Get-MessageBlock -Text $body -Role 'agent' -StartAt $agentStart
        if ($null -eq $agentBlock) {
            continue
        }

        $bodyStart = $marker.Index + $match.Groups['body'].Index
        $turns += [PSCustomObject]@{
            TurnId = $marker.TurnId
            User = $userBlock.Text
            Agent = $agentBlock.Text
            UserFormat = $userBlock.Format
            AgentFormat = $agentBlock.Format
            UserStart = $bodyStart + $userBlock.StartIndex
            UserEnd = $bodyStart + $userBlock.EndIndex
            AgentStart = $bodyStart + $agentBlock.StartIndex
            AgentEnd = $bodyStart + $agentBlock.EndIndex
        }
    }
    return $turns
}

function Get-MarkdownIndexEntries {
    param([System.IO.FileInfo]$MarkdownFile)

    $content = [System.IO.File]::ReadAllText($MarkdownFile.FullName)
    $workspaceMatch = [regex]::Match($content, '(?m)^- Workspace: `(?<workspace>.*)`\s*$')
    $sessionMatch = [regex]::Match($content, '(?m)^- Session ID: `(?<session>.*)`\s*$')
    if (-not $workspaceMatch.Success -or -not $sessionMatch.Success) {
        return @()
    }

    $entries = @()
    foreach ($turn in Get-MarkdownTurns -Content $content) {
        $entries += [ordered]@{
            schema = 1
            indexed_at = $MarkdownFile.LastWriteTimeUtc.ToString('o')
            workspace = $workspaceMatch.Groups['workspace'].Value
            session_id = $sessionMatch.Groups['session'].Value
            turn_id = $turn.TurnId
            markdown = $MarkdownFile.Name
            user = $turn.User
            agent = $turn.Agent
        }
    }
    return $entries
}

function New-ContentBoundaryBlock {
    param(
        [AllowEmptyString()]
        [string]$Text,
        [string]$Role,
        [string]$NewLine
    )

    $token = [guid]::NewGuid().ToString('N')
    return @(
        "<!-- codex-session-history:content-start role=$Role token=$token -->",
        $Text,
        "<!-- codex-session-history:content-end token=$token -->"
    ) -join $NewLine
}

function Convert-MarkdownToRenderable {
    param([System.IO.FileInfo]$MarkdownFile)

    $sessionMutex = New-Object System.Threading.Mutex($false, "codex-session-history-$(Get-SafeName $MarkdownFile.BaseName)")
    $sessionLockAcquired = $false
    try {
        try {
            $sessionLockAcquired = $sessionMutex.WaitOne(10000)
        }
        catch [System.Threading.AbandonedMutexException] {
            $sessionLockAcquired = $true
        }
        if (-not $sessionLockAcquired) {
            throw "Could not acquire session history lock: $($MarkdownFile.FullName)"
        }

        return Convert-LockedMarkdownToRenderable -MarkdownFile $MarkdownFile
    }
    finally {
        if ($sessionLockAcquired) {
            $sessionMutex.ReleaseMutex()
        }
        $sessionMutex.Dispose()
    }
}

function Test-MarkdownNeedsMigration {
    param([System.IO.FileInfo]$MarkdownFile)

    $content = [System.IO.File]::ReadAllText($MarkdownFile.FullName)
    $markers = @(Get-StructuralTurnMarkers -Text $content)
    $turns = @(Get-MarkdownTurns -Content $content)
    if ($turns.Count -ne $markers.Count) {
        throw "Cannot inspect malformed session history: $($MarkdownFile.FullName) ($($turns.Count) parsed turns, $($markers.Count) markers)"
    }
    foreach ($turn in $turns) {
        if ($turn.UserFormat -eq 'legacy' -or $turn.AgentFormat -eq 'legacy') {
            return $true
        }
    }
    return $false
}

function Convert-LockedMarkdownToRenderable {
    param([System.IO.FileInfo]$MarkdownFile)

    $content = [System.IO.File]::ReadAllText($MarkdownFile.FullName)
    $markers = @(Get-StructuralTurnMarkers -Text $content)
    $turns = @(Get-MarkdownTurns -Content $content)
    if ($turns.Count -ne $markers.Count) {
        throw "Cannot migrate malformed session history: $($MarkdownFile.FullName) ($($turns.Count) parsed turns, $($markers.Count) markers)"
    }

    $replacements = @()
    foreach ($turn in $turns) {
        if ($turn.UserFormat -eq 'legacy') {
            $replacements += [PSCustomObject]@{ Start = $turn.UserStart; End = $turn.UserEnd; Role = 'user'; Text = $turn.User }
        }
        if ($turn.AgentFormat -eq 'legacy') {
            $replacements += [PSCustomObject]@{ Start = $turn.AgentStart; End = $turn.AgentEnd; Role = 'agent'; Text = $turn.Agent }
        }
    }
    if ($replacements.Count -eq 0) {
        return $false
    }

    $newLine = if ($content.Contains("`r`n")) { "`r`n" } else { "`n" }
    $updated = $content
    foreach ($replacement in $replacements | Sort-Object Start -Descending) {
        $block = New-ContentBoundaryBlock -Text $replacement.Text -Role $replacement.Role -NewLine $newLine
        $updated = $updated.Remove($replacement.Start, $replacement.End - $replacement.Start).Insert($replacement.Start, $block)
    }

    $updatedMarkers = @(Get-StructuralTurnMarkers -Text $updated)
    $updatedTurns = @(Get-MarkdownTurns -Content $updated)
    if ($updatedMarkers.Count -ne $markers.Count -or $updatedTurns.Count -ne $turns.Count) {
        throw "Migration validation failed for session history: $($MarkdownFile.FullName)"
    }
    for ($index = 0; $index -lt $turns.Count; $index++) {
        if ($turns[$index].TurnId -cne $updatedTurns[$index].TurnId -or
            $turns[$index].User -cne $updatedTurns[$index].User -or
            $turns[$index].Agent -cne $updatedTurns[$index].Agent) {
            throw "Migration changed turn content in session history: $($MarkdownFile.FullName)"
        }
    }

    $beforeImages = @([regex]::Matches($content, '(?m)^!\[[^\]\r\n]*\]\(_images/[^\r\n)]+\)[ \t]*\r?$') | ForEach-Object Value)
    $afterImages = @([regex]::Matches($updated, '(?m)^!\[[^\]\r\n]*\]\(_images/[^\r\n)]+\)[ \t]*\r?$') | ForEach-Object Value)
    if (($beforeImages -join "`n") -cne ($afterImages -join "`n")) {
        throw "Migration changed image references in session history: $($MarkdownFile.FullName)"
    }

    $bytes = [System.IO.File]::ReadAllBytes($MarkdownFile.FullName)
    $hasUtf8Bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $encoding = New-Object System.Text.UTF8Encoding($hasUtf8Bom)
    $replacementToken = [guid]::NewGuid().ToString('N')
    $temporaryPath = Join-Path $MarkdownFile.DirectoryName ($MarkdownFile.Name + ".render-$replacementToken.tmp")
    $backupPath = Join-Path $MarkdownFile.DirectoryName ($MarkdownFile.Name + ".backup-$replacementToken.tmp")
    try {
        [System.IO.File]::WriteAllText($temporaryPath, $updated, $encoding)
        [System.IO.File]::Replace($temporaryPath, $MarkdownFile.FullName, $backupPath)
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
        if (Test-Path -LiteralPath $backupPath) {
            Remove-Item -LiteralPath $backupPath -Force
        }
    }
    return $true
}

if (-not (Test-Path -LiteralPath $HistoryRoot)) {
    throw "History root not found: $HistoryRoot"
}

$workspaceDirectories = if ([string]::IsNullOrWhiteSpace($Workspace)) {
    @(Get-ChildItem -LiteralPath $HistoryRoot -Directory)
}
else {
    $workspaceDirectory = Join-Path $HistoryRoot (Get-WorkspaceFolderName -Workspace $Workspace)
    if (Test-Path -LiteralPath $workspaceDirectory) { @(Get-Item -LiteralPath $workspaceDirectory) } else { @() }
}

$total = 0
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
foreach ($workspaceDirectory in $workspaceDirectories) {
    $markdownFiles = @(Get-ChildItem -LiteralPath $workspaceDirectory.FullName -File -Filter '*.md')
    if ($RenderMarkdown) {
        foreach ($markdownFile in $markdownFiles) {
            if ((Test-MarkdownNeedsMigration -MarkdownFile $markdownFile) -and
                $PSCmdlet.ShouldProcess($markdownFile.FullName, 'Replace legacy outer code fences with renderable Markdown boundaries')) {
                if (Convert-MarkdownToRenderable -MarkdownFile $markdownFile) {
                    Write-Output "Migrated Markdown: $($markdownFile.FullName)"
                }
            }
        }
    }

    $indexPath = Join-Path $workspaceDirectory.FullName '_index.jsonl'
    $mutex = New-Object System.Threading.Mutex($false, "codex-session-history-index-$(Get-SafeName $workspaceDirectory.FullName)")
    $lockAcquired = $false
    try {
        try {
            $lockAcquired = $mutex.WaitOne(10000)
        }
        catch [System.Threading.AbandonedMutexException] {
            $lockAcquired = $true
        }
        if (-not $lockAcquired) {
            throw "Could not acquire index lock: $indexPath"
        }
        $entries = @()
        foreach ($markdownFile in Get-ChildItem -LiteralPath $workspaceDirectory.FullName -File -Filter '*.md') {
            $entries += Get-MarkdownIndexEntries -MarkdownFile $markdownFile
        }
        $indexText = if ($entries.Count -gt 0) {
            (($entries | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 5 }) -join "`r`n") + "`r`n"
        }
        else {
            ''
        }
        if ($PSCmdlet.ShouldProcess($indexPath, 'Rebuild session-history search index')) {
            [System.IO.File]::WriteAllText($indexPath, $indexText, $utf8NoBom)
        }
    }
    finally {
        if ($lockAcquired) {
            $mutex.ReleaseMutex()
        }
        $mutex.Dispose()
    }
    $total += $entries.Count
    Write-Output "Indexed $($entries.Count) turns: $indexPath"
}

Write-Output "Indexed total: $total"
