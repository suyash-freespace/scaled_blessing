<#
.SYNOPSIS
    Flash one FSO device: erase -> op-code/keys/region -> firmware -> reboot.

.DESCRIPTION
    The per-device primitive for the 6-station rig. bless_rig.ps1 fans this out, one
    process per ST-LINK probe.

        1. Read the chip UID and report the DevEUI. Pre-flight only: it catches a dead
           or absent probe BEFORE anything is erased, and the front-end needs the
           DevEUI anyway to register the device with the LNS.
        2. -e all
        3. Write the factory page at 0x0803F800: op-code, AppKey, JoinEUI, region
        4. Flash the merged SBSFU+app image, with -hardRst rebooting into it

    That is the whole job. The DEVICE owns its own status - the LED, and the verdict
    word at 0x20003400 - and the front-end reads it; this script does not wait for it.

    Pass -ReadVerdict to poll the verdict anyway. That makes this process own its probe
    for the entire run - DevEUI, erase, keys, flash, verdict - which is what the blessing
    UI wants: nothing else ever connects to that ST-LINK while a station is blessing, so
    there is no contention to lose a device to.

    Pass -StatusFile to get machine-readable progress for that UI (see the parameter).

    RDP is left at level 0.

.PARAMETER Station
    Physical rig station 1-6. Sets the op-code via rig_layout.ps1 and, if
    rig_devices.csv is present, resolves the ST-LINK serial for that slot.

.PARAMETER AppKey
    32 hex chars MSB-first, as the LNS shows it. Stored byte-reversed (see below).
    Defaults to the bring-up value; a front-end supplying generated keys passes this.

.EXAMPLE
    .\flash_device.ps1 -Station 1
    .\flash_device.ps1 -Station 2 -AppKey <32 hex> -JoinEui <16 hex> -Region EU868

.NOTES
    Exit codes: 0 flashed OK | 1 setup error | 2 erase failed | 3 keys failed
                4 flash failed
    With -ReadVerdict only: 5 verdict timeout | 6 DUT FAIL (0 then means PASS)
#>
param(
    [int]$Station = 1,
    [ValidatePattern('^[0-9A-Fa-f]{32}$')][string]$AppKey = '2B7E151628AED2A6ABF7158809CF4F3C',
    [ValidatePattern('^[0-9A-Fa-f]{16}$')][string]$JoinEui = '0E0D0D010E01020E',
    [ValidateSet('AS923','AU915','CN470','CN779','EU433','EU868','KR920','IN865','US915','RU864')]
    [string]$Region = 'US915',
    [string]$SerialNumber,
    [string]$FirmwarePath,
    [int]$Freq = 24000,

    # Off by default: the device reports its own status and the blessing service polls
    # 0x20003400 for it. Turn this on to have the script wait and report instead.
    [switch]$ReadVerdict,
    [int]$VerdictTimeoutSec = 180,

    # Read the DevEUI and exit WITHOUT touching the device. For the blessing service's
    # pre-flash step: it needs the DevEUI to register the device with the LNS against
    # the keys it is about to write. Reimplementing GetUniqueId()'s byte order in the
    # service is exactly the kind of thing that silently goes wrong, so borrow this.
    [switch]$ReadDevEuiOnly,

    # Machine-readable progress for the blessing UI. This process overwrites the file
    # after every step transition, so whoever is watching it always sees the current
    # state of THIS station and nothing else - no log scraping, no shared file between
    # stations, and the last known state survives even if this process is killed.
    [string]$StatusFile
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'rig_layout.ps1')   # station -> op-code, one source of truth

# =============================================================================
# EDIT THESE TWO PATHS IF THEY MOVE
# =============================================================================
# Merged SBSFU + application image, flashed to 0x08000000. Used unless a caller
# passes -FirmwarePath explicitly. This is the only place the location is defined.
$FIRMWARE_IMAGE = "C:\Freespace_Projects\Gen4\fs-lorawan-gen4-monorepo\products\fso\ide\Binary\BFU_FSO.bin"

