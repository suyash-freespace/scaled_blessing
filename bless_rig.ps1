<#
.SYNOPSIS
    Bless several FSO devices concurrently, one process per ST-LINK probe.

.DESCRIPTION
    Thin fan-out wrapper around flash_device.ps1. Each selected station gets its own
    powershell.exe process bound to one probe via -SerialNumber, its own log file, its
    own status file, and its own exit code.

    Running N processes is deliberately the whole mechanism - flash_device.ps1 is
    already stateless and uses GUID temp filenames, so nothing is shared between
    concurrent runs except the firmware image, which is read-only. One station cannot
    stall, fail or crash another, and each process holds its probe for its whole run so
    two processes never fight over one ST-LINK.

    Two ways to consume the result:

      default   - block, print every station's step transitions live as they happen,
                  then a summary table. The terminal is the whole output: the run's
                  working files go to a throwaway %TEMP% folder that is deleted on the
                  way out, so a rig run leaves nothing behind. -KeepLogs retains them.
      -NoWait   - launch and return immediately, leaving the processes running. For the
                  blessing service behind the UI: it polls -StatusDir and pushes each
                  station's state to the front-end independently. Implies -KeepLogs,
                  since the status files ARE the feed.

    Each station writes $StatusDir\station<N>.json, rewritten on every transition:

        { "station": 1, "opCode": "0x11", "serialNumber": "0019...3533",
          "devEui": "0080E1150636DF36", "region": "EU868",
          "step": "WAIT_VERDICT",        // LAUNCH START DEVEUI ERASE KEYS FLASH
                                         // WAIT_VERDICT DONE
          "state": "running",            // running | passed | failed | error
          "message": "DUT running; last read 0x00000000",
          "exitCode": null, "pid": 12345,
          "startedUtc": "...", "updatedUtc": "...", "elapsedSec": 47 }

    'state' is what the UI colours the station dot with; 'devEui' is available from the
    DEVEUI step onward, before anything is erased, for LNS registration.

.PARAMETER DeviceList
    CSV describing the rig. Required columns: SerialNumber, OpCode.
    Optional per-device columns: AppKey, JoinEui, Region.
    See rig_devices.example.csv.

.PARAMETER DryRun
    Validate the list and print exactly what would be launched, touching no hardware.
    Worth doing before a 6-device run - every launch mass-erases a device.

.EXAMPLE
    # Dry run, then bless every station in the list from the command line
    .\bless_rig.ps1 -DeviceList .\rig_devices.csv -DryRun
    .\bless_rig.ps1 -DeviceList .\rig_devices.csv -ReadVerdict

    # Same, but keep each station's raw output to investigate a failure
    .\bless_rig.ps1 -DeviceList .\rig_devices.csv -ReadVerdict -KeepLogs

    # Operator selected stations 1 and 3 in the UI and pressed Start Blessing, with keys
    # minted per blessing and already registered against each station's DevEUI
    .\bless_rig.ps1 -DeviceList .\rig_devices.csv -Stations 1,3 -Region EU868 `
                    -Keys "1=$key1:$eui1,3=$key3:$eui3" `
                    -ReadVerdict -NoWait -StatusDir C:\blessing\status

