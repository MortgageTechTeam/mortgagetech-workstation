# @wbx-modified copilot-a3f7·MTN | 2026-04-22 | Admin onboarding script
<#
.SYNOPSIS
    Provision a new MortgageTech team member across GitHub, Azure, and M365.

.DESCRIPTION
    Run THIS script from an ADMIN workstation (yours) — not the new hire's machine.
    It performs the invitations and license assignments that require admin rights:
      - Invite to MortgageTechTeam GitHub org
      - Assign GitHub Copilot Business seat (after they accept)
      - Invite to Entra/M365 tenant as guest OR confirm member account
      - Assign M365 license (default: ENTERPRISEPREMIUM / E5)
      - Add Azure RBAC role on a chosen subscription (default: Reader)
    Then prints the install one-liner + brain API key for you to send to them.

    Idempotent: re-running on an already-provisioned user reports current state
    and only fills in what's missing.

.PARAMETER Email
    The new member's primary email (becomes their UPN if creating an internal account).

.PARAMETER DisplayName
    Full name, e.g. "Kris Drouet".

.PARAMETER GitHubUsername
    Their GitHub username (must already exist on github.com).

.PARAMETER M365Sku
    SKU part number to assign. Default 'ENTERPRISEPREMIUM' (E5).
    Use 'NONE' to skip M365 license assignment.

.PARAMETER AzureSubscriptionId
    Subscription to grant access on. Default: current default sub.

.PARAMETER AzureRole
    RBAC role. Default 'Reader'. Common: Reader, Contributor, Owner.

.PARAMETER BrainApiKey
    Optional. If supplied, included in the final handoff message.

.EXAMPLE
    .\Onboard-TeamMember.ps1 -Email "newhire@mortgagetech.com" -DisplayName "New Hire" `
        -GitHubUsername "newhire-mortgagetech" -AzureRole "Contributor"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)] [string]$Email,
    [Parameter(Mandatory=$true)] [string]$DisplayName,
    [Parameter(Mandatory=$true)] [string]$GitHubUsername,
    [string]$M365Sku = 'ENTERPRISEPREMIUM',
    [string]$AzureSubscriptionId,
    [string]$AzureRole = 'Reader',
    [string]$GitHubOrg = 'MortgageTechTeam',
    [string]$BrainApiKey
)

$ErrorActionPreference = 'Stop'
$report = [ordered]@{}

function Write-Step    { param($m) Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Write-Ok      { param($m) Write-Host "  OK    $m" -ForegroundColor Green }
function Write-Warn2   { param($m) Write-Host "  WARN  $m" -ForegroundColor Yellow }
function Write-Skip    { param($m) Write-Host "  SKIP  $m" -ForegroundColor DarkGray }
function Write-Err2    { param($m) Write-Host "  ERR   $m" -ForegroundColor Red }

# --- Pre-flight ----------------------------------------------------------------
Write-Step 'Pre-flight'
foreach ($cmd in 'az','gh') {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        throw "$cmd CLI not found on PATH. Install it first."
    }
    Write-Ok "$cmd available"
}

# Azure context
$azAccount = az account show 2>$null | ConvertFrom-Json
if (-not $azAccount) { throw "Run 'az login' first." }
if (-not $AzureSubscriptionId) { $AzureSubscriptionId = $azAccount.id }
az account set --subscription $AzureSubscriptionId | Out-Null
$subName = (az account show --query name -o tsv)
Write-Ok "Azure sub: $subName ($AzureSubscriptionId)"

# GH context
$ghUser = gh api user -q '.login' 2>$null
if (-not $ghUser) { throw "Run 'gh auth login' first." }
Write-Ok "GitHub: $ghUser"

# --- 1. GitHub org membership --------------------------------------------------
Write-Step "GitHub org: $GitHubOrg"
gh api "/orgs/$GitHubOrg/members/$GitHubUsername" 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Ok "$GitHubUsername already a member"
    $report.GitHubOrg = 'member'
} else {
    $pending = gh api "/orgs/$GitHubOrg/invitations" -q ".[] | select(.login==`"$GitHubUsername`") | .login" 2>$null
    if ($pending) {
        Write-Warn2 "Invitation already pending for $GitHubUsername"
        $report.GitHubOrg = 'invitation-pending'
    } else {
        $ghUserInfo = gh api "/users/$GitHubUsername" 2>$null | ConvertFrom-Json
        if (-not $ghUserInfo) { throw "GitHub user '$GitHubUsername' not found on github.com" }
        gh api -X POST "/orgs/$GitHubOrg/invitations" -f "invitee_id=$($ghUserInfo.id)" -f "role=direct_member" | Out-Null
        Write-Ok "Invited $GitHubUsername to $GitHubOrg"
        $report.GitHubOrg = 'invited'
    }
}

