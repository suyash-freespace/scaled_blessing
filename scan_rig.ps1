<#
.SYNOPSIS
    Scan the rig and report the DevEUI of every device on it. Reads only, erases nothing.

.DESCRIPTION
    Answers one question: which devices are on the bench right now, and what is each
    one's DevEUI? Run it before a blessing run to collect the DevEUIs the LNS needs, and
    to confirm every station is populated and its probe is alive.

    Three steps:

        1. Ask STM32_Programmer_CLI which ST-LINK probes are attached.
        2. Map each probe serial to its rig station, using rig_devices.csv.
        3. Read each attached device's DevEUI via flash_device.ps1 -ReadDevEuiOnly.

    The DevEUI comes from the chip UID, not from the factory page. So the rig has to read
    it off the device. flash_device.ps1 already mirrors GetUniqueId()'s byte order, and
    this script calls it rather than reimplementing that order and getting it subtly
    wrong.

    Nothing here writes to a device. -ReadDevEuiOnly returns before the erase step, so a
    scan is safe on an already blessed device, at any time.

    The State column reports every mismatch between the bench and the device list:

        ok           probe attached, DevEUI read
        no probe     the device list expects this station, but its probe is absent
        not listed   a probe is attached that rig_devices.csv does not describe
        read failed  the probe answered, the UID read did not - see Message

.PARAMETER DeviceList
    CSV describing the rig: Position, SerialNumber. Defaults to rig_devices.csv next to
    this script. A missing list is not fatal. The scan then reports every attached probe
    with no station number.

.PARAMETER Stations
    Scan only these stations, comma-separated: -Stations 1,3. Omit for the whole bench.
    Attached probes missing from the device list are always reported.

.PARAMETER Json
    Emit the rows as JSON instead of a table, for the blessing service to consume.

.EXAMPLE
    .\scan_rig.ps1
    .\scan_rig.ps1 -Stations 1,3
    .\scan_rig.ps1 -Json | ConvertFrom-Json

.NOTES
    Exit codes: 0 = every listed station answered | 1 = setup error
                2 = a listed station is empty, or a DevEUI read failed
#>
[CmdletBinding()]
param(
    [string]$DeviceList,

    # Comma-separated, and typed [string[]] for the same reason as bless_rig.ps1: under
    # "powershell.exe -File" every argument arrives as a string, and "1,3" coerced to
    # [int] silently becomes 13.
    [string[]]$Stations,

    [switch]$Json,

    # 24000 to match flash_device.ps1. Drop to 8000 or 4000 if connects start failing.
    [int]$Freq = 24000,

    # Second copy of this path - flash_device.ps1 holds the other one. Overridable here
    # so a moved install needs no edit. Keep the two in step, or move both into
    # rig_layout.ps1 if a third script ever needs the CLI.
    [string]$ProgrammerCli = "C:\Program Files\STMicroelectronics\STM32Cube\STM32CubeProgrammer\bin\STM32_Programmer_CLI.exe"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Canonical station -> op-code map, shared with the other rig scripts. Used here only
# for $VALID_STATIONS.
. (Join-Path $PSScriptRoot 'rig_layout.ps1')

$deviceScript = Join-Path $PSScriptRoot 'flash_device.ps1'
if (-not (Test-Path $deviceScript)) { throw "flash_device.ps1 not found next to this script: $deviceScript" }
if (-not (Test-Path $ProgrammerCli)) { throw "STM32_Programmer_CLI not found: $ProgrammerCli" }
if (-not $DeviceList) { $DeviceList = Join-Path $PSScriptRoot 'rig_devices.csv' }

function Get-AttachedProbe {
    <#
      Serial number of every attached ST-LINK, in the order the CLI lists them.

      Distinct on purpose. STM32_Programmer_CLI -l prints one probe's serial TWICE, once
      under "STLink Interface" and again in its serial-port section, so a raw parse
      reports two probes for one board and then scans it twice.
    #>
    $out = @(& $ProgrammerCli -l)
    if ($LASTEXITCODE -ne 0) { throw "STM32_Programmer_CLI -l failed (exit $LASTEXITCODE)" }
    $serials = New-Object System.Collections.Generic.List[string]
    foreach ($line in $out) {
        # "--- ST-LINK SN  : 001900393234510733353533"
        if ($line -match 'ST-?LINK\s+SN\s*:\s*(\S+)') {
            $sn = $Matches[1]
            # -l is NOT trustworthy on this host: with a probe in DEV_CONNECT_ERR it
            # prints raw bytes where the serial belongs, e.g. "SN : <binary>". Taking
            # that literally invents a probe that does not exist AND hides the real
            # one, so every listed station reads back as 'no probe'. A real serial is
            # plain alphanumeric, so anything else is dropped here.
            if ($sn -notmatch '^[0-9A-Za-z]{8,32}$') { continue }
            if (-not $serials.Contains($sn)) { $serials.Add($sn) }
        }
    }
    return $serials.ToArray()
}

function Read-DevEui {
    <#
      Read one device's DevEUI through flash_device.ps1 -ReadDevEuiOnly.

      Runs in its own process, the way bless_rig.ps1 launches it, so the child's exit
      calls cannot end this scan.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$SerialNumber,
        [int]$Station = 0
    )

    # -Station only selects the op-code, and the op-code is written in a step that
    # -ReadDevEuiOnly never reaches. Station 1 is therefore a harmless filler for a
    # probe the device list does not describe.
    $stationArg = 1
    if ($Station -ge 1) { $stationArg = $Station }

    $out = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $deviceScript `
                 -Station $stationArg -SerialNumber $SerialNumber -Freq $Freq -ReadDevEuiOnly)
    $code = $LASTEXITCODE
    $text = ($out -join "`n")

    # flash_device.ps1 prints exactly one "DevEUI: <16 hex>" line on this path.
    $eui = ''
    if ($text -match 'DevEUI:\s*([0-9A-Fa-f]{16})') { $eui = $Matches[1].ToUpper() }

    # Its failures are plain text on the success stream, so the last non-empty line is
    # the useful one.
    $why = "flash_device.ps1 exit $code"
    $lines = @($out | Where-Object { $_ -and ([string]$_).Trim() })
    if ($lines.Count -gt 0) { $why = ([string]$lines[-1]).Trim() }

    return [pscustomobject]@{ DevEui = $eui; ExitCode = $code; Message = $why }
}

