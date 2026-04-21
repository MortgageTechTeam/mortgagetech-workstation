# @wbx-modified copilot-a3f7·MTN | 2026-04-21 | MortgageTech workstation bootstrap
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
        winget install --id $pkg.Id --exact --silent --accept-package-agreements --accept-source-agreements --source winget 2>&1 | Out-Null
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
    Write-Log 'Launching gh auth login (web browser flow)...'
    & gh auth login --hostname github.com --git-protocol https --web
}

# --- CLONE REPOS ------------------------------------------------------------
foreach ($repo in $Repos) {
    Invoke-Step "Clone or update $GitHubOrg/$repo" {
        $target = Join-Path $InstallRoot $repo
        if (Test-Path (Join-Path $target '.git')) {
            Write-Log "$repo already cloned, pulling latest"
            Push-Location $target
            try { git pull --ff-only 2>&1 | Out-Null } finally { Pop-Location }
        } else {
            git clone "https://github.com/$GitHubOrg/$repo.git" $target 2>&1 | Out-Null
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

# --- MCP CONFIG (TeamAI Brain) ----------------------------------------------
$mcpPath = Join-Path $codeUserDir 'mcp.json'

Invoke-Step 'Configure TeamAI Brain MCP server' {
    $existing = $null
    if (Test-Path $mcpPath) {
        try { $existing = Get-Content $mcpPath -Raw | ConvertFrom-Json } catch {
            Write-Log "Existing mcp.json is not valid JSON; will overwrite" 'WARN'
        }
    }

    # Only prompt for API key if not already configured.
    $needKey = $true
    if ($existing -and $existing.servers -and $existing.servers.'teamai-brain') {
        $cur = $existing.servers.'teamai-brain'.headers.'X-API-Key'
        if ($cur -and $cur.Length -gt 8) {
            Write-Log 'teamai-brain already configured with API key — leaving as-is'
            $needKey = $false
        }
    }

    if (-not $needKey) { return }

    Write-Host ''
    Write-Host 'TeamAI Brain API key required.' -ForegroundColor Yellow
    Write-Host 'Get this from steve@mortgagetech.com (one-time setup).' -ForegroundColor Yellow
    $secure = Read-Host 'Paste TeamAI Brain API key' -AsSecureString
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    $apiKey = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        Write-Log 'No API key entered. Skipping MCP config — re-run script later to add it.' 'WARN'
        return
    }

    # Merge into existing servers if present.
    if (-not $existing) {
        $existing = [pscustomobject]@{ servers = [pscustomobject]@{} }
    } elseif (-not $existing.servers) {
        $existing | Add-Member -NotePropertyName servers -NotePropertyValue ([pscustomobject]@{}) -Force
    }

    $brainConfig = [pscustomobject]@{
        type    = 'sse'
        url     = "$BrainBaseUrl/sse"
        headers = [pscustomobject]@{ 'X-API-Key' = $apiKey }
    }
    $existing.servers | Add-Member -NotePropertyName 'teamai-brain' -NotePropertyValue $brainConfig -Force

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
