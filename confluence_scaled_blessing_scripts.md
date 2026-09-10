# Scaled Blessing — Script Reference

| Property | Value |
|----------|-------|
| **Product** | FSO (Field Sensing & Occupancy) |
| **Scope** | Scripts only. Rig hardware, firmware internals and LNS setup are out of scope. |
| **Location** | `C:\Freespace_Projects\Gen4\ScaledBlessing` |
| **Status** | In use |
| **Last updated** | 2026-09-09 |

---

## 1. What the scripts do

"Blessing" is the factory provisioning step. It turns a bare board into a device the LNS
accepts. The scripts in this folder do that work for up to six devices at once.

One blessing performs four device operations, in this order:

1. Read the DevEUI from the chip UID. Nothing is written in this step.
2. Mass erase the internal flash.
3. Write the factory page: op-code, AppKey, JoinEUI, region.
4. Flash the merged SBSFU and application image, then hard reset into it.

The device then runs its own DUT self-test and publishes a verdict word in RAM. The
scripts can poll that word, but they do not have to. Polling is opt-in through
`-ReadVerdict`.

Each station runs in its own `powershell.exe` process. Each process is bound to one
ST-LINK probe by serial number. One station cannot stall, fail or crash another.

---

## 2. Files

| File | Role |
|------|------|
| `rig_layout.ps1` | Station to op-code map plus helpers. Dot-sourced by the other scripts. |
| `flash_device.ps1` | Per-device primitive. One probe, one device, start to finish. |
| `bless_rig.ps1` | Fan-out and monitor. One child process per selected station. |
| `scan_device.ps1` | Read-only bench scan. Reports each device's DevEUI. |
| `bless.bat` | Operator wrapper for `bless_rig.ps1`, for `cmd.exe`. |
| `scan.bat` | Operator wrapper for `scan_device.ps1`, for `cmd.exe`. |
| `rig_devices.csv` | This bench's `Position,SerialNumber` probe map. Not portable. |
| `rig_devices.example.csv` | Template for all six stations. Commit this one. |

### Call chain

```
bless.bat  --> bless_rig.ps1 --> flash_device.ps1   (one process per station)
scan.bat   --> scan_device.ps1                      (in process, no child spawn)

rig_layout.ps1 is dot-sourced by bless_rig.ps1, flash_device.ps1 and scan_device.ps1
  (station -> op-code, one definition)
```

`flash_device.ps1` is the only script that talks to `STM32_Programmer_CLI.exe`.

---

## 3. Prerequisites

- **STM32CubeProgrammer CLI** at
  `C:\Program Files\STMicroelectronics\STM32Cube\STM32CubeProgrammer\bin\STM32_Programmer_CLI.exe`.
  The path is set in `flash_device.ps1` and again in `scan_device.ps1` as the
  `-ProgrammerCli` default. Keep the two in step.
- **Firmware image** at
  `C:\Freespace_Projects\Gen4\fs-lorawan-gen4-monorepo\products\fso\ide\Binary\BFU_FSO.bin`.
  Override it per run with `-FirmwarePath`.
- **Execution policy.** The children are launched with `-ExecutionPolicy Bypass`. The
  parent needs the same. Use `powershell -NoProfile -ExecutionPolicy Bypass -File ...`,
  or run the `.bat` wrappers, which already do this.
- **`rig_devices.csv` populated** with this bench's probe serials.

---

## 4. `rig_layout.ps1` — the shared layout

This file is dot-sourced by `flash_device.ps1`, `bless_rig.ps1` and `scan_device.ps1`. It is
the single definition of the station to op-code map.

| Station | Op-code | Frequency plan | Join stagger |
|---------|---------|----------------|--------------|
| 1 | `0x11` | 1 | 0 ms |
| 2 | `0x22` | 2 | 2000 ms |
| 3 | `0x33` | 3 | 4000 ms |
| 4 | `0x14` | 1 | 6000 ms |
| 5 | `0x25` | 2 | 8000 ms |
| 6 | `0x36` | 3 | 10000 ms |

The low nibble of the op-code is the physical station. The high nibble is the frequency
plan. The firmware derives both from the same byte:

```
freq_code = (op_code >> 4) & 0x0F
delay_ms  = ((op_code & 0x0F) - 1) * 2000
```

Do not reassign op-codes. The low nibble also sets the join stagger. The stagger is what
stops six simultaneous OTAA joins from colliding. Stations 1/4, 2/5 and 3/6 share a
frequency plan on purpose.