# --- Which stations were asked for --------------------------------------
$wanted = New-Object System.Collections.Generic.List[int]
if ($PSBoundParameters.ContainsKey('Stations') -and $Stations) {
    # Flatten "1,3" / "1 3" / "1, 3" into distinct integers.
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
        Write-Host ("Bad -Stations value(s): {0}. Valid stations are {1}." -f `
            ($bad -join ', '), ($VALID_STATIONS -join ', ')) -ForegroundColor Red
        exit 1
    }
}

# --- Load the device list -----------------------------------------------
# station -> probe serial. An absent list is fine: every attached probe is then reported
# with no station, which is still the DevEUI answer the caller wanted.
$serialByStation = @{}
$haveList = Test-Path $DeviceList
if ($haveList) {
    $rows = @(Import-Csv -Path $DeviceList)
    $cols = @()
    if ($rows.Count -gt 0) { $cols = $rows[0].PSObject.Properties.Name }

    $problems = @()
    foreach ($required in @('Position', 'SerialNumber')) {
        if ($cols -notcontains $required) {
            $problems += "missing required column '$required' (found: $($cols -join ', '))"
        }
    }
    if ($problems.Count -eq 0) {
        foreach ($r in $rows) {
            $pos = 0
            if (-not [int]::TryParse([string]$r.Position, [ref]$pos) -or $VALID_STATIONS -notcontains $pos) {
                $problems += "Position '$($r.Position)' (SN $($r.SerialNumber)) must be one of $($VALID_STATIONS -join ', ')"
                continue
            }
            if (-not $r.SerialNumber) { $problems += "station $pos has an empty SerialNumber"; continue }
            # A duplicate on either side makes the station -> probe map ambiguous, so the
            # scan would report a DevEUI against the wrong station.
            if ($serialByStation.ContainsKey($pos)) {
                $problems += "station $pos appears more than once"
                continue
            }
            $serialByStation[$pos] = $r.SerialNumber
        }
        foreach ($dup in ($rows | Group-Object SerialNumber | Where-Object { $_.Count -gt 1 })) {
            $problems += "SerialNumber $($dup.Name) appears $($dup.Count) times"
        }
    }
    if ($problems.Count -gt 0) {
        Write-Host "Device list is not usable: $DeviceList" -ForegroundColor Red
        $problems | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
        exit 1
    }
}

# --- Scan ---------------------------------------------------------------
$attached = @(Get-AttachedProbe)

if (-not $Json) {
    Write-Host "FSO rig scan - $($attached.Count) probe(s) attached" -ForegroundColor White
    if ($haveList) { Write-Host "  device list : $DeviceList" }
    else { Write-Host "  device list : none at $DeviceList - reporting attached probes only" -ForegroundColor DarkGray }
    if ($wanted.Count -gt 0) {
        Write-Host ("  stations    : {0}" -f (($wanted | Sort-Object) -join ', ')) -ForegroundColor Cyan
    }
    Write-Host "  reads only - no device is erased or written" -ForegroundColor DarkGray
    Write-Host ""
}

$results = New-Object System.Collections.Generic.List[object]

function Add-Row {
    param(
        $Station, [string]$SerialNumber, [string]$DevEui,
        [string]$State, [string]$Message, $ExitCode
    )
    $results.Add([pscustomobject]@{
        Station      = $Station
        SerialNumber = $SerialNumber
        DevEUI       = $DevEui
        State        = $State
        Message      = $Message
        ExitCode     = $ExitCode
    })
}

# Only believe 'not attached' when the probe list is usable. If -l returned nothing
# valid, the enumeration failed rather than the bench being empty, so attempt every
# listed station and report what the connect actually says.
$probeListUsable = ($attached.Count -gt 0)
if (-not $probeListUsable -and $serialByStation.Count -gt 0 -and -not $Json) {
    Write-Host ("note: STM32_Programmer_CLI -l listed no usable probe serial. Reading each " +
                "listed station directly instead - a garbled -l is known on this host.") -ForegroundColor Yellow
}

foreach ($station in ($serialByStation.Keys | Sort-Object)) {
    if ($wanted.Count -gt 0 -and $wanted -notcontains $station) { continue }
    $sn = $serialByStation[$station]

    if ($probeListUsable -and $attached -notcontains $sn) {
        Add-Row -Station $station -SerialNumber $sn -DevEui '' -State 'no probe' `
                -Message 'ST-LINK not attached' -ExitCode $null
        continue
    }

    if (-not $Json) { Write-Host "station $station  reading DevEUI ..." -ForegroundColor DarkGray }
    $read = Read-DevEui -SerialNumber $sn -Station $station
    if ($read.ExitCode -eq 0 -and $read.DevEui) {
        Add-Row -Station $station -SerialNumber $sn -DevEui $read.DevEui -State 'ok' `
                -Message '' -ExitCode $read.ExitCode
    }
    else {
        Add-Row -Station $station -SerialNumber $sn -DevEui $read.DevEui -State 'read failed' `
                -Message $read.Message -ExitCode $read.ExitCode
    }
}

