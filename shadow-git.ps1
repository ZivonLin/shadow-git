[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('help', 'init', 'snapshot', 'diff', 'list', 'path', 'install-codex')]
    [string]$Command = 'help',

    [string]$Project = (Get-Location).Path,
    [string]$Store,
    [string]$Message,
    [string]$From,
    [string]$To,
    [switch]$Stat
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:ToolRoot = Split-Path -Parent $PSCommandPath

function Get-ProjectRoot {
    param([string]$Path)

    $candidate = (Resolve-Path -LiteralPath $Path).Path
    $root = & git -C $candidate rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($root -join ''))) {
        throw "Project is not inside a Git repository: $candidate"
    }

    return (Resolve-Path -LiteralPath (($root -join '').Trim())).Path
}

function Get-DefaultStore {
    param([string]$Root)

    $name = [System.IO.Path]::GetFileName($Root)
    if ([string]::IsNullOrWhiteSpace($name)) {
        $name = 'project'
    }

    return Join-Path 'E:\ShadowGitRepo' $name
}

function Set-ShadowPaths {
    param([string]$Root, [string]$StorePath)

    $script:ProjectRoot = $Root
    $script:StoreRoot = (New-Item -ItemType Directory -Force -Path $StorePath).FullName
    $script:ShadowRepo = Join-Path $script:StoreRoot 'repo'
    $script:ShadowGit = Join-Path $script:ShadowRepo '.git'
    $script:ShadowIndex = Join-Path $script:StoreRoot 'index'
}

function Invoke-ShadowGit {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $oldGitDir = $env:GIT_DIR
    $oldWorkTree = $env:GIT_WORK_TREE
    $oldIndex = $env:GIT_INDEX_FILE

    try {
        $env:GIT_DIR = $script:ShadowGit
        $env:GIT_WORK_TREE = $script:ProjectRoot
        $env:GIT_INDEX_FILE = $script:ShadowIndex

        Push-Location $script:ProjectRoot
        try {
            $previousErrorActionPreference = $ErrorActionPreference
            $gitExitCode = 0
            try {
                $ErrorActionPreference = 'Continue'
                $output = & git @Arguments 2>&1
                $gitExitCode = $LASTEXITCODE
            }
            finally {
                $ErrorActionPreference = $previousErrorActionPreference
            }
            if ($gitExitCode -ne 0) {
                throw (($output | Out-String).Trim())
            }
            return $output
        }
        finally {
            Pop-Location
        }
    }
    finally {
        $env:GIT_DIR = $oldGitDir
        $env:GIT_WORK_TREE = $oldWorkTree
        $env:GIT_INDEX_FILE = $oldIndex
    }
}

function Invoke-ShadowGitText {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    return ((Invoke-ShadowGit -Arguments $Arguments) -join [Environment]::NewLine).Trim()
}

function Test-ShadowInitialized {
    return (Test-Path -LiteralPath $script:ShadowGit)
}

function Get-ShadowHead {
    if (-not (Test-ShadowInitialized)) {
        return $null
    }

    $oldGitDir = $env:GIT_DIR
    $oldWorkTree = $env:GIT_WORK_TREE
    $oldIndex = $env:GIT_INDEX_FILE
    try {
        $env:GIT_DIR = $script:ShadowGit
        $env:GIT_WORK_TREE = $script:ProjectRoot
        $env:GIT_INDEX_FILE = $script:ShadowIndex
        $value = & git rev-parse --verify --quiet refs/heads/shadow 2>$null
        if ($LASTEXITCODE -ne 0) {
            return $null
        }
        return ($value -join '').Trim()
    }
    finally {
        $env:GIT_DIR = $oldGitDir
        $env:GIT_WORK_TREE = $oldWorkTree
        $env:GIT_INDEX_FILE = $oldIndex
    }
}