.NOTES
    Exit codes: 0 = every device PASSed (or, with -NoWait, all processes launched)
                1 = setup/validation error - reason on stderr, stdout empty under -Json
                2 = at least one device did not PASS
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$DeviceList,

    # Which stations to run. Omit for every row in the device list; pass a subset to
    # flash only those, e.g. -Stations 1,3 for the UI's "station 1 and 3" case. Rows
    # for unselected stations are left completely alone.
    #
    # COMMA-SEPARATED: -Stations 1,3  or  -Stations "1, 3"  or  -Stations 2.
    # Do NOT space-separate ("-Stations 1 3"): under -File the 3 binds positionally to
    # the NEXT parameter and you get a confusing complaint about -Region.
    #
    # Typed [string[]], NOT [int[]], on purpose: under "powershell.exe -File" every
    # argument arrives as a string, and "1,3" coerced to [int] silently becomes 13 (the
    # comma is read as a group separator) - so asking for stations 1 and 3 would fail
    # with "no row for station 13". Parsed by hand below instead.
    [string[]]$Stations,

    # Region for every device in this run, overriding any Region column in the CSV.
    # The blessing UI carries one region per run, so this is its injection point.
    [ValidateSet('AS923','AU915','CN470','CN779','EU433','EU868','KR920','IN865','US915','RU864')]
    [string]$Region,

    # Per-station key material, freshly minted for this blessing. One entry per selected
    # station, as station=<appKey>:<joinEui>, comma-separated:
    #
    #   -Keys "2=<32 hex>:<16 hex>,3=<32 hex>:<16 hex>"
    #
    # AppKey is 32 hex chars (16 bytes, AES-128); JoinEUI is 16 hex chars (8 bytes,
    # EUI-64). Both are written byte-REVERSED by flash_device.ps1 - pass them in the
    # natural order the LNS shows, exactly as you registered them.
    #
    # Wins over any AppKey/JoinEui column in the device list. Anything omitted falls back
    # to flash_device.ps1's shared bring-up defaults, which this script warns about,
    # because shipping production devices on a shared root key is a silent defect.
    #
    # [string[]] and hand-parsed for the same reason as -Stations: under
    # "powershell.exe -File" every argument arrives as a string.
    [string[]]$Keys,

    # Off by default: the blessing service polls 0x20003400 itself. Turn this on for a
    # command-line run where you want pass/fail in the summary table.
    [switch]$ReadVerdict,

    [string]$FirmwarePath,

    # Per-station stdout/stderr. Defaults to a throwaway folder under %TEMP% that is
    # DELETED when the run ends - see -KeepLogs. Passing an explicit path implies
    # -KeepLogs, because asking for a specific location means you want to read it.
    [string]$LogDir,

    # Keep the run directory (child stdout/stderr + status files) instead of deleting it.
    #
    # These files are not optional machinery: Start-Process can only redirect a child's
    # output to a real file, and the live monitor works by reading the status files. So a
    # run always writes them - this switch only decides whether they still exist
    # afterwards. Off by default so a rig run leaves nothing behind; turn it on when you
    # need to see what a child actually printed, which is the only place the
    # STM32_Programmer_CLI error text survives.
    [switch]$KeepLogs,

    # Where the per-station status files land: one station<N>.json per selected station,
    # each owned by exactly one process and rewritten on every step transition. This is
    # the blessing UI's feed - it watches this directory and maps station<N>.json onto
    # the Station N column. Defaults to a 'status' folder inside -LogDir.
    [string]$StatusDir,

    # Launch the station processes and return immediately, instead of waiting for them.
    # For the blessing service behind the UI: "Start Blessing" fans out and comes straight
    # back, then the service polls -StatusDir and pushes each station's state to the
    # front-end on its own timeline. Without this, the script blocks and prints the
    # transitions itself, which is what you want from the command line.
    [switch]$NoWait,

    # 24000 to match flash_device.ps1's default. Drop to 8000 or 4000 if connects or
    # verifies start failing - it is the first thing to try when a probe is marginal.
    [int]$Freq = 24000,
    [int]$VerdictTimeoutSec = 180,
    [int]$OverallTimeoutSec = 600,

    # The summary table prints Station and Verdict only. Turn this on for the full
    # row - serial, op-code, DevEUI, decoded faults, exit code and result text - which
    # is what you want when a station fails and you need to know why.
    [switch]$FullSummary,

    # Print ONE JSON document and nothing else. For the Node service calling this
    # blocking: stdout is JSON.parse-able as-is, with no banner, no live transitions
    # and no table to scrape. Every human-facing line is suppressed, so a parse error
    # means a real failure rather than decoration leaking in.
    #
    # For live progress use -NoWait -StatusDir instead and poll station<N>.json; this
    # switch is for the "run it and give me the result" call.
    #
    # Check the exit code BEFORE parsing. A setup or validation error (exit 1) fails
    # before any station runs, so there is no result to report and stdout is empty.
    # Exit 0 and exit 2 both emit the document.
    #
    # On exit 1, read STDERR for the reason: the refusal is written there as plain
    # lines, one per problem, e.g. "AppKey is identical on stations 2, 4". Capture it -
    # discarding stderr turns every validation failure into a bare exit 1.
    [switch]$Json,

    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Json) {
    # Silence every human-facing line from one place. A script-scope function shadows
    # the Write-Host cmdlet, so every call site goes quiet without touching any of
    # them. Refusals are exempt - they go through Write-Diag below, to stderr, because a
    # run that cannot start must still say why.
    #
    # Declared with no param block on purpose: a simple function swallows any
    # arguments, including -ForegroundColor, where an advanced one would reject them.
    # The Format-Table calls write to the success stream instead and are gated
    # separately, at each call site.
    function Write-Host { }
}

# Setup/validation diagnostics, for the lines that decide the run cannot start.
#
# These must survive -Json. Write-Host is a no-op there, so routing a refusal through
# it left the caller with exit 1, an empty stdout and no idea what was wrong - a
# duplicate AppKey and an unreadable device list looked identical. stderr is the right
# channel: stdout stays a single parse-able document, and the reason travels with it.
#
# [Console]::Error rather than Write-Error on purpose - Write-Error decorates the text
# with the exception, the call site and a stack position, which the caller would have
# to strip to recover one sentence.
function Write-Diag {
    param(
        [string[]]$Lines,
        [ValidateSet('Red', 'Yellow')]
        [string]$Colour = 'Red'
    )
    foreach ($line in $Lines) {
        if ($Json) { [Console]::Error.WriteLine($line) }
        else { Write-Host $line -ForegroundColor $Colour }
    }
}