### Exports

| Name | Type | Purpose |
|------|------|---------|
| `$OPCODE_BY_STATION` | hashtable | Station number to op-code string. |
| `$VALID_STATIONS` | `1..6` | Accepted station numbers. |
| `$VALID_OPCODES` | array | Derived from the map, so the two cannot drift. |
| `Get-StationOpCode -Station <n>` | function | Op-code for a station. Throws when out of range. |
| `Get-OpCodeFacts -OpCode <hex>` | function | Decodes an op-code into station, plan and stagger. |
| `Resolve-StationProbe -Station <n> -DeviceListPath <path>` | function | Station to ST-LINK serial, from the device list. |

---

## 5. `rig_devices.csv` — the probe map

```csv
Position,SerialNumber
1,001900393234510733353533
2,005100303233510A39363634
3,0050002A3234510836303532
4,003F00253234510733353533
```

| Column | Required | Meaning |
|--------|----------|---------|
| `Position` | Yes, or `OpCode` instead | Physical station, 1 to 6. Preferred. |
| `SerialNumber` | Yes | ST-LINK probe serial. |
| `OpCode` | No | Explicit override. Must match the station's canonical op-code. |
| `AppKey` | No | Per-device AppKey, 32 hex characters. |
| `JoinEui` | No | Per-device JoinEUI, 16 hex characters. |
| `Region` | No | Per-device region name. |

Prefer `Position`. It pins the op-code to the canonical layout, so an operator cannot pair
a station with the wrong frequency plan or stagger slot.

Get probe serials with `STM32_Programmer_CLI.exe -c port=SWD mode=HOTPLUG`. That output is
reliable. `-l` can garble serials on this host. `scan_device.ps1` also prints any attached
probe the CSV does not list, with state `not listed`.

---

## 6. `flash_device.ps1` — one device

The per-device primitive. It owns its probe for the whole run. Nothing else connects to
that ST-LINK while the station is blessing.

### Parameters

| Parameter | Default | Purpose |
|-----------|---------|---------|
| `-Station` | `1` | Rig station 1 to 6. Sets the op-code. Also resolves the probe from `rig_devices.csv`. |
| `-AppKey` | `2B7E151628AED2A6ABF7158809CF4F3C` | 32 hex characters, MSB first, as the LNS shows it. |
| `-JoinEui` | `0E0D0D010E01020E` | 16 hex characters, MSB first. |
| `-Region` | `US915` | One of the ten supported region names. |
| `-SerialNumber` | from the CSV | Explicit probe serial. Wins over the device list. |
| `-FirmwarePath` | `BFU_FSO.bin` | Image flashed to `0x08000000`. |
| `-Freq` | `24000` | SWD clock in kHz. |
| `-ReadVerdict` | off | Poll the DUT verdict word and report pass or fail. |
| `-VerdictTimeoutSec` | `180` | Verdict poll budget. |
| `-ReadDevEuiOnly` | off | Read the DevEUI and exit. Nothing is erased or written. |
| `-StatusFile` | none | Write machine-readable progress to this path. |

The defaults for `-AppKey` and `-JoinEui` are shared bring-up values. They are for bench
work only. A production blessing must pass unique key material.

RDP is left at level 0.

### Sequence

| Step | Action | Failure exit code |
|------|--------|-------------------|
| `START` | Resolve station, op-code, probe and firmware path. | 1 |
| `DEVEUI` | Read the chip UID and compute the DevEUI. | 1 |
| `ERASE` | `-e all`, connect mode `UR`. | 2 |
| `KEYS` | Write the 56-byte factory page at `0x0803F800`, verified. | 3 |
| `FLASH` | Write the image at `0x08000000`, verified, with `-hardRst`. | 4 |
| `WAIT_VERDICT` | Poll `0x20003400` every 3 s, connect mode `HOTPLUG`. Opt-in. | 5 |
| `DONE` | Decode the verdict word. | 6 on a DUT fail |

The firmware image is checked for existence before the erase. A missing image can then
never leave a wiped device. That check is skipped under `-ReadDevEuiOnly`, because that
path never flashes.

The DevEUI is read before the erase. This catches a dead or absent probe early. It also
gives the service the DevEUI it needs for LNS registration.

The probe is resolved in three steps. An explicit `-SerialNumber` wins. Otherwise the
script reads this station's row from `rig_devices.csv`. Otherwise it leaves `sn=` off and
lets the CLI use the only attached probe.

