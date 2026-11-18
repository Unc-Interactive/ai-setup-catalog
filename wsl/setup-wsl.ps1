# Alky's WSL setup, for any Windows PC (made for Dewsky, 2026-11-18).
# One line in PowerShell (it asks for admin by itself):
#   irm https://raw.githubusercontent.com/Unc-Interactive/ai-setup-catalog/main/wsl/setup-wsl.ps1 | iex
#
# What it does (safe to run again; each step skips what is already done):
#  1. Installs WSL + Ubuntu 24.04 if missing (keeps every distro you already have).
#  2. Writes C:\Users\<you>\.wslconfig sized for THIS PC (old file backed up first).
#  3. Inside Ubuntu 24.04: systemd on, apt basics (git, build tools, Python 3.12, ffmpeg, jq...),
#     uv, Node 24 (nvm), gh, Ollama with Alky's settings (flash attention, 1 at a time, 2 models max),
#     Blender 4.5.16 LTS (sha256 checked), Claude Code, Codex CLI.
#  4. Pulls nomic-embed-text + one chat model that fits this GPU (skip with -NoModels).
# It never deletes a distro, never touches Windows apps, and sends nothing anywhere.

param([switch]$NoModels, [string]$Distro = "Ubuntu-24.04", [string]$LinuxUser = "")

$ErrorActionPreference = "Continue"   # native wsl.exe output on stderr must not abort (PowerShell 5.1)
$Url = "https://raw.githubusercontent.com/Unc-Interactive/ai-setup-catalog/main/wsl/setup-wsl.ps1"

function Say($t) { Write-Host "`n== $t" -ForegroundColor Cyan }
function Ok($t)  { Write-Host "   ok: $t" -ForegroundColor Green }
function Warn($t){ Write-Host "   !! $t" -ForegroundColor Yellow }

# ---- admin (re-launch elevated when run as a normal user) ----
$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Asking for admin (needed for the WSL install)..."
    $a = "-NoProfile -ExecutionPolicy Bypass -NoExit -Command `"& ([scriptblock]::Create((irm '$Url')))"
    if ($NoModels) { $a += " -NoModels" }
    if ($LinuxUser) { $a += " -LinuxUser '$LinuxUser'" }
    $a += "`""
    Start-Process powershell -Verb RunAs -ArgumentList $a
    return
}
$env:WSL_UTF8 = "1"