# Canonical station -> op-code map, shared with flash_device.ps1. Defines
# $OPCODE_BY_STATION, $VALID_OPCODES, $VALID_STATIONS and the helpers.
. (Join-Path $PSScriptRoot 'rig_layout.ps1')
$OPCODE_BY_POSITION = $OPCODE_BY_STATION

$deviceScript = Join-Path $PSScriptRoot 'flash_device.ps1'
if (-not (Test-Path $deviceScript)) { throw "flash_device.ps1 not found next to this script: $deviceScript" }
if (-not (Test-Path $DeviceList)) { throw "Device list not found: $DeviceList" }

if (-not $LogDir) {
    $LogDir = Join-Path $env:TEMP ('fso_rig\{0:yyyyMMdd_HHmmss}' -f (Get-Date))
}
if (-not $StatusDir) { $StatusDir = Join-Path $LogDir 'status' }

# Delete the run directory afterwards unless something needs it to survive:
#   -KeepLogs                    asked for explicitly
#   -LogDir / -StatusDir         a named location means the caller intends to read it
#   -NoWait                      the children outlive this script and the service polls
#                                the status files; deleting them would break the UI feed
$keepRunDir = $KeepLogs -or $NoWait -or
              $PSBoundParameters.ContainsKey('LogDir') -or
              $PSBoundParameters.ContainsKey('StatusDir')

# --- Load and validate the rig layout ------------------------------------
$rows = @(Import-Csv -Path $DeviceList)
if ($rows.Count -eq 0) { throw "Device list is empty: $DeviceList" }

$cols = $rows[0].PSObject.Properties.Name
$problems = @()
if ($cols -notcontains 'SerialNumber') {
    $problems += "missing required column 'SerialNumber' (found: $($cols -join ', '))"
}
# Prefer Position: it is the rig's own identifier and pins the op-code to the
# canonical layout, so an operator cannot silently pair a position with the wrong
# frequency plan or stagger slot. OpCode stays accepted for one-off overrides.
if (($cols -notcontains 'Position') -and ($cols -notcontains 'OpCode')) {
    $problems += "need a 'Position' column (1-6, preferred) or an explicit 'OpCode' column (found: $($cols -join ', '))"
}
if ($problems.Count -gt 0) {
    Write-Diag "Device list is not usable:"
    Write-Diag @($problems | ForEach-Object { "  - $_" })
    exit 1
}

# Resolve Position -> OpCode, and cross-check any explicitly supplied OpCode.
foreach ($r in $rows) {
    $hasPos = ($cols -contains 'Position') -and $r.Position
    if ($hasPos) {
        $pos = 0
        if (-not [int]::TryParse([string]$r.Position, [ref]$pos) -or -not $OPCODE_BY_POSITION.ContainsKey($pos)) {
            $problems += "Position '$($r.Position)' (SN $($r.SerialNumber)) must be 1-6"
            continue
        }
        $expected = $OPCODE_BY_POSITION[$pos]
        if (($cols -contains 'OpCode') -and $r.OpCode) {
            if ($r.OpCode -ne $expected) {
                $problems += "Position $pos must use OpCode $expected, not $($r.OpCode) (SN $($r.SerialNumber)) - the low nibble is the rig position"
            }
        }
        else {
            $r | Add-Member -NotePropertyName OpCode -NotePropertyValue $expected -Force
        }
    }
}
if (-not ($cols -contains 'OpCode')) { $cols = @($cols) + 'OpCode' }

# Guarantee the property exists on every row before it is read. Under StrictMode,
# touching a property a row never had is a terminating error, so a row with a blank
# Position and no OpCode column would blow up with a stack trace instead of being
# reported as the list problem it actually is.
foreach ($r in $rows) {
    if (-not $r.PSObject.Properties['OpCode']) {
        $r | Add-Member -NotePropertyName OpCode -NotePropertyValue $null -Force
    }
}

foreach ($r in $rows) {
    if (-not $r.SerialNumber) { $problems += "a row has an empty SerialNumber" }
    if (-not $r.OpCode) {
        $problems += "row for SN $($r.SerialNumber) has neither a Position (1-6) nor an OpCode"
    }
    elseif ($VALID_OPCODES -notcontains $r.OpCode) {
        $problems += "OpCode '$($r.OpCode)' (SN $($r.SerialNumber)) is not one of: $($VALID_OPCODES -join ', ')"
    }
}

