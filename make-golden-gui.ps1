#requires -Version 5.1
<#
.SYNOPSIS
  Build a golden Veeam appliance ISO on a remote Linux host, driven from Windows -
  NON-INTERACTIVELY (the engine behind the single-window GUI).

.DESCRIPTION
  ORCHESTRATOR ONLY - the ISO is still built on Linux with xorriso. This drives the
  remote build WITHOUT prompts: it uploads the kit + your ISO to a Linux build host,
  runs `make-golden-iso.sh --non-interactive` there, and downloads the built ISO +
  the build LOGS + the secrets file back.

  SECRETS handling (Brad-signed-off design, v2.0.0): passwords are taken as
  SecureString, marshalled to plaintext ONLY at the moment of the build, and fed to
  the remote script over the encrypted SSH channel via STDIN - never on argv, env,
  or shell history. The plaintext is cleared from memory immediately after. The
  remote build files (filled block, secrets file, ISO) are CLEANED UP on success.

  Two ways to run:
    * Headless transport (Phase 2) - pass parameters; testable from the jumpbox.
    * Single-window GUI (Phase 3, -Gui) - a WinForms form that collects the same
      values and calls the very same transport. Launch it with Launch-GUI.cmd
      (which supplies the -STA WinForms needs), or:  powershell -STA -File this.ps1 -Gui

  Use SSH KEY auth (-IdentityFile) - password auth prompts on every step and can
  break the build's stdin secret feed.

.EXAMPLE
  $admin = Read-Host 'veeamadmin pw' -AsSecureString
  $so    = Read-Host 'veeamso pw'    -AsSecureString
  .\make-golden-gui.ps1 -BuildHost root@10.0.0.50 -IdentityFile ~\.ssh\ks-build-key `
     -IsoPath .\VeeamInfrastructureAppliance_13.0.2.29.iso -Role proxy -Ntp 10.0.0.5 `
     -VeeamAdminPassword $admin -VeeamsoPassword $so

.EXAMPLE
  # Single-window GUI (double-click Launch-GUI.cmd, or:)
  powershell -NoProfile -ExecutionPolicy Bypass -STA -File .\make-golden-gui.ps1 -Gui
#>
[CmdletBinding()]
param(
    [string]$BuildHost,
    [string]$IsoPath,
    [string]$IdentityFile,
    [string]$OutputDir = ".",
    [ValidateSet('proxy', 'vmware-proxy', 'hardened-repo', 'vsa', 'vbem')][string]$Role,
    [string]$HostnamePrefix,
    [string]$Ntp,
    [switch]$SkipNtpSync,
    [switch]$VeeamAdminMfa,
    [switch]$NoVeeamso,
    [switch]$ByoKeys,
    [string]$CustomPost,
    [securestring]$VeeamAdminPassword,
    [securestring]$VeeamsoPassword,
    [string]$VeeamAdminMfaKey,
    [string]$VeeamsoMfaKey,
    [string]$VeeamsoRecoveryToken,
    [switch]$PrepOnly,
    [switch]$KeepRemote,
    [switch]$KeepOnFailure,   # GUI "Keep on failure" (Advanced): on failure, KEEP the remote workdir
                              # (so a built-but-undownloaded ISO isn't lost) instead of the default rm -rf
    [ValidateSet('SSH', 'WSL')][string]$BuildBackend = 'SSH',   # SSH = remote Linux over SSH (default); WSL = local WSL2
    [string]$WslDistro,       # WSL backend only: distro name (blank = WSL default distro)
    [switch]$Gui   # launch the WinForms single-window form (collects the above, then runs the transport)
)
$ErrorActionPreference = 'Stop'

