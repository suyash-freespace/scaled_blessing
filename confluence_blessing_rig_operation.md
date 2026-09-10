# Blessing Rig — Parallel Device Provisioning

| Property | Value |
|----------|-------|
| **Product** | FSO (Field Sensing & Occupancy) |
| **Author** | Firmware Team |
| **Status** | In use |
| **Last Updated** | 2026-08-13 |

---

## Purpose

"Blessing" is the factory provisioning step that turns a bare board into a device the LNS
will accept. For each device it must:

1. Read the **DevEUI** — derived from the chip UID at `0x1FFF7580`, not assignable
2. **Mass erase** the internal flash
3. Write the **factory page**: rig op-code, AppKey, JoinEUI, region
4. Flash the merged **SBSFU + application** image and reboot into it
5. Let the device run its own **DUT** (hardware checks + OTAA join) and report PASS/FAIL

The rig runs up to 6 stations at once. Each station is a separate OS process bound to its
own ST-LINK probe, so one station cannot stall, fail, or crash another.

Measured: **4 devices blessed in 34 seconds**, wall clock, including four OTAA joins.

---

## Rig Layout

The op-code written to `0x0803F800` identifies the station to the firmware. The **low
nibble is the physical station**; the high nibble selects the frequency plan.

| Station | Op-code | Frequency plan | Join stagger |
|---------|---------|----------------|--------------|
| 1 | `0x11` | 1 | 0 ms |
| 2 | `0x22` | 2 | 2000 ms |
| 3 | `0x33` | 3 | 4000 ms |
| 4 | `0x14` | 1 | 6000 ms |
| 5 | `0x25` | 2 | 8000 ms |
| 6 | `0x36` | 3 | 10000 ms |

Stations 1/4, 2/5 and 3/6 share a frequency plan. What keeps them from transmitting on top
of each other is the **join stagger**, `(station - 1) × 2000 ms`, applied by the firmware.
This is why the station↔op-code pairing must not be improvised: `rig_layout.ps1` is the
single source of truth and both scripts derive from it.

---

## Files

| File | Role |
|------|------|
| `rig_layout.ps1` | Station → op-code map, validation helpers. Shared, authoritative. |
| `flash_device.ps1` | Per-device primitive. One probe, one device, start to finish. |
| `bless_rig.ps1` | Fan-out. Launches and monitors one process per selected station. |
| `scan_device.ps1` | Read-only bench scan. Reports every device's DevEUI. Erases nothing. |
| `bless.bat` | Operator wrapper for `cmd.exe`. Bench runs on the shared keys. |
| `scan.bat` | Operator wrapper for `scan_device.ps1`. |
| `rig_devices.csv` | This bench's `Position,SerialNumber` probe map. **Not portable.** |
| `rig_devices.example.csv` | Template with all 6 stations. Commit this one. |

The firmware image defaults to `ide\Binary\BFU_FSO.bin`.

---

## Prerequisites

- **STM32CubeProgrammer** at
  `C:\Program Files\STMicroelectronics\STM32Cube\STM32CubeProgrammer\bin\STM32_Programmer_CLI.exe`
- **Execution policy.** The rig launches its children with `-ExecutionPolicy Bypass`, but
  the parent needs it too. Either invoke via `powershell -NoProfile -ExecutionPolicy Bypass -File …`
  or run `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass` once per terminal.
- **`rig_devices.csv` populated** with this bench's probe serials. Get them with
  `STM32_Programmer_CLI.exe -c port=SWD mode=HOTPLUG` (the `-c` output is reliable;
  `-l st-link` has been observed to garble serials on this host). `scan_device.ps1` also
  prints the serial of any attached probe the CSV does not list, as `not listed`.
- **A reachable gateway and LNS registration.** The mass erase wipes the LoRaWAN NVM at
  `0x0803F000`, so every blessing forces a fresh OTAA join. No gateway means every device
  reports `DUT FAIL`.

---