# Duplicate probes would fight over one device; duplicate op-codes would give two
# devices the same join-stagger slot, which is exactly the collision the stagger exists
# to prevent - and on the same frequency plan they would transmit on top of each other.
foreach ($dup in ($rows | Group-Object SerialNumber | Where-Object { $_.Count -gt 1 })) {
    $problems += "SerialNumber $($dup.Name) appears $($dup.Count) times"
}
foreach ($dup in ($rows | Group-Object OpCode | Where-Object { $_.Count -gt 1 })) {
    $problems += "OpCode $($dup.Name) appears $($dup.Count) times - those devices would share a join-stagger slot"
}

if ($problems.Count -gt 0) {
    Write-Diag "Device list is not usable:"
    Write-Diag @($problems | ForEach-Object { "  - $_" })
    exit 1
}

# --- Select stations -----------------------------------------------------
# Validation above ran against the WHOLE list on purpose: a duplicate serial or a bad
# op-code anywhere is a config error worth catching even if this run skips that row.
if ($PSBoundParameters.ContainsKey('Stations') -and $Stations) {
    # Flatten "1,3" / "1 3" / "1, 3" into distinct integers.
    $wanted = New-Object System.Collections.Generic.List[int]
    $bad = @()
    foreach ($tok in ($Stations -split '[,\s]+')) {
        if (-not $tok) { continue }
        $n = 0
        if ([int]::TryParse($tok, [ref]$n) -and $VALID_STATIONS -contains $n) {
            if (-not $wanted.Contains($n)) { $wanted.Add($n) }
        }
        else { $bad += $tok }
    }
    if ($bad.Count -gt 0) {
        Write-Diag ("Bad -Stations value(s): {0}. Valid stations are {1}." -f `
            ($bad -join ', '), ($VALID_STATIONS -join ', '))
        exit 1
    }

    $available = @($rows | ForEach-Object { [Convert]::ToInt32($_.OpCode, 16) -band 0x0F })
    $missing = @($wanted | Where-Object { $available -notcontains $_ })
    if ($missing.Count -gt 0) {
        Write-Diag ("Device list has no row for station(s): {0}. It defines stations: {1}." -f `
            ($missing -join ', '), (($available | Sort-Object) -join ', '))
        exit 1
    }

    $rows = @($rows | Where-Object { $wanted -contains ([Convert]::ToInt32($_.OpCode, 16) -band 0x0F) })
    Write-Host ("Selected station(s): {0}" -f (($wanted | Sort-Object) -join ', ')) -ForegroundColor Cyan
}

# --- Parse -Keys --------------------------------------------------------
# station -> @{ AppKey; JoinEui }. Validated here rather than in the child so a bad
# allocation is refused BEFORE any device is erased - a station that fails validation
# mid-run would already have lost its keys and NVM.
$stationKeys = @{}
if ($Keys) {
    $selected = @($rows | ForEach-Object { [Convert]::ToInt32($_.OpCode, 16) -band 0x0F })
    $problems = @()
    foreach ($tok in ($Keys -split ',')) {
        $tok = $tok.Trim()
        if (-not $tok) { continue }
        if ($tok -notmatch '^\s*(\d+)\s*=\s*([0-9A-Fa-f]{32})\s*:\s*([0-9A-Fa-f]{16})\s*$') {
            $problems += "'$tok' is not station=<32 hex appKey>:<16 hex joinEui>"
            continue
        }
        $st = [int]$Matches[1]; $ak = $Matches[2].ToUpper(); $je = $Matches[3].ToUpper()
        if ($VALID_STATIONS -notcontains $st) {
            $problems += "station $st is not one of $($VALID_STATIONS -join ', ')"
        }
        elseif ($stationKeys.ContainsKey($st)) {
            $problems += "station $st has keys given more than once"
        }
        elseif ($selected -notcontains $st) {
            # Not a warning: keys allocated for a station that is not being blessed means
            # the caller's station list and its key allocation disagree, and the likeliest
            # explanation is that some OTHER station is about to get the wrong keys.
            $problems += "keys given for station $st, which is not in this run (running: $(($selected | Sort-Object) -join ', '))"
        }
        else {
            $stationKeys[$st] = @{ AppKey = $ak; JoinEui = $je }
        }
    }

    # Two devices sharing a root key, or a JoinEUI already spoken for, is a provisioning
    # bug that is invisible on the rig and painful to unpick at the LNS.
    foreach ($f in @('AppKey', 'JoinEui')) {
        $dups = $stationKeys.Keys | Group-Object { $stationKeys[$_].$f } | Where-Object { $_.Count -gt 1 }
        foreach ($d in $dups) {
            $problems += "$f is identical on stations $(($d.Group | Sort-Object) -join ', ')"
        }
    }

    if ($problems.Count -gt 0) {
        Write-Diag "Key allocation is not usable:"
        Write-Diag @($problems | ForEach-Object { "  - $_" })
        exit 1
    }

    $noKeys = @($selected | Where-Object { -not $stationKeys.ContainsKey($_) } | Sort-Object)
    if ($noKeys.Count -gt 0) {
        Write-Diag -Colour Yellow ("WARNING: no keys given for station(s) $($noKeys -join ', ') - they will be blessed with the SHARED bring-up AppKey")
    }
}