### DevEUI derivation

The DevEUI comes from the chip UID, not from the factory page. The script mirrors
`GetUniqueId()` in `common/board/src/sys_app.c`.

- Primary source is the 64-bit UID at `0x1FFF7580`.
- When the UDN word reads `0xFFFFFFFF`, the script falls back to the 96-bit UID at
  `0x1FFF7590` and folds it the way the firmware does.

This byte order now exists twice: here, and in `scan_device.ps1`, which reads the UID in
process to avoid a child spawn per station. Change one and you must change the other. A
wrong order produces a plausible-looking wrong DevEUI and no error.

### Factory page layout

56 bytes (`0x38`), filled with `0xFF`, written to `0x0803F800`.

| Offset | Size | Content |
|--------|------|---------|
| `0x00` | 4 | Op-code, little-endian word. |
| `0x10` | 16 | AppKey, byte-reversed. |
| `0x20` | 8 | JoinEUI, byte-reversed. |
| `0x30` | 4 | Region ID byte, then three zero bytes. |

AppKey and JoinEUI are stored byte-reversed on purpose. `keys_update.c` reads them back as
`ptr[15-i]` and `ptr[7-i]`. Natural order gives a device that provisions cleanly and then
never joins.

The region goes at offset `0x30`, which is address `0x0803F830`. That is the address
`keys_update.h` defines and the firmware reads. It is not `0x0803F840`.

### Region IDs

| Name | ID | Name | ID |
|------|----|------|----|
| `AS923` | 0 | `KR920` | 6 |
| `AU915` | 1 | `IN865` | 7 |
| `CN470` | 2 | `US915` | 8 |
| `CN779` | 3 | `RU864` | 9 |
| `EU433` | 4 | | |
| `EU868` | 5 | | |

### Verdict word at `0x20003400`

```
 31    24 | 23    16 | 15     8 | 7      0
   0xD5   |   0x00   |  stage 2 |  stage 1
signature   reserved   faults     faults
```

A word counts as a verdict only when the signature byte is `0xD5` and the reserved byte is
zero. Pass or fail is then the fault bits alone. Zero faults means pass.

| Bit | Fault name |
|-----|------------|
| `0x0001` | PIR |
| `0x0002` | SPI flash |
| `0x0004` | KTD I2C |
| `0x0100` | OTAA join |

The name is "KTD I2C" and not "LED" on purpose. A clear bit only proves the KTD2026
answered on I2C. It says nothing about whether the LEDs light.

Any fault bit the script has no name for is reported as `unknown fault bits 0xNNNN`. Newer
firmware on an older rig therefore fails loudly instead of shipping.

A stage-1 fault means the join was never attempted. `main()` gates the join on
`g_bHwDutPassed`. The script reports that note with the fault list.

Values that are not a verdict:

| Value | Meaning |
|-------|---------|
| `0x00000000` | The DUT is still running. |
| `0x00005776` | SBSFU's `uFlowCryptoValue`. SBSFU has not handed over yet. |
| `1` or `2` | Pre-coded pass or fail from an old build. Rejected. |

`1` and `2` are no longer accepted as verdicts. That firmware is not going to production. A
board still holding it reports a verdict timeout. The timeout message names the value and
tells the operator to reflash.

The verdict poll uses connect mode `HOTPLUG` only. Any reset runs SBSFU, whose `.data`
section starts at exactly `0x20003400`. A reset would overwrite the verdict before the
application writes it.

### Exit codes

| Code | Meaning |
|------|---------|
| 0 | Flashed and rebooted. With `-ReadVerdict`, the DUT also passed. |
| 1 | Setup error. Bad station, missing image, or a probe read failure. |
| 2 | Mass erase failed. |
| 3 | Factory page write failed. |
| 4 | Firmware write failed. |
| 5 | Verdict timeout. `-ReadVerdict` only. |
| 6 | The DUT reported FAIL. `-ReadVerdict` only. |

---

## 7. `bless_rig.ps1` — the whole rig

A fan-out wrapper around `flash_device.ps1`. Each selected station gets its own process,
its own log file, its own status file and its own exit code.

Running N processes is the entire isolation mechanism. `flash_device.ps1` is stateless and
uses GUID temp filenames. Nothing is shared between concurrent runs except the firmware
image, which is read-only.

### Parameters

