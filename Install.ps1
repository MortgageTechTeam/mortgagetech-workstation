# @wbx-modified copilot-a3f7·MTN | 2026-04-21 | Key prompt restored; passed via mcp.json env block, never embedded in proxy file | prev: copilot-a3f7@2026-04-21
# MortgageTech workstation bootstrap
#
# MortgageTech Workstation One-Click Installer
#
# Usage:
#   iwr -useb https://raw.githubusercontent.com/MortgageTechTeam/mortgagetech-workstation/main/Install.ps1 | iex
#
# Idempotent: safe to re-run. Only fixes what is missing or wrong.
# Self-repairing: each step is wrapped in try/catch and logged.
# Does not require admin rights for most steps.

[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $env:USERPROFILE 'MortgageTech'),
    [string]$LogDir = (Join-Path $env:LOCALAPPDATA 'MortgageTech'),
    [string]$GitHubOrg = 'MortgageTechTeam',
    [string[]]$Repos = @('encompass-authoring'),
    [string]$BrainBaseUrl = 'https://teamai-brain-app.redmeadow-3ceab978.eastus2.azurecontainerapps.io',
    [switch]$SkipExtensions,
    [switch]$NoOpen,
    [switch]$WhatIfOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# --- LOGGING ----------------------------------------------------------------
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$LogFile = Join-Path $LogDir 'install.log'
$RunStarted = Get-Date

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -Path $LogFile -Value $line
    $color = switch ($Level) {
        'OK'   { 'Green' }
        'WARN' { 'Yellow' }
        'ERR'  { 'Red' }
        'STEP' { 'Cyan' }
        default { 'Gray' }
    }
    Write-Host $line -ForegroundColor $color
}

function Invoke-Step {
    param([string]$Name, [scriptblock]$Action)
    Write-Log "BEGIN: $Name" 'STEP'
    if ($WhatIfOnly) {
        Write-Log "WhatIfOnly: skipping $Name" 'WARN'
        return
    }
    try {
        & $Action
        Write-Log "OK:    $Name" 'OK'
    } catch {
        Write-Log ("FAIL:  {0} -- {1}" -f $Name, $_.Exception.Message) 'ERR'
        Write-Log $_.ScriptStackTrace 'ERR'
        # Continue rather than abort — script is self-repairing on rerun.
    }
}

Write-Log "================================================================"
Write-Log "MortgageTech Workstation Bootstrap"
Write-Log "InstallRoot : $InstallRoot"
Write-Log "LogFile     : $LogFile"
Write-Log "User        : $env:USERNAME on $env:COMPUTERNAME"
Write-Log "PSVersion   : $($PSVersionTable.PSVersion)"
Write-Log "WhatIfOnly  : $WhatIfOnly"
Write-Log "================================================================"

# --- PRECHECK ---------------------------------------------------------------
Invoke-Step 'Verify Windows + winget' {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw 'winget not found. Install App Installer from the Microsoft Store, then re-run.'
    }
    $v = (winget --version) 2>&1
    Write-Log "winget version: $v"
}

# --- INSTALL ROOT -----------------------------------------------------------
Invoke-Step "Create install root: $InstallRoot" {
    if (-not (Test-Path $InstallRoot)) {
        New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
    }
}

# --- WINGET PACKAGES --------------------------------------------------------
$packages = @(
    @{ Id = 'Git.Git';                  Name = 'Git' },
    @{ Id = 'GitHub.cli';               Name = 'GitHub CLI' },
    @{ Id = 'Microsoft.VisualStudioCode'; Name = 'Visual Studio Code' },
    @{ Id = 'Microsoft.PowerShell';     Name = 'PowerShell 7' },
    @{ Id = 'OpenJS.NodeJS.LTS';        Name = 'Node.js LTS' },
    @{ Id = 'Microsoft.AzureCLI';       Name = 'Azure CLI' }
)

foreach ($pkg in $packages) {
    Invoke-Step "Install $($pkg.Name) ($($pkg.Id))" {
        $check = winget list --id $pkg.Id --exact 2>$null | Out-String
        if ($check -match $pkg.Id) {
            Write-Log "$($pkg.Name) already installed"
            return
        }
        Write-Log "Downloading and installing $($pkg.Name) (this can take 1-3 minutes; live winget output below)..."
        # Show live winget output so user sees progress and any UAC/error prompts.
        # --silent removed so installer windows surface; --disable-interactivity keeps it scriptable.
        & winget install --id $pkg.Id --exact --accept-package-agreements --accept-source-agreements --source winget --disable-interactivity
        if ($LASTEXITCODE -ne 0) {
            throw "winget exit code $LASTEXITCODE installing $($pkg.Id)"
        }
    }
}

