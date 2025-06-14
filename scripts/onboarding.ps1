# ===============================
# Onboarding Automation Script
# Author: Elie Shane
# ===============================

# Ensure running as Administrator
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "❌ Please run this script as Administrator." -ForegroundColor Red
    exit
}

# ===============================
# CONFIGURATION
# ===============================
$RepoRoot = "$PSScriptRoot\.."  # One level above 'scripts'
$PubKeyFolder = "$RepoRoot\pubkey"
$KeyBasePath = "$HOME\.ssh"
$WslDistro = "Ubuntu"

# ===============================
# PRE-RUN NOTICE
# ===============================
Write-Host "`n📋 Before continuing, ensure:"
Write-Host "1. Git is installed and authenticated to GitHub"
Write-Host "2. You have cloned the repo (not downloaded ZIP)"
Write-Host "3. You have write access to this repo"
Write-Host "4. Git user.name and user.email are set"
Write-Host "`nPress any key to continue..."
[void][System.Console]::ReadKey($true)

# ===============================
# 1. Prompt for username
# ===============================
function Get-ValidUsername {
    while ($true) {
        $Username = Read-Host "Enter your first name (letters and numbers only)"
        if ($Username -match '^[a-zA-Z0-9]+$') {
            return $Username
        }
        Write-Host "❗ Invalid input. Use only letters and numbers." -ForegroundColor Yellow
    }
}
$Username = Get-ValidUsername
$KeyName = "$Username-key"

# ===============================
# 2. Install PowerShell 7
# ===============================
if (-not (Get-Command pwsh -ErrorAction SilentlyContinue)) {
    Write-Host "⚙️ Installing PowerShell 7..."
    winget install --id Microsoft.PowerShell --source winget
} else {
    Write-Host "✔ PowerShell 7 is already installed."
}

# ===============================
# 3. Setup WSL + Ubuntu
# ===============================
if (-not (wsl -l -v | Select-String $WslDistro)) {
    Write-Host "⚙️ Installing WSL with Ubuntu..."
    wsl --install -d $WslDistro
} else {
    Write-Host "✔ WSL Ubuntu already installed."
}

# ===============================
# 4. Install Ansible in WSL
# ===============================
Write-Host "⚙️ Installing Ansible inside WSL..."
wsl -d $WslDistro -- bash -c "sudo apt update && sudo apt install -y ansible"

# ===============================
# 5. Install Docker Desktop
# ===============================
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Host "⚙️ Installing Docker Desktop..."
    winget install -e --id Docker.DockerDesktop
} else {
    Write-Host "✔ Docker is already installed."
}

# ===============================
# 6. Enable RDP
# ===============================
Write-Host "🔓 Enabling Remote Desktop (RDP)..."
Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" -Name "fDenyTSConnections" -Value 0
Enable-NetFirewallRule -DisplayGroup "Remote Desktop"

# ===============================
# 7. Generate SSH Keys
# ===============================
if (!(Test-Path $KeyBasePath)) { New-Item -Path $KeyBasePath -ItemType Directory | Out-Null }

$PrivateKey = "$KeyBasePath\$KeyName"
$PublicKey = "$PrivateKey.pub"

if (!(Test-Path $PrivateKey)) {
    Write-Host "🔑 Generating SSH key pair..."
    ssh-keygen -t rsa -b 2048 -f $PrivateKey -N "" | Out-Null
    Write-Host "✔ SSH Key pair generated."
} else {
    Write-Host "✔ SSH Key already exists at: $PrivateKey"
}

# ===============================
# 8. Copy Public Key to pubkey/
# ===============================
if (!(Test-Path $PubKeyFolder)) { New-Item -ItemType Directory -Path $PubKeyFolder | Out-Null }

$DestKey = "$PubKeyFolder\$KeyName.pub"
Copy-Item -Path $PublicKey -Destination $DestKey -Force
Write-Host "📁 Public key saved to pubkey/$KeyName.pub"

# ===============================
# 9. Git Commit and Push
# ===============================
Set-Location -Path $RepoRoot

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "⚙️ Installing Git..."
    winget install Git.Git
}

# Set Git identity if missing
if (-not (git config user.name)) {
    git config user.name $Username
}
if (-not (git config user.email)) {
    $email = Read-Host "Enter your email for Git config"
    git config user.email $email
}

# Create and push new branch
$BranchName = "user-$Username"
git checkout -b $BranchName
git add "pubkey/$KeyName.pub"
git commit -m "Add SSH public key for $Username"

try {
    git push -u origin $BranchName
    Write-Host "🚀 Public key pushed to GitHub on branch: $BranchName" -ForegroundColor Green
}
catch {
    Write-Host "❌ Git push failed. Check your credentials or remote setup." -ForegroundColor Red
}

Write-Host "`n🎉 Onboarding complete!" -ForegroundColor Cyan
