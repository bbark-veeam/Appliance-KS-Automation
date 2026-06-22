#requires -Version 5.1
<#
.SYNOPSIS
  Build a golden Veeam appliance ISO on a remote Linux host, driven from Windows.

.DESCRIPTION
  ORCHESTRATOR ONLY — this does NOT build the ISO on Windows. The repack still runs
  on Linux with xorriso (the only reliable way to preserve the appliance's UEFI boot).
  This script just automates the push -> build -> pull dance over SSH:

    1. uploads the kit + your source ISO to a Linux build host,
    2. runs make-golden-iso.sh there INTERACTIVELY (you answer the role/password/NTP
       prompts live in this window — passwords are entered on the Linux side and never
       touch this script or PowerShell history),
    3. downloads the built *_UNATTENDED.iso (and the secrets file) back here,
    4. on SUCCESS, deletes the remote copies (they contain cleartext credentials).
       On FAILURE it KEEPS them so you can retry the download without rebuilding,
       and prints the exact commands to re-pull and then clean up.

  STRONGLY RECOMMENDED: use SSH KEY auth (-IdentityFile, or an ssh-agent key). With a
  password, Windows OpenSSH cannot reuse one connection, so you'll be prompted on every
  step — and a single mistyped password can interrupt the run. A key = zero prompts.

  REQUIREMENTS:
    - Windows OpenSSH client (ssh.exe / scp.exe). Install once if missing:
        Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0
    - A Linux build host reachable over SSH with: xorriso, python3, and the login
      user either root OR able to sudo (the build loop-mounts the UEFI image -> needs
      root). Connecting as root@host is simplest.
    - Run this from the kit folder (the .sh + unattended-block.tmpl live next to it).

.PARAMETER BuildHost
  SSH target: user@host (e.g. root@10.0.0.50 or administrator@test-rocky.hackshack.local).

.PARAMETER IsoPath
  Local path to the source Veeam ISO (the VIA ISO for proxy/hardened-repo, the VSA ISO
  for vsa). Pick the matching role at the interactive prompt.

.PARAMETER OutputDir
  Local folder to save the built ISO + secrets file. Default: current folder.

.PARAMETER IdentityFile
  Path to an SSH private key. STRONGLY recommended (avoids repeated password prompts).

.PARAMETER KeepRemote
  Debug only: skip remote cleanup even on success. Leaves cleartext credentials on the
  build host — delete them by hand afterward.

.EXAMPLE
  .\make-golden-remote.ps1 -BuildHost root@10.0.0.50 -IsoPath .\VeeamInfrastructureAppliance_<version>.iso -IdentityFile ~\.ssh\id_ed25519
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BuildHost,
    [Parameter(Mandatory)][string]$IsoPath,
    [string]$OutputDir = ".",
    [string]$IdentityFile,
    [switch]$KeepRemote
)
$ErrorActionPreference = 'Stop'

# ---- preflight --------------------------------------------------------------
foreach ($t in 'ssh', 'scp') {
    if (-not (Get-Command $t -ErrorAction SilentlyContinue)) {
        throw "$t not found. Install the Windows OpenSSH client:  Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0"
    }
}
if (-not (Test-Path -LiteralPath $IsoPath)) { throw "Source ISO not found: $IsoPath" }
$iso = Get-Item -LiteralPath $IsoPath
$kit = $PSScriptRoot
$needed = @('make-golden-iso.sh', 'build-appliance-iso.sh', 'generate-secrets.sh',
            'check-credentials.sh', 'kslog.sh', 'unattended-block.tmpl', 'VERSION')