$CLI = "C:\Program Files\STMicroelectronics\STM32Cube\STM32CubeProgrammer\bin\STM32_Programmer_CLI.exe"
# =============================================================================

$REGION_IDS = @{ 'AS923' = 0; 'AU915' = 1; 'CN470' = 2; 'CN779' = 3; 'EU433' = 4
                 'EU868' = 5; 'KR920' = 6; 'IN865' = 7; 'US915' = 8; 'RU864' = 9 }

$FACTORY_PAGE = 0x0803F800   # device_dut.h FACTORY_PROD_ADDRESS
$VERDICT_ADDR = 0x20003400   # .dut_result, STM32WL55JCIX_FLASH.ld
$UID64        = 0x1FFF7580   # LL_FLASH_GetUDN / GetDeviceID / GetSTCompanyID

# ---- DUT verdict word ------------------------------------------------------
# Layout, mirroring products/fso/app/device_dut.h:
#
#     31    24 | 23    16 | 15     8 | 7      0
#       0xD5   |   0x00   |  stage 2 |  stage 1
#     signature   reserved   faults     faults
#
# The signature is what makes a read trustworthy. .dut_result is NOLOAD and is
# cleared only when the op-code matches, so the word can hold stale bytes; the one
# seen in practice is 0x00005776, SBSFU's uFlowCryptoValue, read before SBSFU hands
# over. Pass/fail is the fault bits alone - zero faults means pass.
# The L suffixes are REQUIRED, not decoration. Windows PowerShell types a bare
# 0xD5000000 as Int32, which overflows to -721420288; comparing that against a real
# uint32 read from the device is always false, so the poll loop would never accept a
# verdict and every device would report VERDICT TIMEOUT. The suffix forces Int64.
# Verified: (3573547015 -band 0xFF000000) -eq 0xD5000000 is False, with L it is True.
$VERDICT_SIGNATURE      = 0xD5000000L
$VERDICT_SIGNATURE_MASK = 0xFF000000L
$VERDICT_RESERVED_MASK  = 0x00FF0000L
$VERDICT_FAULT_MASK     = 0x0000FFFFL

# Bit -> operator-facing name, in the order faults are reported. "KTD I2C" and not
# "LED" on purpose: a clear bit only proves the KTD2026 answered on I2C, and says
# nothing about whether the LEDs light.
#
# A list of pairs, NOT a hashtable. An [ordered]@{} indexed by an integer key returns
# the element at that POSITION, not the value for that key - so [4] threw and [1]
# silently returned the wrong fault name. A plain @{} would fix the lookup but leaves
# the report order undefined.
$VERDICT_FAULT_NAMES = @(
    @{ Bit = 0x0001L; Name = 'PIR' }
    @{ Bit = 0x0002L; Name = 'SPI flash' }
    @{ Bit = 0x0004L; Name = 'KTD I2C' }
    @{ Bit = 0x0100L; Name = 'OTAA join' }
)

function Test-VerdictWord {
    <# True when the word is a verdict rather than stale RAM or a mid-run read. #>
    param([uint32]$Word)
    # The signature is the only thing that makes a word a verdict. The pre-coded 1 and 2
    # are NOT accepted: that firmware is not going to production, so a board still
    # holding it must report a verdict timeout rather than a pass or a fault name. The
    # timeout path names 1 and 2 explicitly, so the operator is told to reflash.
    return ((($Word -band $VERDICT_SIGNATURE_MASK) -eq $VERDICT_SIGNATURE) -and
            (($Word -band $VERDICT_RESERVED_MASK) -eq 0))
}

