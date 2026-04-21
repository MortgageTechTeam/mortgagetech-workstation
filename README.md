# MortgageTech Workstation Bootstrap

One-line install for the full MortgageTech development environment on Windows 10/11.

## What it sets up

- Git, GitHub CLI, Node.js, Azure CLI, PowerShell 7
- Visual Studio Code + extensions (GitHub Copilot, PowerShell, Azure tools, etc.)
- Clones MortgageTech private repos (you sign in once via `gh auth login`)
- Configures the TeamAI Brain MCP server (`mcp.json`)
- Drops workspace prompts for Encompass authoring slash-commands

## How to install

Open **Windows PowerShell** and run:

```powershell
iwr -useb https://raw.githubusercontent.com/MortgageTechTeam/mortgagetech-workstation/main/Install.ps1 | iex
```

That's it. Walk away for ~10 minutes. When it finishes, VS Code opens to your workshop.

## Self-repair

Something broke or got out of date? Paste the same line again. The script is idempotent —
it only fixes what's missing or wrong. It does NOT clobber your work.

## Where it puts things

| What | Where |
|---|---|
| Repos | `%USERPROFILE%\MortgageTech\` |
| VS Code user settings | `%APPDATA%\Code\User\settings.json` |
| MCP config (brain) | `%APPDATA%\Code\User\mcp.json` |
| Prompts (slash commands) | `%APPDATA%\Code\User\prompts\` |
| Logs | `%LOCALAPPDATA%\MortgageTech\install.log` |

Nothing is forced onto C:. If your user profile is on D:, that's where it goes.

## What you need first

- Windows 10 or 11
- A MortgageTech GitHub account with access to MortgageTechTeam org
- A GitHub Copilot license assigned to that account
- The TeamAI Brain API key (Steve will give you this once)

## Troubleshooting

If it gets stuck or errors:

1. Read `%LOCALAPPDATA%\MortgageTech\install.log`
2. Re-run the one-liner — most issues self-heal
3. Email steve@mortgagetech.com with the log

## What this script does NOT do

- Install Encompass SDK (separate, manual, requires ICE credentials)
- Install Visual Studio (full IDE) — only VS Code
- Touch your existing files outside `%USERPROFILE%\MortgageTech\`

## Brand

@wbx-modified copilot-a3f7·MTN | 2026-04-21 | initial bootstrap repo
