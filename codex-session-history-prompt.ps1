[CmdletBinding()]
param(
    [string]$CacheRoot = (Join-Path $env:LOCALAPPDATA 'codex-session-history\pending')
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
    $cachePath = Get-PromptCachePath -SessionId (Get-PayloadText -Payload $payload -Name 'session_id') -TurnId (Get-PayloadText -Payload $payload -Name 'turn_id')
    if (-not $cachePath) {
        exit 0
    }

    $entry = [PSCustomObject]@{
        prompt = $prompt
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $cachePath) | Out-Null
    Set-Content -LiteralPath $cachePath -Value ($entry | ConvertTo-Json -Compress) -Encoding utf8
}
catch {
    Write-HookError $_.Exception.Message
}

exit 0
