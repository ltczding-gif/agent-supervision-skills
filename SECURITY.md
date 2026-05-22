# Security Policy

## Supported Versions

Security fixes are accepted for the current `main` branch.

## Reporting a Vulnerability

If GitHub Security Advisories are enabled for this repository, please use a private advisory. Otherwise, open a minimal public issue asking for a private maintainer contact without including exploit details, secrets, or sensitive logs.

Please include:

- affected skill folder
- affected script or documentation path
- impact summary
- reproduction steps that do not expose private credentials
- suggested mitigation, if known

## Sensitive Data Policy

Do not include any of the following in issues, pull requests, screenshots, or logs:

- API keys, OAuth tokens, refresh tokens, cookies, or personal access tokens
- full local session transcripts containing private user prompts
- `.env` files or native CLI auth stores
- private repository names, customer data, or unpublished research data

## Threat Model Summary

These skills supervise local CLIs. They do not turn untrusted agent output into trusted truth. Callers must still inspect artifacts, verify claims, and constrain file or token access for sensitive work.

See [docs/SECURITY_MODEL.md](docs/SECURITY_MODEL.md) for details.