| Parameter | Default | Purpose |
|-----------|---------|---------|
| `-DeviceList` | required | CSV describing the rig. |
| `-Stations` | all rows | Stations to run, comma-separated. |
| `-Region` | none | One region for the whole run. Overrides the CSV column. |
| `-Keys` | none | Per-station key material. See below. |
| `-ReadVerdict` | off | Wait for each DUT verdict and report it. |
| `-FirmwarePath` | script default | Image for every station. |
| `-LogDir` | `%TEMP%\fso_rig\<timestamp>` | Per-station stdout and stderr. |
| `-KeepLogs` | off | Keep the run directory instead of deleting it. |
| `-StatusDir` | `<LogDir>\status` | Where the `station<N>.json` files land. |
| `-NoWait` | off | Launch and return immediately. Implies `-KeepLogs`. |
| `-Freq` | `24000` | SWD clock in kHz. |
| `-VerdictTimeoutSec` | `180` | Passed to each child. |
| `-OverallTimeoutSec` | `600` | Cap on the whole monitored run. |
| `-FullSummary` | off | Print the full summary table instead of two columns. |
| `-Json` | off | Print one JSON document and nothing else. |
| `-DryRun` | off | Print the launch plan. Touch no hardware. |

`-Stations` and `-Keys` are typed `[string[]]`, not `[int[]]`. Under
`powershell.exe -File` every argument arrives as a string, and `"1,3"` coerced to `[int]`
becomes `13`. Both parameters are parsed by hand.

Pass stations comma-separated. Do not space-separate them. Under `-File`, a space-separated
`3` binds positionally to the next parameter, and the error message then names `-Region`.

### Device list validation

Validation runs against the whole list, not just the selected rows. A config error anywhere
is worth catching. All of these are refused with exit 1, before any device is touched:

- Missing `SerialNumber` column.
- Neither a `Position` column nor an `OpCode` column.
- A `Position` outside 1 to 6.
- An explicit `OpCode` that disagrees with its `Position`.
- A row with an empty `SerialNumber`.
- A row with neither a `Position` nor an `OpCode`.
- An `OpCode` outside the canonical set.
- A duplicate `SerialNumber`. Two processes would fight over one probe.
- A duplicate `OpCode`. Two devices would share a join-stagger slot.
- A requested station with no row in the list.

### `-Keys` format

```
-Keys "2=<32 hex appKey>:<16 hex joinEui>,3=<32 hex appKey>:<16 hex joinEui>"
```

Pass both values in the natural order the LNS shows. `flash_device.ps1` reverses the bytes
when it writes them.

Key allocation is validated before anything is erased. A station that failed validation
mid-run would already have lost its keys and its NVM. These are refused with exit 1:

- A malformed entry.
- A station outside 1 to 6.
- The same station given twice.
- Keys for a station that is not in this run.
- The same AppKey on two stations.
- The same JoinEUI on two stations.

Keys for a station outside the run are an error, not a warning. The caller's station list
and its key allocation disagree. The likeliest explanation is that some other station is
about to get the wrong keys.

A selected station with no keys is a warning. The script says that the station will be
blessed with the shared bring-up AppKey.

The launch table shows a `Keys` column, `unique` or `default`. An operator can then see at
a glance that every station got its own key material.

### Precedence

Lowest to highest:

1. `flash_device.ps1` bring-up defaults.
2. The device list column, per station.
3. `-Region`, for the whole run.
4. `-Keys`, per station.

Each option is resolved to one value before the child arguments are built. Appending as it
went would emit `-Region X -Region Y`, and PowerShell rejects a parameter given twice.

### Two ways to consume a run

**Default, blocking.** The script prints each station's step transitions live, then a
summary table. The run directory goes to `%TEMP%` and is deleted on the way out. The
terminal is the whole output.

**`-NoWait`, service mode.** The script launches the children and returns. The children
outlive it. The blessing service then polls `-StatusDir` and pushes each station's state to
the front-end on its own timeline. No cleanup happens in this mode, because killing the
children is exactly what must not happen.

### Dry run

`-DryRun` validates the list and prints the exact command line for each station. No
hardware is touched. Do this before a six-device run, because every launch mass-erases its
device.

The AppKey is masked in the printed command line as `<32 hex, masked>`. A dry run exists to
check the launch plan, not the key bytes, so its output is safe to paste into a ticket.

### Launch details

`Start-Process` is used, not `Start-Job`. That gives real separate processes, per-device
output redirection and a trustworthy exit code.

Each status file is seeded before its child starts. If a child dies before writing one, the
UI still shows that station as launching and then stale, rather than showing no row.

