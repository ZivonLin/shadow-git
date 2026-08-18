[CmdletBinding()]
param(
    [string]$SnapshotScript
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($SnapshotScript)) {
    $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
    $SnapshotScript = Join-Path $scriptRoot 'shadow-git.ps1'
}

function Write-HookError {
    param([string]$Text)

    try {
        $logRoot = Join-Path $env:LOCALAPPDATA 'shadow-git-turns'
        New-Item -ItemType Directory -Force -Path $logRoot | Out-Null
        Add-Content -LiteralPath (Join-Path $logRoot 'codex-hook-errors.log') -Value "$(Get-Date -Format o) $Text"
    }
    catch {
        # A snapshot failure must not stop the coding session.
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

function Get-PromptCachePath {
    param(
        [string]$SessionId,
        [string]$TurnId
    )

    if ([string]::IsNullOrWhiteSpace($SessionId) -or [string]::IsNullOrWhiteSpace($TurnId)) {
        return $null
    }

    $safeSessionId = $SessionId -replace '[^A-Za-z0-9._-]', '_'
    $safeTurnId = $TurnId -replace '[^A-Za-z0-9._-]', '_'
    $cacheRoot = Join-Path (Join-Path $env:LOCALAPPDATA 'shadow-git-turns') 'prompts'
    return Join-Path $cacheRoot "$safeSessionId-$safeTurnId.txt"
}

function Get-CapturedUserPrompt {
    param([object]$Payload)

    $cachePath = Get-PromptCachePath -SessionId (Get-PayloadText -Payload $Payload -Name 'session_id') -TurnId (Get-PayloadText -Payload $Payload -Name 'turn_id')
    if (-not $cachePath -or -not (Test-Path -LiteralPath $cachePath)) {
        return [PSCustomObject]@{ Text = ''; CachePath = $null }
    }

    return [PSCustomObject]@{
        Text = (Get-Content -LiteralPath $cachePath -Raw).Trim()
        CachePath = $cachePath
    }
}

function Get-TaskDescription {
    param([object]$Payload)

    foreach ($name in @('task_description', 'task', 'description', 'last_user_message', 'user_prompt', 'prompt', 'last_assistant_message')) {
        $value = Get-PayloadText -Payload $Payload -Name $name
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return (($value -replace '\s+', ' ').Trim())
        }
    }
    return ''
}

try {
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) {
        exit 0
    }

    $payload = $raw | ConvertFrom-Json
    $eventProperty = $payload.PSObject.Properties['hook_event_name']
    if ($eventProperty -and $eventProperty.Value -ne 'Stop') {
        exit 0
    }

    $cwdProperty = $payload.PSObject.Properties['cwd']
    $project = if ($cwdProperty) { [string]$cwdProperty.Value } else { '' }
    if ([string]::IsNullOrWhiteSpace($project) -or -not (Test-Path -LiteralPath $project)) {
        exit 0
    }

    $parts = @('Codex turn complete')
    $capturedPrompt = Get-CapturedUserPrompt -Payload $payload
    $description = $capturedPrompt.Text
    if ([string]::IsNullOrWhiteSpace($description)) {
        $description = Get-TaskDescription -Payload $payload
    }
    if ($description.Length -gt 240) {
        $description = $description.Substring(0, 237) + '...'
    }
    if (-not [string]::IsNullOrWhiteSpace($description)) {
        $parts += "task=$description"
    }
    $sessionProperty = $payload.PSObject.Properties['session_id']
    if ($sessionProperty -and $sessionProperty.Value) {
        $parts += "session=$($sessionProperty.Value)"
    }
    $turnProperty = $payload.PSObject.Properties['turn_id']
    if ($turnProperty -and $turnProperty.Value) {
        $parts += "turn=$($turnProperty.Value)"
    }

    try {
        & $SnapshotScript -Command snapshot -Project $project -Message ($parts -join ' ') | Out-Null
        $snapshotExitCode = $LASTEXITCODE
    }
    finally {
        if ($capturedPrompt.CachePath) {
            try {
                Remove-Item -LiteralPath $capturedPrompt.CachePath -Force -ErrorAction Stop
            }
            catch {
                Write-HookError "failed to remove prompt cache: $($_.Exception.Message)"
            }
        }
    }
    if ($snapshotExitCode -ne 0) {
        Write-HookError "snapshot exited with code $snapshotExitCode for $project"
    }
}
catch {
    Write-HookError $_.Exception.Message
}

exit 0