## Scanning The Bench

`scan_device.ps1` answers one question: which devices are on the bench right now, and what
is each one's DevEUI? **It reads only. No device is erased or written**, so it is safe to
run at any time, including on an already blessed device.

Run it before a blessing to collect the DevEUIs the LNS needs, and to confirm every
station is populated and its probe is alive.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scan_device.ps1
```

```
FSO rig scan - 1 probe(s) attached
  device list : C:\…\ScaledBlessing\rig_devices.csv
  reads only - no device is erased or written

station 2  reading DevEUI ...

==== Rig scan ====

Station SerialNumber             DevEUI           State    Message
------- ------------             ------           -----    -------
      1 001900393234510733353533                  no probe ST-LINK not attached
      2 005100303233510A39363634 0080E1150636D6B5 ok
      3 0050002A3234510836303532                  no probe ST-LINK not attached
      4 003F00253234510733353533                  no probe ST-LINK not attached

3 station(s) did not report a DevEUI
```

Three steps: list the attached ST-LINK probes, map each serial to its station via
`rig_devices.csv`, then read each device's chip UID directly and derive its DevEUI.

It reads the UID in its own process. It does not call `flash_device.ps1`. This saves one
`powershell.exe` start per station, which dominated the old scan time. The cost is a
second copy of the byte order. `scan_device.ps1` mirrors `GetUniqueId()` the same way
`flash_device.ps1` does. Keep the two in step. A wrong byte order produces a
plausible-looking wrong DevEUI and no error.

The `State` column names every mismatch between the bench and the device list:

| State | Meaning |
|-------|---------|
| `ok` | Probe attached, DevEUI read |
| `no probe` | The device list expects this station, but its ST-LINK is absent |
| `not listed` | A probe is attached that `rig_devices.csv` does not describe |
| `read failed` | The probe answered, the UID read did not — see `Message` |

`read failed` covers two different bench faults, and the `Message` does not separate
them: **no board seated** in an otherwise healthy probe, and a **wrong serial** in
`rig_devices.csv`. Tell them apart with a direct connect to that probe — an empty socket
reports a good voltage and `No STM32 target found!`:

```powershell
& $env:PROGRAMFILES\STMicroelectronics\STM32Cube\STM32CubeProgrammer\bin\STM32_Programmer_CLI.exe `
    -c port=SWD freq=24000 mode=HOTPLUG sn=<serial> -r32 0x1FFF7580 8
```

`-Stations 2,3` limits the scan. Attached probes missing from the device list are always
reported, even under `-Stations`, because an unexpected probe is what a scan should
surface.

### `-Json`, for the blessing service

`-Json` emits one JSON document on stdout instead of the table, and prints nothing
else. This is the service's pre-flash input: it needs each DevEUI to register the device
with the LNS against the keys it is about to write.

**Pass `-Stations` to match the blessing call.** Without it the scan covers every row in
`rig_devices.csv`, so a bench running two boards out of four always exits `2` — see the
exit-code note below.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scan_device.ps1 -Json -Stations 1,2
```

```json
{
    "stations":  [
        { "station": 1, "serialNumber": "001900393234510733353533",
          "devEui": "0080E1150636CED9", "state": "ok", "message": "", "exitCode": 0 },
        { "station": 2, "serialNumber": "005100303233510A39363634",
          "devEui": "0080E1150636D6B5", "state": "ok", "message": "", "exitCode": 0 }
    ],
    "total":  2, "ok":  2, "notListed":  0, "failed":  0
}
```

**Same envelope and field names as `bless_rig.ps1 -Json`**, so one consumer reads both:
an object with a `stations` array plus counts, never a bare array. `station`,
`serialNumber`, `devEui` and `exitCode` mean the same thing in both documents.

`station` is `null` for a `not listed` probe. `exitCode` is `flash_device.ps1`'s own exit
code, and `null` where the scan never launched it.

The counts mirror the exit code: **`failed > 0` is exactly when this script exits `2`**.
A `not listed` row read its DevEUI successfully, so it counts as neither `ok` nor
`failed`. Do not treat a non-zero exit as "the scan broke" — the DevEUIs it did read are
still valid, and `failed` tells you how many stations did not answer.

> Two things this needed, both of which were bugs first. `STM32_Programmer_CLI -l` prints
> each serial **twice**, once under `STLink Interface` and again in its serial-port
> section, so the probe list must be de-duplicated or one board is reported as two and
> scanned twice. And Windows PowerShell 5.1 `ConvertTo-Json` throws
> `Argument types do not match` on a `List[object]`, piped or as `-InputObject`, so the
> rows are passed as a real array.

---

## Running It

Always dry-run an unfamiliar invocation first — **every launch mass-erases its device**:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\bless_rig.ps1 `
  -DeviceList .\rig_devices.csv -Stations 2,3,4 -Region US915 -DryRun
