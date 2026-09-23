[CmdletBinding()]
param(
    [string]$HistoryRoot = 'E:\codex-session-history',
    [string]$CacheRoot = (Join-Path $env:LOCALAPPDATA 'codex-session-history\pending'),
    [string]$SessionRoot = (Join-Path $env:USERPROFILE '.codex\sessions')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-HookError {
    param([string]$Text)

    try {
        $logRoot = Split-Path -Parent $CacheRoot
        New-Item -ItemType Directory -Force -Path $logRoot | Out-Null
        Add-Content -LiteralPath (Join-Path $logRoot 'hook-errors.log') -Value "$(Get-Date -Format o) $Text"
    }
    catch {
        # Capture failures must not stop the Codex session.
    }
}

function Get-PayloadText {
    param(
        [object]$Payload,
        [string]$Name
    )

    $property = $Payload.PSObject.Properties[$Name]
    if ($property -and $null -ne $property.Value) {
        return [string]$property.Value
    }
    return ''
}

function Get-SafeName {
    param([string]$Value)

    return ($Value -replace '[^A-Za-z0-9._-]', '_')
}

function Get-PromptCachePath {
    param(
        [string]$SessionId,
        [string]$TurnId
    )

    if ([string]::IsNullOrWhiteSpace($SessionId) -or [string]::IsNullOrWhiteSpace($TurnId)) {
        return $null
    }

    return Join-Path $CacheRoot "$((Get-SafeName $SessionId))-$((Get-SafeName $TurnId)).json"
}

function Get-CapturedPrompt {
    param([string]$CachePath)

    if (-not $CachePath -or -not (Test-Path -LiteralPath $CachePath)) {
        return ''
    }

    $entry = Get-Content -LiteralPath $CachePath -Raw | ConvertFrom-Json
    return Get-PayloadText -Payload $entry -Name 'prompt'
}

function Get-SessionTranscriptPath {
    param(
        [string]$Root,
        [string]$SessionId
    )

    if (-not (Test-Path -LiteralPath $Root)) {
        return $null
    }

    $safeSessionId = Get-SafeName $SessionId
    return Get-ChildItem -LiteralPath $Root -Recurse -File -Filter "rollout-*-$safeSessionId.jsonl" |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}

function Get-MessageText {
    param([object]$Message)

    return @($Message.content | ForEach-Object {
        $property = $_.PSObject.Properties['text']
        if ($property -and $null -ne $property.Value) {
            [string]$property.Value
        }
    }) -join ''
}

function Get-UserMessageText {
    param([object]$Message)

    return @($Message.content | ForEach-Object {
        $text = Get-PayloadText -Payload $_ -Name 'text'
        if ((Get-PayloadText -Payload $_ -Name 'type') -eq 'input_text' -and $text -notmatch '^<image\b' -and $text -ne '</image>') {
            $text
        }
    }) -join ''
}

function Get-TurnContent {
    param(
        [string]$TranscriptPath,
        [string]$Prompt,
        [string]$TurnId
    )

    $currentTurnStarted = $false
    $answer = ''
    $images = @()
    $reader = $null
    try {
        # Read forward through the file. PowerShell's -Tail scans backwards and can
        # take longer than the hook timeout when a JSONL record contains a huge line.
        $stream = [System.IO.File]::Open(
            $TranscriptPath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite
        )
        $reader = [System.IO.StreamReader]::new(
            $stream,
            [System.Text.UTF8Encoding]::new($false, $true),
            $true
        )

        while ($null -ne ($line = $reader.ReadLine())) {
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }

            try {
                $record = $line | ConvertFrom-Json
            }
            catch {
                continue
            }

            if ($record.type -ne 'response_item' -or $record.payload.type -ne 'message') {
                continue
            }

            if ($record.payload.role -eq 'user') {
                $metadataProperty = $record.payload.PSObject.Properties['internal_chat_message_metadata_passthrough']
                $recordTurnId = if ($metadataProperty) { Get-PayloadText -Payload $metadataProperty.Value -Name 'turn_id' } else { '' }
                $currentTurnStarted = ($recordTurnId -eq $TurnId -and (Get-UserMessageText -Message $record.payload) -ceq $Prompt)
                if ($currentTurnStarted) {
                    $answer = ''
                    $images = @($record.payload.content | ForEach-Object {
                        if ((Get-PayloadText -Payload $_ -Name 'type') -eq 'input_image') {
                            Get-PayloadText -Payload $_ -Name 'image_url'
                        }
                    } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                }
                continue
            }

            if (-not $currentTurnStarted -or $record.payload.role -ne 'assistant' -or (Get-PayloadText -Payload $record.payload -Name 'phase') -ne 'final_answer') {
                continue
            }

            $text = Get-MessageText -Message $record.payload
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                $answer = $text
            }
        }
    }
    finally {
        if ($reader) {
            $reader.Dispose()
        }
    }

    return [PSCustomObject]@{
        Answer = $answer
        Images = $images
    }
}

