# ===============================
# Onboarding Automation Script
# ===============================
# Run this script as Administrator
# ===============================

# --- Admin Check ---
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Run this script as Administrator." -ForegroundColor Red
    exit
}

# --- Detect repo root ---
$RepoRoot = (Resolve-Path "$PSScriptRoot\..").Path
if (!(Test-Path "$RepoRoot\.git")) {
    # If not found, try the current folder (in case script is in repo root)
    $RepoRoot = $PSScriptRoot
}
if (!(Test-Path "$RepoRoot\.git")) {
    Write-Host "Couldn't detect git repository root. Please run this script from inside your repository." -ForegroundColor Red
    exit
}
Write-Host "Detected repo root: $RepoRoot"

$PubKeyFolder = "$RepoRoot\pubkey"
$WslDistro = "Ubuntu"
$FixedWslUser = "ubuntu"  # Enforce fixed user 'ubuntu'
$WslUserCacheFile = "$env:TEMP\onboard_wsl_user.txt"

# --- Confirm home directory exists and is writable for fixed user ---
$HomeTest = wsl -d $WslDistro -- bash -c "test -d /home/$FixedWslUser && test -w /home/$FixedWslUser && echo ok"
if ($HomeTest -ne "ok") {
    Write-Host "User /home/$FixedWslUser does not exist or is not writable. Please ensure this user exists and rerun." -ForegroundColor Red
    exit
}
$WslUser = $FixedWslUser
Set-Content $WslUserCacheFile $WslUser

$KeyName = "$WslUser-key"
$WslKeyBasePath = "/home/$WslUser/.ssh"
$WslPrivateKey = "$WslKeyBasePath/$KeyName"
$WslPublicKey = "$WslPrivateKey.pub"
$WindowsPubKeyPath = "$PubKeyFolder\$KeyName.pub"

# --- Ensure winget available ---
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Host "'winget' not available. Installing App Installer..." -ForegroundColor Red
    Start-Process "https://apps.microsoft.com/store/detail/app-installer/9NBLGGH4NNS1"
    exit
}

# --- Install PowerShell 7 ---
if (-not (Get-Command pwsh -ErrorAction SilentlyContinue)) {
    Write-Host "Installing PowerShell 7..."
    winget install --id Microsoft.PowerShell -e
} else {
    Write-Host "PowerShell 7 already installed."
}

# --- Install WSL and Ubuntu ---
$InstalledDistros = (wsl -l -q) -replace "`0", ""
if ($InstalledDistros -notcontains $WslDistro) {
    Write-Host "Installing WSL and Ubuntu..."
    wsl --install -d $WslDistro
    Write-Host "Wait for WSL to finish setup. Then re-run this script."
    exit
} else {
    Write-Host "Ubuntu is already installed."
}

# --- Check WSL is initialized ---
$WslReady = wsl -d $WslDistro -- echo "ok" 2>$null
if ($WslReady -ne "ok") {
    Write-Host "Ubuntu is installed but not initialized yet. Open Ubuntu manually once, then re-run this script." -ForegroundColor Yellow
    exit
}

# --- Install Ansible in WSL ---
$AnsibleInstalled = wsl -d $WslDistro -- bash -c "which ansible"
if (-not $AnsibleInstalled) {
    Write-Host "Installing Ansible inside WSL..."
    wsl -d $WslDistro -- bash -c "sudo apt update && sudo apt install -y ansible"
} else {
    Write-Host "Ansible is already present in WSL."
}

# --- Install Docker Desktop ---
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Host "Installing Docker Desktop..."
    winget install -e --id Docker.DockerDesktop
} else {
    Write-Host "Docker Desktop already installed."
}

# --- Enable RDP ---
Write-Host "Enabling Remote Desktop (RDP)..."
Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" -Name "fDenyTSConnections" -Value 0
$rdpRules = Get-NetFirewallRule | Where-Object { $_.DisplayName -match "Remote Desktop" }
if ($rdpRules) {
    foreach ($rule in $rdpRules) {
        Enable-NetFirewallRule -Name $rule.Name
    }
} else {
    Write-Host "Remote Desktop firewall rule not found. Skipping..."
}