```

### With the shared bring-up keys

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\bless_rig.ps1 `
  -DeviceList .\rig_devices.csv -Stations 2,3,4 -Region US915 -ReadVerdict -KeepLogs
```

### With keys minted per blessing

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\bless_rig.ps1 `
  -DeviceList .\rig_devices.csv -Stations 3,4 -Region US915 `
  -Keys "3=2B7E151628AED2A6ABF7158809CF4F3C:0E0D0D010E01020E,4=2B7E151628AED2A6ABF7158809CF4F3A:0E0D0D010E01020A" `
  -ReadVerdict -KeepLogs
```

`-Stations` must be **comma-separated**. Space-separating (`-Stations 3 4`) makes the `4`
bind positionally to the next parameter and fails with a confusing complaint about `-Region`.

### Live output

```
  launched station 3 SN 0050002A3234510836303532 opcode 0x33 -> pid 31240
  launched station 4 SN 003F00253234510733353533 opcode 0x14 -> pid 27860

  [12:11:39] station 3  LAUNCH       running process starting
  [12:11:41] station 4  KEYS         running writing op-code 0x14, AppKey, JoinEUI, region US915
  [12:11:50] station 3  WAIT_VERDICT running DUT running; last read 0x00005776
  [12:12:10] station 3  DONE         passed  DUT PASS
  [12:12:12] station 4  DONE         passed  DUT PASS
```

Transitions are printed as each station reaches them, independently. A station moving
faster than the 2-second poll may skip a line — the status file is a current-state
snapshot, not an event log. The full sequence is in the per-station log under `-KeepLogs`.

---

## Running From `cmd.exe`

The scripts are PowerShell, but nothing needs converting — `powershell.exe` is just an
executable, so the same command works unchanged from a Command Prompt:

```bat
powershell -NoProfile -ExecutionPolicy Bypass -File .\bless_rig.ps1 -DeviceList .\rig_devices.csv -Stations 2,3,4 -Region US915 -ReadVerdict -KeepLogs
```

`-Keys` survives cmd's parser both quoted and unquoted — hex, `=`, `:` and `,` are all
safe as a single token. Quote it anyway out of habit.

Three differences from PowerShell:

| | PowerShell | cmd.exe |
|---|---|---|
| Line continuation | `` ` `` (backtick) | `^` (caret) |
| Exit code | `$LASTEXITCODE` | `%ERRORLEVEL%` |
| Literal `%` in an argument | as-is | must be doubled `%%` inside a `.bat` |

### `bless.bat`

A wrapper so the bench can type one short command. It pre-fills the device list and
`-ReadVerdict`, and forwards everything else:

```bat
bless 2,3,4                        REM stations 2, 3 and 4, region US915
bless 1,3 -Region EU868            REM stations 1 and 3 as EU868
bless 2,3,4 -DryRun                REM print the launch plan, touch no hardware
bless 2,3,4 -KeepLogs              REM keep each station's output
bless -Stations 2,3,4 -Freq 8000   REM any bless_rig.ps1 parameter works
bless                              REM usage
```

