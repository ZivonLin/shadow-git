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
outside the project at `%LOCALAPPDATA%\shadow-git-turns\...`. Use `-Store`
to choose another local path.

## How to integrate with an agent

Call `snapshot` once after each user instruction finishes. The agent process
does not need to know about the shadow repository. For a fully automatic
integration, call the same command from the agent SDK's turn-complete event.
A file watcher alone cannot reliably identify user-instruction boundaries.

### Automatic Codex CLI integration

For the normal Codex CLI, use a local `UserPromptSubmit` hook together with the
`Stop` hook instead of building an app-server client. Add these entries to
`%USERPROFILE%\.codex\hooks.json` (merge them with any existing hooks):

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

Test the adapter without starting Codex:

```powershell
'{"hook_event_name":"Stop","cwd":"D:\\path\\to\\your\\repo","session_id":"test"}' |
  powershell -NoProfile -ExecutionPolicy Bypass -File E:\\ShadowGit\\codex-shadow-stop.ps1
```

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