# --- SSH Key Generation in WSL (FIXED) ---
wsl -d $WslDistro -- bash -c "mkdir -p $WslKeyBasePath && chmod 700 $WslKeyBasePath"
$KeyExists = wsl -d $WslDistro -- bash -c "[ -f '$WslPrivateKey' ] && [ -f '$WslPublicKey' ] && echo exists"
if ($KeyExists -ne "exists") {
    Write-Host "Generating SSH key pair in WSL for user $WslUser ..."
    wsl -d $WslDistro -- bash -c "ssh-keygen -t rsa -b 2048 -f '$WslPrivateKey' -N ''"
    wsl -d $WslDistro -- bash -c "chmod 600 '$WslPrivateKey' && chmod 644 '$WslPublicKey'"
} else {
    Write-Host "SSH key already exists in WSL at $WslPrivateKey"
}

# --- Save Public Key from WSL to Windows repo ---
if (!(Test-Path $PubKeyFolder)) {
    New-Item -Path $PubKeyFolder -ItemType Directory | Out-Null
}
$PubKeyContent = wsl -d $WslDistro -- bash -c "cat '$WslPublicKey'"
Set-Content -Path $WindowsPubKeyPath -Value $PubKeyContent
Write-Host "Public key saved to pubkey/$KeyName.pub"

# --- Git Setup and Commit ---
Set-Location $RepoRoot

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "Installing Git..."
    winget install --id Git.Git -e
}

if (-not (git config user.name)) {
    git config --global user.name $WslUser
}
if (-not (git config user.email)) {
    $email = Read-Host "Enter your Git email"
    git config --global user.email $email
}

$Branch = "user-$WslUser"
$Existing = git branch --list $Branch
if ($Existing) {
    git switch $Branch
} else {
    git checkout -b $Branch
}

# Double check the pubkey file now exists before git add
if (Test-Path "pubkey\$KeyName.pub") {
    git add "pubkey/$KeyName.pub"
    git commit -m "Add SSH key for $WslUser" | Out-Null
    try {
        git push -u origin $Branch
        Write-Host "Public key pushed to GitHub branch: $Branch"
    } catch {
        Write-Host "Git push failed. Please push manually using:"
        Write-Host "git push -u origin $Branch"
    }
} else {
    Write-Host "ERROR: pubkey/$KeyName.pub does not exist. Commit step skipped." -ForegroundColor Red
}

# --- Create standard Ansible folder structure ---
$AnsibleRoot = "$RepoRoot\ansible"
$FoldersToCreate = @(
    "$AnsibleRoot\inventories",
    "$AnsibleRoot\group_vars",
    "$AnsibleRoot\host_vars",
    "$AnsibleRoot\roles\myrole\tasks",
    "$AnsibleRoot\roles\myrole\handlers",
    "$AnsibleRoot\roles\myrole\templates",
    "$AnsibleRoot\roles\myrole\files",
    "$AnsibleRoot\roles\myrole\vars",
    "$AnsibleRoot\roles\myrole\defaults",
    "$AnsibleRoot\playbooks"
)
foreach ($folder in $FoldersToCreate) {
    if (!(Test-Path $folder)) {
        New-Item -Path $folder -ItemType Directory | Out-Null
    }
}

# --- Create minimal starter files if missing ---
$FilesToCreate = @{
    "$AnsibleRoot\inventories\hosts" = ""
    "$AnsibleRoot\group_vars\all.yml" = ""
    "$AnsibleRoot\roles\myrole\tasks\main.yml" = "---`n# Tasks for myrole"
    "$AnsibleRoot\roles\myrole\handlers\main.yml" = "---`n# Handlers for myrole"
    "$AnsibleRoot\roles\myrole\vars\main.yml" = "---`n# Variables for myrole"
    "$AnsibleRoot\roles\myrole\defaults\main.yml" = "---`n# Defaults for myrole"
    "$AnsibleRoot\playbooks\site.yml" = "---`n# Main playbook"
}
foreach ($file in $FilesToCreate.Keys) {
    if (!(Test-Path $file)) {
        Set-Content -Path $file -Value $FilesToCreate[$file]
    }
}
Write-Host "Ansible folder structure created/updated at $AnsibleRoot" -ForegroundColor Green

Write-Host "Onboarding complete. Your environment is ready." -ForegroundColor Green