Only `-DeviceList` and `-ReadVerdict` are pre-filled — **everything else is forwarded
verbatim**, so there is no separate provision for keys or region; pass them as you would
to `bless_rig.ps1`:

```bat
bless 3,4 -Region EU868 -Keys "3=<32 hex>:<16 hex>,4=<32 hex>:<16 hex>" -KeepLogs
```

`-Keys` works quoted or unquoted through cmd — hex, `=`, `:` and `,` are all safe as a
single token.

It prints a plain-language result line and propagates the exit code:

```
RESULT: all selected device(s) PASSED
RESULT: setup or validation error - nothing was flashed
RESULT: at least one device did not pass
```

Two things it does deliberately, both of which were bugs first:

- **It forwards `%*`, the raw command line, rather than reading `%1 %2 %3`.** `cmd.exe`
  treats a **comma as an argument separator**, so `bless 2,3,4` read positionally arrives
  as three separate arguments and the `3` binds to `-Region`, failing with
  `The argument "3" does not belong to the set …`. `%*` keeps the comma list intact.
- **It suppresses the result line on `-DryRun`**, which also exits 0 and would otherwise
  report "all device(s) PASSED" when nothing was flashed.

All paths are built from `%~dp0`, so it works from any working directory.

> `bless.bat` does not handle `-Keys` — unique per-blessing key material comes from the
> blessing service, which calls `bless_rig.ps1` directly.

### `scan.bat`

The same wrapper treatment for `scan_device.ps1`. It pre-fills the device list and forwards
everything else. No arguments is the normal case — it scans the whole bench:

```bat
scan                               REM every station in the device list
scan 2,3                           REM stations 2 and 3 only
scan -Json                         REM JSON on stdout, for the blessing service
scan 2,3 -Freq 8000                REM any scan_device.ps1 parameter works
scan /?                            REM usage
```

It prints a result line and propagates the exit code, but **suppresses that line under
`-Json`** so a caller can parse stdout:

```
RESULT: every listed station reported a DevEUI
RESULT: setup error - no device was read
RESULT: a station is empty, or a DevEUI read failed
```

It forwards `%*` for the same reason `bless.bat` does — cmd splits on commas — and tests
for empty arguments *before* reading `%ARGS:~0,1%`, or a bare `scan` becomes
`-Stations` with no value.

### From Node

Spawn `powershell.exe` with an **argument array** and no shell. This removes cmd's and
PowerShell's quoting rules from the picture entirely, which matters most for key values:

```js
const { spawn } = require('child_process');

const p = spawn('powershell.exe', [
  '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'bless_rig.ps1',
  '-DeviceList', 'rig_devices.csv',
  '-Stations', '2,3,4',
  '-Region', 'US915',
  '-Keys', `2=${k2}:${e2},3=${k3}:${e3},4=${k4}:${e4}`,
  '-ReadVerdict', '-NoWait',
  '-StatusDir', 'C:\\blessing\\status',
], { cwd: 'C:\\...\\products\\fso' });
```

Do **not** pass `shell: true` — that reintroduces the quoting rules this avoids.

#### `-Json`: one document, nothing else

`-NoWait -StatusDir` above is the right choice for **live** progress: the service polls
`station<N>.json` and pushes each station independently.

For a **blocking** "run it and give me the result" call, pass `-Json` instead. stdout is
then a single JSON document with no banner, no live transitions and no table, so it is
`JSON.parse`-able as-is and there is nothing to scrape:

```json
{
  "stations": [
    { "station": 2, "serialNumber": "0051…3634", "devEui": "0080E1150636D6B5",
      "verdict": "0xD5000000", "exitCode": 0, "passed": true, "killed": false },
    { "station": 3, "serialNumber": "0050…3532", "devEui": "0080E1150636C932",
      "verdict": "0xD5000001", "exitCode": 6, "passed": false, "killed": false }
  ],
  "total": 2, "passed": 1, "failed": 1
}
```