# --- Build the launch plan ----------------------------------------------
$plan = @()
foreach ($r in $rows) {
    # Pass the station, not the op-code: flash_device.ps1 derives the op-code from the
    # same shared map, so there is one place that decides station -> op-code. The probe
    # serial is passed explicitly so the child never has to re-read the device list.
    $station = ($r.OpCode | ForEach-Object { [Convert]::ToInt32($_, 16) -band 0x0F })
    $statusFile = Join-Path $StatusDir ("station{0}.json" -f $station)
    $a = @('-Station', $station, '-SerialNumber', $r.SerialNumber,
           '-Freq', $Freq, '-VerdictTimeoutSec', $VerdictTimeoutSec,
           '-StatusFile', $statusFile)

    # Only wait for the DUT result if explicitly asked. By default the blessing service
    # polls 0x20003400 itself, so the child just flashes and exits.
    if ($ReadVerdict) { $a += '-ReadVerdict' }

    # Resolve overrides into one value per option BEFORE emitting them. Appending as we
    # go would emit "-Region X -Region Y" when the CSV has a Region column and -Region is
    # also passed, and PowerShell rejects a parameter specified twice - so the whole
    # station would fail to launch with a binding error rather than honouring the override.
    #
    # Precedence, lowest to highest:
    #   flash_device.ps1's own bring-up defaults  (anything left unset here)
    #   device list column                        (per-station, static)
    #   -Region                                   (whole run)
    #   -Keys                                     (per-station, minted for this blessing)
    $override = @{}
    foreach ($opt in @('AppKey', 'JoinEui', 'Region')) {
        if (($cols -contains $opt) -and $r.$opt) { $override[$opt] = $r.$opt }
    }
    if ($Region) { $override['Region'] = $Region }
    if ($stationKeys.ContainsKey($station)) {
        $override['AppKey']  = $stationKeys[$station].AppKey
        $override['JoinEui'] = $stationKeys[$station].JoinEui
    }
    foreach ($opt in $override.Keys) { $a += @("-$opt", $override[$opt]) }
    if ($FirmwarePath) { $a += @('-FirmwarePath', $FirmwarePath) }

    $opCodeValue = [Convert]::ToInt32($r.OpCode, 16)
    $plan += [pscustomobject]@{
        Station      = $station
        SerialNumber = $r.SerialNumber
        OpCode       = $r.OpCode
        FreqPlan     = ($opCodeValue -shr 4) -band 0x0F
        Slot         = $opCodeValue -band 0x0F
        StaggerMs    = ((($opCodeValue -band 0x0F) - 1) * 2000)
        # Shown in the launch table so an operator can see at a glance that every station
        # got its own key material, rather than finding out from the LNS later.
        Keys         = $(if ($stationKeys.ContainsKey($station)) { 'unique' } else { 'default' })
        Args         = $a
        Log          = Join-Path $LogDir ("{0}_{1}.log" -f $r.SerialNumber, $r.OpCode)
        ErrLog       = Join-Path $LogDir ("{0}_{1}.err.log" -f $r.SerialNumber, $r.OpCode)
        StatusFile   = $statusFile
        Process      = $null
        ExitCode     = $null
        Killed       = $false
        LastStep     = ''       # monitor bookkeeping: only print on change
    }
}

Write-Host "FSO rig blessing - $($plan.Count) device(s)" -ForegroundColor White
Write-Host "  device list : $DeviceList"
if ($keepRunDir) {
    Write-Host "  logs        : $LogDir"
    Write-Host "  status      : $StatusDir"
}
else {
    Write-Host "  logs        : none kept (temporary; pass -KeepLogs to retain)"
}
if (-not $Json) {
    $plan | Format-Table Station, SerialNumber, OpCode, FreqPlan, Slot, StaggerMs, Keys -AutoSize
}

$plansOnSameFreq = $plan | Group-Object FreqPlan | Where-Object { $_.Count -gt 1 }
foreach ($g in $plansOnSameFreq) {
    Write-Host ("note: {0} devices share frequency plan {1} - their join stagger ({2} ms) is what keeps them from colliding." -f `
        $g.Count, $g.Name, (($g.Group | ForEach-Object { $_.StaggerMs }) -join '/')) -ForegroundColor DarkGray
}

if ($DryRun) {
    if ($Json) {
        # Emit parseable stdout here too, so a caller can JSON.parse unconditionally
        # on exit 0 instead of special-casing the dry run.
        ConvertTo-Json -Depth 3 -InputObject ([pscustomobject]@{
            dryRun   = $true
            stations = @($plan | ForEach-Object { $_.Station })
            total    = @($plan).Count
        })
    }
    Write-Host ""
    Write-Host "DRY RUN - nothing launched, no device touched." -ForegroundColor Yellow
    foreach ($p in $plan) {
        # Mask the AppKey. A dry run exists to check the launch plan, not the key bytes,
        # and its whole point is being safe to paste into a ticket or a chat.
        $shown = @()
        for ($i = 0; $i -lt $p.Args.Count; $i++) {
            if ($i -gt 0 -and $p.Args[$i - 1] -eq '-AppKey') { $shown += '<32 hex, masked>' }
            else { $shown += $p.Args[$i] }
        }
        Write-Host "  powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$deviceScript`" $($shown -join ' ')"
    }
    exit 0
}