function Initialize-Shadow {
    if (Test-ShadowInitialized) {
        & git -C $script:ShadowRepo config core.longpaths true
        return
    }

    New-Item -ItemType Directory -Force -Path $script:StoreRoot | Out-Null
    & git init --quiet $script:ShadowRepo
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to initialize shadow repository: $script:ShadowRepo"
    }

    & git -C $script:ShadowRepo config user.name 'Shadow Git'
    & git -C $script:ShadowRepo config user.email 'shadow-git@localhost'
    & git -C $script:ShadowRepo config remote.pushDefault ''
    & git -C $script:ShadowRepo config core.longpaths true

    $exclude = Join-Path $script:ShadowGit 'info\exclude'
    if (-not (Test-Path -LiteralPath $exclude)) {
        New-Item -ItemType File -Force -Path $exclude | Out-Null
    }
    $existing = Get-Content -LiteralPath $exclude -ErrorAction SilentlyContinue
    if ($existing -notcontains '.git/') {
        Add-Content -LiteralPath $exclude -Value '.git/'
    }
}

function Get-NextTurnId {
    $refs = Invoke-ShadowGitText -Arguments @('for-each-ref', 'refs/turn', '--format=%(refname:short)')
    $count = @($refs -split "`r?`n" | Where-Object { $_ -match '^turn/\d+$' }).Count
    return ($count + 1).ToString('0000')
}

function Resolve-TurnRef {
    param([string]$Value, [switch]$Latest)

    if ($Latest) {
        $refs = Invoke-ShadowGitText -Arguments @('for-each-ref', 'refs/turn', '--sort=-refname', '--format=%(refname:short)')
        $latest = @($refs -split "`r?`n" | Where-Object { $_ }) | Select-Object -First 1
        if (-not $latest) {
            throw 'No snapshots exist yet.'
        }
        return $latest
    }

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw 'A turn ref is required.'
    }

    if ($Value -match '^\d+$') {
        return "turn/$($Value.PadLeft(4, '0'))"
    }
    if ($Value -notmatch '/') {
        return "turn/$Value"
    }
    return $Value
}

function Save-Snapshot {
    param([string]$SnapshotMessage)

    Initialize-Shadow
    Invoke-ShadowGit -Arguments @('add', '-A', '--', '.', ':!.git') | Out-Null

    $tree = Invoke-ShadowGitText -Arguments @('write-tree')
    $parent = Get-ShadowHead
    $turn = Get-NextTurnId
    if ([string]::IsNullOrWhiteSpace($SnapshotMessage)) {
        $SnapshotMessage = "turn $turn"
    }

    $commitArgs = @('commit-tree', $tree)
    if ($parent) {
        $commitArgs += @('-p', $parent)
    }
    $commitArgs += @('-m', $SnapshotMessage)
    $commit = Invoke-ShadowGitText -Arguments $commitArgs

    if ($parent) {
        Invoke-ShadowGit -Arguments @('update-ref', 'refs/heads/shadow', $commit, $parent) | Out-Null
    }
    else {
        Invoke-ShadowGit -Arguments @('update-ref', 'refs/heads/shadow', $commit) | Out-Null
    }
    Invoke-ShadowGit -Arguments @('update-ref', "refs/turn/$turn", $commit) | Out-Null
    Invoke-ShadowGit -Arguments @('update-ref', "refs/tags/turn-$turn", $commit) | Out-Null

    [PSCustomObject]@{
        Turn = $turn
        Ref = "turn/$turn"
        Commit = $commit
        Message = $SnapshotMessage
        Store = $script:StoreRoot
    }
}

function Show-Snapshots {
    Initialize-Shadow
    $lines = Invoke-ShadowGitText -Arguments @('for-each-ref', 'refs/turn', '--sort=refname', '--format=%(refname:short)|%(objectname:short)|%(creatordate:iso8601)|%(subject)')
    if ([string]::IsNullOrWhiteSpace($lines)) {
        Write-Output 'No snapshots.'
        return
    }
    $lines -split "`r?`n" | Where-Object { $_ } | ForEach-Object { Write-Output $_ }
}