foreach ($f in $needed) {
    if (-not (Test-Path (Join-Path $kit $f))) { throw "Kit file missing next to this script: $f (run this from the kit folder)" }
}
if (-not (Test-Path -LiteralPath $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir | Out-Null }

# ---- transport log (Veeam job-style; this .ps1 is the Windows orchestrator) --
# Thin, FILE-ONLY record of THIS script's push/build/pull/cleanup actions (the
# friendly console output is unchanged). It NEVER handles secrets — the build is
# interactive on Linux — so it cannot leak any. The authoritative job + agent
# logs are produced on Linux and pulled back after the build.
$TLog = Join-Path $OutputDir ("Job.make-golden-remote-{0}.log" -f (Get-Date -Format "yyyy-MM-ddTHH-mm-ssZ"))
function Write-TLog {
    param([string]$Level = 'Info', [Parameter(Mandatory)][string]$Msg)
    $line = "[{0}]    <{1}>    {2,-7}    {3}" -f (Get-Date -Format "dd.MM.yyyy HH:mm:ss.fff"), $PID, $Level, $Msg
    try { Add-Content -LiteralPath $TLog -Value $line } catch { }
}
try {
    Set-Content -LiteralPath $TLog -Value @(
        ""
        "==================================================================="
        "Starting new log"
        "Tool: [Veeam Appliance Kickstart - COMMUNITY TOOL, NOT an official Veeam product]"
        "Report issues: [https://github.com/bbark-veeam/Appliance-KS-Automation/issues]"
        ("Module: [make-golden-remote.ps1] (Windows transport orchestrator). PID: [{0}], Host: [{1}]" -f $PID, $env:COMPUTERNAME)
        ("CmdLineParams: [BuildHost={0}; IsoPath={1}; OutputDir={2}]" -f $BuildHost, $iso.Name, $OutputDir)
        ""
    )
} catch { }

$sshOpts = @()
if ($IdentityFile) {
    $sshOpts += @('-i', $IdentityFile)
}
else {
    Write-Warning "No -IdentityFile given: with password auth you'll be prompted on EVERY step, and a mistyped password can interrupt the run. Set up SSH key auth and pass -IdentityFile for a prompt-free, robust run."
}

# Retry wrapper for the non-interactive ssh/scp steps, so one fumbled password (or a
# transient hiccup) re-prompts instead of aborting. NOT used for the interactive build.
function Invoke-Net {
    param([Parameter(Mandatory)][scriptblock]$Action, [string]$What = 'step', [int]$Tries = 3)
    for ($i = 1; $i -le $Tries; $i++) {
        & $Action
        if ($LASTEXITCODE -eq 0) { return $true }
        if ($i -lt $Tries) { Write-Warning ("{0} failed (attempt {1}/{2}) — retrying..." -f $What, $i, $Tries) }
    }
    return $false
}

# ---- create remote working dir ----------------------------------------------
Write-Host "Connecting to $BuildHost ..."
Write-TLog -Msg "Connecting to $BuildHost"
$remote = (& ssh @sshOpts $BuildHost 'mktemp -d' | Select-Object -Last 1)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($remote)) {
    throw "Could not open an SSH session / create a remote working dir on $BuildHost (check host, auth, connectivity)."
}
$remote = $remote.Trim()
Write-Host "Remote work dir: $remote"
Write-TLog -Msg "Remote work dir: $remote"