`$p.Process.Handle` is read immediately after launch. That is what makes `.ExitCode`
readable later. Without it, .NET releases the handle when the process ends, and the exit
code comes back empty. `WaitForExit()` alone does not fix this.

### Monitor

The monitor polls every status file every 2 seconds. It prints a line only when a station
changes step or state. A three-minute verdict wait therefore does not bury the other
stations' transitions.

The loop reads the status files, not the children's stdout. This keeps it immune to
redirection buffering. A file caught mid-write costs one skipped poll.

When `-OverallTimeoutSec` expires, any process still running is killed. The script then
stamps that station's status file with state `error`. A killed child cannot write its own
terminal state, so the UI would otherwise show that station mid-step forever.

### Summary

The summary prefers the structured status file. It falls back to scraping the child log for
the DevEUI, the verdict and the fault list. A run made without status files still reports.

Result classification prefers the exit code. When there is no exit code but a verdict was
logged, the verdict is decoded the way `flash_device.ps1` decodes it. A process bookkeeping
problem can therefore never misreport a device that actually passed.

Exit codes are mapped to result text as follows: 0 `PASS`, 1 `setup error`, 2
`erase failed`, 3 `keys write failed`, 4 `flash failed`, 5 `verdict timeout`, 6 `DUT FAIL`.

Default output is two columns, Station and Verdict. A station with no verdict word shows
its result text instead, so the column always says something. `-FullSummary` prints serial,
op-code, DevEUI, verdict, faults, exit code and result text.

### Run directory cleanup

The run directory is kept when any of these is true:

- `-KeepLogs` was passed.
- `-LogDir` or `-StatusDir` was passed explicitly.
- `-NoWait` was passed.

Otherwise the directory is deleted after the summary is built. The `%TEMP%\fso_rig` parent
is removed too, once it is empty. A cleanup failure never fails a run.

The log and status files are not optional machinery. `Start-Process` can only redirect a
child's output to a real file, and the monitor works by reading the status files. A run
always writes them. `-KeepLogs` only decides whether they survive.

The child log is the only place the `STM32_Programmer_CLI` error text survives. Re-run with
`-KeepLogs` to diagnose a failure.

### Exit codes

| Code | Meaning |
|------|---------|
| 0 | Every device passed. With `-NoWait`, every process launched. |
| 1 | Setup or validation error. Nothing was flashed. |
| 2 | At least one device did not pass. |

`-DryRun` also exits 0. Do not read a 0 as "devices passed" without checking whether the
run was a dry run.

---

## 8. `scan_device.ps1` — read-only bench scan

Answers one question. Which devices are on the bench, and what is each one's DevEUI?

Nothing here writes to a device. It only reads the chip UID, so a scan is safe at any
time, including on an already blessed device.

Run it before a blessing. It collects the DevEUIs the LNS needs. It also confirms that
every station is populated and that its probe is alive.

### Steps

1. Ask `STM32_Programmer_CLI -l` which probes are attached.
2. Map each probe serial to its station using `rig_devices.csv`.
3. Read each device's chip UID with `STM32_Programmer_CLI -r32` and derive its DevEUI.

Step 3 runs in this process. No child is spawned, and a failed read is caught rather than
ending the scan.

This is the whole reason the script exists. Measured on the rig, it removes about
**1120 ms per station**: one `powershell.exe` start, plus the parse of the 21 KB
`flash_device.ps1`, plus its `rig_layout.ps1` dot-source, its two `Write-Status` calls
and the capture of its stdout. All of that wrapped a single CLI call the parent can make
itself.

A one-station scan, same probe and same board, measured back to back:

| Script | Wall clock | DevEUI |
|--------|-----------|--------|
| Old `scan_rig.ps1` (child process per station) | 1991 ms | `0080E1150636E069` |
| `scan_device.ps1` (in process) | 871 ms | `0080E1150636E069` |

Identical DevEUI, so the copied byte order is correct.

Every CLI call passes `-q`. Do **not** rely on it for speed: on CubeProgrammer v2.16.0
`-q` does not suppress the banner, which was observed printing in full. The gain comes
entirely from not spawning a child process.

### Parameters

| Parameter | Default | Purpose |
|-----------|---------|---------|
| `-DeviceList` | `rig_devices.csv` beside the script | Probe map. A missing list is not fatal. |
| `-Stations` | whole bench | Scan only these stations, comma-separated. |
| `-Json` | off | Emit the rows as JSON instead of a table. |
| `-Freq` | `24000` | SWD clock in kHz. |
| `-ProgrammerCli` | STM32CubeProgrammer path | Second copy of the CLI path. |