function Show-Diff {
    param([string]$FromValue, [string]$ToValue, [switch]$Summary)

    Initialize-Shadow
    $fromRef = Resolve-TurnRef -Value $FromValue
    $toRef = if ([string]::IsNullOrWhiteSpace($ToValue)) {
        Resolve-TurnRef -Latest
    }
    else {
        Resolve-TurnRef -Value $ToValue
    }

    $args = @('diff', '--no-ext-diff', '--binary')
    if ($Summary) {
        $args += '--stat'
    }
    $args += @($fromRef, $toRef)
    Invoke-ShadowGit -Arguments $args | ForEach-Object { Write-Output $_ }
}

function Ensure-ShadowBaseline {
    Initialize-Shadow
    if (-not (Get-ShadowHead)) {
        return Save-Snapshot -SnapshotMessage 'baseline'
    }
    return $null
}

function Get-CodexHooksPath {
    if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        throw 'USERPROFILE is not set; cannot locate the Codex hooks configuration.'
    }
    return Join-Path (Join-Path $env:USERPROFILE '.codex') 'hooks.json'
}

function Read-CodexHooksConfiguration {
    param([string]$HooksPath)

    $hadExistingFile = Test-Path -LiteralPath $HooksPath
    if ($hadExistingFile) {
        $raw = Get-Content -LiteralPath $HooksPath -Raw
        if ([string]::IsNullOrWhiteSpace($raw)) {
            $configuration = [PSCustomObject]@{}
        }
        else {
            try {
                $configuration = $raw | ConvertFrom-Json
            }
            catch {
                throw "Cannot parse existing Codex hooks configuration: $HooksPath"
            }
        }
    }
    else {
        $configuration = [PSCustomObject]@{}
    }

    if ($configuration -is [System.Array] -or $null -eq $configuration) {
        throw "Codex hooks configuration must contain a JSON object: $HooksPath"
    }

    $hooksProperty = $configuration.PSObject.Properties['hooks']
    if (-not $hooksProperty) {
        $configuration | Add-Member -NotePropertyName 'hooks' -NotePropertyValue ([PSCustomObject]@{})
    }
    elseif ($null -eq $hooksProperty.Value) {
        $hooksProperty.Value = [PSCustomObject]@{}
    }
    elseif ($hooksProperty.Value -isnot [PSCustomObject]) {
        throw "The hooks property must be a JSON object: $HooksPath"
    }

    return [PSCustomObject]@{
        Configuration = $configuration
        HadExistingFile = $hadExistingFile
    }
}

function Test-CodexCommandHook {
    param(
        [object]$Configuration,
        [string]$EventName,
        [string]$CommandWindows
    )

    $eventProperty = $Configuration.hooks.PSObject.Properties[$EventName]
    if (-not $eventProperty) {
        return $false
    }

    foreach ($registration in @($eventProperty.Value)) {
        if ($null -eq $registration) {
            continue
        }
        $registeredHooks = $registration.PSObject.Properties['hooks']
        if (-not $registeredHooks) {
            continue
        }
        foreach ($hook in @($registeredHooks.Value)) {
            if ($null -eq $hook) {
                continue
            }
            $type = $hook.PSObject.Properties['type']
            $command = $hook.PSObject.Properties['commandWindows']
            if ($type -and $command -and $type.Value -eq 'command' -and $command.Value -eq $CommandWindows) {
                return $true
            }
        }
    }
    return $false
}

function Add-CodexCommandHook {
    param(
        [object]$Configuration,
        [string]$EventName,
        [string]$CommandWindows,
        [int]$Timeout,
        [string]$StatusMessage
    )

    $registration = [PSCustomObject]@{
        hooks = @(
            [PSCustomObject]@{
                type = 'command'
                commandWindows = $CommandWindows
                timeout = $Timeout
                statusMessage = $StatusMessage
            }
        )
    }
    $eventProperty = $Configuration.hooks.PSObject.Properties[$EventName]
    if ($eventProperty) {
        $eventProperty.Value = @($eventProperty.Value) + $registration
    }
    else {
        $Configuration.hooks | Add-Member -NotePropertyName $EventName -NotePropertyValue @($registration)
    }
}