Write-Host ""
Write-Host "Each launch MASS ERASES its device." -ForegroundColor Yellow

New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
New-Item -ItemType Directory -Path $StatusDir -Force | Out-Null

# --- Launch ------------------------------------------------------------
# Start-Process rather than Start-Job: real separate processes, per-device stdout/stderr
# redirection, and a trustworthy ExitCode - no PS job serialisation in the way.
#
# One process per station is the whole isolation model. Each child is bound to its own
# probe by sn=, writes its own log and its own status file, and returns its own exit
# code, so a station that hangs, fails or has its probe yanked cannot affect the others.
foreach ($p in $plan) {
    # Seed the status file before launching. If the child dies so early it never writes
    # one (bad ExecutionPolicy, missing script), the UI still sees that station as
    # 'launching' and then stale, rather than showing no row at all.
    $seed = [pscustomobject]@{
        station = $p.Station; opCode = $p.OpCode; serialNumber = $p.SerialNumber
        devEui = ''; region = $Region; step = 'LAUNCH'; state = 'running'
        message = 'process starting'; exitCode = $null; pid = $null
        startedUtc = (Get-Date).ToUniversalTime().ToString('o')
        updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        elapsedSec = 0
    }
    [System.IO.File]::WriteAllText($p.StatusFile, ($seed | ConvertTo-Json -Depth 3))

    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $deviceScript) + $p.Args
    $p.Process = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList `
        -RedirectStandardOutput $p.Log -RedirectStandardError $p.ErrLog `
        -PassThru -NoNewWindow

    # Touching .Handle NOW is what makes .ExitCode readable later. Without it, .NET
    # releases the handle when the process ends and ExitCode comes back empty - which
    # is exactly why the summary showed "no exit code" for devices that ran fine.
    # WaitForExit() alone does not fix it; verified both ways.
    $null = $p.Process.Handle

    Write-Host ("  launched station {0} SN {1} opcode {2} -> pid {3}" -f `
        $p.Station, $p.SerialNumber, $p.OpCode, $p.Process.Id) -ForegroundColor Cyan
}

# --- Hand off (service mode) -------------------------------------------
# The processes are running and each owns its probe. Return now so the caller - the
# blessing service - can poll $StatusDir and drive the UI at its own pace. Deliberately
# no cleanup here: killing the children on exit is exactly what must NOT happen.
if ($NoWait) {
    Write-Host ""
    Write-Host "$($plan.Count) station process(es) running independently." -ForegroundColor Green
    Write-Host "  status files : $StatusDir\station<N>.json"
    Write-Host "  pids         : $(($plan | ForEach-Object { '{0}={1}' -f $_.Station, $_.Process.Id }) -join '  ')"
    exit 0
}

# --- Monitor -----------------------------------------------------------
# Poll every station's status file and report each transition as it happens. Reading the
# files rather than the children's stdout keeps this loop immune to redirection buffering:
# a child can be mid-write and the worst case is one skipped poll.
function Read-StationStatus {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json) }
    catch { return $null }   # caught mid-rename; next poll gets it
}

Write-Host ""
Write-Host "Monitoring $($plan.Count) station(s) in parallel (verdict timeout ${VerdictTimeoutSec}s, overall cap ${OverallTimeoutSec}s)..."
$deadline = (Get-Date).AddSeconds($OverallTimeoutSec)
while ((Get-Date) -lt $deadline) {
    foreach ($p in $plan) {
        $s = Read-StationStatus -Path $p.StatusFile
        if ($null -eq $s) { continue }
        # Only print when this station actually moved on, so a 3-minute verdict wait does
        # not bury the other stations' transitions in repeated lines.
        $key = "$($s.step)/$($s.state)"
        if ($key -eq $p.LastStep) { continue }
        $p.LastStep = $key

        $colour = switch ($s.state) {
            'passed' { 'Green' }
            'failed' { 'Red' }
            'error'  { 'Red' }
            default  { 'Gray' }
        }
        Write-Host ("  [{0:HH:mm:ss}] station {1}  {2,-12} {3,-7} {4}" -f `
            (Get-Date), $s.station, $s.step, $s.state, $s.message) -ForegroundColor $colour
    }

    $running = @($plan | Where-Object { -not $_.Process.HasExited })
    if ($running.Count -eq 0) { break }
    Start-Sleep -Seconds 2
}