# --- 2. GitHub Copilot seat ----------------------------------------------------
Write-Step 'GitHub Copilot Business seat'
$seat = gh api "/orgs/$GitHubOrg/members/$GitHubUsername/copilot" 2>$null | ConvertFrom-Json
if ($seat -and $seat.created_at) {
    Write-Ok "Copilot seat already assigned"
    $report.Copilot = 'assigned'
} elseif ($report.GitHubOrg -eq 'invited' -or $report.GitHubOrg -eq 'invitation-pending') {
    Write-Warn2 "Cannot assign Copilot seat until $GitHubUsername accepts org invite. Re-run after acceptance."
    $report.Copilot = 'deferred'
} else {
    try {
        gh api -X POST "/orgs/$GitHubOrg/copilot/billing/selected_users" `
            -f "selected_usernames[]=$GitHubUsername" | Out-Null
        Write-Ok "Copilot seat assigned"
        $report.Copilot = 'assigned'
    } catch {
        Write-Err2 "Copilot assignment failed: $_"
        $report.Copilot = 'failed'
    }
}

# --- 3. Entra/M365 user --------------------------------------------------------
Write-Step "Entra/M365 user: $Email"
$user = az ad user show --id $Email 2>$null | ConvertFrom-Json
if (-not $user) {
    Write-Warn2 "User $Email not found in tenant."
    Write-Host "  Create them manually in Entra admin center, then re-run." -ForegroundColor Yellow
    Write-Host "  (Internal users with @mortgagetech.com domain require admin-portal creation.)" -ForegroundColor DarkGray
    $report.Entra = 'missing'
} else {
    Write-Ok "Found: $($user.displayName) ($($user.userPrincipalName))"
    $report.Entra = 'present'
    $userOid = $user.id

    # --- 4. M365 license -------------------------------------------------------
    if ($M365Sku -ne 'NONE') {
        Write-Step "M365 license: $M365Sku"
        $skus = az rest --method GET --url 'https://graph.microsoft.com/v1.0/subscribedSkus' 2>$null | ConvertFrom-Json
        $sku = $skus.value | Where-Object { $_.skuPartNumber -eq $M365Sku }
        if (-not $sku) {
            Write-Err2 "SKU $M365Sku not found in tenant."
            $report.M365License = 'sku-missing'
        } else {
            $assigned = az rest --method GET --url "https://graph.microsoft.com/v1.0/users/$Email/licenseDetails" 2>$null | ConvertFrom-Json
            $hasIt = $assigned.value | Where-Object { $_.skuPartNumber -eq $M365Sku }
            if ($hasIt) {
                Write-Ok "$M365Sku already assigned"
                $report.M365License = 'assigned'
            } else {
                $available = $sku.prepaidUnits.enabled - $sku.consumedUnits
                if ($available -le 0) {
                    Write-Err2 "$M365Sku has 0 free seats ($($sku.consumedUnits)/$($sku.prepaidUnits.enabled) used). Buy more or pick another SKU."
                    $report.M365License = 'no-seats'
                } else {
                    $body = @{ addLicenses = @(@{ skuId = $sku.skuId; disabledPlans = @() }); removeLicenses = @() } | ConvertTo-Json -Depth 5 -Compress
                    $tmp = New-TemporaryFile
                    Set-Content -Path $tmp -Value $body -NoNewline
                    try {
                        az rest --method POST --url "https://graph.microsoft.com/v1.0/users/$Email/assignLicense" `
                            --headers "Content-Type=application/json" --body "@$tmp" | Out-Null
                        Write-Ok "$M365Sku assigned"
                        $report.M365License = 'assigned'
                    } catch {
                        Write-Err2 "License assign failed: $_"
                        $report.M365License = 'failed'
                    } finally {
                        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
                    }
                }
            }
        }
    } else {
        Write-Skip 'M365 license assignment (M365Sku=NONE)'
        $report.M365License = 'skipped'
    }

    # --- 5. Azure RBAC ---------------------------------------------------------
    Write-Step "Azure RBAC: $AzureRole on $subName"
    $scope = "/subscriptions/$AzureSubscriptionId"
    $existingRole = az role assignment list --assignee $userOid --scope $scope `
        --query "[?roleDefinitionName=='$AzureRole'].id" -o tsv 2>$null
    if ($existingRole) {
        Write-Ok "$AzureRole already granted at sub scope"
        $report.AzureRBAC = 'present'
    } else {
        try {
            az role assignment create --assignee-object-id $userOid `
                --assignee-principal-type User --role $AzureRole --scope $scope | Out-Null
            Write-Ok "Granted $AzureRole at $scope"
            $report.AzureRBAC = 'granted'
        } catch {
            Write-Err2 "RBAC grant failed: $_"
            $report.AzureRBAC = 'failed'
        }
    }
}

# --- 6. Final handoff ----------------------------------------------------------
Write-Step 'Summary'
$report.GetEnumerator() | ForEach-Object { "{0,-15} {1}" -f $_.Key, $_.Value } | Write-Host

Write-Step 'Send this to the new team member'
$msg = @"
Welcome to MortgageTech. To set up your workstation:

1. Sign in to GitHub (github.com) as: $GitHubUsername
   - Accept the org invite at: https://github.com/$GitHubOrg
2. Sign in to Microsoft 365 with: $Email
3. Open Windows PowerShell and run:

   iwr -useb https://raw.githubusercontent.com/$GitHubOrg/mortgagetech-workstation/main/Install.ps1 | iex

4. When prompted, paste the TeamAI Brain API key (sent separately).
"@
Write-Host $msg -ForegroundColor White

if ($BrainApiKey) {
    Write-Step 'Brain API key (send via SECURE channel: Signal / 1Password / encrypted email)'
    Write-Host "  $BrainApiKey" -ForegroundColor Yellow
}

Write-Host "`nDone." -ForegroundColor Green