function Save-TurnImages {
    param(
        [string[]]$ImageUrls,
        [string]$ImageRoot,
        [string]$TurnId
    )

    $references = @()
    $imageNumber = 0
    foreach ($imageUrl in @($ImageUrls)) {
        if ($imageUrl -notmatch '^data:(image/(png|jpeg|gif|webp));base64,(.+)$') {
            continue
        }

        $extension = switch ($matches[2]) {
            'jpeg' { 'jpg' }
            default { $matches[2] }
        }
        $imageNumber++
        $fileName = "$TurnId-$imageNumber.$extension"
        New-Item -ItemType Directory -Force -Path $ImageRoot | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $ImageRoot $fileName), [System.Convert]::FromBase64String($matches[3]))
        $references += "![Image $imageNumber](_images/$fileName)"
    }

    return $references
}

function Get-WorkspaceFolderName {
    param([string]$Workspace)

    $name = [System.IO.Path]::GetFileName($Workspace.TrimEnd('\'))
    if ([string]::IsNullOrWhiteSpace($name)) {
        $name = 'workspace'
    }
    return ($name -replace '[\\/:*?"<>|]', '_')
}

function ConvertTo-RenderableMarkdownBlock {
    param(
        [AllowEmptyString()]
        [string]$Text,
        [ValidateSet('user', 'agent')]
        [string]$Role
    )

    $token = [guid]::NewGuid().ToString('N')
    return @(
        "<!-- codex-session-history:content-start role=$Role token=$token -->",
        $Text,
        "<!-- codex-session-history:content-end token=$token -->"
    ) -join "`r`n"
}

function New-SessionDocumentHeader {
    param(
        [string]$Workspace,
        [string]$SessionId
    )

    return @(
        '# Codex Session History',
        '',
        ('- Workspace: `' + $Workspace + '`'),
        ('- Session ID: `' + $SessionId + '`'),
        ''
    ) -join "`r`n"
}

function Ensure-SearchIndexEntry {
    param(
        [string]$WorkspaceRoot,
        [string]$Workspace,
        [string]$SessionId,
        [string]$TurnId,
        [string]$MarkdownPath,
        [string]$Prompt,
        [string]$Answer,
        [System.Text.Encoding]$Encoding
    )

    $indexPath = Join-Path $WorkspaceRoot '_index.jsonl'
    $safeWorkspaceRoot = Get-SafeName $WorkspaceRoot
    $mutex = New-Object System.Threading.Mutex($false, "codex-session-history-index-$safeWorkspaceRoot")
    $lockAcquired = $false

    try {
        try {
            $lockAcquired = $mutex.WaitOne(10000)
        }
        catch [System.Threading.AbandonedMutexException] {
            $lockAcquired = $true
        }
        if (-not $lockAcquired) {
            Write-HookError "could not acquire search index lock for session=$SessionId turn=$TurnId"
            return
        }

        if (Test-Path -LiteralPath $indexPath) {
            $indexMarker = '"turn_id":"' + $TurnId + '"'
            foreach ($indexLine in [System.IO.File]::ReadLines($indexPath)) {
                if ($indexLine.Contains($indexMarker)) {
                    return
                }
            }
        }

        $entry = [ordered]@{
            schema = 1
            indexed_at = (Get-Date).ToUniversalTime().ToString('o')
            workspace = $Workspace
            session_id = $SessionId
            turn_id = $TurnId
            markdown = (Split-Path -Leaf $MarkdownPath)
            user = $Prompt
            agent = $Answer
        }
        $line = $entry | ConvertTo-Json -Compress -Depth 5
        [System.IO.File]::AppendAllText($indexPath, $line + "`r`n", $Encoding)
    }
    catch {
        Write-HookError "search index write failed for session=$SessionId turn=${TurnId}: $($_.Exception.Message)"
    }
    finally {
        if ($lockAcquired) {
            $mutex.ReleaseMutex()
        }
        $mutex.Dispose()
    }
}

try {
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) {
        exit 0
    }

    $payload = $raw | ConvertFrom-Json
    if ((Get-PayloadText -Payload $payload -Name 'hook_event_name') -ne 'Stop') {
        exit 0
    }

    $workspace = Get-PayloadText -Payload $payload -Name 'cwd'
    $sessionId = Get-PayloadText -Payload $payload -Name 'session_id'
    $turnId = Get-PayloadText -Payload $payload -Name 'turn_id'
    if ([string]::IsNullOrWhiteSpace($workspace) -or [string]::IsNullOrWhiteSpace($sessionId) -or [string]::IsNullOrWhiteSpace($turnId) -or -not (Test-Path -LiteralPath $workspace)) {
        exit 0
    }

    $cachePath = Get-PromptCachePath -SessionId $sessionId -TurnId $turnId
    $prompt = Get-CapturedPrompt -CachePath $cachePath
    if (-not (Test-Path -LiteralPath $cachePath)) {
        exit 0
    }

    $answer = ''
    $images = @()
    for ($attempt = 0; $attempt -lt 10; $attempt++) {
        $transcript = Get-SessionTranscriptPath -Root $SessionRoot -SessionId $sessionId
        if ($transcript) {
            $turnContent = Get-TurnContent -TranscriptPath $transcript.FullName -Prompt $prompt -TurnId $turnId
            $answer = $turnContent.Answer
            $images = $turnContent.Images
            if (-not [string]::IsNullOrWhiteSpace($answer)) {
                break
            }
        }
        if ($attempt -lt 9) {
            Start-Sleep -Milliseconds 500
        }
    }
    if ([string]::IsNullOrWhiteSpace($answer)) {
        Write-HookError "final answer not found for session=$sessionId turn=$turnId"
        exit 0
    }

    $resolvedWorkspace = (Resolve-Path -LiteralPath $workspace).Path
    $workspaceRoot = Join-Path $HistoryRoot (Get-WorkspaceFolderName -Workspace $resolvedWorkspace)
    $safeSessionId = Get-SafeName $sessionId
    $safeTurnId = Get-SafeName $turnId
    $markdownPath = Join-Path $workspaceRoot "$safeSessionId.md"
    $imageRoot = Join-Path $workspaceRoot '_images'
    $marker = "<!-- codex-session-history:turn=$safeTurnId -->"
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $mutex = New-Object System.Threading.Mutex($false, "codex-session-history-$safeSessionId")
    $lockAcquired = $false

    try {
        try {
            $lockAcquired = $mutex.WaitOne(10000)
        }
        catch [System.Threading.AbandonedMutexException] {
            $lockAcquired = $true
        }
        if (-not $lockAcquired) {
            Write-HookError "could not acquire history lock for session=$sessionId turn=$turnId"
            exit 0
        }

        New-Item -ItemType Directory -Force -Path $workspaceRoot | Out-Null
        if (-not (Test-Path -LiteralPath $markdownPath)) {
            [System.IO.File]::WriteAllText($markdownPath, (New-SessionDocumentHeader -Workspace $resolvedWorkspace -SessionId $sessionId), $utf8NoBom)
        }

        $existing = [System.IO.File]::ReadAllText($markdownPath)
        if (-not $existing.Contains($marker)) {
            $imageReferences = Save-TurnImages -ImageUrls $images -ImageRoot $imageRoot -TurnId $safeTurnId
            $userContent = @((ConvertTo-RenderableMarkdownBlock -Text $prompt -Role 'user'))
            if (@($imageReferences).Count -gt 0) {
                $userContent += ''
                $userContent += $imageReferences
            }
            $userContentText = $userContent -join "`r`n"
            $entry = @(
                '',
                $marker,
                '',
                "## Turn $safeTurnId",
                '',
                '### User',
                '',
                $userContentText,
                '',
                '### Agent',
                '',
                (ConvertTo-RenderableMarkdownBlock -Text $answer -Role 'agent'),
                ''
            ) -join "`r`n"
            [System.IO.File]::AppendAllText($markdownPath, $entry, $utf8NoBom)
        }

        Ensure-SearchIndexEntry `
            -WorkspaceRoot $workspaceRoot `
            -Workspace $resolvedWorkspace `
            -SessionId $sessionId `
            -TurnId $safeTurnId `
            -MarkdownPath $markdownPath `
            -Prompt $prompt `
            -Answer $answer `
            -Encoding $utf8NoBom

        if (Test-Path -LiteralPath $cachePath) {
            Remove-Item -LiteralPath $cachePath -Force
        }
    }
    finally {
        if ($lockAcquired) {
            $mutex.ReleaseMutex()
        }
        $mutex.Dispose()
    }
}
catch {
    Write-HookError $_.Exception.Message
}

exit 0
