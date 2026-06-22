# =============================================================================
# kslog.sh — Veeam-style logging helpers for the Veeam Appliance Kickstart
# =============================================================================
# COMMUNITY TOOL. This mirrors the *format* of Veeam's job/agent logs so they are
# familiar to Veeam engineers — but it is NOT an official Veeam product and every
# log it writes is clearly marked as such (see the headers below).
#
# Sourced by the build scripts (make-golden-iso.sh = "job"/orchestrator style;
# build-appliance-iso.sh, generate-secrets.sh = "agent"/worker style). Never run
# directly.
#
# Two formats, matching Veeam's own split:
#   job   :  [dd.MM.yyyy HH:MM:SS.fff]    <pid>    Level    message       (4-space sep)
#   agent :  [dd.MM.yyyy HH:MM:SS.fff] <pid> tag      | message          (9-char tag col)
# (Level = severity: Info | Warning | Error. We do NOT mirror Veeam's numeric
#  verbosity column "(n)" or a "Logging level" header — this tool has no variable
#  verbosity, so copying them would imply a control that doesn't exist.)
#
# HARD SECRETS RULE: never log a secret value (password / mfaSecretKey /
# recoveryToken / etc.). Where a secret would appear, emit the fixed-width mask
# below — a CONSTANT width, never the real length (length itself leaks info).
# Route any line that might carry block content through kslog_scrub() as a net.
# =============================================================================

# Fixed-width secret mask — constant 16 chars, NOT length-revealing. Never change
# this to echo a per-secret length.
KSLOG_MASK='****************'

# ---- timestamp --------------------------------------------------------------
# Veeam uses day-first with milliseconds. Fast path = GNU date (%3N), present on
# the Linux build host. Fall back to python3 (already a build dependency) so the
# lib still renders correctly when tested on macOS/BSD date.
if [ "$(date +%3N 2>/dev/null)" != '3N' ] 2>/dev/null && [ -n "$(date +%3N 2>/dev/null)" ]; then
  kslog_ts() { date +'[%d.%m.%Y %H:%M:%S.%3N]'; }
else
  kslog_ts() { python3 -c 'import datetime as d;n=d.datetime.now();print(n.strftime("[%d.%m.%Y %H:%M:%S.")+f"{n.microsecond//1000:03d}]")'; }
fi

# ---- run id (correlates a job log with the agent logs it spawns) ------------
# Doubles as the per-run log FOLDER name, so it's built human-friendly: optional
# $1 = a prefix (the role) → folders read/sort as e.g.
#   proxy-2026-06-18T19-03-10Z-12345   /   vbem-2026-06-18T14-22-05Z-67890
# (role first to group at a glance, readable UTC time, trailing PID as a
# same-second collision guard). An orchestrator exports KSLOG_RUN_ID (already
# prefixed) and its workers reuse it verbatim, keeping job+agent correlated.
kslog_runid() { printf '%s' "${KSLOG_RUN_ID:-${1:+$1-}$(date -u +%Y-%m-%dT%H-%M-%SZ)-$$}"; }

# ---- secret scrubber (defense-in-depth) -------------------------------------
# Masks the VALUE after any known sensitive key (password / mfaSecretKey /
# recoveryToken / *secret* / token), case-insensitive, for =, :, or ' = ' forms.
# Use on anything derived from the filled block before logging it.
kslog_scrub() {
  sed -E "s/((password|mfasecretkey|recoverytoken|secretkey|secret|token)[[:space:]]*[:=][[:space:]]*)[^[:space:]]+/\\1${KSLOG_MASK}/Ig"
}

# ---- agent (worker) line:  [ts] <pid> tag      | message --------------------
# Usage: alog <tag> <message...>   tag = short component code (extract/grub/repack/error/...)
alog() {
  local tag="$1"; shift
  printf '%s <%s> %-9s| %s\n' "$(kslog_ts)" "$$" "$tag" "$*"
}

# ---- job (orchestrator) line:  [ts]    <pid>    Level    message -----------
# Usage: jlog <Level> <message...>   Level = Info | Warning | Error (severity only).
# No numeric "(n)" verbosity column — this tool has no variable logging levels.
jlog() {
  local level="$1"; shift
  # Level padded to 7 (width of "Warning") so the message column aligns.
  printf '%s    <%s>    %-7s    %s\n' "$(kslog_ts)" "$$" "$level" "$*"
}

# ---- agent banner (written to the top of a worker log) ----------------------
# Args: <component> <module-path> <kit-version> <run-id>
kslog_agent_banner() {
  local component="$1" path="$2" version="$3" runid="$4"
  printf '====================================================================================\n'
  printf '{\n'
  printf '  Veeam Appliance Kickstart \xe2\x80\x94 build agent\n'
  printf '  COMMUNITY TOOL \xe2\x80\x94 NOT an official Veeam product; not developed/supported by Veeam.\n'
  printf '  Report issues: https://github.com/bbark-veeam/Appliance-KS-Automation/issues\n'
  printf '  Component: %s\n' "$component"
  printf '  Path to the executable module: %s\n' "$path"
  printf '  Kit version: %s\n' "$version"
  printf '  UTC Time: %s. UTC offset: %s.\n' "$(date -u +'%H:%M:%S')" "$(date +'%z')"
  printf '  Executable architecture: %s-bit\n' "$(getconf LONG_BIT 2>/dev/null || echo 64)"
  printf '  PID: %s\n' "$$"
  printf '  Run ID: %s\n' "$runid"
  printf '  uname: %s\n' "$(uname -srm 2>/dev/null || echo unknown)"
  printf '}\n'
  printf '====================================================================================\n'
}

# ---- job header (written to the top of an orchestrator log) -----------------
# Args: <module> <kit-version> <run-id> <cmdline...>
kslog_job_header() {
  local module="$1" version="$2" runid="$3"; shift 3
  printf '\n'
  printf '===================================================================\n'
  printf 'Starting new log\n'
  printf 'Tool: [Veeam Appliance Kickstart \xe2\x80\x94 COMMUNITY TOOL, NOT an official Veeam product]\n'
  printf 'Report issues: [https://github.com/bbark-veeam/Appliance-KS-Automation/issues]\n'
  printf 'MachineName: [%s], HostName: [%s], OS: [%s], CPU: [%s]\n' \
    "$(hostname 2>/dev/null)" "$(hostname 2>/dev/null)" "$(uname -sr 2>/dev/null)" "$(nproc 2>/dev/null || echo '?')"
  printf 'Process: [%s bit], PID: [%s], Run ID: [%s]\n' \
    "$(getconf LONG_BIT 2>/dev/null || echo 64)" "$$" "$runid"
  printf 'UTC Time: [%s], DaylightSavingTime: [False]\n' "$(date -u +'%-m/%-d/%Y %-I:%M:%S %p' 2>/dev/null || date -u)"
  printf 'Module: [%s]. Kit version: [%s]\n' "$module" "$version"
  printf 'CmdLineParams: [%s]\n' "$*"
  printf 'UTC offset: 0.00 hours\n'
  printf '\n'
}