$success = $false
$built = $false
try {
    # ---- upload kit + ISO ---------------------------------------------------
    Write-Host "Uploading kit files ..."
    Write-TLog -Msg ("Uploading kit ({0} files, incl. kslog.sh)" -f $needed.Count)
    $kitPaths = $needed | ForEach-Object { Join-Path $kit $_ }
    if (-not (Invoke-Net -What 'Kit upload' -Action { & scp @sshOpts @kitPaths "${BuildHost}:${remote}/" })) {
        throw "Kit upload failed."
    }

    Write-Host ("Uploading ISO ({0:N2} GB) — large transfer, please wait ..." -f ($iso.Length / 1GB))
    Write-TLog -Msg ("Uploading source ISO {0} ({1:N2} GB)" -f $iso.Name, ($iso.Length / 1GB))
    if (-not (Invoke-Net -What 'ISO upload' -Action { & scp @sshOpts $iso.FullName "${BuildHost}:${remote}/" })) {
        Write-TLog -Level Error -Msg "ISO upload failed"
        throw "ISO upload failed."
    }

    # ---- interactive build (you answer the prompts) -------------------------
    $isoName = $iso.Name
    $buildCmd = "cd '$remote' && chmod +x *.sh && sudo ./make-golden-iso.sh './$isoName'"
    Write-Host "`n=== Starting interactive build on $BuildHost — answer the prompts below ===`n"
    Write-TLog -Msg "Invoking interactive build (credentials entered on Linux; not captured here)"
    & ssh -t @sshOpts $BuildHost $buildCmd
    if ($LASTEXITCODE -ne 0) {
        Write-TLog -Level Error -Msg "Remote build failed (exit $LASTEXITCODE)"
        throw "Remote build failed (exit $LASTEXITCODE). The remote dir is kept for inspection (see below)."
    }

    # ---- locate + make readable (one round-trip), then pull -----------------
    $info = & ssh @sshOpts $BuildHost "cd '$remote' && sudo chown `$(id -un):`$(id -gn) *_UNATTENDED.iso veeam-*-secrets-*.txt 2>/dev/null; ls -1 *_UNATTENDED.iso 2>/dev/null; echo '---SECRETS---'; ls -1 veeam-*-secrets-*.txt 2>/dev/null"
    $sep = [array]::IndexOf($info, '---SECRETS---')
    $isoOut = if ($sep -ge 1) { ($info[0..($sep - 1)] | Where-Object { $_ } | Select-Object -Last 1) } else { $null }
    $secOut = if ($sep -ge 0 -and $sep -lt ($info.Count - 1)) { ($info[($sep + 1)..($info.Count - 1)] | Where-Object { $_ } | Select-Object -Last 1) } else { $null }
    if ([string]::IsNullOrWhiteSpace($isoOut)) {
        throw "No built ISO (*_UNATTENDED.iso) found on the remote — the build may not have completed."
    }
    $built = $true
    $isoOut = $isoOut.Trim()
    Write-TLog -Msg "Built ISO: $isoOut"

    Write-Host "`nDownloading built ISO ..."
    if (-not (Invoke-Net -What 'ISO download' -Action { & scp @sshOpts "${BuildHost}:${remote}/${isoOut}" $OutputDir })) {
        Write-TLog -Level Error -Msg "Built-ISO download failed"
        throw "Download of the built ISO failed."
    }
    Write-TLog -Msg "Downloaded built ISO to $OutputDir"
    if (-not [string]::IsNullOrWhiteSpace($secOut)) {
        $secOut = $secOut.Trim()
        Invoke-Net -What 'secrets download' -Action { & scp @sshOpts "${BuildHost}:${remote}/${secOut}" $OutputDir } | Out-Null
        Write-TLog -Msg "Downloaded secrets file: $secOut (SENSITIVE — contents not logged)"
    }

    # Pull the Linux job + agent logs back (non-secret: job log is masked, agent log
    # is secret-free). Best-effort, single attempt — never fail the run over logs.
    Write-Host "Downloading build logs (job + agent) ..."
    & scp -r @sshOpts "${BuildHost}:${remote}/logs" $OutputDir 2>$null
    if ($LASTEXITCODE -eq 0) { Write-TLog -Msg "Downloaded build logs to $OutputDir\logs" }
    else { Write-TLog -Level Warning -Msg "Build logs not pulled (none present or transfer failed)" }

    $success = $true
    $outResolved = (Resolve-Path $OutputDir).Path
    Write-TLog -Msg "SUCCESS — saved to $outResolved (ISO: $isoOut)"
    Write-Host "`nDone. Saved to: $outResolved"
    Write-Host "  ISO     : $isoOut"
    if (-not [string]::IsNullOrWhiteSpace($secOut)) {
        Write-Host "  Secrets : $secOut"
        Write-Host "  NOTE: the ISO and the secrets file contain cleartext credentials — store them securely and delete after the fleet rollout."
    }
}
finally {
    $optStr = ($sshOpts -join ' ')
    if ($success -and -not $KeepRemote) {
        Write-Host "Cleaning up remote build host (removing the kit, ISOs, and secrets) ..."
        & ssh @sshOpts $BuildHost "sudo rm -rf '$remote'" 2>$null
        Write-TLog -Msg "Cleaned up remote workdir $remote"
    }
    elseif ($KeepRemote) {
        Write-Warning "KeepRemote set: remote copies (with cleartext credentials) left at ${BuildHost}:$remote. Remove manually:  ssh $optStr $BuildHost 'sudo rm -rf $remote'"
        Write-TLog -Level Warning -Msg "KeepRemote set: remote workdir kept ($remote) — holds cleartext credentials"
    }
    else {
        # Failure path — DO NOT delete; the built ISO may still be there. Let the user retry the pull.
        Write-Warning "Run did not complete — the remote dir is KEPT so you don't lose the build:"
        Write-Host    "    ${BuildHost}:$remote"
        if ($built) {
            Write-Host "  The ISO built successfully; only the transfer failed. Retry just the download:"
            Write-Host "    scp $optStr ${BuildHost}:$remote/*_UNATTENDED.iso `"$OutputDir`""
        }
        Write-Host    "  When you're done, DELETE the remote copy (it holds cleartext credentials):"
        Write-Host    "    ssh $optStr $BuildHost 'sudo rm -rf $remote'"
        Write-TLog -Level Error -Msg "Run did not complete — remote workdir kept ($remote)"
    }
    if ($success) { Write-TLog -Msg "TRANSPORT RESULT: SUCCESS" }
    else { Write-TLog -Level Error -Msg "TRANSPORT RESULT: FAILURE" }
    Write-Host "Transport log: $TLog"
}
