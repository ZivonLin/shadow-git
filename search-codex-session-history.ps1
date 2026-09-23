[CmdletBinding()]
param(
    [string]$HistoryRoot = 'E:\codex-session-history',
    [string]$Query = '',
    [string]$Workspace = '',
    [string]$SessionId = '',
    [int]$Limit = 50,
    [switch]$Full
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-SafeWorkspaceName {
    param([string]$Value)

    $name = [System.IO.Path]::GetFileName($Value.TrimEnd('\'))
    if ([string]::IsNullOrWhiteSpace($name)) {
        $name = 'workspace'
    }
    return ($name -replace '[\\/:*?"<>|]', '_')
}

function Get-Preview {
    param(
        [string]$Text,
        [int]$MaxLength = 240
    )

    $preview = ($Text -replace '\s+', ' ').Trim()
    if ($preview.Length -gt $MaxLength) {
        return $preview.Substring(0, $MaxLength - 3) + '...'
    }
    return $preview
}

function Get-ResultTimestamp {
    param(
        [string]$TurnId,
        [string]$IndexedAt
    )

    $match = [regex]::Match($TurnId, '^(?<high>[0-9A-Fa-f]{8})-(?<low>[0-9A-Fa-f]{4})-7[0-9A-Fa-f]{3}-')
    if ($match.Success) {
        try {
            $milliseconds = [System.Convert]::ToInt64($match.Groups['high'].Value + $match.Groups['low'].Value, 16)
            return [System.DateTimeOffset]::FromUnixTimeMilliseconds($milliseconds).ToUniversalTime().ToString('o')
        }
        catch {
            # Fall back to the index timestamp for nonstandard IDs.
        }
    }
    return $IndexedAt
}

if ($Limit -lt 1) {
    $Limit = 50
}
if (-not (Test-Path -LiteralPath $HistoryRoot)) {
    exit 0
}

if ([string]::IsNullOrWhiteSpace($Workspace)) {
    $indexFiles = Get-ChildItem -LiteralPath $HistoryRoot -Recurse -File -Filter '_index.jsonl'
}
else {
    $workspaceFolder = Get-SafeWorkspaceName -Value $Workspace
    $workspaceRoot = Join-Path $HistoryRoot $workspaceFolder
    $indexPath = Join-Path $workspaceRoot '_index.jsonl'
    $indexFiles = if (Test-Path -LiteralPath $indexPath) { @(Get-Item -LiteralPath $indexPath) } else { @() }
}

$results = [System.Collections.Generic.List[object]]::new()
foreach ($indexFile in $indexFiles) {
    $reader = $null
    try {
        $reader = [System.IO.StreamReader]::new(
            $indexFile.FullName,
            [System.Text.UTF8Encoding]::new($false, $true),
            $true
        )
        while ($null -ne ($line = $reader.ReadLine())) {
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }
            try {
                $entry = $line | ConvertFrom-Json
            }
            catch {
                continue
            }

            $entrySessionId = if ($entry.PSObject.Properties['session_id']) { [string]$entry.session_id } else { '' }
            if (-not [string]::IsNullOrWhiteSpace($SessionId) -and $entrySessionId -cne $SessionId) {
                continue
            }

            $user = if ($entry.PSObject.Properties['user']) { [string]$entry.user } else { '' }
            $agent = if ($entry.PSObject.Properties['agent']) { [string]$entry.agent } else { '' }
            if (-not [string]::IsNullOrWhiteSpace($Query)) {
                $searchText = $user + "`n" + $agent
                if ($searchText.IndexOf($Query, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
                    continue
                }
            }

            $markdownName = if ($entry.PSObject.Properties['markdown']) { [string]$entry.markdown } else { '' }
            $entryTurnId = if ($entry.PSObject.Properties['turn_id']) { [string]$entry.turn_id } else { '' }
            $indexedAt = if ($entry.PSObject.Properties['indexed_at']) { [string]$entry.indexed_at } else { '' }
            $result = [ordered]@{
                Timestamp = Get-ResultTimestamp -TurnId $entryTurnId -IndexedAt $indexedAt
                Workspace = if ($entry.PSObject.Properties['workspace']) { [string]$entry.workspace } else { '' }
                SessionId = $entrySessionId
                TurnId = $entryTurnId
                MarkdownPath = Join-Path $indexFile.DirectoryName $markdownName
                UserPreview = Get-Preview -Text $user
                AgentPreview = Get-Preview -Text $agent
            }
            if ($Full) {
                $result.User = $user
                $result.Agent = $agent
            }
            $results.Add([PSCustomObject]$result)
        }
    }
    finally {
        if ($reader) {
            $reader.Dispose()
        }
    }
}

$results |
    Sort-Object Timestamp -Descending |
    Select-Object -First $Limit
