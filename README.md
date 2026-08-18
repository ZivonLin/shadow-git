# Local Shadow Git Turns

This is a local-only snapshot tool for AI coding sessions. It stores each
instruction result in a separate Git repository and leaves the real project's
Git history, branch, and index untouched.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7+
- Git for Windows on `PATH`
- A target directory inside a Git repository

No remote, login, network access, or package installation is required.

## Quick start

Run these commands from the project you want to observe:

```powershell
powershell -ExecutionPolicy Bypass -File E:\ShadowGit\shadow-git.ps1 init -Project .

# Run one AI instruction, then snapshot its result:
powershell -ExecutionPolicy Bypass -File E:\ShadowGit\shadow-git.ps1 snapshot -Message "turn 1: add login form" -Project .

# After the next instruction:
powershell -ExecutionPolicy Bypass -File E:\ShadowGit\shadow-git.ps1 snapshot -Message "turn 2: validate login form" -Project .

# See only the changes made by turn 2:
powershell -ExecutionPolicy Bypass -File E:\ShadowGit\shadow-git.ps1 diff -From 0002 -To 0003 -Project .

# List snapshots and their local commit ids:
powershell -ExecutionPolicy Bypass -File E:\ShadowGit\shadow-git.ps1 list -Project .
```

`init` creates `turn/0001` as the baseline. The default snapshot store is
outside the project at `E:\ShadowGitRepo\<project-name>`. Use `-Store` to
choose another local path.

## How to integrate with an agent

Call `snapshot` once after each user instruction finishes. The agent process
does not need to know about the shadow repository. For a fully automatic
integration, call the same command from the agent SDK's turn-complete event.
A file watcher alone cannot reliably identify user-instruction boundaries.

### Automatic Codex CLI integration

For the normal Codex CLI, use a local `UserPromptSubmit` hook together with the
`Stop` hook instead of building an app-server client. Install both hooks for a
project with one command:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\shadow-git.ps1 install-codex -Project C:\src\my-project
```

The command creates the baseline snapshot when needed, merges only missing
Shadow Git hooks into `%USERPROFILE%\.codex\hooks.json`, and creates a
timestamped backup before changing an existing configuration. It is safe to run
again: installed hooks are not duplicated. Run it from the cloned Shadow Git
directory, then restart Codex CLI after it finishes.

For a manual installation, add these entries to `%USERPROFILE%\.codex\hooks.json`
and merge them with any existing hooks:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "commandWindows": "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"E:\\ShadowGit\\codex-shadow-prompt.ps1\"",
            "timeout": 5,
            "statusMessage": "Capturing original user prompt"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "commandWindows": "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"E:\\ShadowGit\\codex-shadow-stop.ps1\"",
            "timeout": 20,
            "statusMessage": "Saving local shadow snapshot"
          }
        ]
      }
    ]
  }
}
```

Codex sends the hook payload on stdin. `UserPromptSubmit` caches the normalized,
240-character user prompt by session and turn. The Stop adapter consumes that
prompt first, adds the session/turn identifiers, invokes `snapshot` once, then
removes the cache file. If the prompt cache is unavailable, it falls back to the
existing task-description fields. Snapshot failures are logged to
`%LOCALAPPDATA%\shadow-git-turns\codex-hook-errors.log` and do not block Codex.

#### Installation

1. Run the installer once for every project to be captured:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\shadow-git.ps1 install-codex -Project C:\src\my-project
```

2. The installer initializes the local baseline as needed, creates
   `%USERPROFILE%\.codex\hooks.json` when absent, preserves existing hooks, and
   creates a timestamped backup before modifying an existing configuration.

3. Restart Codex CLI. Each submitted prompt is captured first, then the `Stop`
   hook creates one snapshot when that turn completes.

#### Verification

Run this sequence with a disposable session and turn id. It exercises both
hooks and confirms that the Stop hook uses the cached original prompt:

```powershell
$promptPayload = '{"hook_event_name":"UserPromptSubmit","prompt":"verify shadow hook write","session_id":"shadow-test","turn_id":"1"}'
$promptPayload | powershell -NoProfile -ExecutionPolicy Bypass -File E:\ShadowGit\codex-shadow-prompt.ps1

$stopPayload = '{"hook_event_name":"Stop","cwd":"C:\\src\\my-project","session_id":"shadow-test","turn_id":"1"}'
$stopPayload | powershell -NoProfile -ExecutionPolicy Bypass -File E:\ShadowGit\codex-shadow-stop.ps1

powershell -NoProfile -ExecutionPolicy Bypass -File E:\ShadowGit\shadow-git.ps1 list -Project C:\src\my-project
```

Replace `C:\src\my-project` with the repository initialized in step 1. The
last command should show a new turn whose subject contains
`task=verify shadow hook write`. A successful Stop hook removes its temporary
prompt file from `%LOCALAPPDATA%\shadow-git-turns\prompts`.

### When an app-server client is appropriate

Codex CLI 0.147.0 exposes an experimental JSON-RPC app-server protocol. A
custom client can listen for `turn/completed` and call the same snapshot
command. That route is for building your own Codex UI or session host; it is
not needed for the stock CLI.

The snapshot uses a separate `GIT_DIR`, `GIT_WORK_TREE`, and `GIT_INDEX_FILE`.
The target repository's `.git/index` is never used.

## Visual review with Fork

Install [Fork](https://git-fork.com/) on Windows, then open the `repo` folder
inside the printed shadow store path (run `path` to print it). The shadow
repository has local tags such as `turn-0001` and `turn-0002`; select two tags
in Fork and use its commit comparison/diff view. No account or remote is
needed for this local review.

## Safety notes

- The shadow repository is local and has no configured remote.
- Snapshot contents can include source code and untracked files; protect the
  local store and avoid snapshotting secrets or large generated directories.
- The default staging behavior follows the project's `.gitignore` rules.