Seven fields per station, and nothing the consumer can work out for itself. **The
verdict is the raw word** — decode the fault bits with the table in
*Blessing Rig — DUT Error Codes*. `opCode` is omitted because `rig_layout.ps1` fixes it
per station; `result` is omitted because `exitCode` carries the same classification as a
number. The terminal tables still show all three.

`verdict` is `""` when no verdict word was read; `exitCode` then says why —
`5` verdict timeout, `2` erase, `3` keys, `4` flash. `killed` marks a station stopped by
`-OverallTimeoutSec`, the one case where `exitCode` can be `null`.

**Check the exit code before parsing.** A setup or validation error (exit `1`) fails
before any station runs, so there is no result and **stdout is empty**. Exit `0` and
exit `2` both emit the document. `-Json -DryRun` emits `{ "dryRun": true, … }`, so a
caller can parse unconditionally whenever the exit code is 0.

```js
const p = spawn('powershell.exe', [ …, '-ReadVerdict', '-Json' ]);
let buf = '';
p.stdout.on('data', d => buf += d);
p.on('close', code => {
  if (code === 1) throw new Error('rig setup error');   // stdout is empty
  const r = JSON.parse(buf);
  for (const s of r.stations) {
    console.log(s.station, s.verdict, decodeFaults(s.verdict));
  }
});

// Verdict word: 0xD5 signature | reserved | stage-2 faults | stage-1 faults.
// Zero fault bits means pass.
const FAULT_BITS = [
  [0x0001, 'PIR'], [0x0002, 'SPI flash'], [0x0004, 'KTD I2C'], [0x0100, 'OTAA join'],
];

function decodeFaults(verdict) {
  if (!verdict) return ['no verdict'];
  const w = parseInt(verdict, 16) >>> 0;              // >>> 0 keeps it unsigned
  if ((w & 0xFF000000) >>> 0 !== 0xD5000000) {
    return ['not a verdict'];                         // includes pre-coded 1 and 2
  }
  const bits = w & 0xFFFF;
  if (bits === 0) return [];                          // pass
  const named = FAULT_BITS.filter(([b]) => bits & b).map(([, n]) => n);
  const unknown = bits & ~FAULT_BITS.reduce((a, [b]) => a | b, 0) & 0xFFFF;
  if (unknown) named.push(`unknown bits 0x${unknown.toString(16)}`);
  return named;
}
```

A stage-1 bit means the join was **never attempted**, so never report a join failure
alongside a hardware fault.

#### Terminal summary width

Without `-Json`, the summary table prints **`Station` and `Verdict` only**. A station
that produced no verdict word shows its result text in that column instead, so the row
is never blank. Pass `-FullSummary` for the wide row — serial, op-code, DevEUI, decoded
faults, exit code and result — which is what you want when a station fails.

---

## Parameters — `bless_rig.ps1`

| Parameter | Default | Notes |
|-----------|---------|-------|
| `-DeviceList` | *required* | CSV with `Position,SerialNumber` (or an explicit `OpCode` column) |
| `-Stations` | all rows | Comma-separated subset, e.g. `1,3` |
| `-Region` | per-CSV / `US915` | Whole-run override; wins over the CSV column |
| `-Keys` | none | `station=<32 hex appKey>:<16 hex joinEui>`, comma-separated |
| `-ReadVerdict` | off | Poll the DUT verdict and report PASS/FAIL |
| `-KeepLogs` | off | Retain the run directory instead of deleting it |
| `-NoWait` | off | Launch and return immediately (service mode); implies `-KeepLogs` |
| `-StatusDir` | under `-LogDir` | Where `station<N>.json` are written |
| `-LogDir` | `%TEMP%\fso_rig\<ts>` | Throwaway unless `-KeepLogs` or an explicit path |
| `-Freq` | `24000` | Drop to `8000`/`4000` if a probe is marginal — try this first |
| `-VerdictTimeoutSec` | `180` | Per-station wait for the DUT verdict |
| `-OverallTimeoutSec` | `600` | Hard cap; stragglers are killed |
| `-DryRun` | off | Print the launch plan, touch no hardware |

