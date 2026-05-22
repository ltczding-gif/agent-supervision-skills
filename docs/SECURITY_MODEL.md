# Security Model

These skills are local wrappers around agent CLIs. They improve observability and verification, but they are not a sandbox, policy engine, or secret manager.

## Trust Boundaries

The trusted boundary is the supervising human or supervising agent after it has inspected artifacts and verified claims. The delegated agent's output is not trusted by default.

Each skill may write:

- the prompt sent to the target CLI
- the final or recovered response
- stderr or raw JSONL output
- structured session metadata
- pointers to native CLI session files

These artifacts can contain sensitive task context.

## Main Risks

- **Credential exposure:** target CLIs may inherit environment variables or read native auth stores.
- **Prompt injection:** delegated agents may read untrusted repository content and follow malicious instructions.
- **Over-broad file access:** local CLIs can inspect or modify files allowed by their own sandbox and permission configuration.
- **Artifact retention:** prompts and outputs are stored on disk unless redirected or deleted.
- **False confidence:** a successful CLI exit code does not prove the delegated work is correct.

## Recommended Mitigations

- Use read-only modes for review tasks.
- Scope workspaces narrowly.
- Keep tokens out of prompts, issue reports, logs, and screenshots.
- Set `CLAUDE_SUPERVISION_HOME`, `CODEX_SUPERVISION_HOME`, or `KIMI_SUPERVISION_HOME` to an ephemeral directory for sensitive tasks.
- Inspect `session.json`, `stderr.log`, and response artifacts before relaying results.
- Run independent tests or deterministic checks before claiming completion.

## What These Skills Do Not Guarantee

- They do not prevent all prompt injection.
- They do not guarantee target CLI sandbox behavior.
- They do not remove secrets from the target CLI's native logs.
- They do not prove that generated patches are correct.

Use them as supervision scaffolding, not as a substitute for review.