# Refresh PATH so newly installed CLIs are available in this session.
$env:Path = [System.Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path','User')

# --- VS CODE EXTENSIONS -----------------------------------------------------
if (-not $SkipExtensions) {
    $extensions = @(
        'github.copilot',
        'github.copilot-chat',
        'ms-vscode.powershell',
        'ms-vscode.azure-account',
        'ms-azuretools.vscode-azurefunctions',
        'ms-azuretools.vscode-azureresourcegroups',
        'ms-azuretools.vscode-bicep',
        'ms-azuretools.vscode-docker',
        'redhat.vscode-yaml',
        'esbenp.prettier-vscode',
        'eamodio.gitlens'
    )
    $code = Get-Command code -ErrorAction SilentlyContinue
    if (-not $code) {
        $code = Get-Command 'code.cmd' -ErrorAction SilentlyContinue
    }
    if ($code) {
        foreach ($ext in $extensions) {
            Invoke-Step "Install VS Code extension: $ext" {
                & $code.Source --install-extension $ext --force 2>&1 | Out-Null
            }
        }
    } else {
        Write-Log 'VS Code "code" command not on PATH yet. Open a NEW PowerShell window and re-run to install extensions.' 'WARN'
    }
}

# --- GITHUB AUTH ------------------------------------------------------------
Invoke-Step 'GitHub CLI authentication' {
    $gh = Get-Command gh -ErrorAction SilentlyContinue
    if (-not $gh) {
        Write-Log 'gh not found on PATH. Open a NEW PowerShell window and re-run.' 'WARN'
        return
    }
    $status = & gh auth status 2>&1 | Out-String
    if ($status -match 'Logged in to github.com') {
        Write-Log 'Already authenticated to github.com'
        return
    }
    Write-Log ''
    Write-Log '====================================================================='
    Write-Log ' GitHub authentication required.'
    Write-Log ' A browser window will open. Sign in with your MortgageTechTeam account.'
    Write-Log ' Complete the browser flow before this script continues.'
    Write-Log '====================================================================='
    Write-Log ''
    & gh auth login --hostname github.com --git-protocol https --web
    $loginExit = $LASTEXITCODE

    # gh auth login can return 0 before the cookie is fully written, or non-zero
    # in non-interactive shells even when the browser flow succeeded. Don't trust
    # exit code alone — poll gh auth status with a short backoff.
    $authed = $false
    for ($i = 1; $i -le 6; $i++) {
        Start-Sleep -Seconds 2
        $check = & gh auth status 2>&1 | Out-String
        if ($check -match 'Logged in to github.com') { $authed = $true; break }
    }

    if (-not $authed) {
        Write-Log "gh auth login exit=$loginExit, status check still negative after retries." 'WARN'
        Write-Log 'Open a NEW PowerShell window, run:  gh auth login --hostname github.com --git-protocol https --web' 'WARN'
        Write-Log 'Complete the browser flow, then re-run this installer to finish.' 'WARN'
        # Do not throw — let downstream steps that depend on auth handle it themselves.
        return
    }
    Write-Log 'GitHub authentication confirmed.'
}

# --- CLONE REPOS ------------------------------------------------------------
foreach ($repo in $Repos) {
    Invoke-Step "Clone or update $GitHubOrg/$repo" {
        $target = Join-Path $InstallRoot $repo
        if (Test-Path (Join-Path $target '.git')) {
            Write-Log "$repo already cloned, pulling latest"
            Push-Location $target
            try {
                & git pull --ff-only
                if ($LASTEXITCODE -ne 0) { throw "git pull exit $LASTEXITCODE" }
            } finally { Pop-Location }
        } else {
            # Use 'gh repo clone' so the cloned repo inherits gh auth token (avoids credential prompts)
            & gh repo clone "$GitHubOrg/$repo" $target
            if ($LASTEXITCODE -ne 0) {
                throw "gh repo clone exit $LASTEXITCODE — verify you have access to $GitHubOrg/$repo"
            }
        }
    }
}

# --- VS CODE USER CONFIG ----------------------------------------------------
$codeUserDir = Join-Path $env:APPDATA 'Code\User'
$promptsDir  = Join-Path $codeUserDir 'prompts'

Invoke-Step 'Ensure VS Code user folders exist' {
    foreach ($d in @($codeUserDir, $promptsDir)) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
}

# Copy prompts from the cloned encompass-authoring repo (if present) into VS Code prompts.
Invoke-Step 'Sync prompts from encompass-authoring -> VS Code user prompts' {
    $src = Join-Path $InstallRoot 'encompass-authoring\prompts'
    if (-not (Test-Path $src)) {
        Write-Log "No prompts folder at $src yet (repo may not be cloned)" 'WARN'
        return
    }
    Get-ChildItem -Path $src -Filter '*.prompt.md' -File | ForEach-Object {
        $dest = Join-Path $promptsDir $_.Name
        Copy-Item -Path $_.FullName -Destination $dest -Force
        Write-Log "  copied: $($_.Name)"
    }
}

# --- MCP PROXY -------------------------------------------------------------
# VS Code's SSE MCP client does not reliably pass the X-API-Key header. We use
# a small node-based stdio<->SSE bridge that runs locally and handles auth.
# The bridge file is downloaded from the workstation repo and stored in a
# stable per-user location so mcp.json can reference it by absolute path.
$mcpProxyDir  = Join-Path $env:LOCALAPPDATA 'MortgageTech'
$mcpProxyPath = Join-Path $mcpProxyDir 'mcp-proxy.mjs'
$mcpProxyUrl  = 'https://raw.githubusercontent.com/MortgageTechTeam/mortgagetech-workstation/main/mcp-proxy.mjs'

Invoke-Step 'Install TeamAI Brain MCP proxy bridge' {
    if (-not (Test-Path $mcpProxyDir)) { New-Item -ItemType Directory -Path $mcpProxyDir -Force | Out-Null }
    try {
        Invoke-WebRequest -Uri $mcpProxyUrl -OutFile $mcpProxyPath -UseBasicParsing -TimeoutSec 30
        Write-Log "Downloaded proxy: $mcpProxyPath"
    } catch {
        throw "Failed to download mcp-proxy.mjs from $mcpProxyUrl : $($_.Exception.Message)"
    }
}

# --- VS CODE SETTINGS PATCH -------------------------------------------------
# Bump virtualTools threshold so MCP tools (especially the brain) are NOT
# auto-grouped behind activator stubs. With many MCP servers installed, the
# default threshold (128) causes Copilot Chat to disable tool groups until
# the user "calls" an activator first — unacceptable UX for the team brain.
Invoke-Step 'Patch VS Code settings: raise virtualTools threshold' {
    $settingsPath = Join-Path $codeUserDir 'settings.json'
    $obj = $null
    if (Test-Path $settingsPath) {
        try {
            $raw = Get-Content $settingsPath -Raw
            # Strip // comments before parsing (settings.json allows them)
            $clean = ($raw -split "`n" | ForEach-Object { $_ -replace '^\s*//.*$', '' }) -join "`n"
            $obj = $clean | ConvertFrom-Json -ErrorAction Stop
        } catch {
            Write-Log "Existing settings.json could not be parsed cleanly; skipping patch" 'WARN'
            return
        }
    } else {
        $obj = [pscustomobject]@{}
    }

    $changed = $false
    foreach ($k in @('github.copilot.chat.virtualTools.threshold', 'chat.tools.virtualTools.threshold')) {
        # Remove bogus keys (schema-only or non-existent — runtime ignores them)
        if ($obj.PSObject.Properties.Name -contains $k) {
            $obj.PSObject.Properties.Remove($k)
            $changed = $true
        }
    }
    # The ACTUAL runtime key Copilot Chat reads is 'chat.virtualTools.threshold'
    # (no github.copilot prefix). Default is 128 — too low when MCP servers add
    # 200+ tools, causing brain tools to be virtualized behind activator stubs.
    $realKey = 'chat.virtualTools.threshold'
    $current = $obj.$realKey
    if ($null -eq $current -or [int]$current -lt 1000) {
        if ($obj.PSObject.Properties.Name -contains $realKey) {
            $obj.$realKey = 1000
        } else {
            $obj | Add-Member -NotePropertyName $realKey -NotePropertyValue 1000 -Force
        }
        $changed = $true
    }

    if ($changed) {
        $obj | ConvertTo-Json -Depth 20 | Set-Content -Path $settingsPath -Encoding UTF8
        Write-Log "Set chat.virtualTools.threshold = 1000 in $settingsPath"
    } else {
        Write-Log 'chat.virtualTools.threshold already >= 1000, no change'
    }
}

# --- MCP CONFIG (TeamAI Brain) ----------------------------------------------
$mcpPath = Join-Path $codeUserDir 'mcp.json'

Invoke-Step 'Configure TeamAI Brain MCP server' {
    $existing = $null
    if (Test-Path $mcpPath) {
        try { $existing = Get-Content $mcpPath -Raw | ConvertFrom-Json } catch {
            Write-Log "Existing mcp.json is not valid JSON; will overwrite" 'WARN'
        }
    }

    # The proxy reads MORTGAGETECH_BRAIN_KEY from its environment. We pass the
    # key into the proxy via mcp.json's per-server "env" block so it never
    # touches disk anywhere except the user-scoped mcp.json file.
    $existingKey = $null
    if ($existing -and $existing.servers -and $existing.servers.'copilot-memory' -and $existing.servers.'copilot-memory'.env) {
        $existingKey = $existing.servers.'copilot-memory'.env.MORTGAGETECH_BRAIN_KEY
    } elseif ($existing -and $existing.servers -and $existing.servers.'teamai-brain' -and $existing.servers.'teamai-brain'.env) {
        # Migrate from old key name
        $existingKey = $existing.servers.'teamai-brain'.env.MORTGAGETECH_BRAIN_KEY
        $existing.servers.PSObject.Properties.Remove('teamai-brain')
        Write-Log 'Migrated mcp.json key from teamai-brain -> copilot-memory'
    }

    if ([string]::IsNullOrWhiteSpace($existingKey)) {
        Write-Host ''
        Write-Host '====================================================================='
        Write-Host ' TeamAI Brain API key required.'
        Write-Host ' Get this from steve@mortgagetech.com (sent separately, out-of-band).'
        Write-Host ' Input is hidden as you paste.'
        Write-Host '====================================================================='
        $secure = Read-Host 'Paste TeamAI Brain API key' -AsSecureString
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try {
            $apiKey = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
        } finally {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
        if ([string]::IsNullOrWhiteSpace($apiKey)) {
            Write-Log 'No API key entered. Skipping MCP config — re-run installer to add it.' 'WARN'
            return
        }
        if ($apiKey.Length -lt 16) {
            Write-Log "API key looks short ($($apiKey.Length) chars); continuing anyway." 'WARN'
        }
    } else {
        Write-Log 'copilot-memory key already present in mcp.json — leaving as-is'
        $apiKey = $existingKey
    }

    if (-not $existing) {
        $existing = [pscustomobject]@{ servers = [pscustomobject]@{} }
    } elseif (-not $existing.servers) {
        $existing | Add-Member -NotePropertyName servers -NotePropertyValue ([pscustomobject]@{}) -Force
    }

    $brainConfig = [pscustomobject]@{
        type    = 'stdio'
        command = 'node'
        args    = @($mcpProxyPath)
        env     = [pscustomobject]@{
            MORTGAGETECH_BRAIN_KEY = $apiKey
        }
    }
    $existing.servers | Add-Member -NotePropertyName 'copilot-memory' -NotePropertyValue $brainConfig -Force

    $existing | ConvertTo-Json -Depth 10 | Set-Content -Path $mcpPath -Encoding UTF8
    Write-Log "Wrote $mcpPath"
}

# --- VERIFY -----------------------------------------------------------------
Invoke-Step 'Verify brain reachable' {
    try {
        $r = Invoke-WebRequest -Uri "$BrainBaseUrl/health" -TimeoutSec 10 -SkipHttpErrorCheck
        Write-Log "Brain /health -> $($r.StatusCode)"
    } catch {
        Write-Log "Brain unreachable: $($_.Exception.Message)" 'WARN'
    }
}

# --- DONE -------------------------------------------------------------------
$elapsed = (Get-Date) - $RunStarted
Write-Log "================================================================"
Write-Log "FINISHED in $([int]$elapsed.TotalSeconds)s. Log: $LogFile" 'OK'
Write-Log "Install root: $InstallRoot"
Write-Log "================================================================"

if (-not $NoOpen) {
    $workshop = Join-Path $InstallRoot 'encompass-authoring'
    if (Test-Path $workshop) {
        Write-Log 'Opening VS Code at the workshop...'
        $code = Get-Command code -ErrorAction SilentlyContinue
        if (-not $code) { $code = Get-Command 'code.cmd' -ErrorAction SilentlyContinue }
        if ($code) { Start-Process $code.Source -ArgumentList "`"$workshop`"" }
    }
}

Write-Host ''
Write-Host 'NEXT STEPS:' -ForegroundColor Green
Write-Host '  1. Sign in to GitHub Copilot in VS Code (bottom-right Accounts icon)'
Write-Host '  2. Open Copilot Chat and try: /new-client-package YourClientName'
Write-Host '  3. Re-run this script anytime to self-repair or update.'