By default **nothing is written to disk that survives the run** — the terminal is the whole
output. `-KeepLogs` retains each station's stdout/stderr, which is the only place the
`STM32_Programmer_CLI` error text survives.

### Key precedence

Lowest to highest: `flash_device.ps1` bring-up defaults → device-list column →
`-Region` (whole run) → `-Keys` (per station).

### Key validation

Checked **before any device is erased**, since a station rejected mid-run would already
have lost its keys and NVM:

| Condition | Behaviour |
|-----------|-----------|
| Malformed entry | Refuse the run |
| Same AppKey or JoinEUI on two stations | Refuse the run |
| Keys given for a station not in this run | Refuse the run — the allocation and the station list disagree |
| Selected station with no keys | Warn, mark `default` in the launch table, proceed |

---

## Production Flow — Unique Keys Per Blessing

The AppKey and JoinEUI must be registered against the DevEUI **before the device boots**,
because `-hardRst` at the end of the flash step sends it straight into the DUT and it
attempts OTAA within seconds. There is no window afterwards in which to register.

The DevEUI is not assignable — it comes from the chip UID — so keys cannot be chosen until
the board in the slot has been identified. That forces two phases per station:

```
1  read DevEUI     flash_device.ps1 -Station N -ReadDevEuiOnly
                   -> DevEUI: 0080E1150636DF36      (no erase, no reset)

2  service         mint AppKey (16 B) + JoinEUI (8 B)
                   register (DevEUI, JoinEUI, AppKey) with the LNS
                   ...wait for confirmation...

3  bless           bless_rig.ps1 -Stations N -Keys "N=<appKey>:<joinEui>" -ReadVerdict
                   erase -> factory page -> firmware -> hardRst -> DUT -> verdict

4  result          PASS -> keep the LNS device
                   FAIL -> delete that LNS device; a re-bless mints new keys
```

`-ReadDevEuiOnly` reports the DevEUI and exits **before** the erase, so it is safe to call
on a board you have not committed to reflashing.

> **Writing a key the LNS does not know produces a device that flashes cleanly and then
> fails its join, reporting `DUT FAIL`.** Register first.

### Key generation (service side)

| Field | Length | Guidance |
|-------|--------|----------|
| AppKey | 32 hex chars = **16 bytes**, AES-128 | Must be unguessable. Use a CSPRNG (`crypto.randomBytes`) for the random portion. |
| JoinEUI | 16 hex chars = **8 bytes**, EUI-64 | An identifier, not a secret. Uniqueness is all that is required. |

An epoch prefix plus CSPRNG padding is sound — the epoch gives uniqueness, the random
padding gives entropy. Two cautions:

- Use **epoch seconds** (10 digits). `Date.now()` is 13 digits and eats into the padding.
- With several stations blessing in the same second the epoch prefix is *identical*, so the
  random padding is the only thing keeping the keys apart. It must come from a CSPRNG, not
  `Math.random()` seeded per worker.

Put a unique constraint on AppKey and JoinEUI in the blessing table, so a generation bug
surfaces as an insert failure rather than two devices quietly sharing a root key.

---

## UI / Service Integration

With `-NoWait`, the rig launches the station processes and returns immediately. Each
station owns its probe for its whole run — DevEUI, erase, keys, flash, verdict — so nothing
else may connect to that ST-LINK while it is blessing.

```powershell
.\bless_rig.ps1 -DeviceList .\rig_devices.csv -Stations 1,3 -Region EU868 `
                -Keys "1=…:…,3=…:…" -ReadVerdict -NoWait -StatusDir C:\blessing\status