# Probes on the bench that the list does not describe. Reported even under -Stations: an
# unexpected probe is exactly what a scan should surface.
$listed = @($serialByStation.Values)
foreach ($sn in $attached) {
    if ($listed -contains $sn) { continue }
    if (-not $Json) { Write-Host "unlisted probe $sn  reading DevEUI ..." -ForegroundColor DarkGray }
    $read = Read-DevEui -SerialNumber $sn
    $state = 'not listed'
    if ($read.ExitCode -ne 0 -or -not $read.DevEui) { $state = 'read failed' }
    $note = 'no row in the device list'
    if ($state -eq 'read failed') { $note = "$($read.Message) (and no row in the device list)" }
    Add-Row -Station $null -SerialNumber $sn -DevEui $read.DevEui -State $state `
            -Message $note -ExitCode $read.ExitCode
}

# --- Report -------------------------------------------------------------
if ($Json) {
    # Same envelope and the same camelCase field names as bless_rig.ps1 -Json, so one
    # consumer can read both: an object with a 'stations' array plus counts, never a
    # bare array. station / serialNumber / devEui / exitCode mean the same thing in
    # both documents.
    #
    # Rows stay PascalCase internally because the table and the filters below read
    # them; the mapping to the wire format happens only here.
    #
    # .ToArray() is required, not tidiness. Windows PowerShell 5.1 ConvertTo-Json
    # throws "Argument types do not match" on a List[object], piped or as -InputObject.
    $rows = @($results.ToArray() | ForEach-Object {
        [pscustomobject]@{
            station      = $_.Station
            serialNumber = $_.SerialNumber
            devEui       = $_.DevEUI
            state        = $_.State
            message      = $_.Message
            exitCode     = $_.ExitCode
        }
    })

    # The counts mirror the exit code: failed > 0 is exactly when this script exits 2.
    # 'not listed' reads a DevEUI successfully, so it is neither ok nor failed.
    $doc = [pscustomobject]@{
        stations  = $rows
        total     = $rows.Count
        ok        = @($rows | Where-Object { $_.state -eq 'ok' }).Count
        notListed = @($rows | Where-Object { $_.state -eq 'not listed' }).Count
        failed    = @($rows | Where-Object { $_.state -eq 'no probe' -or $_.state -eq 'read failed' }).Count
    }
    ConvertTo-Json -InputObject $doc -Depth 4
}
else {
    Write-Host ""
    Write-Host "==== Rig scan ====" -ForegroundColor White
    if ($results.Count -eq 0) {
        Write-Host "No devices found. Check the USB hub and rig_devices.csv." -ForegroundColor Yellow
    }
    else {
        $results | Format-Table Station, SerialNumber, DevEUI, State, Message -AutoSize
    }
    foreach ($u in @($results | Where-Object { $_.State -eq 'not listed' })) {
        Write-Host ("note: probe $($u.SerialNumber) is attached but has no row in $DeviceList - " +
                    "add one with its Position, or bless_rig.ps1 will never select it.") -ForegroundColor Yellow
    }
}

$broken = @($results | Where-Object { $_.State -eq 'no probe' -or $_.State -eq 'read failed' })
if ($broken.Count -eq 0) { exit 0 }
if (-not $Json) {
    Write-Host "$($broken.Count) station(s) did not report a DevEUI" -ForegroundColor Red
}
exit 2
