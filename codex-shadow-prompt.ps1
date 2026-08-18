[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-HookError {
    param([string]$Text)

    try {
        $logRoot = Join-Path $env:LOCALAPPDATA 'shadow-git-turns'
        New-Item -ItemType Directory -Force -Path $logRoot | Out-Null
        Add-Content -LiteralPath (Join-Path $logRoot 'codex-hook-errors.log') -Value "$(Get-Date -Format o) $Text"
    }
    catch {
        # A capture failure must not stop the coding session.
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

try {
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) {
        exit 0
    }

    $payload = $raw | ConvertFrom-Json
    if ((Get-PayloadText -Payload $payload -Name 'hook_event_name') -ne 'UserPromptSubmit') {
        exit 0
    }

    $prompt = Get-PayloadText -Payload $payload -Name 'prompt'
    if ([string]::IsNullOrWhiteSpace($prompt)) {
        exit 0
    }

    $prompt = ($prompt -replace '\s+', ' ').Trim()
    if ($prompt.Length -gt 240) {
        $prompt = $prompt.Substring(0, 237) + '...'
    }

    $cachePath = Get-PromptCachePath -SessionId (Get-PayloadText -Payload $payload -Name 'session_id') -TurnId (Get-PayloadText -Payload $payload -Name 'turn_id')
    if (-not $cachePath) {
        exit 0
    }

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $cachePath) | Out-Null
    Set-Content -LiteralPath $cachePath -Value $prompt -Encoding utf8
}
catch {
    Write-HookError $_.Exception.Message
}

exit 0