```

Each station rewrites `$StatusDir\station<N>.json` on every transition:

```json
{
  "station": 1, "opCode": "0x11",
  "serialNumber": "001900393234510733353533",
  "devEui": "0080E1150636C932",
  "region": "EU868",
  "step": "WAIT_VERDICT",
  "state": "running",
  "message": "DUT running; last read 0x00000000",
  "exitCode": null, "pid": 12345,
  "startedUtc": "2026-08-13T06:41:38Z",
  "updatedUtc": "2026-08-13T06:42:25Z",
  "elapsedSec": 47
}
```

| Field | Use |
|-------|-----|
| `step` | `LAUNCH` `START` `DEVEUI` `ERASE` `KEYS` `FLASH` `WAIT_VERDICT` `DONE` |
| `state` | `running` \| `passed` \| `failed` \| `error` — drives the station indicator |
| `devEui` | Populated from the `DEVEUI` step onward, before any erase |
| `elapsedSec` / `updatedUtc` | Drives the Time column; also detects a stalled station |

Files are written-then-renamed, so a poller never parses a half-written file. **No key
material is ever written to the status file or the logs.**

---

## Exit Codes

`flash_device.ps1`:

| Code | Meaning |
|------|---------|
| 0 | Flashed OK (with `-ReadVerdict`: DUT PASS) |
| 1 | Setup error — bad probe, unreadable UID, missing firmware image |
| 2 | Mass erase failed |
| 3 | Factory page write failed |
| 4 | Firmware write failed |
| 5 | Verdict timeout |
| 6 | DUT FAIL |

The missing-image check runs **before** the erase, so a bad `-FirmwarePath` can never
leave a wiped device. It is skipped for `-ReadDevEuiOnly`, which never flashes — that
path must work on a machine with no current build.

`bless_rig.ps1`: `0` every device passed (or, with `-NoWait`, all processes launched);
`1` setup/validation error; `2` at least one device did not pass.

`scan_device.ps1`: `0` every listed station reported a DevEUI; `1` setup error;
`2` a listed station is empty, or a DevEUI read failed. A `not listed` probe that reads
successfully is a warning, not a failure — it does not change the exit code.

---

## What Gets Written

### Factory page at `0x0803F800` (56 bytes, `0xFF` filled)

| Offset | Address | Size | Field |
|--------|---------|------|-------|
| `0x00` | `0x0803F800` | 4 | Rig op-code, little-endian |
| `0x10` | `0x0803F810` | 16 | AppKey, **byte-reversed** |
| `0x20` | `0x0803F820` | 8 | JoinEUI, **byte-reversed** |
| `0x30` | `0x0803F830` | 4 | Region ID, zero-extended little-endian word |

**Byte order is not cosmetic.** `keys_update.c` reads these back as `ptr[15 - i]` and
`ptr[7 - i]`. Writing them in natural order yields a device that provisions cleanly and
then silently never joins.

**The region address is `0x0803F830`**, as defined in `common/lora/keys_update.h` — the
address its only consumer actually reads. `device_dut.h` once also defined
`REGION_FLASH_ADDR` as `0x0803F840`, which nothing read; provisioning to that address
leaves the region as `0xFF` and the firmware blinks amber forever in
`UpdateKeysAndRegion()`. That stale definition has been removed.

Region IDs: `AS923`=0, `AU915`=1, `CN470`=2, `CN779`=3, `EU433`=4, `EU868`=5, `KR920`=6,
`IN865`=7, `US915`=8, `RU864`=9.

To verify a written key (remembering the reversal):

```powershell
STM32_Programmer_CLI.exe -c port=SWD freq=24000 mode=HOTPLUG sn=<probe> -r8 0x0803F810 16
```

### DUT verdict word at `0x20003400`

| Value | Meaning |
|-------|---------|
| `0x00000000` | DUT has not finished |
| `0xD5000000` | PASS — signature present, no fault bits |
| `0xD50000NN` | FAIL — stage-1 hardware faults in the low byte |
| `0xD500NN00` | FAIL — stage-2 link faults in the second byte |
| `0x00000001`, `0x00000002` | Pre-coded pass/fail. **Not accepted**, reflash the device |
| `0x00005776` | Not the verdict — SBSFU's `FLOW_CTRL_INIT_VALUE`, i.e. it has not handed over yet |

The fault bits are `0x0001` PIR, `0x0002` SPI flash, `0x0004` KTD I2C and `0x0100` OTAA
join. See `confluence_dut_error_codes.md` for the full list and for what each fault does
and does not prove.

`g_u32DutResult` lives in its own `.dut_result` section at the very start of the
application RAM region, pinned by `ide/STM32WL55JCIX_FLASH.ld`. Two hard constraints:

- **Reads must use `mode=HOTPLUG`.** SBSFU's `.data` starts at exactly `0x20003400`, so any
  reset overwrites the verdict before the application can publish it.
- **The linker region must not be removed.** `RAM1` starts at `0x20003408` and the 8-byte
  reservation is deliberate: at `0x20003404`, the `ALIGN(8)` inside `.data` skews LMA
  against VMA and every initialised global comes up shifted one word, **with no build
  error**. Drop the `DUT_RESULT` region while `device_dut.c` still targets `.dut_result`
  and the section becomes an orphan placed after `.data`, so the rig silently reads
  SBSFU's `uFlowCryptoValue` instead of the verdict.

Commit the linker script **together with** the code that depends on it.

---

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| `cannot be loaded because running scripts is disabled` | Execution policy on the *parent*. See Prerequisites. |
| `SETUP FAILED: read at 0x1FFF7580 failed (exit 1)` | Probe not attached, or the serial in `rig_devices.csv` is wrong. The underlying CLI message is `Serial number not found` — re-run with `-KeepLogs` to see it. |
| `DUT FAIL` with all hardware checks passing | The OTAA join failed. The mass erase forces a fresh join, so a gateway must be reachable **and** the AppKey/JoinEUI must already be registered against that DevEUI. |
| Verdict reads `0x00005776` forever | Something reset the device — a verdict read must use `mode=HOTPLUG`. |
| `VERDICT TIMEOUT` | DUT still running after `-VerdictTimeoutSec`, or the device never booted the new image. |
| Connect or verify failures on one station | Lower `-Freq` to `8000` or `4000`. |
| Probes vanish from USB mid-run | Recurring on this bench with 5–6 STLINK-V3SETs — a USB power/hub topology problem, not a script one. Treat as the main production risk. |
| `Bad -Stations value(s)` | Use commas: `-Stations 1,3`, not `-Stations 1 3`. |
| Scan reports `no probe` for a populated station | The serial in `rig_devices.csv` does not match the probe. Check the `not listed` row in the same scan — it carries the serial actually attached. |
| Scan reports `read failed` on a station you believe is populated | Usually no board seated. A direct connect to that probe reports a good voltage and `No STM32 target found!`. See *Scanning The Bench*. |
| Scan reports every station twice | The probe list was not de-duplicated. `STM32_Programmer_CLI -l` prints each serial twice. |
| `The argument "3" does not belong to the set …` for `-Region` | A station number leaked into `-Region`. Either space-separated `-Stations`, or a `.bat` reading `%1 %2 %3` instead of `%*` — cmd splits on commas. |

---

## Known Gaps

| Gap | Impact |
|-----|--------|
| Only 4 concurrent stations proven | 5–6 unverified; the launch path is identical, but USB stability is the unknown |
| Keys passed on the command line | Visible in the process list to anything on the host. Acceptable for bring-up; production key material wants stdin or a locked-down file |
| `products/tim/app/device_dut.h` | Still carries the stale `REGION_FLASH_ADDR 0x0803F840`; TIM is otherwise unaffected |
| No `-ExpectDevEui` guard | Deliberate — boards leave the rig only after PASS/FAIL, so there is no swap window between the DevEUI read and the flash |
