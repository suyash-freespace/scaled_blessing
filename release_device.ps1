<#
.SYNOPSIS
    Release one productionised FSO device: regress RDP level 1 back to level 0.

.DESCRIPTION
    The reverse of bless_rig.ps1 -Secure. A device that passed blessing had its key page
    cleared and RDP set to 0xBB, which locks the debug port on the next power-on reset.
    This hands it back.

    THIS MASS ERASES THE DEVICE. That is not a side effect, it is the mechanism: STM32
    will not return debug access without destroying what the lock was protecting. The
    board comes back completely blank - no firmware, no keys, no op-code - and needs a
    full blessing before it is a device again.

    One station per run, on purpose. Each release destroys a provisioned board, so naming
    exactly one station is the speed bump on an irreversible action.

    No child process is spawned. The CLI is called directly in this process, the same way
    scan_device.ps1 does it, because there is nothing here to isolate or run in parallel.

    Steps:

        1. Read the option bytes and note the current RDP level.
        2. If already 0xAA, report released=false and stop. Nothing is erased.
        3. Otherwise write RDP=0xAA, read the option bytes BACK, and read 0x08000000 to
           confirm the flash really went blank.

    Step 3's read-back is the point. bless_rig.ps1 -Secure deliberately verifies nothing,
    so "locked" there means only that the programmer returned 0. Here the whole job is one
    option-byte write, so there is no excuse for not checking that it landed.

    The DevEUI is deliberately NOT reported. Deriving it means a third copy of
    GetUniqueId()'s byte order, which already exists in flash_device.ps1 and
    scan_device.ps1 and which the repo rules say must not be duplicated again - a wrong
    order yields a plausible-looking WRONG DevEUI with no error. The ST-LINK serial
    identifies the station just as well here, and it costs no read.

.PARAMETER Stations
    The one station to release, 1-6. Resolved to an ST-LINK serial through
    rig_devices.csv, so the operator never handles a 24-character serial by hand.

.EXAMPLE
    .\release_device.ps1 -Stations 2

.NOTES
    STDOUT IS ALWAYS ONE JSON DOCUMENT, with five fields, on EVERY exit path:

        { "station": 2, "serialNumber": "005100303233510A39363634",
          "released": true, "exitCode": 0, "error": "" }

    Unlike bless_rig.ps1 -Json, there is no "check the exit code before parsing" trap
    here: even a setup failure emits the document, with the reason in 'error' and
    station 0 when the failure happened before a station could be resolved. Nothing is
    written to stderr, so a caller needs to read one stream only.

    'error' is "" on success and a single sentence otherwise. 'exitCode' repeats the
    process exit code inside the document, so a caller that has already parsed stdout
    never has to reach back for $LASTEXITCODE.

    'released' is true ONLY when the RDP byte regressed to 0xAA AND the flash read back
    blank. A board whose option byte moved but whose flash did not is reported false,
    with exit 2 - never as a reassuring true. See the comment at $released below.

    Exit codes: 0 = released, or already unlocked and nothing was erased
                1 = setup error - bad station, no probe, unreadable option bytes
                2 = the release did not fully take

    Note that exit 0 covers two outcomes, told apart by 'released': true means the board
    was locked and has been wiped, false means it was already open and nothing was done.

    A released board is blank. Power cycle it, then bless it before shipping it.