# =============================================================================
#  THE TRANSPORT  (Phase 2 engine) - one definition, two call sites:
#    * non-GUI path below calls it synchronously in THIS process.
#    * the GUI runs it in a background runspace (live status, no frozen window).
#  It is a scriptblock so the GUI runspace gets the full text via .ToString().
#  $KitRoot is passed in explicitly because $PSScriptRoot is empty inside a
#  runspace launched from .AddScript().
# =============================================================================
$TransportScript = {
    [CmdletBinding()]
    param(
        [string]$BuildHost,
        [string]$IsoPath,
        [string]$IdentityFile,
        [string]$OutputDir = ".",
        [string]$Role,
        [string]$HostnamePrefix,
        [string]$Ntp,
        [switch]$SkipNtpSync,
        [switch]$VeeamAdminMfa,
        [switch]$NoVeeamso,
        [switch]$ByoKeys,
        [string]$CustomPost,
        [securestring]$VeeamAdminPassword,
        [securestring]$VeeamsoPassword,
        [string]$VeeamAdminMfaKey,
        [string]$VeeamsoMfaKey,
        [string]$VeeamsoRecoveryToken,
        [switch]$PrepOnly,
        [switch]$KeepRemote,
        [switch]$KeepOnFailure,
        [string]$KitRoot,
        [ValidateSet('SSH', 'WSL')][string]$BuildBackend = 'SSH',   # SSH = remote Linux (default); WSL = local WSL2
        [string]$WslDistro                                          # WSL backend: distro name; blank = WSL default distro
    )
    # Native ssh/scp write progress + banners to stderr; under Windows PowerShell 5.1,
    # $ErrorActionPreference='Stop' turns ANY native stderr into a TERMINATING error
    # (a 5.1-only quirk - PowerShell 7 does not). This orchestrator is almost entirely
    # native-command driven and checks $LASTEXITCODE + throws explicitly after every
    # step, so Continue is correct here; Stop would abort mid-build on a harmless banner.
    $ErrorActionPreference = 'Continue'

    # ---- helpers ------------------------------------------------------------
    # Marshal a SecureString to plaintext (only at send time; caller clears it ASAP).
    function ConvertFrom-SecureToPlain {
        param([securestring]$Secure)
        if (-not $Secure) { return $null }
        [System.Net.NetworkCredential]::new('', $Secure).Password
    }

    # POSIX single-quote escaping for any value that ends up interpolated into the
    # remote build command (NTP, hostname prefix, file names, ...). Wraps the value in
    # single quotes and rewrites embedded ' as '\'' so the remote shell treats it
    # LITERALLY - the security boundary against command injection on the build host.
    # (The GUI also format-validates these before Build; this is the defense-in-depth
    # layer that holds even if a value reaches the transport unchecked.)
    function ConvertTo-ShSq { param([string]$s) "'" + ($s -replace "'", "'\''") + "'" }

    # Assemble the plaintext key=value secrets blob fed to the build over stdin (NOT argv).
    # Single source for both backends (SSH + WSL); caller scrubs the result ASAP. The build
    # host strips any trailing CR, so a Windows CRLF on the pipe can't corrupt a value.
    function New-SecretBlob {
        $lines = @("veeamadmin.password=" + (ConvertFrom-SecureToPlain $VeeamAdminPassword))
        if (-not $NoVeeamso) { $lines += "veeamso.password=" + (ConvertFrom-SecureToPlain $VeeamsoPassword) }
        if ($ByoKeys) {
            if ($VeeamAdminMfaKey)                          { $lines += "veeamadmin.mfaSecretKey=$VeeamAdminMfaKey" }
            if (-not $NoVeeamso -and $VeeamsoMfaKey)         { $lines += "veeamso.mfaSecretKey=$VeeamsoMfaKey" }
            if (-not $NoVeeamso -and $VeeamsoRecoveryToken)  { $lines += "veeamso.recoveryToken=$VeeamsoRecoveryToken" }
        }
        ($lines -join "`n")
    }

    # Translate a Windows path to its WSL /mnt path in-process (avoids quoting a backslash
    # path through wsl.exe + a subprocess per file). C:\Users\x -> /mnt/c/Users/x.
    function ConvertTo-WslPath {
        param([string]$WinPath)
        $full = $WinPath
        try { $rp = (Resolve-Path -LiteralPath $WinPath -ErrorAction Stop).Path; if ($rp) { $full = $rp } } catch { }
        if ($full -match '^([A-Za-z]):[\\/](.*)$') { '/mnt/' + $Matches[1].ToLower() + '/' + ($Matches[2] -replace '\\', '/') }
        else { $full -replace '\\', '/' }
    }

    # Lock a pulled-back artifact down to the current Windows user - the built ISO and
    # the secrets file both carry CLEARTEXT credentials, so on a shared/multi-user box
    # they should not inherit the output folder's (often wide) ACLs. Mirrors the Linux
    # side's `chmod 600` intent. Local Administrators is deliberately NOT granted: an
    # admin who genuinely needs the file can take ownership (they hold SeTakeOwnership),
    # so least-privilege-by-default is the right posture for a cleartext-credential file.
    # Best-effort: a failure WARNS but never fails the build (the file still exists; the
    # operator is told to secure/delete it). Windows-only - .NET file ACLs aren't
    # supported elsewhere, so it's a no-op on pwsh/Linux.
    function Protect-LocalFile {
        param([string]$Path)
        if (-not ($PSVersionTable.PSEdition -eq 'Desktop' -or $IsWindows)) { return }
        try {
            $me  = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
            $acl = Get-Acl -LiteralPath $Path
            $acl.SetAccessRuleProtection($true, $false)            # disable inheritance, drop inherited ACEs
            # Strip any remaining EXPLICIT ACEs (inherited ones are already gone via the
            # protection call). Null-guarded: on a freshly downloaded file .Access can come
            # back empty/null, and @($null) would otherwise pass $null to RemoveAccessRule.
            foreach ($rule in @($acl.Access)) { if ($rule) { [void]$acl.RemoveAccessRule($rule) } }
            $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($me, 'FullControl', 'Allow')))
            $acl.SetOwner($me)
            Set-Acl -LiteralPath $Path -AclObject $acl
            Write-TLog -Msg "Restricted ACL on $(Split-Path -Leaf $Path) to current user only"
        } catch {
            Write-Warning "Could not restrict permissions on '$Path' - it holds CLEARTEXT credentials; secure or delete it manually. ($($_.Exception.Message))"
            Write-TLog -Level Warning -Msg "ACL restriction FAILED on $(Split-Path -Leaf $Path): $($_.Exception.Message)"
        }
    }

    # Transport log (Veeam job-style, FILE-ONLY). NEVER receives a secret.
    function Write-TLog {
        param([string]$Level = 'Info', [Parameter(Mandatory)][string]$Msg)
        $line = "[{0}]    <{1}>    {2,-7}    {3}" -f (Get-Date -Format "dd.MM.yyyy HH:mm:ss.fff"), $PID, $Level, $Msg
        try { Add-Content -LiteralPath $script:TLog -Value $line } catch { }
    }

    # Retry wrapper for non-interactive ssh/scp steps (not the build itself).
    function Invoke-Net {
        param([Parameter(Mandatory)][scriptblock]$Action, [string]$What = 'step', [int]$Tries = 3)
        for ($i = 1; $i -le $Tries; $i++) {
            & $Action
            if ($LASTEXITCODE -eq 0) { return $true }
            if ($i -lt $Tries) { Write-Warning ("{0} failed (attempt {1}/{2}) - retrying..." -f $What, $i, $Tries) }
        }
        return $false
    }

    # Pull the Linux build logs back (non-secret). Best-effort, with an explicit callout
    # if nothing comes back - the logs are how a failed run gets diagnosed.
    function Receive-RemoteLog {
        # Pull the uniquely-named per-run folder (proxy-<runid>) INTO $OutputDir\logs\.
        # It never pre-exists locally, so scp -r placement is deterministic across scp
        # versions (the old `scp -r .../logs $OutputDir` could land files in the run dir).
        $rf = "$(& ssh @sshOpts $BuildHost "ls -1 '$remote/logs' 2>/dev/null | head -1")".Trim()
        if (-not $rf) { Write-Warning "Build logs were NOT pulled back (none present on the remote) - diagnose before cleanup."; Write-TLog -Level Warning -Msg "Build logs not pulled (none present on remote)"; return }
        & scp -r @sshOpts "${BuildHost}:${remote}/logs/$rf" "$script:LogDir" 2>$null
        if ($LASTEXITCODE -eq 0) { Write-Host "Build logs saved to $script:LogDir\$rf"; Write-TLog -Msg "Downloaded build logs to $script:LogDir\$rf" }
        else { Write-Warning "Build logs were NOT pulled back (transfer failed) - diagnose from the remote before it's removed."; Write-TLog -Level Warning -Msg "Build logs not pulled (transfer failed)" }
    }

    # Fully remove the remote workdir, with a callout if the removal itself fails (so a
    # stray cleartext-bearing artifact can't silently linger and get in the way later).
    function Remove-Remote {
        & ssh @sshOpts $BuildHost "$($script:SudoPrefix)rm -rf '$remote'" 2>$null
        if ($LASTEXITCODE -eq 0) { Write-Host "Cleaned up remote workdir."; Write-TLog -Msg "Cleaned up remote workdir $remote" }
        else {
            $o = ($sshOpts -join ' ')
            Write-Warning "CLEANUP FAILED - the remote workdir may remain at ${BuildHost}:$remote (it holds cleartext credentials). Remove it manually:  ssh $o $BuildHost 'sudo rm -rf $remote'"
            Write-TLog -Level Error -Msg "cleanup FAILED (rm -rf returned non-zero) - remote workdir may remain: $remote"
        }
    }

    # ---- preflight ----------------------------------------------------------
    foreach ($req in 'IsoPath', 'Role', 'Ntp') {
        if ([string]::IsNullOrWhiteSpace((Get-Variable $req -ValueOnly))) { throw "Missing required parameter: -$req" }
    }
    if ($BuildBackend -eq 'SSH') {
        foreach ($t in 'ssh', 'scp') {
            if (-not (Get-Command $t -ErrorAction SilentlyContinue)) {
                throw "$t not found. Install the Windows OpenSSH client:  Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0"
            }
        }
        if ([string]::IsNullOrWhiteSpace($BuildHost)) { throw "Missing required parameter: -BuildHost (SSH backend)" }
    } else {
        # WSL2 local backend: wsl.exe must be present (WSL2 installed + a distro).
        if (-not (Get-Command 'wsl.exe' -ErrorAction SilentlyContinue)) {
            throw "wsl.exe not found - WSL2 is not installed/enabled. Run 'wsl --install', or use the Remote (SSH) backend."
        }
    }
    if (-not $VeeamAdminPassword) { throw "Missing required -VeeamAdminPassword (SecureString)" }
    if (-not $NoVeeamso -and -not $VeeamsoPassword) { throw "Missing -VeeamsoPassword (SecureString) - or pass -NoVeeamso to disable the account" }
    if (-not (Test-Path -LiteralPath $IsoPath)) { throw "Source ISO not found: $IsoPath" }
    if ($CustomPost -and -not (Test-Path -LiteralPath $CustomPost)) { throw "Custom %post file not found: $CustomPost" }
    $iso = Get-Item -LiteralPath $IsoPath
    $kit = if ([string]::IsNullOrWhiteSpace($KitRoot)) { $PSScriptRoot } else { $KitRoot }
    $needed = @('make-golden-iso.sh', 'build-appliance-iso.sh', 'generate-secrets.sh',
                'check-credentials.sh', 'kslog.sh', 'unattended-block.tmpl', 'VERSION')
    foreach ($f in $needed) {
        if (-not (Test-Path (Join-Path $kit $f))) { throw "Kit file missing next to this script: $f (run this from the kit folder)" }
    }
    if (-not (Test-Path -LiteralPath $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir | Out-Null }

    # accept-new: auto-accept a NEW host's key on first connect (so a non-interactive /
    # GUI run never stalls on the "Are you sure you want to continue connecting?" prompt),
    # while still REFUSING a CHANGED key (MITM protection after first contact). The GUI
    # additionally presents an explicit type-to-confirm dialog BEFORE this runs, so the
    # key is normally already in known_hosts by the time the transport connects.
    $sshOpts = @('-o', 'StrictHostKeyChecking=accept-new')
    if ($BuildBackend -eq 'SSH') {
        if ($IdentityFile) { $sshOpts += @('-i', $IdentityFile) }
        else { Write-Warning "No -IdentityFile: with password auth you'll be prompted on EVERY step (and the build's stdin secret feed can break). Use SSH key auth." }
    }

    # All logs (this transport log + the pulled-back per-run folder) live under
    # $OutputDir\logs\ so they land in ONE predictable place; the ISO + secrets file
    # stay in $OutputDir root.
    $script:LogDir = Join-Path $OutputDir 'logs'
    New-Item -ItemType Directory -Force -Path $script:LogDir | Out-Null
    $script:TLog = Join-Path $script:LogDir ("Job.make-golden-gui-{0}.log" -f (Get-Date -Format "yyyy-MM-ddTHH-mm-ssZ"))
    try {
        Set-Content -LiteralPath $script:TLog -Value @(
            ""
            "==================================================================="
            "Starting new log"
            "Tool: [Veeam Appliance Kickstart - COMMUNITY TOOL, NOT an official Veeam product]"
            "Report issues: [https://github.com/bbark-veeam/Appliance-KS-Automation/issues]"
            ("Module: [make-golden-gui.ps1] (Windows non-interactive transport). PID: [{0}], Host: [{1}]" -f $PID, $env:COMPUTERNAME)
            ("CmdLineParams: [Backend={0}; Target={1}; Role={2}; IsoPath={3}; OutputDir={4}; PrepOnly={5}]" -f $BuildBackend, $(if ($BuildBackend -eq 'WSL') { if ($WslDistro) { "wsl:$WslDistro" } else { 'wsl:(default)' } } else { $BuildHost }), $Role, $iso.Name, $OutputDir, [bool]$PrepOnly)
            ""
        )
    } catch { }

    # ---- build the make-golden non-interactive flag list (NON-SECRET only) ------
    # Every interpolated value is shell-single-quote-escaped (ConvertTo-ShSq) so it
    # cannot break out of the remote command line - Role/Ntp/HostnamePrefix and the
    # custom-post file name are all operator-supplied text.
    $mgFlags = "--non-interactive --role $(ConvertTo-ShSq $Role) --ntp $(ConvertTo-ShSq $Ntp)"
    if ($HostnamePrefix) { $mgFlags += " --hostname-prefix $(ConvertTo-ShSq $HostnamePrefix)" }
    if ($SkipNtpSync)    { $mgFlags += " --skip-ntp-sync" }
    if ($VeeamAdminMfa)  { $mgFlags += " --veeamadmin-mfa" }
    if ($NoVeeamso)      { $mgFlags += " --no-veeamso" }
    if ($ByoKeys)        { $mgFlags += " --byo-keys" }
    if ($CustomPost)     { $mgFlags += " --custom-post $(ConvertTo-ShSq ('./' + (Split-Path -Leaf $CustomPost)))" }
    if ($PrepOnly)       { $mgFlags += " --prep-only" }

    # ---- shared pre-copy check: does the ISO contain the selected role's kickstart? ----
    # Catch a wrong ISO (e.g. role 'vbem' on a VIA ISO) BEFORE the expensive transfer -
    # the scp UPLOAD to the remote host (SSH backend) or the copy into WSL. Each role's
    # stock kickstart lives at the ISO ROOT.
    #   GOTCHA (why this isn't a naive Test-Path): Windows CDFS exposes the ISO9660
    #   namespace, which UPPERCASES names and turns '-' into '_' - so proxy-ks.cfg shows
    #   up as PROXY_KS.CFG. A Test-Path for the real (Rock Ridge) name ALWAYS misses and
    #   would reject every valid build. So we check BOTH the literal name (in case a
    #   future ISO carries Joliet/Rock Ridge to Windows) AND the ISO9660-mangled form,
    #   across every mounted volume. Best-effort: if mounting is blocked we warn and let
    #   build-appliance-iso.sh's own xorriso extract-or-die be the authoritative backstop.
    $roleKs = @{ 'proxy' = 'proxy-ks.cfg'; 'vmware-proxy' = 'vmware-proxy-ks.cfg'; 'hardened-repo' = 'hardened-repo-ks.cfg'; 'vsa' = 'vbr-ks.cfg'; 'vbem' = 'vbem-ks.cfg' }[$Role]
    if ($roleKs) {
        $isoHasKs = $null
        $ksNames  = @($roleKs, ($roleKs.ToUpper() -replace '-', '_'))   # literal + ISO9660-mangled (PROXY_KS.CFG)
        try {
            $di   = Mount-DiskImage -ImagePath $iso.FullName -PassThru -ErrorAction Stop
            $drvs = @($di | Get-Volume | Where-Object DriveLetter | ForEach-Object DriveLetter)
            if ($drvs.Count -gt 0) {
                $isoHasKs = $false
                foreach ($d in $drvs) {
                    foreach ($n in $ksNames) {
                        if (Test-Path -LiteralPath ("{0}:\{1}" -f $d, $n)) { $isoHasKs = $true; break }
                    }
                    if ($isoHasKs) { break }
                }
            }
        } catch {
            Write-Warning "Could not mount the ISO to pre-verify the role kickstart ($($_.Exception.Message)); proceeding - the build will verify."
        } finally {
            Dismount-DiskImage -ImagePath $iso.FullName -ErrorAction SilentlyContinue | Out-Null
        }
        if ($isoHasKs -eq $false) {
            Write-TLog -Level Error -Msg "Pre-check FAILED: ISO has no /$roleKs for role $Role"
            throw "The selected ISO has no '/$roleKs' at its root, so it can't build the '$Role' role. Wrong ISO? proxy/vmware-proxy/hardened-repo need the VeeamInfrastructureAppliance ISO; vsa/vbem need the VeeamSoftwareAppliance ISO."
        }
        if ($isoHasKs) { Write-TLog -Msg "Pre-check OK: ISO contains /$roleKs (role $Role)" }
    }

    # =========================================================================
    #  WSL2 LOCAL BACKEND - build in WSL2 on this machine as root (no SSH).
    #  Mirrors the SSH flow with wsl.exe + cp instead of ssh + scp; reuses the
    #  same non-interactive make-golden engine + stdin secrets (+ build-host CR
    #  strip) + Protect-LocalFile + logging.
    # =========================================================================
    if ($BuildBackend -eq 'WSL') {
        $env:WSL_UTF8 = '1'   # force UTF-8 from wsl.exe so captured output parses (no UTF-16/nulls)
        $dd = @(); if ($WslDistro) { $dd = @('-d', $WslDistro) }
        $wslLabel = if ($WslDistro) { $WslDistro } else { '(default distro)' }
        Write-Host "Building locally in WSL2: $wslLabel"
        Write-TLog -Msg "WSL backend: distro=$wslLabel"

        $xchk = (& wsl.exe @dd -u root -- bash -lc 'command -v xorriso >/dev/null 2>&1 && echo OK || echo NO' 2>&1 | Select-Object -Last 1)
        if (("$xchk").Trim() -ne 'OK') {
            throw "xorriso is not installed in WSL distro '$wslLabel'. Install it there (sudo apt install -y xorriso  /  sudo dnf install -y xorriso) and retry."
        }

        # Free-space pre-check on the ACTUAL work filesystem (/var/tmp), NOT / and NOT the
        # default /tmp tmpfs. The build copies the source ISO in AND writes the rebuilt ISO
        # in the work dir (~2x the ISO), so require ~2.2x up front. This is the honest reading
        # Stage 0 should give: df'ing / overstates free space (the ext4 vhdx max), and /tmp
        # being a RAM tmpfs understated it (the original failure). df -P guarantees one data line.
        $wkRoot = '/var/tmp'
        $dfRaw  = & wsl.exe @dd -u root -- bash -lc "df -Pk '$wkRoot' 2>/dev/null"
        $dfData = ($dfRaw | Where-Object { "$_" -match '^\S' } | Select-Object -Last 1)
        $cols   = ("$dfData").Trim() -split '\s+'
        $availKb = [int64]0
        if ($cols.Count -ge 4 -and [int64]::TryParse($cols[3], [ref]$availKb)) {
            $availBytes = $availKb * 1024
            $needBytes  = [int64]($iso.Length * 2.2)
            Write-TLog -Msg ("WSL work FS {0}: {1:N1} GB free; need ~{2:N1} GB (~2.2x the {3:N1} GB ISO)" -f $wkRoot, ($availBytes / 1GB), ($needBytes / 1GB), ($iso.Length / 1GB))
            if ($availBytes -lt $needBytes) {
                throw ("Not enough space on the WSL work filesystem {0}: {1:N1} GB free, but the build needs ~{2:N1} GB (the {3:N1} GB source ISO is copied in AND the rebuilt ISO is written there). The WSL ext4 vhdx is capped by free space on the Windows host - free up disk where the distro's vhdx lives, or use the Remote (SSH) backend." -f $wkRoot, ($availBytes / 1GB), ($needBytes / 1GB), ($iso.Length / 1GB))
            }
            Write-Host ("Work FS {0}: {1:N1} GB free (need ~{2:N1} GB) - OK" -f $wkRoot, ($availBytes / 1GB), ($needBytes / 1GB))
        } else {
            Write-Warning "Could not read free space on $wkRoot (df output unparseable); proceeding - xorriso will fail loudly if space runs short."
            Write-TLog -Level Warning -Msg "WSL work FS space pre-check skipped (df unparseable)"
        }

        # Work dir on /var/tmp (ext4 vhdx), NOT the default /tmp: on systemd WSL2 distros /tmp is a
        # RAM-backed tmpfs sized ~50% of VM memory (e.g. 2.9G on a 5.8G box), too small to hold the
        # copied-in source ISO (~1.8G) PLUS the rebuilt output ISO (~1.8G) -> xorriso fails with
        # "Image size ... exceeds free space on media". /var/tmp lives on / with the real vhdx space.
        $remote = (& wsl.exe @dd -u root -- mktemp -d -p /var/tmp 2>&1 | Where-Object { "$_" -match '^/\S' } | Select-Object -Last 1)
        $remote = "$remote".Trim()
        if ([string]::IsNullOrWhiteSpace($remote)) { throw "Could not create a WSL work dir (mktemp -d failed)." }
        Write-Host "WSL work dir: $remote"
        Write-TLog -Msg "WSL work dir: $remote"

        $success = $false; $built = $false
        try {
            Write-TLog -Msg ("Copying kit ({0} files) + ISO into WSL" -f $needed.Count)
            foreach ($f in $needed) {
                $src = ConvertTo-WslPath (Join-Path $kit $f)
                & wsl.exe @dd -u root -- cp "$src" "$remote/"
                if ($LASTEXITCODE -ne 0) { throw "Failed to copy kit file '$f' into WSL." }
            }
            if ($CustomPost) {
                $cpSrc = ConvertTo-WslPath $CustomPost
                & wsl.exe @dd -u root -- cp "$cpSrc" "$remote/"
                if ($LASTEXITCODE -ne 0) { throw "Failed to copy the custom-post file into WSL." }
            }
            $wslIso = ConvertTo-WslPath $iso.FullName
            Write-Host ("Copying ISO ({0:N2} GB) into WSL ..." -f ($iso.Length / 1GB))
            Write-TLog -Msg ("Copying source ISO {0} into WSL" -f $iso.Name)
            & wsl.exe @dd -u root -- cp "$wslIso" "$remote/"
            if ($LASTEXITCODE -ne 0) { throw "Failed to copy the ISO into WSL." }

            $blob = New-SecretBlob
            $isoName = $iso.Name
            $buildCmd = "cd $(ConvertTo-ShSq $remote) && chmod +x *.sh && ./make-golden-iso.sh $mgFlags $(ConvertTo-ShSq ('./' + $isoName))"
            Write-Host "`nBuilding in WSL ($wslLabel), non-interactive ..."
            Write-TLog -Msg "Invoking non-interactive build in WSL (secrets via stdin; not captured here)"
            $blob | & wsl.exe @dd -u root -- bash -c $buildCmd
            $buildRc = $LASTEXITCODE
            $blob = $null; [System.GC]::Collect()
            if ($buildRc -ne 0) { Write-TLog -Level Error -Msg "WSL build failed (exit $buildRc)"; throw "WSL build failed (exit $buildRc). $(if (-not $KeepOnFailure) { 'Re-run with -KeepOnFailure to retain the WSL work dir for inspection.' })" }

            if ($PrepOnly) {
                $success = $true
                Write-TLog -Msg "prep-only build complete (no ISO produced)"
                Write-Host "Prep-only complete in WSL (no ISO). Logs will be copied back."
            } else {
                $info = & wsl.exe @dd -u root -- bash -c "cd $(ConvertTo-ShSq $remote) && ls -1 *_UNATTENDED.iso 2>/dev/null; echo '---SECRETS---'; ls -1 veeam-*-secrets-*.txt 2>/dev/null"
                $sep = [array]::IndexOf($info, '---SECRETS---')
                $isoOut = if ($sep -ge 1) { ($info[0..($sep - 1)] | Where-Object { $_ } | Select-Object -Last 1) } else { $null }
                $secOut = if ($sep -ge 0 -and $sep -lt ($info.Count - 1)) { ($info[($sep + 1)..($info.Count - 1)] | Where-Object { $_ } | Select-Object -Last 1) } else { $null }
                if ([string]::IsNullOrWhiteSpace($isoOut)) { throw "No built ISO (*_UNATTENDED.iso) in the WSL work dir - the build may not have completed." }
                $built = $true; $isoOut = "$isoOut".Trim()
                Write-TLog -Msg "Built ISO: $isoOut"
                $wslOut = ConvertTo-WslPath ((Resolve-Path $OutputDir).Path)
                Write-Host "`nCopying built ISO back ..."
                & wsl.exe @dd -u root -- cp "$remote/$isoOut" "$wslOut/"
                if ($LASTEXITCODE -ne 0) { Write-TLog -Level Error -Msg "Built-ISO copy-back failed"; throw "Copy-back of the built ISO failed." }
                Write-TLog -Msg "Copied built ISO to $OutputDir"
                Protect-LocalFile (Join-Path $OutputDir $isoOut)
                if (-not [string]::IsNullOrWhiteSpace($secOut)) {
                    $secOut = "$secOut".Trim()
                    & wsl.exe @dd -u root -- cp "$remote/$secOut" "$wslOut/"
                    Protect-LocalFile (Join-Path $OutputDir $secOut)
                    Write-TLog -Msg "Copied secrets file: $secOut (SENSITIVE - contents not logged)"
                }
                $success = $true
            }
            $outResolved = (Resolve-Path $OutputDir).Path
            Write-Host "`nDone. Saved to: $outResolved"
            Write-TLog -Msg "SUCCESS - saved to $outResolved"
        }
        finally {
            if (Get-Variable blob -Scope Local -ErrorAction SilentlyContinue) { $blob = $null; [System.GC]::Collect() }
            $rf = "$(& wsl.exe @dd -u root -- bash -c "ls -1 '$remote/logs' 2>/dev/null | head -1")".Trim()
            if ($rf) {
                $wslLog = ConvertTo-WslPath $script:LogDir
                & wsl.exe @dd -u root -- cp -r "$remote/logs/$rf" "$wslLog/" 2>$null
                if ($LASTEXITCODE -eq 0) { Write-Host "Build logs saved to $script:LogDir\$rf"; Write-TLog -Msg "Copied build logs to $script:LogDir\$rf" }
                else { Write-Warning "Build logs were NOT copied back - diagnose from $remote before cleanup."; Write-TLog -Level Warning -Msg "Build logs not copied (cp failed)" }
            } else { Write-Warning "Build logs were NOT copied back (none present) - diagnose before cleanup."; Write-TLog -Level Warning -Msg "Build logs not copied (none present)" }

            $keep = $KeepRemote -or ((-not $success) -and $KeepOnFailure)
            if ($keep) {
                $why = if ($KeepRemote) { 'KeepRemote' } else { 'KeepOnFailure (run failed)' }
                Write-Warning "WSL work dir KEPT at $remote ($why) - it holds cleartext credentials. Remove it:  wsl.exe $($dd -join ' ') -u root -- rm -rf '$remote'"
                if ($built -and -not $success) { Write-Host "  A built ISO is there; copy it out:  wsl.exe $($dd -join ' ') -u root -- cp '$remote'/*_UNATTENDED.iso <dest>" }
                Write-TLog -Level Warning -Msg "WSL work dir KEPT ($remote) - $why"
            } else {
                & wsl.exe @dd -u root -- rm -rf "$remote" 2>$null
                if ($LASTEXITCODE -eq 0) { Write-Host "Cleaned up WSL work dir."; Write-TLog -Msg "Cleaned up WSL work dir $remote" }
                else { Write-Warning "CLEANUP FAILED - the WSL work dir may remain at $remote (cleartext creds). Remove:  wsl.exe $($dd -join ' ') -u root -- rm -rf '$remote'"; Write-TLog -Level Error -Msg "WSL cleanup FAILED: $remote" }
            }
            if ($success) { Write-TLog -Msg "TRANSPORT RESULT: SUCCESS" } else { Write-TLog -Level Error -Msg "TRANSPORT RESULT: FAILURE" }
            Write-Host "Transport log: $script:TLog"
        }
        return
    }

    Write-Host "Connecting to $BuildHost ..."
    Write-TLog -Msg "Connecting to $BuildHost (non-interactive build, role=$Role)"
    $hostOnly = $BuildHost -replace '^.*@', ''
    # Capture stderr too so we can classify a failure. A CHANGED host key (accept-new
    # refuses it) is a hard SECURITY error - possible MITM - and this tool ships
    # credentials, so we abort + LOG it explicitly rather than treat it as generic.
    $connOut = & ssh @sshOpts $BuildHost 'mktemp -d' 2>&1
    if ($LASTEXITCODE -ne 0) {
        if (($connOut | Out-String) -match 'REMOTE HOST IDENTIFICATION HAS CHANGED') {
            Write-TLog -Level Error -Msg "SECURITY ABORT - SSH host key for $hostOnly has CHANGED (possible MITM). No build run; NO credentials sent."
            throw "SECURITY ALERT: the SSH host key for '$hostOnly' has CHANGED since it was first trusted. This is the classic man-in-the-middle signature, and this tool transmits credentials to the build host - so the run is ABORTED and NOTHING was sent. If the host was legitimately rebuilt, verify its new fingerprint OUT-OF-BAND, then clear the stale key:  ssh-keygen -R '$hostOnly'"
        }
        Write-TLog -Level Error -Msg "SSH connect to $BuildHost failed (host/key/auth/connectivity)"
        throw "Could not open SSH / create a remote work dir on $BuildHost (check host, key/auth, connectivity).`n$($connOut | Out-String)"
    }
    # stdout = the mktemp path (starts with '/'); ignore the first-connect 'Permanently added' notice on stderr.
    $remote = ($connOut | Where-Object { "$_" -match '^/\S' } | Select-Object -Last 1)
    $remote = "$remote".Trim()
    if ([string]::IsNullOrWhiteSpace($remote)) { throw "Could not create a remote work dir on $BuildHost." }
    Write-Host "Remote work dir: $remote"
    Write-TLog -Msg "Remote work dir: $remote"

    $success = $false; $built = $false
    $script:SudoPrefix = ''   # set by the privilege probe below; '' = run as the login user
    try {
        # ---- detect how the build host can patch efiboot.img --------------------
        # build-appliance-iso.sh patches efiboot.img via loop-mount (needs root) OR
        # mtools/mcopy (ROOTLESS). Pick the least-privileged path that works so a
        # non-root login WITH mtools is supported, and we don't sudo when we needn't
        # (sudo -n would otherwise fail a perfectly good rootless build).
        Write-Host "Detecting build privileges on $BuildHost ..."
        $mode = (& ssh @sshOpts $BuildHost 'if [ "$(id -u)" -eq 0 ]; then echo root; elif command -v mcopy >/dev/null 2>&1; then echo mtools; elif sudo -n true 2>/dev/null; then echo sudo; else echo none; fi' | Select-Object -Last 1)
        if ($LASTEXITCODE -ne 0) { throw "Could not probe build privileges on $BuildHost (check host/auth)." }
        switch (("$mode").Trim()) {
            'root'   { $script:SudoPrefix = '';         $privNote = 'root (loop-mount)' }
            'mtools' { $script:SudoPrefix = '';         $privNote = 'non-root + mtools (rootless efiboot patch)' }
            'sudo'   { $script:SudoPrefix = 'sudo -n '; $privNote = 'non-root + passwordless sudo (loop-mount)' }
            default  { throw "Build host '$BuildHost' can't build the ISO: it is not root, has no passwordless sudo, and has no mtools. Install mtools for a rootless build, or grant root / NOPASSWD sudo." }
        }
        Write-Host "  build privilege: $privNote"
        Write-TLog -Msg "Build privilege mode: $privNote"

        # ---- upload kit (+ custom-post) + ISO -----------------------------------
        Write-TLog -Msg ("Uploading kit ({0} files, incl. kslog.sh)" -f $needed.Count)
        $kitPaths = $needed | ForEach-Object { Join-Path $kit $_ }
        if (-not (Invoke-Net -What 'Kit upload' -Action { & scp @sshOpts @kitPaths "${BuildHost}:${remote}/" })) { throw "Kit upload failed." }
        if ($CustomPost) {
            if (-not (Invoke-Net -What 'custom-post upload' -Action { & scp @sshOpts $CustomPost "${BuildHost}:${remote}/" })) { throw "Custom %post upload failed." }
        }
        Write-Host ("Uploading ISO ({0:N2} GB) ..." -f ($iso.Length / 1GB))
        Write-TLog -Msg ("Uploading source ISO {0} ({1:N2} GB)" -f $iso.Name, ($iso.Length / 1GB))
        if (-not (Invoke-Net -What 'ISO upload' -Action { & scp @sshOpts $iso.FullName "${BuildHost}:${remote}/" })) { throw "ISO upload failed." }

        # ---- assemble the SECRET stdin blob (plaintext exists only here) --------
        $blobLines = @("veeamadmin.password=" + (ConvertFrom-SecureToPlain $VeeamAdminPassword))
        if (-not $NoVeeamso) { $blobLines += "veeamso.password=" + (ConvertFrom-SecureToPlain $VeeamsoPassword) }
        if ($ByoKeys) {
            if ($VeeamAdminMfaKey)                     { $blobLines += "veeamadmin.mfaSecretKey=$VeeamAdminMfaKey" }
            if (-not $NoVeeamso -and $VeeamsoMfaKey)        { $blobLines += "veeamso.mfaSecretKey=$VeeamsoMfaKey" }
            if (-not $NoVeeamso -and $VeeamsoRecoveryToken) { $blobLines += "veeamso.recoveryToken=$VeeamsoRecoveryToken" }
        }
        $blob = ($blobLines -join "`n")

        # ---- run the NON-INTERACTIVE build; secrets piped to STDIN (not argv) ----
        # Prefix is from the privilege probe: '' for root or rootless-mtools, 'sudo -n '
        # for a passwordless sudoer. `sudo -n` never prompts, so it can't read (and eat)
        # our secret stdin blob - it fails fast instead.
        $isoName = $iso.Name
        # $remote is mktemp -d output (safe), but $isoName is the operator's file name - escape it.
        $buildCmd = "cd '$remote' && chmod +x *.sh && $($script:SudoPrefix)./make-golden-iso.sh $mgFlags $(ConvertTo-ShSq ('./' + $isoName))"
        Write-Host "`nBuilding on $BuildHost (non-interactive) ..."
        Write-TLog -Msg "Invoking non-interactive build (secrets via stdin; not captured here)"
        $blob | & ssh @sshOpts $BuildHost $buildCmd
        $buildRc = $LASTEXITCODE
        # Scrub plaintext secrets from memory ASAP.
        $blob = $null; $blobLines = $null; [System.GC]::Collect()
        if ($buildRc -ne 0) { Write-TLog -Level Error -Msg "Remote build failed (exit $buildRc)"; throw "Remote build failed (exit $buildRc). Remote dir kept for inspection (see below)." }

        if ($PrepOnly) {
            $success = $true
            Write-TLog -Msg "prep-only build complete (no ISO produced)"
            Write-Host "Prep-only complete on remote (no ISO). Logs will be pulled back."
        } else {
            # ---- locate + readable, then pull ISO -------------------------------
            # chown is only needed when the build ran via sudo (root-owned outputs);
            # for root or rootless-mtools the login user already owns them.
            $chown = if ($script:SudoPrefix) { "$($script:SudoPrefix)chown `$(id -un):`$(id -gn) *_UNATTENDED.iso veeam-*-secrets-*.txt 2>/dev/null; " } else { "" }
            $info = & ssh @sshOpts $BuildHost "cd '$remote' && ${chown}ls -1 *_UNATTENDED.iso 2>/dev/null; echo '---SECRETS---'; ls -1 veeam-*-secrets-*.txt 2>/dev/null"
            $sep = [array]::IndexOf($info, '---SECRETS---')
            $isoOut = if ($sep -ge 1) { ($info[0..($sep - 1)] | Where-Object { $_ } | Select-Object -Last 1) } else { $null }
            $secOut = if ($sep -ge 0 -and $sep -lt ($info.Count - 1)) { ($info[($sep + 1)..($info.Count - 1)] | Where-Object { $_ } | Select-Object -Last 1) } else { $null }
            if ([string]::IsNullOrWhiteSpace($isoOut)) { throw "No built ISO (*_UNATTENDED.iso) on the remote - the build may not have completed." }
            $built = $true; $isoOut = $isoOut.Trim()
            Write-TLog -Msg "Built ISO: $isoOut"
            Write-Host "`nDownloading built ISO ..."
            if (-not (Invoke-Net -What 'ISO download' -Action { & scp @sshOpts "${BuildHost}:${remote}/${isoOut}" $OutputDir })) { Write-TLog -Level Error -Msg "Built-ISO download failed"; throw "Download of the built ISO failed." }
            Write-TLog -Msg "Downloaded built ISO to $OutputDir"
            Protect-LocalFile (Join-Path $OutputDir $isoOut)        # ISO embeds cleartext creds until first-boot applies them
            if (-not [string]::IsNullOrWhiteSpace($secOut)) {
                $secOut = $secOut.Trim()
                Invoke-Net -What 'secrets download' -Action { & scp @sshOpts "${BuildHost}:${remote}/${secOut}" $OutputDir } | Out-Null
                Protect-LocalFile (Join-Path $OutputDir $secOut)    # the secrets sheet - most sensitive artifact
                Write-TLog -Msg "Downloaded secrets file: $secOut (SENSITIVE - contents not logged)"
            }
            $success = $true
        }

        $outResolved = (Resolve-Path $OutputDir).Path
        Write-Host "`nDone. Saved to: $outResolved"
        Write-TLog -Msg "SUCCESS - saved to $outResolved"
    }
    finally {
        # Defensive: ensure no plaintext blob lingers if we threw before scrubbing.
        if (Get-Variable blob -Scope Local -ErrorAction SilentlyContinue) { $blob = $null; [System.GC]::Collect() }
        $optStr = ($sshOpts -join ' ')

        # Always pull the logs back (diagnosis on failure, record on success).
        Receive-RemoteLog
        # DEFAULT = clean up (rm -rf) in every outcome - success OR failure - so nothing
        # is ever left behind. Keep the remote ONLY if explicitly requested: -KeepRemote
        # (debug, keep even on success) or -KeepOnFailure (keep on a FAILED run so a
        # built-but-undownloaded ISO can be recovered).
        $keep = $KeepRemote -or ((-not $success) -and $KeepOnFailure)
        if ($keep) {
            $why = if ($KeepRemote) { 'KeepRemote' } else { 'KeepOnFailure (run failed)' }
            Write-Warning "Remote workdir KEPT at ${BuildHost}:$remote ($why) - it holds cleartext credentials."
            if ($built -and -not $success) {
                Write-Host "  A built ISO is there; re-pull it:  scp $optStr ${BuildHost}:$remote/*_UNATTENDED.iso `"$OutputDir`""
            }
            Write-Host    "  Delete when done:  ssh $optStr $BuildHost '$($script:SudoPrefix)rm -rf $remote'"
            Write-TLog -Level Warning -Msg "remote workdir KEPT ($remote) - $why"
        }
        else {
            Remove-Remote
        }
        if ($success) { Write-TLog -Msg "TRANSPORT RESULT: SUCCESS" } else { Write-TLog -Level Error -Msg "TRANSPORT RESULT: FAILURE" }
        Write-Host "Transport log: $script:TLog"
    }
}

# =============================================================================
#  SHARED CLIENT-SIDE VALIDATORS (also used by the GUI for live feedback) -
#  PowerShell mirror of make-golden-iso.sh's validate_pw / is_b32 / is_guid, so
#  the form blocks a bad value BEFORE a multi-minute build instead of after.
# =============================================================================
# Returns a [string[]] of human-readable requirements the password FAILS
# (empty array = the password passes the appliance policy). Mirrors the
# DISA RHEL8 STIG rules the appliance enforces (see make-golden-iso.sh validate_pw).
function Test-VeeamPasswordPolicy {
    param([string]$Pw)
    $errs = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Pw) { $Pw = '' }
    if ($Pw.Length -lt 15)      { $errs.Add("15+ characters") }
    if ($Pw -cnotmatch '[A-Z]') { $errs.Add("an uppercase letter") }
    if ($Pw -cnotmatch '[a-z]') { $errs.Add("a lowercase letter") }
    if ($Pw -notmatch  '[0-9]') { $errs.Add("a digit") }
    if ($Pw -notmatch  '[^A-Za-z0-9]') { $errs.Add("a special character") }
    # max 4 consecutive of the same class (maxclassrepeat=4) AND max 3 identical (maxrepeat=3)
    $classOf = {
        param([char]$c)
        if ("$c" -cmatch '[A-Z]') { 'U' } elseif ("$c" -cmatch '[a-z]') { 'L' }
        elseif ("$c" -match '[0-9]') { 'D' } else { 'S' }
    }
    $classRun = 1; $identRun = 1
    for ($i = 1; $i -lt $Pw.Length; $i++) {
        if ((& $classOf $Pw[$i]) -eq (& $classOf $Pw[$i - 1])) { $classRun++ } else { $classRun = 1 }
        if ($Pw[$i] -ceq $Pw[$i - 1]) { $identRun++ } else { $identRun = 1 }
        if ($classRun -gt 4) { $errs.Add("no more than 4 of the same class (upper/lower/digit/special) in a row"); break }
        if ($identRun -gt 3) { $errs.Add("no more than 3 identical characters in a row"); break }
    }
    , $errs.ToArray()
}
function Test-B32  { param([string]$s) $s -cmatch '^[A-Z2-7]{16}$' }                                                  # 16-char Base32
function Test-Guid { param([string]$s) $s -match '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$' }

# Build a SecureString from a plain string (the WinForms TextBox unavoidably holds
# plaintext; we convert at Build time and hand the SecureString to the transport).
function ConvertTo-SecureStringPlain {
    param([string]$Plain)
    $ss = New-Object System.Security.SecureString
    foreach ($ch in $Plain.ToCharArray()) { $ss.AppendChar($ch) }
    $ss.MakeReadOnly()
    $ss
}

# =============================================================================
#  NON-GUI PATH - run the transport synchronously in this process.
# =============================================================================
if (-not $Gui) {
    $bound = @{} + $PSBoundParameters
    [void]$bound.Remove('Gui')
    $bound['KitRoot'] = $PSScriptRoot
    & $TransportScript @bound
    return
}

# =============================================================================
#  GUI PATH (Phase 3) - single-window WinForms form. Requires -STA (Launch-GUI.cmd
#  supplies it). Collects the same values, validates client-side, confirms the SSH
#  host key (type-to-confirm), then runs the transport in a background runspace with
#  a live status feed so the window never freezes during the multi-minute build.
# =============================================================================
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    throw "The GUI needs a single-threaded apartment. Launch it with Launch-GUI.cmd, or:  powershell -NoProfile -ExecutionPolicy Bypass -STA -File `"$PSCommandPath`" -Gui"
}
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ---- host-key type-to-confirm (DECISION 4) ----------------------------------
# Return the SHA256 fingerprint (e.g. "SHA256:abc...") for a known_hosts-format line.
function Get-Sha256Fingerprint {
    param([string]$KnownHostsLine)
    $ErrorActionPreference = 'Continue'   # ssh-keygen writes to stderr; under PS 5.1 + Stop that would throw
    $out = ($KnownHostsLine | & ssh-keygen -lf - 2>$null) | Out-String
    if ($out -match '(SHA256:[A-Za-z0-9+/=]+)') { return $Matches[1] } else { return $null }
}

# The Accept/Reject dialog for an UNKNOWN host key. Guards against accidental
# acceptance: Reject is the default (Enter/Esc reject); Accept stays DISABLED until
# the operator either pastes the exact expected SHA256 OR types the literal word
# ACCEPT (AWS-style type-to-confirm - never a one-click checkbox).
function Show-HostKeyDialog {
    param([string]$HostLabel, [string]$Fingerprint, [string]$KeyType)
    $normShown = ($Fingerprint -replace '(?i)^SHA256:', '').Trim()

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Verify SSH host key - $HostLabel"
    $dlg.FormBorderStyle = 'FixedDialog'; $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.StartPosition = 'CenterParent'; $dlg.ClientSize = New-Object System.Drawing.Size(560, 360)

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.SetBounds(12, 12, 536, 150)
    $lbl.Text = @"
The build host's SSH identity has NOT been verified before. This tool sends
credentials to it, so confirm the key is genuine BEFORE trusting it.

Host:        $HostLabel
Key type:    $KeyType
Fingerprint: $Fingerprint

Verify this OUT-OF-BAND - on the host itself, run:
   ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
and confirm the SHA256 matches. Do NOT trust a key you cannot verify.
"@
    $dlg.Controls.Add($lbl)

    $lblPaste = New-Object System.Windows.Forms.Label
    $lblPaste.SetBounds(12, 172, 536, 18); $lblPaste.Text = "Paste the expected SHA256 fingerprint (preferred - verified + zero click-through):"
    $dlg.Controls.Add($lblPaste)
    $txtPaste = New-Object System.Windows.Forms.TextBox
    $txtPaste.SetBounds(12, 192, 536, 22)
    $dlg.Controls.Add($txtPaste)

    $lblType = New-Object System.Windows.Forms.Label
    $lblType.SetBounds(12, 224, 536, 18); $lblType.Text = "...or, if you've verified it another way, type the word  ACCEPT  to enable the button:"
    $dlg.Controls.Add($lblType)
    $txtType = New-Object System.Windows.Forms.TextBox
    $txtType.SetBounds(12, 244, 536, 22)
    $dlg.Controls.Add($txtType)

    $btnAccept = New-Object System.Windows.Forms.Button
    $btnAccept.SetBounds(352, 300, 90, 30); $btnAccept.Text = "Accept"; $btnAccept.Enabled = $false
    $btnAccept.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $dlg.Controls.Add($btnAccept)

    $btnReject = New-Object System.Windows.Forms.Button
    $btnReject.SetBounds(448, 300, 100, 30); $btnReject.Text = "Reject"
    $btnReject.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dlg.Controls.Add($btnReject)

    # Reject is BOTH the Accept- and Cancel-button so Enter AND Esc reject - Accept is
    # never reachable by a reflexive keypress; only an explicit click after verifying.
    $dlg.AcceptButton = $btnReject
    $dlg.CancelButton = $btnReject

    $evalAccept = {
        $p = ($txtPaste.Text -replace '(?i)^SHA256:', '').Trim()
        $typed = $txtType.Text.Trim()
        $btnAccept.Enabled = (($p.Length -gt 0) -and ($p -ceq $normShown)) -or ($typed -ceq 'ACCEPT')
    }.GetNewClosure()
    $txtPaste.Add_TextChanged($evalAccept)
    $txtType.Add_TextChanged($evalAccept)

    ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK)
}

# Verify the host key before the transport connects. Returns $true to proceed.
#   * already known -> proceed; the build's ssh is the AUTHORITY on a CHANGED key. ssh does
#                      correct PER-KEY-TYPE detection and the transport hard-aborts on a
#                      changed key before any credential is sent. We do NOT re-implement that
#                      here - the old "any scanned fingerprint matches any stored one" check
#                      was too lenient: ssh-keyscan returns rsa+ecdsa+ed25519, so if only one
#                      type's stored key changed, the others still matched and it wrongly
#                      proceeded (the changed key was then caught downstream by ssh anyway).
#   * unknown       -> type-to-confirm dialog; on Accept, append to known_hosts.
function Confirm-HostKey {
    param([string]$HostOnly)
    $ErrorActionPreference = 'Continue'   # ssh-keyscan/ssh-keygen banners go to stderr; under PS 5.1 + Stop that throws

    # Known already? Proceed - let the transport's ssh validate the key. A CHANGED key is
    # caught there (REMOTE HOST IDENTIFICATION HAS CHANGED) and the run is aborted before
    # anything is sent; the GUI surfaces that as a clear refusal dialog.
    $known = & ssh-keygen -F $HostOnly 2>$null | Where-Object { $_ -and $_ -notmatch '^#' }
    if ($known) { return $true }

    # Unknown host -> retrieve the key and require explicit type-to-confirm trust.
    $scan = & ssh-keyscan -T 8 $HostOnly 2>$null | Where-Object { $_ -and $_ -notmatch '^#' }
    if (-not $scan) {
        [System.Windows.Forms.MessageBox]::Show(
            "Could not retrieve an SSH host key from '$HostOnly' (host unreachable, or sshd not responding). The build cannot proceed.",
            "Host key unavailable", 'OK', 'Error') | Out-Null
        return $false
    }
    # present the strongest key (prefer ed25519) for type-to-confirm
    $line = ($scan | Where-Object { $_ -match ' ssh-ed25519 ' } | Select-Object -First 1)
    if (-not $line) { $line = $scan | Select-Object -First 1 }
    $fpr = Get-Sha256Fingerprint $line
    $ktype = if ($line -match '\s(ssh-\S+|ecdsa-\S+)\s') { $Matches[1] } else { 'unknown' }
    if (-not (Show-HostKeyDialog -HostLabel $HostOnly -Fingerprint $fpr -KeyType $ktype)) { return $false }

    # accepted -> append ALL scanned keys for this host to the user's known_hosts so the
    # subsequent transport connects against a now-known key (a later CHANGE is still refused
    # by ssh / the transport).
    $sshDir = Join-Path $env:USERPROFILE '.ssh'
    if (-not (Test-Path -LiteralPath $sshDir)) { New-Item -ItemType Directory -Path $sshDir | Out-Null }
    $kh = Join-Path $sshDir 'known_hosts'
    Add-Content -LiteralPath $kh -Value $scan
    return $true
}

# ---- the form ---------------------------------------------------------------
$kitVersion = try { (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'VERSION') -ErrorAction Stop | Select-Object -First 1).Trim() } catch { '' }

$form = New-Object System.Windows.Forms.Form
$form.Text = "Veeam Appliance Kickstart - Golden ISO Builder" + ($(if ($kitVersion) { "  (v$kitVersion)" } else { '' }))
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'; $form.MaximizeBox = $false
$form.ClientSize = New-Object System.Drawing.Size(700, 820)
$form.AutoScroll = $true
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$LX = 16; $CX = 210; $CW = 460; $y = 12
function Add-RowLabel { param([string]$Text, [int]$Top, [int]$Width = 190)
    $l = New-Object System.Windows.Forms.Label; $l.SetBounds($LX, ($Top + 3), $Width, 18); $l.Text = $Text; $form.Controls.Add($l); $l }

$banner = New-Object System.Windows.Forms.Label
$banner.SetBounds($LX, $y, 668, 16); $banner.ForeColor = [System.Drawing.Color]::DimGray
$banner.Text = "Community tool - NOT an official Veeam product. Builds on a remote Linux host over SSH."
$form.Controls.Add($banner); $y += 28

# Linux host + SSH login
Add-RowLabel "Linux build host (IP/DNS):" $y | Out-Null
$txtHost = New-Object System.Windows.Forms.TextBox; $txtHost.SetBounds($CX, $y, $CW, 22); $form.Controls.Add($txtHost); $y += 30
Add-RowLabel "SSH username:" $y | Out-Null
$txtUser = New-Object System.Windows.Forms.TextBox; $txtUser.SetBounds($CX, $y, 200, 22); $txtUser.Text = 'root'; $form.Controls.Add($txtUser); $y += 30
Add-RowLabel "SSH private key file:" $y | Out-Null
$txtKey = New-Object System.Windows.Forms.TextBox; $txtKey.SetBounds($CX, $y, ($CW - 90), 22); $form.Controls.Add($txtKey)
$btnKey = New-Object System.Windows.Forms.Button; $btnKey.SetBounds(($CX + $CW - 84), ($y - 1), 84, 24); $btnKey.Text = "Browse..."; $form.Controls.Add($btnKey); $y += 30

# Role
Add-RowLabel "ISO type (role):" $y | Out-Null
$cboRole = New-Object System.Windows.Forms.ComboBox; $cboRole.SetBounds($CX, $y, 260, 22); $cboRole.DropDownStyle = 'DropDownList'
[void]$cboRole.Items.AddRange(@('proxy', 'vmware-proxy', 'hardened-repo', 'vsa', 'vbem')); $cboRole.SelectedIndex = 0
$form.Controls.Add($cboRole); $y += 30

# Source ISO
Add-RowLabel "Source ISO:" $y | Out-Null
$txtIso = New-Object System.Windows.Forms.TextBox; $txtIso.SetBounds($CX, $y, ($CW - 90), 22); $form.Controls.Add($txtIso)
$btnIso = New-Object System.Windows.Forms.Button; $btnIso.SetBounds(($CX + $CW - 84), ($y - 1), 84, 24); $btnIso.Text = "Browse..."; $form.Controls.Add($btnIso); $y += 30

# Hostname prefix
Add-RowLabel "Hostname prefix (all roles):" $y | Out-Null
$txtPrefix = New-Object System.Windows.Forms.TextBox; $txtPrefix.SetBounds($CX, $y, 200, 22); $form.Controls.Add($txtPrefix)
$lblPrefixHint = New-Object System.Windows.Forms.Label; $lblPrefixHint.SetBounds(($CX + 210), ($y + 3), 250, 18); $lblPrefixHint.ForeColor = [System.Drawing.Color]::DimGray; $lblPrefixHint.Text = "blank = role default (vprx/vlhr/vbr)"; $form.Controls.Add($lblPrefixHint); $y += 30

# NTP
Add-RowLabel "NTP server (IP recommended):" $y | Out-Null
$txtNtp = New-Object System.Windows.Forms.TextBox; $txtNtp.SetBounds($CX, $y, 260, 22); $form.Controls.Add($txtNtp); $y += 30

# Output folder
Add-RowLabel "Output folder (ISO + logs):" $y | Out-Null
$txtOut = New-Object System.Windows.Forms.TextBox; $txtOut.SetBounds($CX, $y, ($CW - 90), 22); $txtOut.Text = (Get-Location).Path; $form.Controls.Add($txtOut)
$btnOut = New-Object System.Windows.Forms.Button; $btnOut.SetBounds(($CX + $CW - 84), ($y - 1), 84, 24); $btnOut.Text = "Browse..."; $form.Controls.Add($btnOut); $y += 36

# ---- credentials ----
$sep1 = New-Object System.Windows.Forms.Label; $sep1.SetBounds($LX, $y, 668, 2); $sep1.BorderStyle = 'Fixed3D'; $form.Controls.Add($sep1); $y += 10

Add-RowLabel "veeamadmin password:" $y | Out-Null
$txtAdminPw = New-Object System.Windows.Forms.TextBox; $txtAdminPw.SetBounds($CX, $y, 300, 22); $txtAdminPw.UseSystemPasswordChar = $true; $form.Controls.Add($txtAdminPw)
$chkAdminMfa = New-Object System.Windows.Forms.CheckBox; $chkAdminMfa.SetBounds(($CX + 312), $y, 130, 22); $chkAdminMfa.Text = "Enable MFA"; $form.Controls.Add($chkAdminMfa); $y += 26
Add-RowLabel "confirm password:" $y | Out-Null
$txtAdminPw2 = New-Object System.Windows.Forms.TextBox; $txtAdminPw2.SetBounds($CX, $y, 300, 22); $txtAdminPw2.UseSystemPasswordChar = $true; $form.Controls.Add($txtAdminPw2); $y += 24
$lblAdminMsg = New-Object System.Windows.Forms.Label; $lblAdminMsg.SetBounds($CX, $y, $CW, 16); $lblAdminMsg.ForeColor = [System.Drawing.Color]::Firebrick; $form.Controls.Add($lblAdminMsg); $y += 26

$chkVeeamso = New-Object System.Windows.Forms.CheckBox; $chkVeeamso.SetBounds($LX, $y, 400, 22); $chkVeeamso.Text = "Enable Security Officer account (veeamso)"; $chkVeeamso.Checked = $true; $form.Controls.Add($chkVeeamso); $y += 28
Add-RowLabel "veeamso password:" $y | Out-Null
$txtSoPw = New-Object System.Windows.Forms.TextBox; $txtSoPw.SetBounds($CX, $y, 300, 22); $txtSoPw.UseSystemPasswordChar = $true; $form.Controls.Add($txtSoPw)
$chkSoMfa = New-Object System.Windows.Forms.CheckBox; $chkSoMfa.SetBounds(($CX + 312), $y, 130, 22); $chkSoMfa.Text = "MFA (enforced)"; $chkSoMfa.Checked = $true; $chkSoMfa.Enabled = $false; $form.Controls.Add($chkSoMfa); $y += 26
Add-RowLabel "confirm password:" $y | Out-Null
$txtSoPw2 = New-Object System.Windows.Forms.TextBox; $txtSoPw2.SetBounds($CX, $y, 300, 22); $txtSoPw2.UseSystemPasswordChar = $true; $form.Controls.Add($txtSoPw2); $y += 24
$lblSoMsg = New-Object System.Windows.Forms.Label; $lblSoMsg.SetBounds($CX, $y, $CW, 16); $lblSoMsg.ForeColor = [System.Drawing.Color]::Firebrick; $form.Controls.Add($lblSoMsg); $y += 30

# ---- advanced toggle ----
$chkAdvanced = New-Object System.Windows.Forms.CheckBox; $chkAdvanced.SetBounds($LX, $y, 300, 22); $chkAdvanced.Text = "Advanced options"; $form.Controls.Add($chkAdvanced); $y += 28

# Advanced group (collapsed by default; toggling shifts everything below it)
$grpAdv = New-Object System.Windows.Forms.GroupBox
$grpAdv.SetBounds($LX, $y, 668, 230); $grpAdv.Text = "Advanced"; $grpAdv.Visible = $false   # tall enough for all rows incl. the recovery-token field (was 196 -> clipped + overlapped Build)
$form.Controls.Add($grpAdv)
$ay = 22
$chkSkipNtp = New-Object System.Windows.Forms.CheckBox; $chkSkipNtp.SetBounds(12, $ay, 620, 22); $chkSkipNtp.Text = "Skip NTP time-sync at first boot (--skip-ntp-sync)"; $grpAdv.Controls.Add($chkSkipNtp); $ay += 26
$chkKeepOnFail = New-Object System.Windows.Forms.CheckBox; $chkKeepOnFail.SetBounds(12, $ay, 620, 22); $chkKeepOnFail.Text = "Keep remote build files if the build fails (for recovery/diagnosis)"; $grpAdv.Controls.Add($chkKeepOnFail); $ay += 28
$lblPost = New-Object System.Windows.Forms.Label; $lblPost.SetBounds(12, ($ay + 3), 180, 18); $lblPost.Text = "Post-install script (%post):"; $grpAdv.Controls.Add($lblPost)
$txtPost = New-Object System.Windows.Forms.TextBox; $txtPost.SetBounds(196, $ay, 380, 22); $grpAdv.Controls.Add($txtPost)
$btnPost = New-Object System.Windows.Forms.Button; $btnPost.SetBounds(582, ($ay - 1), 74, 24); $btnPost.Text = "Browse..."; $grpAdv.Controls.Add($btnPost); $ay += 30
$chkByo = New-Object System.Windows.Forms.CheckBox; $chkByo.SetBounds(12, $ay, 620, 22); $chkByo.Text = "Bring your own MFA keys / recovery token (blank = auto-generate)"; $grpAdv.Controls.Add($chkByo); $ay += 26
$lblAdminKey = New-Object System.Windows.Forms.Label; $lblAdminKey.SetBounds(12, ($ay + 3), 200, 18); $lblAdminKey.Text = "veeamadmin MFA key (16 Base32):"; $grpAdv.Controls.Add($lblAdminKey)
$txtAdminKey = New-Object System.Windows.Forms.TextBox; $txtAdminKey.SetBounds(216, $ay, 200, 22); $txtAdminKey.Enabled = $false; $grpAdv.Controls.Add($txtAdminKey); $ay += 26
$lblSoKey = New-Object System.Windows.Forms.Label; $lblSoKey.SetBounds(12, ($ay + 3), 200, 18); $lblSoKey.Text = "veeamso MFA key (16 Base32):"; $grpAdv.Controls.Add($lblSoKey)
$txtSoKey = New-Object System.Windows.Forms.TextBox; $txtSoKey.SetBounds(216, $ay, 200, 22); $txtSoKey.Enabled = $false; $grpAdv.Controls.Add($txtSoKey); $ay += 26
$lblSoTok = New-Object System.Windows.Forms.Label; $lblSoTok.SetBounds(12, ($ay + 3), 200, 18); $lblSoTok.Text = "veeamso recovery token (GUID):"; $grpAdv.Controls.Add($lblSoTok)
$txtSoTok = New-Object System.Windows.Forms.TextBox; $txtSoTok.SetBounds(216, $ay, 300, 22); $txtSoTok.Enabled = $false; $grpAdv.Controls.Add($txtSoTok)

# Bottom panel (Build + status + log) - repositioned when Advanced toggles.
$pnlBottom = New-Object System.Windows.Forms.Panel
$pnlBottom.SetBounds(0, ($y + 8), 700, 240); $form.Controls.Add($pnlBottom)
$btnBuild = New-Object System.Windows.Forms.Button; $btnBuild.SetBounds($LX, 4, 160, 32); $btnBuild.Text = "Build ISO"; $btnBuild.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold); $pnlBottom.Controls.Add($btnBuild)
$lblStatus = New-Object System.Windows.Forms.Label; $lblStatus.SetBounds(($LX + 176), 12, 500, 18); $lblStatus.Text = "Fill the form, then click Build."; $pnlBottom.Controls.Add($lblStatus)
$txtLog = New-Object System.Windows.Forms.TextBox; $txtLog.SetBounds($LX, 44, 668, 188); $txtLog.Multiline = $true; $txtLog.ReadOnly = $true; $txtLog.ScrollBars = 'Vertical'; $txtLog.BackColor = [System.Drawing.Color]::White; $txtLog.Font = New-Object System.Drawing.Font('Consolas', 9); $pnlBottom.Controls.Add($txtLog)

