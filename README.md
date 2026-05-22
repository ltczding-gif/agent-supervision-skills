# Agent Supervision Skills

[English](#agent-supervision-skills) | [中文](#中文版)

Local-first supervision skills for delegating work to another coding agent, collecting its artifacts, and independently verifying the result before trusting it.

This repository packages three standalone skills:

| Skill | Delegates to | Typical caller | Primary use |
| --- | --- | --- | --- |
| `claude-supervision` | Claude Code CLI | Codex, Kimi, scripts, other agents | Ask Claude Code to perform or review work, then inspect its artifacts. |
| `codex-supervision` | Codex CLI | Claude Desktop / Claude Code environments | Ask Codex to review or rescue work from Claude-facing workflows. |
| `kimi-supervision` | Kimi Code CLI | Codex or other local agents | Ask Kimi Code to do local work, recover native output when stdout is incomplete, and classify trust. |

Supervision means the caller does not blindly relay another agent's final text. Each skill writes prompts, responses, stderr, and structured session metadata to disk so a supervising agent can inspect what actually happened.

## Why This Exists

Agent-to-agent handoffs often fail quietly: stdout is empty, the target CLI timed out, a native log contains the real answer, or the delegated agent claims a fix without evidence. These skills add a local supervision layer around those handoffs so the caller can inspect artifacts before trusting the result.

The project is intentionally narrow: it is not a hosted orchestrator or a unified agent API. It is a set of Windows-first PowerShell wrappers for local CLI agents, built around audit trails, recovery paths, and explicit verification.

## Who This Is For

- Windows-first agent-tooling developers who need reliable local CLI delegation.
- Claude Desktop or Claude Code users who want Codex review/rescue workflows without relying on a plugin-only path.
- Local multi-agent power users who compare Claude, Codex, and Kimi on the same task.
- Batch or research workflow authors who need timeout, recovery, and structured artifacts.
- Security-conscious developers who want local, inspectable handoffs instead of blind relays.

See [docs/USE_CASES.md](docs/USE_CASES.md) for detailed personas, pain points, example workflows, and boundaries.

## Repository Layout

```text
.
├── claude-supervision/
│   ├── SKILL.md
│   └── scripts/
├── codex-supervision/
│   ├── SKILL.md
│   └── scripts/
├── kimi-supervision/
│   ├── SKILL.md
│   ├── agents/
│   └── scripts/
├── docs/
│   ├── INSTALLATION.md
│   ├── USE_CASES.md
│   └── SECURITY_MODEL.md
├── .github/
│   ├── ISSUE_TEMPLATE/
│   └── pull_request_template.md
├── AGENTS.md
├── CONTRIBUTING.md
├── SECURITY.md
├── CODE_OF_CONDUCT.md
├── CHANGELOG.md
└── LICENSE
```

Each skill folder is self-contained. You can copy only the folder you need.

## Requirements

These skills are designed and tested for Windows-first local agent workflows.

- Windows with PowerShell 7+ (`pwsh.exe`) is the primary supported environment.
- Other platforms may work only where the target CLI and PowerShell scripts behave compatibly; they are not validated yet.
- A locally installed and authenticated target CLI for the skill you use:
  - `claude-supervision`: Claude Code CLI (`claude`)
  - `codex-supervision`: Codex CLI (`codex`)
  - `kimi-supervision`: Kimi Code CLI (`kimi`)
- Permission to write local session artifacts under the skill's state directory.

The scripts are intentionally local-first and Windows-oriented. They do not provide a hosted service, cloud queue, remote execution environment, or cross-platform compatibility layer.

## Quick Start

Clone or download the repository, then copy the desired skill folder into the skill root used by your agent environment.

For an agent environment that reads from `$env:USERPROFILE\.agents\skills`:

```powershell
$skillRoot = Join-Path $env:USERPROFILE ".agents\skills"
Copy-Item ".\claude-supervision" (Join-Path $skillRoot "claude-supervision") -Recurse
Copy-Item ".\kimi-supervision" (Join-Path $skillRoot "kimi-supervision") -Recurse
```

For Claude environments that read from `$env:USERPROFILE\.claude\skills`:

```powershell
$skillRoot = Join-Path $env:USERPROFILE ".claude\skills"
Copy-Item ".\codex-supervision" (Join-Path $skillRoot "codex-supervision") -Recurse
```

Then open the target skill's `SKILL.md` and run its setup command.

## Safety Notes

- These wrappers store prompts and outputs on disk. Do not run sensitive tasks unless you are comfortable with local artifact retention.
- Use the `*_SUPERVISION_HOME` environment variables documented in each `SKILL.md` to redirect artifacts to a temporary or private directory.
- Do not commit generated `sessions/`, `artifacts/`, logs, `.env` files, or native CLI history.
- Treat outputs from delegated agents as untrusted until inspected by the supervising agent or human reviewer.

For the fuller threat model, see [docs/SECURITY_MODEL.md](docs/SECURITY_MODEL.md).

## Contributing

Small, focused improvements are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request.

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE).

## 中文版

Agent Supervision Skills 是一组本地优先的 Agent 监督技能，用来把任务委托给另一个本地 CLI Agent，同时保存执行产物，并在信任结果之前进行独立验证。

这个仓库目前包含三个独立 skill：

