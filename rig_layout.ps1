<#
    Canonical FSO rig layout - dot-sourced by flash_device.ps1 and bless_rig.ps1 so
    there is exactly ONE definition of station -> op-code.

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