# ---- 0. Windows checks ----
Say "Checking Windows"
$build = [int](Get-CimInstance Win32_OperatingSystem).BuildNumber
if ($build -lt 19041) { throw "WSL 2 needs Windows 10 2004 (build 19041) or newer; this PC is $build." }
Ok "Windows build $build"
$ramGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
$cpus  = [int](Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
$vram  = 0
try {
    $smi = & nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>$null
    if ($smi) { $vram = [math]::Round(([int]($smi | Select-Object -First 1)) / 1024) }
} catch {}
Ok "RAM $ramGB GB, $cpus threads, NVIDIA VRAM $vram GB (0 = no NVIDIA card found)"

# ---- 1. WSL + Ubuntu 24.04 ----
Say "WSL + $Distro"
$list = (wsl.exe -l -q 2>$null) -join "`n"
if ($LASTEXITCODE -ne 0 -or -not $list) { $list = "" }
if ($list -notmatch [regex]::Escape($Distro)) {
    wsl.exe --update 2>$null | Out-Null
    wsl.exe --install -d $Distro --no-launch
    $list = (wsl.exe -l -q 2>$null) -join "`n"
    if ($list -notmatch [regex]::Escape($Distro)) {
        # older Store-style installs register on first start
        $exe = Get-Command ("ubuntu" + ($Distro -replace '\D', '') + ".exe") -ErrorAction SilentlyContinue
        if ($exe) { & $exe.Source install --root | Out-Null; $list = (wsl.exe -l -q 2>$null) -join "`n" }
    }
    if ($list -notmatch [regex]::Escape($Distro)) {
        Warn "Windows needs a restart to finish turning WSL on."
        Warn "Restart the PC, then paste the same command again. It carries on from here."
        return
    }
    Ok "$Distro installed"
} else { Ok "$Distro already there (left as is)" }

# Linux user: default = Windows user name, lower case, letters/digits only
if (-not $LinuxUser) {
    $LinuxUser = (wsl.exe -d $Distro -u root -- sh -c "getent passwd 1000 | cut -d: -f1" 2>$null | Out-String).Trim()
    if (-not $LinuxUser) { $LinuxUser = ($env:USERNAME.ToLower() -replace '[^a-z0-9]', ''); if (-not $LinuxUser) { $LinuxUser = "dev" } }
}
$hasUser = (wsl.exe -d $Distro -u root -- sh -c "id -u $LinuxUser >/dev/null 2>&1 && echo yes" 2>$null | Out-String).Trim()
if ($hasUser -ne "yes") {
    wsl.exe -d $Distro -u root -- useradd -m -s /bin/bash -G sudo $LinuxUser
    Write-Host "   Pick a Linux password for '$LinuxUser' (used for sudo):" -ForegroundColor Yellow
    wsl.exe -d $Distro -u root -- passwd $LinuxUser
    Ok "Linux user $LinuxUser made"
} else { Ok "Linux user $LinuxUser" }

# ---- 2. .wslconfig sized for this PC ----
Say ".wslconfig"
$memGB  = [math]::Min(44, [math]::Max(4, [math]::Floor($ramGB * 0.6)))
$swapGB = [math]::Min(24, [math]::Max(4, [math]::Floor($ramGB / 2)))
$procs  = [math]::Max(2, $cpus - 4)
$cfg = "[wsl2]`r`nmemory=${memGB}GB`r`nswap=${swapGB}GB`r`nprocessors=$procs`r`n"
$cfgPath = Join-Path $env:USERPROFILE ".wslconfig"
$cfgChanged = $true
if (Test-Path $cfgPath) {
    $old = Get-Content $cfgPath -Raw
    if ($old -eq $cfg) { $cfgChanged = $false }
    else { $bak = "$cfgPath.bak-" + (Get-Date -Format yyyyMMdd-HHmmss); Copy-Item $cfgPath $bak; Ok "old one saved as $bak" }
}
if ($cfgChanged) { [IO.File]::WriteAllText($cfgPath, $cfg) }
Ok "memory=${memGB}GB swap=${swapGB}GB processors=$procs  ($cfgPath)"

# ---- 3. inside Ubuntu ----
# chat model that fits the card (weights + context room)
$chat = ""
if (-not $NoModels) {
    if     ($vram -ge 22) { $chat = "qwen3:32b" }
    elseif ($vram -ge 14) { $chat = "qwen3:14b" }
    elseif ($vram -ge 10) { $chat = "qwen3:8b" }
    else                  { $chat = "qwen3:4b-instruct" }
}

$inside = @'
#!/bin/bash
# runs as root inside the distro: $1 = phase (conf|full), $2 = linux user, $3 = chat model (absent = no models)
set -euo pipefail
PHASE="$1"; U="$2"; CHAT="${3:-}"; H=$(getent passwd "$U" | cut -d: -f6)
say(){ echo; echo "== $*"; }
asuser(){ sudo -u "$U" -H bash -lc "cd ~; $1"; }

if [ "$PHASE" = conf ]; then
  # same as Alky's: systemd on, default user, Windows PATH kept out (faster, no clashes)
  cat > /etc/wsl.conf <<EOF
[boot]
systemd=true

[interop]
appendWindowsPath = false

[user]
default=$U
EOF
  exit 0
fi

export DEBIAN_FRONTEND=noninteractive
say "apt basics"
apt-get update -q
apt-get install -y -q build-essential git git-lfs curl wget unzip zip jq htop tmux ca-certificates gnupg \
  python3 python3-pip python3-venv python3-dev pipx ffmpeg libgl1 libglib2.0-0 libxi6 libxrender1 libxkbcommon0 \
  libsm6 libxxf86vm1 libxfixes3 libegl1 libusb-1.0-0 zstd pciutils

say "GitHub CLI"
if ! command -v gh >/dev/null; then
  install -d -m 755 /etc/apt/keyrings
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
  chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list
  apt-get update -q && apt-get install -y -q gh
fi
gh --version | head -1

say "GPU check"
if [ -x /usr/lib/wsl/lib/nvidia-smi ]; then /usr/lib/wsl/lib/nvidia-smi -L; else echo "no NVIDIA GPU visible in WSL (update the Windows NVIDIA driver)"; fi

say "Ollama"
if ! command -v ollama >/dev/null; then curl -fsSL https://ollama.com/install.sh | sh; fi
mkdir -p /etc/systemd/system/ollama.service.d
cat > /etc/systemd/system/ollama.service.d/ai-setup.conf <<'EOF'
[Service]
Environment="OLLAMA_MAX_LOADED_MODELS=2"
Environment="OLLAMA_FLASH_ATTENTION=1"
Environment="OLLAMA_NUM_PARALLEL=1"
EOF
systemctl daemon-reload; systemctl enable ollama >/dev/null 2>&1 || true; systemctl restart ollama
for i in $(seq 1 30); do curl -s localhost:11434/api/version >/dev/null && break; sleep 1; done
ollama --version

say "uv (Python tool manager)"
asuser 'command -v uv >/dev/null || [ -x ~/.local/bin/uv ] || curl -LsSf https://astral.sh/uv/install.sh | sh; ~/.local/bin/uv --version'

say "Node 24 (nvm) + Codex CLI"
asuser 'export NVM_DIR=~/.nvm; [ -s $NVM_DIR/nvm.sh ] || curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
. ~/.nvm/nvm.sh; nvm install 24 >/dev/null; nvm alias default 24 >/dev/null; node --version
command -v codex >/dev/null || npm install -g @openai/codex >/dev/null; codex --version || true'

say "Claude Code"
asuser 'command -v claude >/dev/null || [ -x ~/.local/bin/claude ] || curl -fsSL https://claude.ai/install.sh | bash; ~/.local/bin/claude --version || true'

say "Blender 4.5.16 LTS (~/opt/blender)"
asuser 'set -e; mkdir -p ~/opt ~/downloads; cd ~/downloads
if [ ! -x ~/opt/blender-4.5.16-linux-x64/blender ]; then
  B=https://download.blender.org/release/Blender4.5
  curl -fL# $B/blender-4.5.16-linux-x64.tar.xz -o blender.tar.xz
  want=$(curl -fsSL $B/blender-4.5.16.sha256 | grep linux-x64.tar.xz | cut -d" " -f1)
  have=$(sha256sum blender.tar.xz | cut -d" " -f1)
  [ -n "$want" ] && [ "$want" = "$have" ] || { echo "Blender sha256 MISMATCH, not installed"; exit 1; }
  echo "sha256 ok"; tar -xJf blender.tar.xz -C ~/opt; rm blender.tar.xz
fi
ln -sfn ~/opt/blender-4.5.16-linux-x64 ~/opt/blender
mkdir -p ~/.local/bin; ln -sfn ~/opt/blender/blender ~/.local/bin/blender
~/opt/blender/blender --version | head -1'

grep -q 'local/bin' "$H/.bashrc" || echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$H/.bashrc"

if [ -n "$CHAT" ]; then
  say "Models: nomic-embed-text + $CHAT"
  ollama pull nomic-embed-text
  ollama pull "$CHAT"
  ollama list
fi

say "DONE"
echo "Ollama: http://localhost:11434 (Windows can use the same address)"
echo "Open Ubuntu:   wsl -d $(. /etc/os-release; echo Ubuntu-$VERSION_ID)"
echo "Then sign in once: claude   |   codex   |   gh auth login"
'@
$tmp = Join-Path $env:TEMP "ai-setup-inside.sh"
[IO.File]::WriteAllText($tmp, ($inside -replace "`r`n", "`n"))
$lin = (wsl.exe -d $Distro -u root -- wslpath -u ($tmp -replace '\\', '/') | Out-String).Trim()

Say "Linux settings (systemd)"
wsl.exe -d $Distro -u root -- bash $lin conf $LinuxUser
if ($LASTEXITCODE -ne 0) { throw "writing /etc/wsl.conf failed" }
Ok "/etc/wsl.conf written"

Say "Restarting WSL so systemd + .wslconfig take effect"
Warn "This closes anything running in WSL right now (TRELLIS, servers...)."
Read-Host "   Press Enter to restart WSL (Ctrl+C to stop here)"
wsl.exe --shutdown
Start-Sleep 3

Say "Installing inside $Distro (10-30 min, most of it downloads)"
wsl.exe -d $Distro -u root -- bash $lin full $LinuxUser $chat
if ($LASTEXITCODE -ne 0) { Warn "a step failed: scroll up for the first error, then run the same command again (finished steps are skipped)"; return }
Remove-Item $tmp -ErrorAction SilentlyContinue
Write-Host "`nAll set. Open it any time with:  wsl -d $Distro" -ForegroundColor Green