A missing device list is not fatal. The scan then reports every attached probe with no
station number, which is still the DevEUI answer the caller wanted.

The device list is validated for its own consistency. A bad `Position`, an empty serial, a
duplicate station or a duplicate serial exits 1. A duplicate on either side makes the
station-to-probe map ambiguous, so the scan would report a DevEUI against the wrong
station.

### Probe enumeration

`-l` output is filtered in two ways, because it is not trustworthy on this host:

- Serials are de-duplicated. `-l` prints one probe's serial twice, once under
  "STLink Interface" and again in its serial-port section. A raw parse reports two probes
  for one board and then scans it twice.
- A serial must match `^[0-9A-Za-z]{8,32}$`. With a probe in `DEV_CONNECT_ERR`, `-l` prints
  raw bytes where the serial belongs. Taking that literally invents a probe that does not
  exist and hides the real one.

When `-l` returns no usable serial, the script does not conclude the bench is empty. It
reads every listed station directly, and reports what the connect actually says.

### States

| State | Meaning |
|-------|---------|
| `ok` | Probe attached, DevEUI read. |
| `no probe` | The device list expects this station, but its probe is absent. |
| `not listed` | A probe is attached that `rig_devices.csv` does not describe. |
| `read failed` | The probe answered, the UID read did not. See `Message`. |

Unlisted probes are reported even under `-Stations`. An unexpected probe is exactly what a
scan should surface. The table run also prints a note telling the operator to add a row for
it, because `bless_rig.ps1` will never select a probe the list does not describe.

### Exit codes

| Code | Meaning |
|------|---------|
| 0 | Every listed station answered. |
| 1 | Setup error. No device was read. |
| 2 | A listed station is empty, or a DevEUI read failed. |

`not listed` reads a DevEUI successfully. It is neither `ok` nor a failure, and it does not
affect the exit code.

---

## 9. `bless.bat` and `scan.bat` — operator wrappers

Both wrappers exist for two reasons. This machine runs with the default `Restricted`
execution policy, so `.\bless_rig.ps1` is refused with "running scripts is disabled on this
system". And `cmd.exe` needs the argument handling described below. The
`-ExecutionPolicy Bypass` applies to one process only and changes no machine setting.

### Argument handling

Arguments are forwarded verbatim through `%*`. They are not parsed positionally. This
matters, because `cmd.exe` treats a comma as an argument separator. Read through
`%1 %2 %3`, `bless 2,3,4` would arrive as three separate arguments and the `3` would bind
to `-Region`. `%*` keeps the comma list intact.

A first character that is not a dash is treated as a bare station list. `bless 2,3,4` and
`bless -Stations 2,3,4` are equivalent.

Paths are built from `%~dp0`, the wrapper's own directory. Both wrappers work from any
working directory. A wrong current directory is the usual cause of "is not recognized".

### `bless.bat`

Pre-fills `-DeviceList` and `-ReadVerdict`. Everything else is forwarded unchanged, quoted
or unquoted.

```
bless 2,3,4                        stations 2, 3 and 4, region US915
bless 1,3 -Region EU868            stations 1 and 3 as EU868
bless 2,3,4 -DryRun                print the launch plan, touch no hardware
bless 2,3,4 -KeepLogs              keep each station's output for diagnosis
bless 2,3,4 -Freq 8000             any bless_rig.ps1 parameter works
bless 3,4 -Keys "3=<32 hex>:<16 hex>,4=<32 hex>:<16 hex>"
```

The wrapper prints a `RESULT:` line for exit codes 0, 1 and 2. It suppresses that line
under `-DryRun`, because a dry run also exits 0 and nothing was flashed. It also suppresses
it under `-Json`, so stdout stays parseable.

In production the blessing service calls `bless_rig.ps1` directly. It has to read each
DevEUI and register the keys with the LNS before flashing. The wrapper is for bench runs.

### `scan.bat`

Pre-fills `-DeviceList` only. No arguments is the normal case, and it scans the whole
bench. That case is tested before `%ARGS:~0,1%` is touched. Otherwise an empty list would
become a bare `-Stations` with no value, and the script would refuse to start.

```
scan                               every station in the device list
scan 2,3                           stations 2 and 3 only
scan -Json                         JSON on stdout, for the blessing service
scan 2,3 -Freq 8000                any scan_device.ps1 parameter works
```

