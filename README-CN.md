# Shadow Git 本地回合快照

Shadow Git 用于为 AI 编码会话保存本地快照。它会将每个用户指令完成后的工作区状态写入一个独立的 Git 仓库，不会向原项目的远程仓库发送内容，也不应修改原项目的提交历史、分支或索引。

## 环境要求

- Windows PowerShell 5.1 或 PowerShell 7+
- 已安装 Git for Windows，且 `git` 已加入 `PATH`
- 需要记录的目录位于一个 Git 仓库内

无需登录、网络访问或安装额外依赖。

## 快速开始

在需要记录的项目目录中执行以下命令。将 `E:\ShadowGit` 替换为本工具所在的实际路径。

```powershell
# 创建独立的 Shadow Git 仓库及基线快照 turn/0001
powershell -ExecutionPolicy Bypass -File E:\ShadowGit\shadow-git.ps1 init -Project .

# 完成一条 AI 指令后，保存当前工作区快照
powershell -ExecutionPolicy Bypass -File E:\ShadowGit\shadow-git.ps1 snapshot -Message "回合 1：新增登录页" -Project .

# 下一条 AI 指令完成后再次保存
powershell -ExecutionPolicy Bypass -File E:\ShadowGit\shadow-git.ps1 snapshot -Message "回合 2：校验登录页" -Project .

# 查看两个回合之间的差异
powershell -ExecutionPolicy Bypass -File E:\ShadowGit\shadow-git.ps1 diff -From 0002 -To 0003 -Project .

# 列出所有快照及本地提交 ID
powershell -ExecutionPolicy Bypass -File E:\ShadowGit\shadow-git.ps1 list -Project .
```

`init` 会创建 `turn/0001` 基线快照。默认快照目录为项目外的
`E:\ShadowGitRepo\<项目目录名>`；可以通过 `-Store` 指定其他本地目录。

## 命令说明

| 命令 | 作用 |
| --- | --- |
| `init` | 初始化 Shadow Git 仓库；首次运行时创建基线快照。 |
| `snapshot` | 将当前工作区保存为新的回合快照。可用 `-Message` 指定提交说明。 |
| `list` | 按回合编号列出快照、本地提交 ID、时间和提交说明。 |
| `diff` | 比较两个回合；使用 `-Stat` 可只显示统计信息。 |
| `path` | 输出当前项目使用的 Shadow Git 存储目录。 |

## 与 Agent 集成

在每条用户指令完成后调用一次 `snapshot` 即可。Agent 无需了解 Shadow
Git 仓库的内部实现。若需要自动记录，应该在 Agent 的回合完成事件中调用该命令；仅使用文件监听无法可靠地区分用户指令的边界。

### Codex CLI 自动集成

常规 Codex CLI 可以通过本地 `UserPromptSubmit` 和 `Stop` Hook 自动保存快照，无需自行实现 app-server 客户端。

通过一条命令即可为项目安装这些 Hook：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\shadow-git.ps1 install-codex -Project C:\src\my-project
```

该命令会按需创建基线快照，将缺失的 Shadow Git 和会话历史 Hook 合并到
`%USERPROFILE%\.codex\hooks.json`，并在修改已有配置前创建带时间戳的备份。重复执行不会重复添加已安装的 Hook；完成后请重启 Codex CLI。
请在克隆得到的 Shadow Git 目录中执行该命令。

如需手动安装，请将下列配置合并到 `%USERPROFILE%\.codex\hooks.json` 的顶层 `hooks` 对象中：

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
      },
      {
        "hooks": [
          {
            "type": "command",
            "commandWindows": "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"E:\\ShadowGit\\codex-session-history-prompt.ps1\"",
            "timeout": 5,
            "statusMessage": "Capturing full session prompt"
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
      },
      {
        "hooks": [
          {
            "type": "command",
            "commandWindows": "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"E:\\ShadowGit\\codex-session-history-stop.ps1\"",
            "timeout": 20,
            "statusMessage": "Saving full session history"
          }
        ]
      }
    ]
  }
}
```

`UserPromptSubmit` 会按会话和回合缓存规范化后的原始用户输入，最长 240 个字符。`Stop` Hook 优先读取该缓存，将会话和回合 ID 加入提交说明，然后调用 `snapshot` 并删除缓存。缓存不可用时，它会回退到 Hook payload 中已有的任务描述字段。快照失败会记录在 `%LOCALAPPDATA%\shadow-git-turns\codex-hook-errors.log`，且不会阻断 Codex 会话。

### 完整会话历史

安装命令还会注册两个独立的会话历史 Hook。`codex-session-history-prompt.ps1`
会将完整、未截断的用户输入临时保存到
`%LOCALAPPDATA%\codex-session-history\pending`。回合结束时，
`codex-session-history-stop.ps1` 会从 `%USERPROFILE%\.codex\sessions` 下的会话记录中
找到当前 `turn_id` 对应的 `final_answer`，并将用户输入和 Agent 完整回答追加到：

```text
E:\codex-session-history\<工作空间目录名>\<session-id>.md
```

Markdown 文件头会保留解析后的完整工作空间路径；每个回合带有 `turn_id` 标记，
重复触发 `Stop` 不会重复写入。历史记录错误会写入
`%LOCALAPPDATA%\codex-session-history\hook-errors.log`，不会阻断 Codex。
User 和 Agent 正文以原生 Markdown 保存，并由不可见的 HTML 注释标记内容边界；
标题、列表、链接和正文自己的代码块可由 Markdown 查看器正常渲染。
图片会保存到工作空间目录的 `_images` 子目录，并由 Markdown 通过相对路径引用。
会话历史 Hook 不会改变 Shadow Git 快照。