$advCollapsedTop = $y          # where the bottom panel sits when Advanced is hidden
$advExpandedTop = $y + 8 + $grpAdv.Height
$pnlBottom.Top = $advCollapsedTop
# Fit the form to the bottom panel, but NEVER taller than the screen working area:
# cap there and let AutoScroll provide a scrollbar (important on smaller / non-full-
# screen RDP sessions). When capped, widen by the scrollbar width so the vertical bar
# doesn't force a horizontal one, and - once shown - nudge the form up if it would run
# off the bottom of the screen.
function Set-FormFit {
    $needed = $pnlBottom.Top + $pnlBottom.Height + 12
    $wa = [System.Windows.Forms.Screen]::FromControl($form).WorkingArea
    $maxH = [Math]::Max(400, $wa.Height - 64)
    if ($needed -gt $maxH) {
        $vsb = [System.Windows.Forms.SystemInformation]::VerticalScrollBarWidth
        $form.ClientSize = New-Object System.Drawing.Size((700 + $vsb), $maxH)
    } else {
        $form.ClientSize = New-Object System.Drawing.Size(700, $needed)
    }
    if ($form.IsHandleCreated -and $form.Bottom -gt $wa.Bottom) {
        $form.Top = [Math]::Max($wa.Top, ($wa.Bottom - $form.Height))
    }
}
Set-FormFit