function Get-VerdictDetail {
    <# Decode a verdict word into pass/fail plus the named faults. #>
    param([uint32]$Word)

    # Only ever called with a word Test-VerdictWord accepted, so the signature is
    # present and pass/fail is the fault bits alone.
    $bits = $Word -band $VERDICT_FAULT_MASK
    $faults = New-Object System.Collections.Generic.List[string]
    $named = 0L
    foreach ($f in $VERDICT_FAULT_NAMES) {
        $named = $named -bor $f.Bit
        if (($bits -band $f.Bit) -ne 0) { $faults.Add($f.Name) }
    }

    # A bit this script has no name for must never vanish into a silent pass. Report
    # it, so newer firmware against an older rig fails loudly instead of shipping.
    $unknown = $bits -band ($VERDICT_FAULT_MASK -bxor $named)
    if ($unknown -ne 0) { $faults.Add(('unknown fault bits 0x{0:X4}' -f $unknown)) }

    # A stage-1 fault means the join was never attempted, because main() gates it on
    # g_bHwDutPassed. Say so rather than letting the reader infer a join failure.
    $note = ''
    if (($bits -band 0x00FF) -ne 0) { $note = 'join not attempted (hardware failed first)' }

    return [pscustomobject]@{
        Passed = ($bits -eq 0)
        Faults = $faults.ToArray()
        Note   = $note
    }
}

function Read-Words {
    param([uint32]$Address, [int]$Count, [string]$Mode = 'HOTPLUG')
    $c = "port=SWD freq=$Freq mode=$Mode"
    if ($SerialNumber) { $c += " sn=$SerialNumber" }
    $out = & $CLI -c $c.Split(' ') -r32 ('0x{0:X8}' -f $Address) ($Count * 4)
    if ($LASTEXITCODE -ne 0) { throw "read at 0x{0:X8} failed (exit $LASTEXITCODE)" -f $Address }
    $w = New-Object System.Collections.Generic.List[uint32]
    foreach ($l in $out) {
        if ($l -match '^\s*0x[0-9A-Fa-f]+\s*:\s*(.+)$') {
            foreach ($t in ($Matches[1] -split '\s+')) {
                if ($t -match '^[0-9A-Fa-f]{8}$') { $w.Add([Convert]::ToUInt32($t, 16)) }
            }
        }
    }
    if ($w.Count -lt $Count) { throw ("expected $Count word(s) at 0x{0:X8}, parsed $($w.Count)" -f $Address) }
    return $w.ToArray()
}

# ---- per-station status reporting ------------------------------------------
# One file per station, owned by exactly one process. Mutable bits live in script
# scope so Write-Status can pick up the DevEUI and op-code once they are known.
$script:StartedUtc  = (Get-Date).ToUniversalTime()
$script:DevEui      = ''
$script:OpCode      = ''
$script:CurrentStep = 'START'
$script:Verdict     = ''    # raw verdict word as hex, once one has been read
$script:Faults      = @()   # decoded fault names for that word

function Write-Status {
    param(
        [Parameter(Mandatory = $true)][string]$Step,
        [string]$State = 'running',        # running | passed | failed | error
        [string]$Message = '',
        $ExitCode = $null
    )
    # Tracked even when no status file was asked for, so the catch block can report
    # which step actually threw instead of guessing.
    $script:CurrentStep = $Step
    if (-not $StatusFile) { return }
    $now = (Get-Date).ToUniversalTime()
    $o = [pscustomobject]@{
        station      = $Station
        opCode       = $script:OpCode
        serialNumber = $SerialNumber
        devEui       = $script:DevEui
        region       = $Region
        step         = $Step
        state        = $State
        message      = $Message
        exitCode     = $ExitCode
        verdict      = $script:Verdict
        faults       = @($script:Faults)
        pid          = $PID
        startedUtc   = $script:StartedUtc.ToString('o')
        updatedUtc   = $now.ToString('o')
        elapsedSec   = [int]($now - $script:StartedUtc).TotalSeconds
    }
    # Write-then-rename so a reader polling the file never parses a half-written one.
    # Best effort throughout: a status write must never be able to fail a flash.
    try {
        $tmp = "$StatusFile.tmp"
        [System.IO.File]::WriteAllText($tmp, ($o | ConvertTo-Json -Depth 3))
        Move-Item -LiteralPath $tmp -Destination $StatusFile -Force
    }
    catch { }
}