#>
[CmdletBinding()]
param(
    # One station only. Typed [string[]] for the same reason as the other rig scripts:
    # under "powershell.exe -File" every argument arrives as a string, and a bare number
    # coerced straight to [int] has bitten this rig before.
    [Parameter(Mandatory = $true)]
    [string[]]$Stations,

    [string]$DeviceList,

    # Accepted and ignored. Output is always JSON, but every other rig command is invoked
    # with -Json, so typing it here must not fail with "parameter cannot be found".
    [switch]$Json,

    [int]$Freq = 24000,

    # Fourth copy of this path in the repo, after flash_device.ps1, scan_device.ps1 and
    # bless_rig.ps1. Overridable here so a moved install needs no edit. The repo rule is
    # to move this into rig_layout.ps1 once a fifth copy appears, and counting
    # enable_security.bat's setenv.bat, this is the fifth.
    [string]$ProgrammerCli = "C:\Program Files\STMicroelectronics\STM32Cube\STM32CubeProgrammer\bin\STM32_Programmer_CLI.exe"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Canonical station map and $VALID_STATIONS, shared with the other rig scripts.
. (Join-Path $PSScriptRoot 'rig_layout.ps1')

# RDP level 0. A constant, not a parameter, for the same reason 0xBB is one in
# bless_rig.ps1: 0xCC is level 2 and is permanent, with no regression path at all.
# One mistyped character is the difference between a blank board and a dead one.
$RDP_LEVEL_0 = '0xAA'

function Write-Result {
    <#
      The one and only thing this script puts on stdout, and the only way it ever exits.

      Emitting the document and exiting in one place is what makes the exitCode field and
      the real process exit code impossible to disagree about - the same reason
      flash_device.ps1 funnels every terminal state through Complete-Run.

      -ErrorMessage, not -Error: a parameter named Error would shadow PowerShell's own
      $Error automatic variable inside this function.
    #>
    param(
        [int]$Station = 0,
        [string]$SerialNumber = '',
        [bool]$Released = $false,
        [Parameter(Mandatory = $true)][int]$Code,
        [string]$ErrorMessage = ''
    )
    ConvertTo-Json -Depth 3 -InputObject ([pscustomobject]@{
        station      = $Station
        serialNumber = $SerialNumber
        released     = $Released
        exitCode     = $Code
        error        = $ErrorMessage
    })
    exit $Code
}

function Get-RdpLevel {
    # Current RDP byte, or $null if the option bytes could not be read.
    #
    # mode=UR, matching the option-byte write below and enable_security.bat before it. A
    # locked device still answers the debug port and still reports its option bytes, so
    # this works at RDP1, which is exactly when it is needed.
    param([string]$Sn)
    $out = & $ProgrammerCli -q -c port=SWD freq=$Freq mode=UR sn=$Sn -ob displ 2>&1
    if ($LASTEXITCODE -ne 0) { return $null }
    foreach ($line in $out) {
        # Capture the digits only, then re-prefix. Upper-casing the whole match would
        # yield "0XAA", which reads wrong and would ship that way in the JSON.
        if ($line -match 'RDP\s*:\s*0x([0-9A-Fa-f]{2})') { return ('0x' + $Matches[1].ToUpper()) }
    }
    return $null
}

# --- Resolve the one station --------------------------------------------
# Failures before a station is pinned down report station 0, because naming one would be
# a guess.
if (-not $DeviceList) { $DeviceList = Join-Path $PSScriptRoot 'rig_devices.csv' }
if (-not (Test-Path $ProgrammerCli)) {
    Write-Result -Code 1 -ErrorMessage "STM32_Programmer_CLI not found: $ProgrammerCli"
}

$wanted = @()
foreach ($tok in ($Stations -split '[,\s]+')) {
    if (-not $tok) { continue }
    $n = 0
    if ([int]::TryParse($tok, [ref]$n) -and $VALID_STATIONS -contains $n) {
        if ($wanted -notcontains $n) { $wanted += $n }
    }
    else {
        Write-Result -Code 1 -ErrorMessage ("Bad -Stations value: {0}. Valid stations are {1}." -f `
            $tok, ($VALID_STATIONS -join ', '))
    }
}

# One at a time. Each release destroys a provisioned board, so a mistyped list must never
# be able to take out more than the operator named.
if ($wanted.Count -ne 1) {
    Write-Result -Code 1 -ErrorMessage ("Name exactly ONE station. Each release MASS ERASES its " +
        "device, so this script will not take a list. Got: {0}." -f ($wanted -join ', '))
}
$station = $wanted[0]

try { $sn = Resolve-StationProbe -Station $station -DeviceListPath $DeviceList }
catch {
    # The station is known from here on, so report it even though the probe is not.
    Write-Result -Station $station -Code 1 -ErrorMessage $_.Exception.Message
}

# --- Read the current level ---------------------------------------------
$before = Get-RdpLevel -Sn $sn
if ($null -eq $before) {
    Write-Result -Station $station -SerialNumber $sn -Code 1 -ErrorMessage (
        "Could not read the option bytes on station $station (SN $sn). The probe is not " +
        "attached, the serial in $DeviceList is wrong, or no board is seated.")
}

# Already open. Report it and erase nothing: there is no reason to destroy a board that is
# already handing back its debug port. released=false because nothing was released.
if ($before -eq $RDP_LEVEL_0) {
    Write-Result -Station $station -SerialNumber $sn -Released $false -Code 0
}

# --- Release -------------------------------------------------------------
& $ProgrammerCli -q -c port=SWD freq=$Freq mode=UR sn=$sn -ob RDP=$RDP_LEVEL_0 *> $null

# Read back regardless of the CLI exit code. A programmer that returned non-zero after the
# option bytes had already taken is a worse thing to misreport than one that returned 0
# without them landing, so the hardware gets the last word either way.
$after = Get-RdpLevel -Sn $sn
$regressed = ($after -eq $RDP_LEVEL_0)

# Confirm the erase too. A blank vector table is what proves the flash really went, rather
# than the option byte flipping on its own. mode=UR, not HOTPLUG: a just-released board
# has no valid vector table and its core is looping in a fault, so it must be held under
# reset to be read reliably.
$blank = $false
if ($regressed) {
    $fw = & $ProgrammerCli -q -c port=SWD freq=$Freq mode=UR sn=$sn -r32 0x08000000 4 2>&1
    if ($LASTEXITCODE -eq 0) {
        foreach ($line in $fw) {
            if ($line -match '^\s*0x08000000\s*:\s*FFFFFFFF') { $blank = $true }
        }
    }
}

# BOTH conditions, deliberately. The dangerous outcome here is an option byte that moved
# while the flash did not: the caller would read released=true and ship a board that may
# still hold its image. Folding the two into one flag is only safe in this direction -
# a partial release reports false and exit 2, never a reassuring true.
$released = ($regressed -and $blank)

# The two failure shapes are named separately, because they need different responses. A
# board still at RDP1 was never opened. One that opened without erasing may still hold its
# firmware, and must not be trusted or shipped.
$errorMessage = ''
if (-not $regressed) {
    $shown = $after
    if ($null -eq $shown) { $shown = 'unreadable' }
    $errorMessage = "RDP did not regress: still $shown. The device may still be locked - try the STM32CubeProgrammer GUI."
}
elseif (-not $blank) {
    $errorMessage = "RDP regressed to $RDP_LEVEL_0 but flash at 0x08000000 did not read back blank. Read it before trusting or shipping this board."
}

$code = 2
if ($released) { $code = 0 }
Write-Result -Station $station -SerialNumber $sn -Released $released -Code $code -ErrorMessage $errorMessage