# ---- field-rule helpers -----------------------------------------------------
function Update-FormRules {
    $isHR = ($cboRole.SelectedItem -eq 'hardened-repo')
    # HR forces MFA on BOTH accounts and requires the SO account - lock those controls on.
    if ($isHR) {
        $chkVeeamso.Checked = $true; $chkVeeamso.Enabled = $false
        $chkAdminMfa.Checked = $true; $chkAdminMfa.Enabled = $false
    } else {
        $chkVeeamso.Enabled = $true
        $chkAdminMfa.Enabled = $true
    }
    # veeamso fields follow the enable checkbox. veeamso MFA is ALWAYS enforced when the
    # account is enabled (the kit has no SO-MFA-off path) - so it's shown checked+locked.
    $soOn = $chkVeeamso.Checked
    $txtSoPw.Enabled = $soOn
    $txtSoPw2.Enabled = $soOn
    $chkSoMfa.Checked = $soOn
    $lblSoMsg.Visible = $soOn
    $txtSoKey.Enabled = ($soOn -and $chkByo.Checked)
    $txtSoTok.Enabled = ($soOn -and $chkByo.Checked)
}
function Update-Validation {
    $adminErrs = Test-VeeamPasswordPolicy $txtAdminPw.Text
    if ($txtAdminPw.Text.Length -eq 0) { $lblAdminMsg.Text = ''; $okAdmin = $false }
    elseif ($adminErrs.Count) { $lblAdminMsg.Text = "needs: " + ($adminErrs -join "; "); $lblAdminMsg.ForeColor = [System.Drawing.Color]::Firebrick; $okAdmin = $false }
    elseif ($txtAdminPw2.Text -cne $txtAdminPw.Text) { $lblAdminMsg.Text = "passwords do not match"; $lblAdminMsg.ForeColor = [System.Drawing.Color]::Firebrick; $okAdmin = $false }
    else { $lblAdminMsg.Text = "OK"; $lblAdminMsg.ForeColor = [System.Drawing.Color]::ForestGreen; $okAdmin = $true }

    $okSo = $true
    if ($chkVeeamso.Checked) {
        $soErrs = Test-VeeamPasswordPolicy $txtSoPw.Text
        if ($txtSoPw.Text.Length -eq 0) { $lblSoMsg.Text = ''; $okSo = $false }
        elseif ($soErrs.Count) { $lblSoMsg.Text = "needs: " + ($soErrs -join "; "); $lblSoMsg.ForeColor = [System.Drawing.Color]::Firebrick; $okSo = $false }
        elseif ($txtSoPw.Text -ceq $txtAdminPw.Text) { $lblSoMsg.Text = "veeamso password must DIFFER from veeamadmin"; $lblSoMsg.ForeColor = [System.Drawing.Color]::Firebrick; $okSo = $false }
        elseif ($txtSoPw2.Text -cne $txtSoPw.Text) { $lblSoMsg.Text = "passwords do not match"; $lblSoMsg.ForeColor = [System.Drawing.Color]::Firebrick; $okSo = $false }
        else { $lblSoMsg.Text = "OK"; $lblSoMsg.ForeColor = [System.Drawing.Color]::ForestGreen; $okSo = $true }
    }
    $btnBuild.Enabled = ($okAdmin -and $okSo -and -not $script:Building)
}

