# Security Policy

## What this repo contains

A PowerShell bootstrap script (`Install.ps1`) and supporting docs that install
the MortgageTech development environment on a Windows workstation.

## What this repo does NOT contain

- API keys, tokens, passwords, certificates, or any other secret
- Loan data, borrower PII, or client-confidential information
- Internal hostnames or private endpoints (the brain URL is public)

## Why it is public

`Install.ps1` is invoked via `iwr | iex` and must be reachable without
authentication. The script itself contains no credentials. The TeamAI Brain
API key is **prompted at runtime** and stored only in the user's local
`%APPDATA%\Code\User\mcp.json` — never in this repo.

## Reporting

Email steve at mortgagetech dot com. Do not open public issues.

## Practices enforced on this repo

- Branch protection on `main` (PR + 1 review required)
- Secret scanning + push protection enabled
- No force-push, no branch deletion
- Conversation resolution required on PRs

@wbx-modified copilot-a3f7·MTN | 2026-04-21