---

## 10. Machine-readable interfaces

### Status file — `<StatusDir>\station<N>.json`

Written by `flash_device.ps1` when `-StatusFile` is passed. `bless_rig.ps1` passes it for
every station. The file is rewritten on every step transition, and on every verdict poll.
It is owned by exactly one process.

```json
{
  "station": 1,
  "opCode": "0x11",
  "serialNumber": "001900393234510733353533",
  "devEui": "0080E1150636DF36",
  "region": "EU868",
  "step": "WAIT_VERDICT",
  "state": "running",
  "message": "DUT running; last read 0x00000000",
  "exitCode": null,
  "verdict": "",
  "faults": [],
  "pid": 12345,
  "startedUtc": "2026-09-09T09:14:02.1234567Z",
  "updatedUtc": "2026-09-09T09:14:49.7654321Z",
  "elapsedSec": 47
}
```

| Field | Notes |
|-------|-------|
| `step` | `LAUNCH`, `START`, `DEVEUI`, `ERASE`, `KEYS`, `FLASH`, `WAIT_VERDICT`, `DONE`. |
| `state` | `running`, `passed`, `failed`, `error`. This is what the UI colours the station dot with. |
| `devEui` | Available from the `DEVEUI` step onward, before anything is erased. |
| `verdict` | Raw verdict word as hex, once one has been read. |
| `faults` | Decoded fault names for that word. |
| `exitCode` | Null until the run ends. |
| `elapsedSec` | Seconds since this station's own process started. |

`LAUNCH` is written by `bless_rig.ps1` as a seed. Every other step is written by the child.

The file is written to a `.tmp` name and then renamed. A reader polling it never parses a
half-written file. Every status write is best effort. A status write can never fail a
flash.

The `WAIT_VERDICT` step refreshes on every poll. The UI can then show that the station is
alive and how long it has waited, rather than a step that looks frozen.

### `bless_rig.ps1 -Json`

Prints one JSON document and nothing else. Every human-facing line is suppressed by
shadowing `Write-Host` with an empty function.

Check the exit code before parsing. Exit 1 fails before any station runs, so stdout is
empty. Exit 0 and exit 2 both emit the document. A dry run emits its own document, so a
caller can parse unconditionally on exit 0.

```json
{
  "stations": [
    { "station": 1, "serialNumber": "0019...3533", "devEui": "0080E1150636DF36",
      "verdict": "0xD5000000", "exitCode": 0, "passed": true, "killed": false }
  ],
  "total": 1, "passed": 1, "failed": 0
}
```

Dry-run document:

```json
{ "dryRun": true, "stations": [1, 3], "total": 2 }
```

`opCode`, `faults` and `result` are left out on purpose. The consumer derives them. The
op-code is fixed per station by `rig_layout.ps1`. The faults are decoded from the verdict
bits. The result is prose, and `exitCode` carries the same classification as a number. The
terminal tables still show all three.

### `scan_device.ps1 -Json`

Same envelope and the same camelCase names, so one consumer can read both. The document is
always an object with a `stations` array plus counts. It is never a bare array. `station`,
`serialNumber`, `devEui` and `exitCode` mean the same thing in both documents.

```json
{
  "stations": [
    { "station": 2, "serialNumber": "0051...3634", "devEui": "0080E1150636D6B5",
      "state": "ok", "message": "", "exitCode": 0 }
  ],
  "total": 1, "ok": 1, "notListed": 0, "failed": 0
}
```

`failed` counts `no probe` and `read failed`. It is greater than zero exactly when the
script exits 2.

### For live progress

Use `-NoWait -StatusDir` and poll `station<N>.json`. Do not use `-Json` for progress.
`-Json` is for the "run it and give me the result" call.

---

## 11. Rules that must not be broken

These are the places where a tidy-looking change breaks the rig silently.