# ---- wire events ------------------------------------------------------------
$btnKey.Add_Click({
    $ofd = New-Object System.Windows.Forms.OpenFileDialog; $ofd.Title = "Select SSH private key"
    if ($ofd.ShowDialog() -eq 'OK') { $txtKey.Text = $ofd.FileName }
})
$btnIso.Add_Click({
    $ofd = New-Object System.Windows.Forms.OpenFileDialog; $ofd.Title = "Select source ISO"; $ofd.Filter = "ISO images (*.iso)|*.iso|All files (*.*)|*.*"
    if ($ofd.ShowDialog() -eq 'OK') { $txtIso.Text = $ofd.FileName }
})
$btnPost.Add_Click({
    $ofd = New-Object System.Windows.Forms.OpenFileDialog; $ofd.Title = "Select post-install (%post) script"; $ofd.Filter = "Shell scripts (*.sh)|*.sh|All files (*.*)|*.*"
    if ($ofd.ShowDialog() -eq 'OK') { $txtPost.Text = $ofd.FileName }
})
$btnOut.Add_Click({
    $fbd = New-Object System.Windows.Forms.FolderBrowserDialog; $fbd.Description = "Output folder for the built ISO + logs"
    if ($fbd.ShowDialog() -eq 'OK') { $txtOut.Text = $fbd.SelectedPath }
})
$chkAdvanced.Add_CheckedChanged({
    $grpAdv.Visible = $chkAdvanced.Checked
    $pnlBottom.Top = if ($chkAdvanced.Checked) { $advExpandedTop } else { $advCollapsedTop }
    Set-FormFit
})
$chkByo.Add_CheckedChanged({
    $txtAdminKey.Enabled = $chkByo.Checked
    Update-FormRules
})
$cboRole.Add_SelectedIndexChanged({ Update-FormRules; Update-Validation })
$chkVeeamso.Add_CheckedChanged({ Update-FormRules; Update-Validation })
$txtAdminPw.Add_TextChanged({ Update-Validation })
$txtAdminPw2.Add_TextChanged({ Update-Validation })
$txtSoPw.Add_TextChanged({ Update-Validation })
$txtSoPw2.Add_TextChanged({ Update-Validation })