# Report the terminal state and exit with the code the caller keys off. Kept in one
# place so no exit path can leave the status file stuck on a 'running' step.
function Complete-Run {
    param(
        [Parameter(Mandatory = $true)][int]$Code,
        [Parameter(Mandatory = $true)][string]$Step,
        [Parameter(Mandatory = $true)][string]$State,
        [string]$Message = ''
    )
    Write-Status -Step $Step -State $State -Message $Message -ExitCode $Code
    exit $Code
}

try {
    $opCode = Get-StationOpCode -Station $Station     # station 1 -> 0x11, 2 -> 0x22, ...
    $script:OpCode = $opCode
    Write-Status -Step 'START' -Message 'resolving station and probe'
    # Checked here, ahead of the erase, so a missing image cannot leave a wiped device.
    # Skipped for -ReadDevEuiOnly: that path never flashes, so requiring an image would
    # stop the rig reading DevEUIs on any machine without a current build.
    if (-not $ReadDevEuiOnly) {
        if (-not $FirmwarePath) { $FirmwarePath = $FIRMWARE_IMAGE }
        if (-not (Test-Path $FirmwarePath)) { throw "firmware image not found: $FirmwarePath" }
    }

    # Probe: explicit serial wins, else this station's row in rig_devices.csv, else
    # leave sn= off and let the CLI use the only attached probe.
    if (-not $SerialNumber) {
        $list = Join-Path $PSScriptRoot 'rig_devices.csv'
        if (Test-Path $list) {
            $row = @(Import-Csv $list | Where-Object { $_.Position -and [int]$_.Position -eq $Station })
            if ($row.Count -eq 1) { $SerialNumber = $row[0].SerialNumber }
        }
    }
    $connect = "port=SWD freq=$Freq mode=UR"
    if ($SerialNumber) { $connect += " sn=$SerialNumber" }

    "Station $Station  opcode $opCode  region $Region  freq $Freq"
    if ($SerialNumber) { "ST-LINK $SerialNumber" }

    # ---- 1. DevEUI, before anything is erased --------------------------------
    # Mirrors GetUniqueId() in common/board/src/sys_app.c. Not stored on the factory
    # page - it comes from the chip UID - so the rig must read it off the device.
    Write-Status -Step 'DEVEUI' -Message 'reading chip UID'
    $u = Read-Words -Address $UID64 -Count 2
    $udn = $u[0]
    $id = New-Object byte[] 8
    if ($udn -eq [uint32]::MaxValue) {
        $u96 = Read-Words -Address 0x1FFF7590 -Count 3
        $a = [uint32](([uint64]$u96[0] + [uint64]$u96[2]) -band 0xFFFFFFFFL); $b = $u96[1]
        $id[7]=($a -shr 24) -band 0xFF; $id[6]=($a -shr 16) -band 0xFF
        $id[5]=($a -shr 8) -band 0xFF;  $id[4]=$a -band 0xFF
        $id[3]=($b -shr 24) -band 0xFF; $id[2]=($b -shr 16) -band 0xFF
        $id[1]=($b -shr 8) -band 0xFF;  $id[0]=$b -band 0xFF
    }
    else {
        $cid = ($u[1] -shr 8) -band 0xFFFFFF
        $id[0]=($cid -shr 16) -band 0xFF; $id[1]=($cid -shr 8) -band 0xFF; $id[2]=$cid -band 0xFF
        $id[3]=$u[1] -band 0xFF
        $id[4]=($udn -shr 24) -band 0xFF; $id[5]=($udn -shr 16) -band 0xFF
        $id[6]=($udn -shr 8) -band 0xFF;  $id[7]=$udn -band 0xFF
    }
    $devEui = (($id | ForEach-Object { '{0:X2}' -f $_ }) -join '')
    $script:DevEui = $devEui
    "DevEUI: $devEui"

    # Pre-flash query only: nothing has been erased yet, so this is safe to call at any
    # time, including on a device you do not intend to reflash.
    if ($ReadDevEuiOnly) { Complete-Run -Code 0 -Step 'DEVEUI' -State 'passed' -Message "DevEUI $devEui" }

    # ---- 2. erase -----------------------------------------------------------
    Write-Status -Step 'ERASE' -Message 'mass erase'
    & $CLI -c $connect.Split(' ') -e all *> $null
    if ($LASTEXITCODE -ne 0) {
        "ERASE FAILED ($LASTEXITCODE)"
        Complete-Run -Code 2 -Step 'ERASE' -State 'error' -Message "mass erase failed (CLI exit $LASTEXITCODE)"
    }
    "ERASE OK"

    # ---- 3. op-code + keys + region -----------------------------------------
    # AppKey and JoinEUI are stored BYTE-REVERSED: keys_update.c reads them back as
    # ptr[15-i] / ptr[7-i], so natural order yields a device that provisions cleanly
    # and then silently never joins. Region goes at offset 0x30 (0x0803F830), the
    # address keys_update.h defines and the firmware actually reads - NOT 0x0803F840.
    Write-Status -Step 'KEYS' -Message "writing op-code $opCode, AppKey, JoinEUI, region $Region"
    $page = New-Object byte[] 0x38
    for ($i = 0; $i -lt $page.Length; $i++) { $page[$i] = 0xFF }

    $op = [Convert]::ToInt32($opCode, 16)
    $page[0]=$op -band 0xFF; $page[1]=($op -shr 8) -band 0xFF
    $page[2]=($op -shr 16) -band 0xFF; $page[3]=($op -shr 24) -band 0xFF

    $k = New-Object byte[] 16
    for ($i = 0; $i -lt 16; $i++) { $k[$i] = [Convert]::ToByte($AppKey.Substring($i*2,2),16) }
    [Array]::Reverse($k); [Array]::Copy($k, 0, $page, 0x10, 16)

    $e = New-Object byte[] 8
    for ($i = 0; $i -lt 8; $i++) { $e[$i] = [Convert]::ToByte($JoinEui.Substring($i*2,2),16) }
    [Array]::Reverse($e); [Array]::Copy($e, 0, $page, 0x20, 8)

    $page[0x30] = [byte]$REGION_IDS[$Region]    # zero-extended to a LE word, matching
    $page[0x31] = 0; $page[0x32] = 0; $page[0x33] = 0   # already-provisioned devices

    $pageBin = Join-Path ([System.IO.Path]::GetTempPath()) "fso_page_$([guid]::NewGuid().ToString('N')).bin"
    [System.IO.File]::WriteAllBytes($pageBin, $page)
    & $CLI -c $connect.Split(' ') -d $pageBin ('0x{0:X8}' -f $FACTORY_PAGE) -v *> $null
    $keysCode = $LASTEXITCODE
    Remove-Item $pageBin -Force
    if ($keysCode -ne 0) {
        "KEYS FAILED ($keysCode)"
        Complete-Run -Code 3 -Step 'KEYS' -State 'error' -Message "factory page write failed (CLI exit $keysCode)"
    }
    "KEYS OK"

    # ---- 4. firmware --------------------------------------------------------
    # Last, with -hardRst, so the device boots into the DUT with keys already in place.
    # BFU_FSO.bin ends well below 0x0803F800 and cannot disturb what we just wrote.
    Write-Status -Step 'FLASH' -Message 'writing firmware image'
    & $CLI -c $connect.Split(' ') -d $FirmwarePath 0x08000000 -v -hardRst *> $null
    if ($LASTEXITCODE -ne 0) {
        "FLASH FAILED ($LASTEXITCODE)"
        Complete-Run -Code 4 -Step 'FLASH' -State 'error' -Message "firmware write failed (CLI exit $LASTEXITCODE)"
    }
    "FLASH OK"

    # The device is now running the new firmware and reporting its own status via the
    # LED and the verdict word at 0x20003400. Flashing is done; stop here unless the
    # caller explicitly asked us to wait for the DUT result.
    if (-not $ReadVerdict) {
        Complete-Run -Code 0 -Step 'FLASH' -State 'passed' -Message 'flashed and rebooted; DUT verdict not polled by this process'
    }

    # ---- 5. verdict (opt-in) ------------------------------------------------
    # HOTPLUG only: any reset runs SBSFU, whose .data starts at exactly 0x20003400,
    # so it would overwrite the verdict before the app ever gets to write it.
    # Only a word Test-VerdictWord accepts ends the wait - a signed 0xD5?????? code.
    # 0x00000000 means the DUT is still running, and 0x00005776 (FLOW_CTRL_INIT_VALUE)
    # means SBSFU has not handed over yet.
    Write-Status -Step 'WAIT_VERDICT' -Message 'device running DUT; polling verdict word'
    $deadline = (Get-Date).AddSeconds($VerdictTimeoutSec)
    $verdict = $null
    $last = $null
    while ((Get-Date) -lt $deadline) {
        try {
            $v = (Read-Words -Address $VERDICT_ADDR -Count 1)[0]
            $last = $v
            if (Test-VerdictWord -Word $v) { $verdict = $v; break }
        }
        catch { }   # a refused connect right after the reset is expected
        # Refresh on every poll so the UI can show this station is alive and how long it
        # has been waiting, rather than a step that looks frozen for up to VerdictTimeoutSec.
        $seenNow = 'no successful read yet'
        if ($null -ne $last) { $seenNow = 'last read 0x{0:X8}' -f $last }
        Write-Status -Step 'WAIT_VERDICT' -Message "DUT running; $seenNow"
        Start-Sleep -Seconds 3
    }

    if ($null -eq $verdict) {
        $seen = 'no successful read'
        if ($null -ne $last) { $seen = '0x{0:X8}' -f $last }
        "VERDICT TIMEOUT after ${VerdictTimeoutSec}s (last read $seen)"
        # 1 and 2 are the pre-coded pass/fail values. They are no longer accepted as a
        # verdict, so name them here: the device booted and finished its DUT, but the
        # image on it predates the coded scheme and has to be replaced.
        if ($last -eq 1 -or $last -eq 2) {
            "  that is a pre-coded verdict, which this rig no longer accepts - reflash with a"
            "  build that writes the 0xD5 coded word, then bless again"
        }
        Complete-Run -Code 5 -Step 'WAIT_VERDICT' -State 'error' `
            -Message "no verdict within ${VerdictTimeoutSec}s (last read $seen)"
    }
    $hex = '0x{0:X8}' -f $verdict
    $detail = Get-VerdictDetail -Word $verdict
    $script:Verdict = $hex
    $script:Faults  = $detail.Faults

    if ($detail.Passed) {
        "VERDICT PASS  verdict=$hex"
        Complete-Run -Code 0 -Step 'DONE' -State 'passed' -Message "DUT PASS ($hex)"
    }

    $what = 'no fault detail'
    if ($detail.Faults.Count -gt 0) { $what = ($detail.Faults -join ', ') }
    "VERDICT FAIL  verdict=$hex"
    "  failed: $what"
    if ($detail.Note) { "  $($detail.Note)" }
    if ($detail.Faults -contains 'OTAA join') {
        "  a mass erase forces a fresh join, so a gateway must be reachable and the"
        "  AppKey/JoinEUI must already be registered against this DevEUI."
    }
    Complete-Run -Code 6 -Step 'DONE' -State 'failed' -Message "DUT FAIL ($hex): $what"
}
catch {
    "SETUP FAILED: $($_.Exception.Message)"
    Complete-Run -Code 1 -Step $script:CurrentStep -State 'error' -Message $_.Exception.Message
}