| Skill | 委托目标 | 常见调用方 | 主要用途 |
| --- | --- | --- | --- |
| `claude-supervision` | Claude Code CLI | Codex、Kimi、脚本或其他 Agent | 让 Claude Code 执行任务或审查代码，然后检查它留下的产物。 |
| `codex-supervision` | Codex CLI | Claude Desktop / Claude Code 环境 | 在 Claude 侧调用 Codex 做代码审查、救援诊断或对抗性复核。 |
| `kimi-supervision` | Kimi Code CLI | Codex 或其他本地 Agent | 让 Kimi Code 执行本地任务，在 stdout 不完整时从原生日志恢复输出，并给出可信度分类。 |

这里的 supervision 指的是“监督”，不是盲目转述。调用方不应该直接把另一个 Agent 的最终文本当作事实，而应该读取提示词、响应、stderr、`session.json` 等本地产物，再判断结果是否可信。

### 为什么需要它

Agent 之间互相委托任务时，经常会静默失败：stdout 为空、目标 CLI 超时、真实答案只存在于原生日志里，或者被委托的 Agent 声称修好了问题但没有证据。

这些 skill 在委托边界外加了一层本地监督：

- 保存输入提示、输出响应、stderr 和结构化元数据
- 记录超时、错误、恢复来源和结果分类
- 支持从本地原生日志恢复输出
- 让监督 Agent 或人类在转述之前先检查证据

项目定位很窄：它不是云端编排平台，也不是统一 Agent API。它是一组 Windows-first 的 PowerShell wrapper，围绕本地 CLI Agent 的可追溯委托、恢复和验证而设计。

### 适合谁

- Windows-first 的 Agent 工具开发者，需要可靠地调用本地 CLI Agent。
- Claude Desktop 或 Claude Code 用户，希望在 Claude 工作流里调用 Codex 做审查或救援。
- 本地多 Agent 重度用户，希望比较 Claude、Codex、Kimi 在同一任务上的表现。
- 批处理、研究或文献工作流作者，需要超时控制、失败恢复和结构化产物。
- 安全敏感的开发者或团队，希望保留本地可审计证据，而不是盲目信任另一个 Agent 的最终回答。

更完整的使用场景、痛点和边界见 [docs/USE_CASES.md](docs/USE_CASES.md)。

### 仓库结构

```text
.
├── claude-supervision/
│   ├── SKILL.md
│   └── scripts/
├── codex-supervision/
│   ├── SKILL.md
│   └── scripts/
├── kimi-supervision/
│   ├── SKILL.md
│   ├── agents/
│   └── scripts/
├── docs/
│   ├── INSTALLATION.md
│   ├── USE_CASES.md
│   └── SECURITY_MODEL.md
├── .github/
│   ├── ISSUE_TEMPLATE/
│   └── pull_request_template.md
├── AGENTS.md
├── CONTRIBUTING.md
├── SECURITY.md
├── CODE_OF_CONDUCT.md
├── CHANGELOG.md
└── LICENSE
```

每个 skill 目录都是自包含的。你可以只复制自己需要的那个目录。

### 运行要求

这些 skill 主要面向 Windows 本地 Agent 工作流。

- Windows + PowerShell 7+ (`pwsh.exe`) 是主要支持环境。
- 其他平台也许能运行，但目前没有验证。
- 需要本地安装并登录对应 CLI：
  - `claude-supervision`：Claude Code CLI (`claude`)
  - `codex-supervision`：Codex CLI (`codex`)
  - `kimi-supervision`：Kimi Code CLI (`kimi`)
- 需要允许脚本在本地状态目录写入 session 产物。

### 快速开始

克隆或下载仓库后，把需要的 skill 目录复制到对应 Agent 环境的 skill root。

如果你的 Agent 环境从 `$env:USERPROFILE\.agents\skills` 读取 skill：

```powershell
$skillRoot = Join-Path $env:USERPROFILE ".agents\skills"
Copy-Item ".\claude-supervision" (Join-Path $skillRoot "claude-supervision") -Recurse
Copy-Item ".\kimi-supervision" (Join-Path $skillRoot "kimi-supervision") -Recurse
```

如果你的 Claude 环境从 `$env:USERPROFILE\.claude\skills` 读取 skill：

```powershell
$skillRoot = Join-Path $env:USERPROFILE ".claude\skills"
Copy-Item ".\codex-supervision" (Join-Path $skillRoot "codex-supervision") -Recurse
```

然后打开目标 skill 的 `SKILL.md`，按其中的 setup 命令检查环境。

### 安全说明

- 这些 wrapper 会把提示词和输出写到磁盘。涉及敏感内容时，请先确认你能接受本地产物保留。
- 可以用各 skill 文档中的 `*_SUPERVISION_HOME` 环境变量，把产物重定向到临时目录或私有目录。
- 不要提交生成的 `sessions/`、`artifacts/`、日志、`.env` 文件或原生 CLI 历史。
- 被委托 Agent 的输出在验证前都应视为不可信。

完整威胁模型见 [docs/SECURITY_MODEL.md](docs/SECURITY_MODEL.md)。

### 贡献

欢迎小而聚焦的改进。提交 PR 前请先阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。

### 许可证

本项目使用 MIT License，见 [LICENSE](LICENSE)。