| Rule | Why |
|------|-----|
| Do not reassign station op-codes. | The low nibble sets the join stagger. Changing it to spread the frequency plans breaks collision avoidance. |
| Keep `rig_layout.ps1` the only station-to-op-code map. | Two copies drift, and a device gets the wrong plan or slot. |
| Keep AppKey and JoinEUI byte-reversed on the factory page. | `keys_update.c` reads them backwards. Natural order gives a device that provisions and never joins. |
| Write the region at offset `0x30`. | That is the address the firmware reads. `0x0803F840` is not. |
| Keep the `L` suffixes on the verdict masks. | Windows PowerShell types a bare `0xD5000000` as `Int32`, which overflows to a negative value. Every comparison against a real `uint32` then fails, and every device reports a verdict timeout. |
| Poll the verdict in `HOTPLUG` mode only. | Any reset runs SBSFU, whose `.data` starts at `0x20003400` and overwrites the verdict. |
| Keep `$VERDICT_FAULT_NAMES` a list of pairs. | An `[ordered]@{}` indexed by an integer returns the element at that position, not the value for that key. |
| Keep reading `$p.Process.Handle` after launch. | It is what makes `.ExitCode` readable. Without it every device reports "no exit code". |
| Keep `@()` around the summary, and `.ToArray()` before `ConvertTo-Json`. | Under `Set-StrictMode -Version Latest`, `.Count` on a lone object throws. PowerShell 5.1 `ConvertTo-Json` throws on a `List[object]`. |
| Do not check the firmware path after the erase. | A missing image would then leave a wiped device. |
| Validate keys before the first erase. | A station that fails validation mid-run has already lost its keys and its NVM. |
| Do not clean up after `-NoWait`. | The children outlive the script, and the status files are the UI feed. |
| Do not accept `1` or `2` as a verdict. | Those are pre-coded values from firmware that is not going to production. |
| Keep an unknown fault bit reported. | An unnamed bit must never vanish into a silent pass. |

---

## 12. Troubleshooting, script side

| Symptom | Cause and fix |
|---------|---------------|
| "running scripts is disabled on this system" | Execution policy. Use the `.bat` wrappers, or `powershell -NoProfile -ExecutionPolicy Bypass -File ...`. |
| "is not recognized" | Wrong working directory. The wrappers use `%~dp0` and work anywhere. |
| An error naming `-Region` after a station list | Stations were space-separated. Use commas. |
| "no row for station 13" | `-Stations` was coerced to an integer somewhere. Pass it as a string. |
| Connect or verify failures | Drop `-Freq` to 8000 or 4000. It is the first thing to try when a probe is marginal. |
| Every station reports `no probe` | `-l` returned garbled serials. `scan_device.ps1` already falls back to direct reads. Confirm with `-c port=SWD mode=HOTPLUG`. |
| One probe scanned twice | Old behaviour. Serials are de-duplicated now. |
| `VERDICT TIMEOUT`, last read `0x00005776` | SBSFU has not handed over. The device did not reach the application. |
| `VERDICT TIMEOUT`, last read `1` or `2` | Pre-coded firmware. Reflash with a build that writes the `0xD5` word. |
| An `OTAA join` fault on every device | A mass erase forces a fresh join. A gateway must be reachable, and the keys must already be registered against that DevEUI. |
| Summary shows "no exit code and no verdict logged" | The child died before writing anything. Re-run with `-KeepLogs` and read the `.err.log`. |
| No `STM32_Programmer_CLI` error text anywhere | It only survives in the child log. Re-run with `-KeepLogs`. |
| A station stuck mid-step in the UI | The child was killed. `bless_rig.ps1` stamps state `error` on an overall timeout, but an externally killed child cannot be stamped. |

---

## 13. Maintenance points

- **The CLI path exists twice.** `flash_device.ps1` sets `$CLI`. `scan_device.ps1` sets the
  `-ProgrammerCli` default. Keep them in step. Move both into `rig_layout.ps1` if a third
  script needs the CLI.
- **The firmware path is hardcoded** in `flash_device.ps1` as `$FIRMWARE_IMAGE`. It is
  overridable per run with `-FirmwarePath`.
- **`rig_devices.csv` is bench-specific** and holds real probe serials. Only
  `rig_devices.example.csv` is portable.
- **The `-DeviceList` help text in `bless_rig.ps1` is out of date.** It says the required
  columns are `SerialNumber` and `OpCode`. The code requires `SerialNumber` plus either
  `Position` or `OpCode`, and it prefers `Position`.
- **`flash_device.ps1` does not set `Set-StrictMode`.** `bless_rig.ps1` and `scan_device.ps1`
  both set `-Version Latest`. Keep that in mind when moving code between them.
- **The shared bring-up AppKey is a script default.** Any production path must pass
  `-Keys`. Shipping devices on a shared root key is a silent defect, and `bless_rig.ps1`
  only warns about it.
- **Related documents.** `confluence_blessing_rig_operation.md` covers operator procedure
  and service integration. `confluence_dut_error_codes.md` covers the verdict word and the
  fault bits in firmware terms.