# ---- Build -> background runspace + live status feed ------------------------
$script:Building = $false
$script:ps = $null
$script:async = $null
$script:infoIdx = 0; $script:warnIdx = 0; $script:errIdx = 0
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 400

function Add-LogLine { param([string]$Text) $txtLog.AppendText($Text + "`r`n") }

# Wipe the cleartext password / BYO-secret text boxes. CAVEAT: .NET strings are immutable
# and GC-managed, so a typed value can still linger in process memory / the page file until
# collected - this clears the LIVE UI surface (shoulder-surf, idle form, accidental re-use),
# not a guaranteed secure erase. The SecureString handed to the build is the protected path;
# the text box is the unavoidable plaintext entry point.
function Clear-SensitiveFields {
    foreach ($tb in @($txtAdminPw, $txtAdminPw2, $txtSoPw, $txtSoPw2, $txtAdminKey, $txtSoKey, $txtSoTok)) { if ($tb) { $tb.Clear() } }
    [System.GC]::Collect()
}

$timer.Add_Tick({
    if (-not $script:ps) { return }
    $inf = $script:ps.Streams.Information
    while ($script:infoIdx -lt $inf.Count) { Add-LogLine ($inf[$script:infoIdx].ToString()); $script:infoIdx++ }
    $wrn = $script:ps.Streams.Warning
    while ($script:warnIdx -lt $wrn.Count) { Add-LogLine ("WARNING: " + $wrn[$script:warnIdx].ToString()); $script:warnIdx++ }
    $er = $script:ps.Streams.Error
    while ($script:errIdx -lt $er.Count) { Add-LogLine ("ERROR: " + $er[$script:errIdx].ToString()); $script:errIdx++ }

    if ($script:async.IsCompleted) {
        $timer.Stop()
        $failed = $false; $emsg = $null
        try { $script:ps.EndInvoke($script:async) } catch { $failed = $true; $emsg = $_.Exception.Message }
        # drain anything that arrived between the last tick and completion
        while ($script:infoIdx -lt $inf.Count) { Add-LogLine ($inf[$script:infoIdx].ToString()); $script:infoIdx++ }
        while ($script:errIdx  -lt $er.Count)  { Add-LogLine ("ERROR: " + $er[$script:errIdx].ToString()); $script:errIdx++ }
        $script:ps.Dispose(); $script:ps = $null
        $script:Building = $false
        if ($failed) {
            # A CHANGED host key is caught by the transport (ssh) and thrown as a SECURITY
            # ALERT; pull the clean alert text out of the EndInvoke wrapper and surface it as
            # its own refusal dialog rather than burying it as a raw exception line.
            $isHostKeyChange = ($emsg -match 'SECURITY ALERT' -and $emsg -match 'CHANGED')
            if ($isHostKeyChange -and $emsg -match 'SECURITY ALERT:') {
                $emsg = ($emsg -replace '^.*?(SECURITY ALERT:)', '$1').Trim().TrimEnd('"').Trim()
            }
            $lblStatus.Text = if ($isHostKeyChange) { "SSH host key CHANGED - build refused (possible MITM)." } else { "Build FAILED - see the log below." }
            $lblStatus.ForeColor = [System.Drawing.Color]::Firebrick
            Add-LogLine "==== BUILD FAILED ===="
            if ($emsg) { Add-LogLine $emsg }
            if ($isHostKeyChange) {
                [System.Windows.Forms.MessageBox]::Show($emsg, "SSH host key CHANGED - refused", 'OK', 'Error') | Out-Null
            }
        } else {
            $lblStatus.Text = "Build complete. ISO + logs saved to the output folder."
            $lblStatus.ForeColor = [System.Drawing.Color]::ForestGreen
            Add-LogLine "==== BUILD COMPLETE ===="
            # Secrets are now baked into the ISO + secrets file; no reason to keep them in
            # the form. (On FAILURE we keep them so the operator can fix + retry.)
            Clear-SensitiveFields
            Add-LogLine "(password / secret fields cleared)"
        }
        Update-Validation   # re-enable Build (respects password validity)
    }
})

