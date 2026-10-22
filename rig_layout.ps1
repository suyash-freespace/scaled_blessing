<#
    Canonical rig layout - dot-sourced by every rig script so there is exactly ONE
    definition of station -> op-code, and ONE of which DUT verdict word each product
    writes (see the end of this file).

    The op-code's LOW nibble IS the physical rig station, and the frequency plan in
    the high nibble deliberately cycles 1,2,3,1,2,3 across the six stations.

    Do NOT reassign op-codes to put several stations on a common frequency plan.
    The low nibble also sets the join stagger, ((station - 1) * 2000 ms), which is
    what keeps six simultaneous OTAA joins from colliding - so changing it to tidy
    up the plan spread silently breaks the thing the stagger exists for.

        station 1 -> 0x11   plan 1   stagger     0 ms
        station 2 -> 0x22   plan 2   stagger  2000 ms
        station 3 -> 0x33   plan 3   stagger  4000 ms
        station 4 -> 0x14   plan 1   stagger  6000 ms
        station 5 -> 0x25   plan 2   stagger  8000 ms
        station 6 -> 0x36   plan 3   stagger 10000 ms

    Source of truth in firmware: the op-code comparisons in products/fso/main.c,
    products/fso/app/device_dut.c and products/fso/lora/lora_app.c, plus
    freq_code = (op_code >> 4) & 0x0F and delay = ((op_code & 0x0F) - 1) * 2000.
#>

$OPCODE_BY_STATION = @{
    1 = '0x11'
    2 = '0x22'
    3 = '0x33'
    4 = '0x14'
    5 = '0x25'
    6 = '0x36'
}

$VALID_STATIONS = 1..6

# Every op-code the firmware recognises, derived from the map so the two can't drift.
$VALID_OPCODES = @($VALID_STATIONS | ForEach-Object { $OPCODE_BY_STATION[$_] })

function Get-StationOpCode {
    param([Parameter(Mandatory = $true)][int]$Station)
    if (-not $OPCODE_BY_STATION.ContainsKey($Station)) {
        throw "Station $Station is out of range - valid stations are $($VALID_STATIONS -join ', ')."
    }
    return $OPCODE_BY_STATION[$Station]
}

function Get-OpCodeFacts {
    <# Decode an op-code into the station/plan/stagger it implies, for display. #>
    param([Parameter(Mandatory = $true)][string]$OpCode)
    $v = [Convert]::ToInt32($OpCode, 16)
    return [pscustomobject]@{
        OpCode    = $OpCode
        FreqPlan  = ($v -shr 4) -band 0x0F
        Station   = $v -band 0x0F
        StaggerMs = (($v -band 0x0F) - 1) * 2000
    }
}

function Resolve-StationProbe {
    <#
      Map a station number to its ST-LINK serial using the rig device list, which is
      the one file describing which probe sits in which physical slot.
    #>
    param(
        [Parameter(Mandatory = $true)][int]$Station,
        [Parameter(Mandatory = $true)][string]$DeviceListPath
    )

    if (-not (Test-Path $DeviceListPath)) {
        throw ("Station $Station needs a device list to find its probe, but '$DeviceListPath' does not exist.`n" +
               "Either create it (copy rig_devices.example.csv and fill in the ST-LINK serials) or pass -SerialNumber explicitly.")
    }

    $rows = @(Import-Csv -Path $DeviceListPath)
    $cols = @()
    if ($rows.Count -gt 0) { $cols = $rows[0].PSObject.Properties.Name }
    foreach ($required in @('Position', 'SerialNumber')) {
        if ($cols -notcontains $required) {
            throw "Device list '$DeviceListPath' needs a '$required' column (found: $($cols -join ', '))."
        }
    }

    $match = @($rows | Where-Object { $_.Position -and ([int]$_.Position) -eq $Station })
    if ($match.Count -eq 0) {
        throw "Device list '$DeviceListPath' has no row for station $Station. Add one, or pass -SerialNumber explicitly."
    }
    if ($match.Count -gt 1) {
        throw "Device list '$DeviceListPath' has $($match.Count) rows for station $Station - it must be unique."
    }
    if (-not $match[0].SerialNumber) {
        throw "Station $Station in '$DeviceListPath' has an empty SerialNumber."
    }

    return $match[0].SerialNumber
}

# ---- DUT verdict word ------------------------------------------------------
# Shared by flash_device.ps1, which polls and decodes the word, and bless_rig.ps1, which
# decides from the logged word whether a station may be secured. Kept here so the two can
# never disagree about which word is a verdict, or which product wrote it.
#
# Layout, mirroring products/fso/app/device_dut.h and products/tim/app/device_dut.h:
#
#     31    24 | 23    16 | 15     8 | 7      0
#       0xD5   | product  |  stage 2 |  stage 1
#     signature  / MLX       faults     faults
#
# Byte 2 names the product. FSO always writes 0x00, because it has no MLX check. TIM
# writes its MLX status there and never 0x00: an ID from $VERDICT_MLX_IDS when a sensor
# answered, or 0x01 when none did (and then fault bit 3 is set as well).
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
$VERDICT_MLX_MASK       = 0x00FF0000L   # byte 2: 0x00 on FSO, the MLX status on TIM
$VERDICT_FAULT_MASK     = 0x0000FFFFL
$VERDICT_FAULT_MLX      = 0x0008L       # TIM bit 3: no MLX sensor answered
$VERDICT_MLX_NONE       = 0x01          # TIM byte 2: no MLX sensor answered

# TIM byte 2 -> the MLX variant that answered (DUT_MLX_ID_* in products/tim/app/device_dut.h).
# A new sensor is one line here, and both scripts then accept it.
$VERDICT_MLX_IDS = @{
    0x40 = 'MLX90640'
    0x42 = 'MLX90642'
}

function Get-VerdictMlxId {
    <# Byte 2 of a verdict word. #>
    param([uint32]$Word)
    # [int] on purpose: the shift yields an Int64, and a hashtable does not match an
    # Int64 64 against the Int32 64 that keys $VERDICT_MLX_IDS.
    return [int](($Word -band $VERDICT_MLX_MASK) -shr 16)
}

function Get-VerdictProduct {
    <# 'FSO' or 'TIM' for a signed verdict word, $null for anything else. #>
    param([uint32]$Word)
    if (($Word -band $VERDICT_SIGNATURE_MASK) -ne $VERDICT_SIGNATURE) { return $null }
    # Byte 2 alone names the product. On TIM it must also agree with bit 3: NONE always
    # comes with bit 3 set, and a sensor ID never does. TIM firmware writes nothing else,
    # so any other pairing is stale RAM rather than a verdict.
    $id    = Get-VerdictMlxId -Word $Word
    $noMlx = (($Word -band $VERDICT_FAULT_MLX) -ne 0)
    if ($id -eq 0x00) { return 'FSO' }
    if ($id -eq $VERDICT_MLX_NONE -and $noMlx) { return 'TIM' }
    if ($VERDICT_MLX_IDS.ContainsKey($id) -and -not $noMlx) { return 'TIM' }
    return $null
}

function Get-VerdictMlx {
    <# TIM only: the MLX variant named in byte 2, or 'none'. '' for any other word. #>
    param([uint32]$Word)
    if ((Get-VerdictProduct -Word $Word) -ne 'TIM') { return '' }
    $id = Get-VerdictMlxId -Word $Word
    if ($VERDICT_MLX_IDS.ContainsKey($id)) { return $VERDICT_MLX_IDS[$id] }
    return 'none'
}