#### 快速检索

现有存储结构保持不变：每个 session 仍对应一个 Markdown 文件，每个 turn
仍由文件内的 `turn_id` 标记定位。Stop Hook 同时在工作空间目录维护旁路索引：

```text
E:\codex-session-history\<工作空间目录名>\_index.jsonl
```

索引每行对应一个 turn，包含工作空间、session ID、turn ID、Markdown 文件名、
完整用户输入和 Agent 最终回答。Markdown 是主记录，索引可随时删除并重建。

按关键词检索全部工作空间：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File E:\ShadowGit\search-codex-session-history.ps1 -Query "写入失败"
```

限定工作空间、session 和返回数量：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File E:\ShadowGit\search-codex-session-history.ps1 `
  -Query "图片" -Workspace C:\src\my-project -SessionId <session-id> -Limit 20
```

默认结果包含用户和 Agent 文本预览、turn ID 以及可直接打开的 `MarkdownPath`。
使用 `-Full` 可返回完整文本。首次启用索引或需要修复索引时，从现有 Markdown 重建：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File E:\ShadowGit\rebuild-codex-session-history-index.ps1
```

也可以用 `-Workspace C:\src\my-project` 只重建一个工作空间。重建会覆盖对应的
`_index.jsonl`，不会修改 session Markdown 或 `_images`。

旧记录若仍将整个 User/Agent 正文包在代码块中，可在重建索引的同时迁移为可渲染格式：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File E:\ShadowGit\rebuild-codex-session-history-index.ps1 -RenderMarkdown
```

迁移只替换旧的最外层代码块，保留 session、turn、正文和图片引用；脚本会在校验
迁移前后 turn 数与正文一致后，以同目录临时文件原子替换原文件。可先加 `-WhatIf`
查看待处理文件，或配合 `-Workspace` 仅迁移一个工作空间。

#### 安装步骤

1. 对每个需要记录的项目运行一次安装命令：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\shadow-git.ps1 install-codex -Project C:\src\my-project
```

2. 安装命令会按需初始化本地基线，创建不存在的 `%USERPROFILE%\.codex\hooks.json`，保留已有 Hook，并在修改已有配置前创建带时间戳的备份。

3. 重启 Codex CLI。之后每次提交用户输入时会先记录原始 prompt，回合结束时由两个 `Stop` Hook 分别创建快照并追加会话历史。

#### 验证安装

使用临时会话和回合 ID 执行以下命令，可以同时验证两个 Hook，并确认 Stop Hook 使用了缓存的原始用户输入：

```powershell
$promptPayload = '{"hook_event_name":"UserPromptSubmit","prompt":"verify shadow hook write","session_id":"shadow-test","turn_id":"1"}'
$promptPayload | powershell -NoProfile -ExecutionPolicy Bypass -File E:\ShadowGit\codex-shadow-prompt.ps1

$stopPayload = '{"hook_event_name":"Stop","cwd":"C:\\src\\my-project","session_id":"shadow-test","turn_id":"1"}'
$stopPayload | powershell -NoProfile -ExecutionPolicy Bypass -File E:\ShadowGit\codex-shadow-stop.ps1

powershell -NoProfile -ExecutionPolicy Bypass -File E:\ShadowGit\shadow-git.ps1 list -Project C:\src\my-project
```

将 `C:\src\my-project` 替换为第 1 步已安装的仓库。最后一条命令应显示新的回合，提交说明中包含 `task=verify shadow hook write`。Stop Hook 成功后会删除 `%LOCALAPPDATA%\shadow-git-turns\prompts` 中对应的临时 prompt 文件。

会话历史集成提供了自动化回归测试：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File E:\ShadowGit\tests\verify-codex-session-history-hooks.ps1
```

### 何时使用 app-server 客户端

Codex CLI 0.147.0 提供实验性的 JSON-RPC app-server 协议。只有在开发自己的 Codex UI 或会话宿主时，才需要通过客户端监听 `turn/completed` 并调用同一条快照命令；普通 Codex CLI 使用者无需采用该方式。

快照通过独立的 `GIT_DIR`、`GIT_WORK_TREE` 和 `GIT_INDEX_FILE` 工作，目标项目的 `.git/index` 不会被用作 Shadow Git 的索引。

## 使用 Fork 查看差异

安装 [Fork](https://git-fork.com/) 后，运行 `path` 获取 Shadow Git 存储路径，并在 Fork 中打开该路径下的 `repo` 目录。仓库包含 `turn-0001`、`turn-0002` 等本地标签；选择两个标签后即可使用 Fork 的提交比较或差异视图。该流程不需要账户或远程仓库。

若使用挂在 `shadow` 分支上的 linked worktree 进行可视化审阅，每次有内容变化的快照都会将该 worktree 同步到新提交，新增和删除文件不会持续堆积在 Changes 列表中。该 worktree 应仅用于审阅，同步时会将其重置到最新影子快照。

## 安全说明

- Shadow Git 仓库仅保存在本地，且不配置远程地址。
- 快照可能包含源代码和未跟踪文件；请保护好本地存储目录，避免把密钥或大型生成文件纳入快照。
- 默认暂存行为遵循目标项目的 `.gitignore` 规则。
- 会话历史 Markdown 和 `_index.jsonl` 会保存完整用户输入和 Agent 最终回答，其中可能含有凭据、个人信息或专有源码。请限制 `E:\codex-session-history` 的访问权限；不要将该目录加入项目仓库或上传，除非已单独完成内容审查。