$btnBuild.Add_Click({
    if ($script:Building) { return }
    # ---- gather + validate ----
    $hostName = $txtHost.Text.Trim()
    $user = $txtUser.Text.Trim()
    if (-not $hostName) { [System.Windows.Forms.MessageBox]::Show("Enter the Linux build host.", "Missing field", 'OK', 'Warning') | Out-Null; return }
    if (-not $user) { [System.Windows.Forms.MessageBox]::Show("Enter the SSH username.", "Missing field", 'OK', 'Warning') | Out-Null; return }
    if (-not (Test-Path -LiteralPath $txtIso.Text.Trim())) { [System.Windows.Forms.MessageBox]::Show("Pick a source ISO that exists.", "Missing ISO", 'OK', 'Warning') | Out-Null; return }
    if (-not $txtNtp.Text.Trim()) { [System.Windows.Forms.MessageBox]::Show("Enter an NTP server (an IP is recommended).", "Missing field", 'OK', 'Warning') | Out-Null; return }
    if ($txtKey.Text.Trim() -and -not (Test-Path -LiteralPath $txtKey.Text.Trim())) { [System.Windows.Forms.MessageBox]::Show("The SSH key file was not found.", "Bad key path", 'OK', 'Warning') | Out-Null; return }
    if ($chkAdvanced.Checked -and $txtPost.Text.Trim() -and -not (Test-Path -LiteralPath $txtPost.Text.Trim())) { [System.Windows.Forms.MessageBox]::Show("The %post script was not found.", "Bad path", 'OK', 'Warning') | Out-Null; return }
    # ---- format-validate the free-text fields that reach the remote command line ----
    # (the transport also shell-escapes these; this catches typos early and rejects
    # anything outside a safe charset before we connect at all.)
    if ($hostName -notmatch '^[A-Za-z0-9][A-Za-z0-9.\-:]*$') { [System.Windows.Forms.MessageBox]::Show("The Linux host should be a hostname or IP (letters, digits, dot, hyphen, colon).", "Bad host", 'OK', 'Warning') | Out-Null; return }
    if ($user -notmatch '^[A-Za-z0-9._-]+$') { [System.Windows.Forms.MessageBox]::Show("The SSH username may only contain letters, digits, dot, underscore, or hyphen.", "Bad username", 'OK', 'Warning') | Out-Null; return }
    if ($txtNtp.Text.Trim() -notmatch '^[A-Za-z0-9][A-Za-z0-9 .,:_-]*$') { [System.Windows.Forms.MessageBox]::Show("The NTP server may only contain letters, digits, and . , : _ - (one or more servers; an IP is recommended).", "Bad NTP value", 'OK', 'Warning') | Out-Null; return }
    if ($txtPrefix.Text.Trim()) {
        $pfx = $txtPrefix.Text.Trim()
        if ($pfx.Length -gt 50 -or $pfx -notmatch '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$') { [System.Windows.Forms.MessageBox]::Show("The hostname prefix must be letters/digits/hyphens, no leading or trailing hyphen, 50 characters or fewer.", "Bad hostname prefix", 'OK', 'Warning') | Out-Null; return }
    }
    # BYO key formats (only when Advanced+BYO and a value is supplied; blank = auto-generate)
    if ($chkAdvanced.Checked -and $chkByo.Checked) {
        if ($txtAdminKey.Text.Trim() -and -not (Test-B32 ($txtAdminKey.Text.Trim().ToUpper()))) { [System.Windows.Forms.MessageBox]::Show("veeamadmin MFA key must be 16-char Base32 (A-Z, 2-7).", "Bad MFA key", 'OK', 'Warning') | Out-Null; return }
        if ($chkVeeamso.Checked -and $txtSoKey.Text.Trim() -and -not (Test-B32 ($txtSoKey.Text.Trim().ToUpper()))) { [System.Windows.Forms.MessageBox]::Show("veeamso MFA key must be 16-char Base32 (A-Z, 2-7).", "Bad MFA key", 'OK', 'Warning') | Out-Null; return }
        if ($chkVeeamso.Checked -and $txtSoTok.Text.Trim() -and -not (Test-Guid ($txtSoTok.Text.Trim()))) { [System.Windows.Forms.MessageBox]::Show("veeamso recovery token must be a GUID (XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX).", "Bad token", 'OK', 'Warning') | Out-Null; return }
    }

    # ---- host-key type-to-confirm (DECISION 4) - BEFORE any credential leaves ----
    $lblStatus.Text = "Verifying SSH host key..."; $lblStatus.ForeColor = [System.Drawing.Color]::Black
    if (-not (Confirm-HostKey -HostOnly $hostName)) {
        $lblStatus.Text = "Host key not accepted - build cancelled."; $lblStatus.ForeColor = [System.Drawing.Color]::Firebrick
        return
    }

    # ---- assemble transport parameters ----
    $p = @{
        BuildHost          = "$user@$hostName"
        IsoPath            = $txtIso.Text.Trim()
        Role               = [string]$cboRole.SelectedItem
        Ntp                = $txtNtp.Text.Trim()
        OutputDir          = $txtOut.Text.Trim()
        KitRoot            = $PSScriptRoot
        VeeamAdminPassword = (ConvertTo-SecureStringPlain $txtAdminPw.Text)
    }
    if ($txtKey.Text.Trim())    { $p.IdentityFile   = $txtKey.Text.Trim() }
    if ($txtPrefix.Text.Trim()) { $p.HostnamePrefix = $txtPrefix.Text.Trim() }
    if ($chkAdminMfa.Checked)   { $p.VeeamAdminMfa  = $true }
    if (-not $chkVeeamso.Checked) {
        $p.NoVeeamso = $true
    } else {
        $p.VeeamsoPassword = (ConvertTo-SecureStringPlain $txtSoPw.Text)
    }
    if ($chkAdvanced.Checked) {
        if ($chkSkipNtp.Checked)    { $p.SkipNtpSync   = $true }
        if ($chkKeepOnFail.Checked) { $p.KeepOnFailure = $true }
        if ($txtPost.Text.Trim())   { $p.CustomPost    = $txtPost.Text.Trim() }
        if ($chkByo.Checked) {
            $p.ByoKeys = $true
            if ($txtAdminKey.Text.Trim()) { $p.VeeamAdminMfaKey = $txtAdminKey.Text.Trim().ToUpper() }
            if ($chkVeeamso.Checked -and $txtSoKey.Text.Trim()) { $p.VeeamsoMfaKey = $txtSoKey.Text.Trim().ToUpper() }
            if ($chkVeeamso.Checked -and $txtSoTok.Text.Trim()) { $p.VeeamsoRecoveryToken = $txtSoTok.Text.Trim() }
        }
    }

    # ---- launch the transport in a background runspace (same process: the
    #      SecureStrings stay live in-memory; nothing is serialized) ----
    $txtLog.Clear()
    $script:infoIdx = 0; $script:warnIdx = 0; $script:errIdx = 0
    $script:Building = $true
    $btnBuild.Enabled = $false
    $lblStatus.Text = "Building on $hostName - this takes several minutes (ISO upload + build + pull)..."
    $lblStatus.ForeColor = [System.Drawing.Color]::Black
    Add-LogLine "Starting build. Secrets are sent only over the SSH channel via stdin; the remote workdir is cleaned up at the end."

    $script:ps = [powershell]::Create()
    [void]$script:ps.AddScript($TransportScript.ToString())
    [void]$script:ps.AddParameters($p)
    $script:async = $script:ps.BeginInvoke()
    $timer.Start()
})

# initial state + show
Update-FormRules
Update-Validation
$form.Add_FormClosing({ Clear-SensitiveFields })   # never leave cleartext in a closed-but-not-collected form
[void]$form.ShowDialog()
$form.Dispose()