foreach ($p in $plan) {
    if (-not $p.Process.HasExited) {
        Write-Host ("  overall timeout - killing pid {0} (station {1}, SN {2})" -f `
            $p.Process.Id, $p.Station, $p.SerialNumber) -ForegroundColor Yellow
        try { $p.Process.Kill() } catch { }
        $p.Killed = $true

        # The child cannot write its own terminal status once killed, so stamp it here.
        # Otherwise the UI would keep showing that station mid-step forever.
        try {
            $s = Read-StationStatus -Path $p.StatusFile
            $lastStep = 'UNKNOWN'
            if ($null -ne $s) { $lastStep = $s.step }
            $killed = [pscustomobject]@{
                station = $p.Station; opCode = $p.OpCode; serialNumber = $p.SerialNumber
                devEui = $(if ($null -ne $s) { $s.devEui } else { '' })
                region = $Region; step = $lastStep; state = 'error'
                message = "killed after overall timeout ${OverallTimeoutSec}s"
                exitCode = $null; pid = $p.Process.Id
                startedUtc = $(if ($null -ne $s) { $s.startedUtc } else { '' })
                updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
                elapsedSec = $OverallTimeoutSec
            }
            [System.IO.File]::WriteAllText($p.StatusFile, ($killed | ConvertTo-Json -Depth 3))
        }
        catch { }
    }

    # WaitForExit() is what caches the exit code. Reading .ExitCode straight off a
    # -PassThru process object that has already gone away yields $null (or throws),
    # which made every device report "no exit code" even on a completely clean run.
    try {
        $p.Process.WaitForExit(5000) | Out-Null
        $p.ExitCode = $p.Process.ExitCode
    }
    catch {
        $p.ExitCode = $null
    }
}

# --- Summarise ---------------------------------------------------------
$codeMeaning = @{
    0 = 'PASS'; 1 = 'setup error'; 2 = 'erase failed'; 3 = 'keys write failed'
    4 = 'flash failed'; 5 = 'verdict timeout'; 6 = 'DUT FAIL'
}

# @() so a single-station run still yields an array: under Set-StrictMode -Version Latest,
# .Count on a lone [pscustomobject] throws instead of returning 1.
$summary = @(foreach ($p in $plan) {
    # Pull the DevEUI and verdict the child already reported, so the rig operator
    # gets one table instead of N logs.
    $devEui = ''
    $verdict = ''
    $faults = ''
    # The status file is the structured source; fall back to scraping the log so a run
    # made without status files (or one whose child died before writing) still reports.
    $s = Read-StationStatus -Path $p.StatusFile
    if ($null -ne $s -and $s.devEui) { $devEui = $s.devEui }
    if ($null -ne $s -and $s.PSObject.Properties['verdict'] -and $s.verdict) { $verdict = $s.verdict }
    if ($null -ne $s -and $s.PSObject.Properties['faults'] -and $s.faults) { $faults = (@($s.faults) -join ', ') }
    if (Test-Path $p.Log) {
        $text = Get-Content $p.Log -Raw
        if (-not $devEui -and $text -match 'DevEUI:\s*([0-9A-Fa-f]{16})') { $devEui = $Matches[1] }
        if (-not $verdict -and $text -match 'verdict=(0x[0-9A-Fa-f]{8})') { $verdict = $Matches[1] }
        if (-not $faults -and $text -match '(?m)^\s*failed:\s*(.+)$') { $faults = $Matches[1].Trim() }
    }
    # Prefer the exit code; fall back to the verdict the child logged, so a process
    # bookkeeping problem here can never misreport a device that actually passed.
    $passed = $false
    if ($p.Killed) {
        $meaning = 'killed (overall timeout)'
    }
    elseif ($null -ne $p.ExitCode -and $codeMeaning.ContainsKey([int]$p.ExitCode)) {
        $meaning = $codeMeaning[[int]$p.ExitCode]
        $passed = ([int]$p.ExitCode -eq 0)
    }
    elseif ($null -ne $p.ExitCode) {
        $meaning = "unknown exit ($($p.ExitCode))"
    }
    elseif ($verdict) {
        # No exit code, but a verdict was logged. Decode it the same way
        # flash_device.ps1 does: the signature plus zero fault bits is a pass. The
        # pre-coded 1 and 2 are not verdicts any more, so they fall through to
        # "unrecognised" instead of being reported as a pass or a fail.
        # L suffixes required: a bare 0xD5000000 is a negative Int32 in Windows
        # PowerShell and never matches a real uint32 word. See flash_device.ps1.
        $v = [Convert]::ToUInt32($verdict, 16)
        $signed = ((($v -band 0xFF000000L) -eq 0xD5000000L) -and (($v -band 0x00FF0000L) -eq 0))
        if ($signed -and ($v -band 0x0000FFFFL) -eq 0) {
            $meaning = 'PASS (from log; no exit code)'
            $passed = $true
        }
        elseif ($signed) {
            $meaning = 'DUT FAIL (from log; no exit code)'
        }
        else {
            $meaning = "unrecognised verdict $verdict (no exit code)"
        }
    }
    else {
        $meaning = 'no exit code and no verdict logged'
    }

    [pscustomobject]@{
        Station      = $p.Station
        SerialNumber = $p.SerialNumber
        OpCode       = $p.OpCode
        DevEUI       = $devEui
        Verdict      = $verdict
        Faults       = $faults
        Exit         = $p.ExitCode
        Result       = $meaning
        Passed       = $passed
        Killed       = $p.Killed
    }
})

Write-Host ""
Write-Host "==== Rig summary ====" -ForegroundColor White
if ($Json) {
    # The whole of stdout in this mode. Field names are camelCase for the consumer and
    # nulls stay null rather than becoming "".
    #
    # Deliberately NOT included, because the consumer derives them itself:
    #   opCode  - fixed per station by rig_layout.ps1
    #   faults  - decoded from the verdict bits
    #   result  - prose; exitCode carries the same classification as a number
    # The terminal tables still show all three; this is the machine feed only.
    $doc = [pscustomobject]@{
        stations = @($summary | Sort-Object Station | ForEach-Object {
            [pscustomobject]@{
                station      = $_.Station
                serialNumber = $_.SerialNumber
                devEui       = $_.DevEUI
                verdict      = $_.Verdict
                exitCode     = $_.Exit
                passed       = $_.Passed
                killed       = $_.Killed
            }
        })
        total  = @($summary).Count
        passed = @($summary | Where-Object { $_.Passed }).Count
        failed = @($summary | Where-Object { -not $_.Passed }).Count
    }
    # .ToArray()-equivalent: pass a real array, since Windows PowerShell 5.1
    # ConvertTo-Json throws "Argument types do not match" on a List[object].
    ConvertTo-Json -InputObject $doc -Depth 5
}
elseif ($FullSummary) {
    $summary | Sort-Object Station |
        Format-Table Station, SerialNumber, OpCode, DevEUI, Verdict, Faults, Exit, Result -AutoSize
}
else {
    # Two columns by default: station and verdict, which is what a bench run is read
    # for. Everything else is still on the objects, so -FullSummary brings it back.
    #
    # A station that never produced a verdict word - setup error, erase failure,
    # timeout, killed - would leave Verdict blank and the whole row uninformative. So
    # fall back to the result text for those, and the column always says something.
    $summary | Sort-Object Station | ForEach-Object {
        $shown = $_.Verdict
        if (-not $shown) { $shown = $_.Result }
        [pscustomobject]@{ Station = $_.Station; Verdict = $shown }
    } | Format-Table -AutoSize
}

# --- Clean up -----------------------------------------------------------
# Everything worth reporting is already in the table above and in the transitions printed
# while the run was in flight, so by default the run directory goes away. Done here, after
# the summary, because building it reads the child logs.
if ($keepRunDir) {
    # Silenced on request: the run header already prints the same two paths (see the
    # "logs" and "status" lines above), so repeating them here only adds noise. The
    # branch itself must stay - the else below is what deletes the run directory.
    # Write-Host "Per-device logs  : $LogDir"
    # Write-Host "Per-station state: $StatusDir"
}
else {
    try {
        Remove-Item -LiteralPath $LogDir -Recurse -Force -ErrorAction Stop
        # Drop the %TEMP%\fso_rig parent too once the last run folder is gone, so nothing
        # of ours is left behind at all.
        $parent = Split-Path -Parent $LogDir
        if ((Test-Path $parent) -and -not (Get-ChildItem -LiteralPath $parent -Force)) {
            Remove-Item -LiteralPath $parent -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
        # Never fail a run over cleanup - a child still holding a log handle is the likely
        # cause, and the files are in %TEMP% where they are harmless.
        Write-Host "  (could not remove temporary run directory $LogDir - $($_.Exception.Message))" -ForegroundColor DarkGray
    }
}

$failed = @($summary | Where-Object { -not $_.Passed })
if ($failed.Count -eq 0) {
    Write-Host "ALL $($summary.Count) DEVICE(S) PASSED" -ForegroundColor Green
    exit 0
}
Write-Host "$($failed.Count) of $($summary.Count) device(s) did not pass" -ForegroundColor Red
if (-not $keepRunDir) {
    Write-Host "  re-run with -KeepLogs to keep each station's output, including the STM32_Programmer_CLI error text" -ForegroundColor DarkGray
}
exit 2