function Install-CodexHooks {
    $baseline = Ensure-ShadowBaseline
    if ($baseline) {
        Write-Output "Created baseline $($baseline.Ref) at $($baseline.Store)"
    }

    $hooksPath = Get-CodexHooksPath
    $hooksDirectory = Split-Path -Parent $hooksPath
    New-Item -ItemType Directory -Force -Path $hooksDirectory | Out-Null
    $state = Read-CodexHooksConfiguration -HooksPath $hooksPath
    $promptCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $script:ToolRoot 'codex-shadow-prompt.ps1')`""
    $stopCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $script:ToolRoot 'codex-shadow-stop.ps1')`""
    $addedEvents = @()

    if (-not (Test-CodexCommandHook -Configuration $state.Configuration -EventName 'UserPromptSubmit' -CommandWindows $promptCommand)) {
        Add-CodexCommandHook -Configuration $state.Configuration -EventName 'UserPromptSubmit' -CommandWindows $promptCommand -Timeout 5 -StatusMessage 'Capturing original user prompt'
        $addedEvents += 'UserPromptSubmit'
    }
    if (-not (Test-CodexCommandHook -Configuration $state.Configuration -EventName 'Stop' -CommandWindows $stopCommand)) {
        Add-CodexCommandHook -Configuration $state.Configuration -EventName 'Stop' -CommandWindows $stopCommand -Timeout 20 -StatusMessage 'Saving local shadow snapshot'
        $addedEvents += 'Stop'
    }

    if ($addedEvents.Count -eq 0) {
        Write-Output "Codex hooks are already installed: $hooksPath"
        return
    }

    $backupPath = $null
    if ($state.HadExistingFile) {
        $backupPath = "$hooksPath.backup-$(Get-Date -Format 'yyyyMMddHHmmss')"
        Copy-Item -LiteralPath $hooksPath -Destination $backupPath
    }
    $state.Configuration | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $hooksPath -Encoding utf8

    Write-Output "Installed Codex hooks: $($addedEvents -join ', ')"
    Write-Output "Configuration: $hooksPath"
    if ($backupPath) {
        Write-Output "Backup: $backupPath"
    }
    Write-Output 'Restart Codex CLI to load the updated hooks.'
}

if ($Command -eq 'help') {
    Write-Output @'
Local shadow Git snapshots

Commands:
  init      Create the local shadow repository and a baseline snapshot.
  snapshot  Save the current working tree as the next turn snapshot.
  diff      Compare two snapshots: -From 0001 -To 0002 (To defaults to latest).
  list      List all snapshots.
  path      Print the local shadow repository path.
  install-codex  Initialize the project and install Codex CLI hooks.

Examples:
  .\shadow-git.ps1 init -Project .
  .\shadow-git.ps1 snapshot -Message "implement login"
  .\shadow-git.ps1 diff -From 0001 -To 0002
  .\shadow-git.ps1 install-codex -Project .
'@
    exit 0
}

$script:ProjectRoot = Get-ProjectRoot -Path $Project
if ([string]::IsNullOrWhiteSpace($Store)) {
    $Store = Get-DefaultStore -Root $script:ProjectRoot
}
Set-ShadowPaths -Root $script:ProjectRoot -StorePath $Store

switch ($Command) {
    'init' {
        $result = Ensure-ShadowBaseline
        if ($result) {
            Write-Output "Created baseline $($result.Ref) at $($result.Store)"
        }
        else {
            Write-Output "Shadow repository already initialized: $($script:StoreRoot)"
        }
    }
    'snapshot' {
        $result = Save-Snapshot -SnapshotMessage $Message
        Write-Output "$($result.Ref) $($result.Commit) $($result.Message)"
    }
    'diff' {
        Show-Diff -FromValue $From -ToValue $To -Summary:$Stat
    }
    'list' {
        Show-Snapshots
    }
    'path' {
        Initialize-Shadow
        Write-Output $script:StoreRoot
    }
    'install-codex' {
        Install-CodexHooks
    }
}
