# Blessing Rig — DUT Error Codes

Every code the blessing rig reports, in one place: the DUT verdict word read over SWD,
and the exit codes of the three rig scripts.

> **Status: implemented, not yet verified on hardware.** The firmware writes these
> codes from `products/fso/app/device_dut.h`, and the rig decodes them. The encoding
> and the rig decoder both have passing unit tests. No device has yet been blessed with
> a build carrying this change, so treat the first rig run as the acceptance test.
>
> A device flashed with an **older** build still reports `1` or `2`. The rig decodes
> those too — see *Values that are not a verdict*.

Applies to **FSO**.

---

## The verdict word

One 32-bit word at a fixed address. The rig reads it over SWD.

| | |
|---|---|
| Address | `0x20003400` |
| Symbol | `g_u32DutResult`, section `.dut_result` |
| Read mode | **`mode=HOTPLUG` only** |
| Written by | `Stage2_Dut()`, before the LED is latched |
| Cleared by | `DutResult_Init()` at every boot, when the op-code matches |

`mode=HOTPLUG` is not optional. Any reset runs SBSFU, whose `.data` starts at exactly
`0x20003400`, so a reset overwrites the verdict before the application can write it.

### Word layout

```
 31    24 | 23    16 | 15     8 | 7      0
   0xD5   |   0x00   |  stage 2 |  stage 1
 signature   reserved   faults     faults
```

The high byte `0xD5` is a **signature**. It marks the word as a real verdict.

The signature exists because `.dut_result` is `NOLOAD`, and it is cleared only when the
factory op-code matches. So the word can hold a stale or leftover value. Without a
signature, stray bytes with low bits set would decode as a specific hardware fault. Any
word whose high byte is not `0xD5` is not a verdict.

**Pass or fail is decided by bits 15-0 only.** Zero fault bits means pass.

---

## Fault bits

| Bit | Mask | Part | Set when |
|-----|------|------|----------|
| 0 | `0x01` | PIR | No trigger seen in the 15 × 500 ms window |
| 1 | `0x02` | SPI flash | `Ext_Flash_DUT()` failed |
| 2 | `0x04` | KTD2026 | No I2C ACK from the LED driver |
| 3 | `0x08` | — | **Reserved. Never set on FSO.** Do not reuse it. |
| 4-7 | — | spare | Future stage-1 parts |
| 8 | `0x100` | OTAA join | Join was attempted and got no accept |
| 9-15 | — | spare | Future stage-2 checks |

Bits 0-2 and bit 8 are the only bits FSO ever sets. Bit 3 stays reserved so the bit list
holds one meaning per bit as more parts are added.

---

## Every code the rig returns

| Code | Meaning | Action |
|------|---------|--------|
| `0x00000000` | DUT still running | Keep polling. Not a failure. |
| `0xD5000000` | **PASS** | Ship the board. |
| `0xD5000001` | PIR | Reject. Check the PIR and its trigger path. |
| `0xD5000002` | SPI flash | Reject. Check the external flash. |
| `0xD5000003` | PIR + SPI flash | Reject. |
| `0xD5000004` | KTD2026 | Reject. Check the I2C bus and the LED driver. |
| `0xD5000005` | PIR + KTD2026 | Reject. |
| `0xD5000006` | SPI flash + KTD2026 | Reject. |
| `0xD5000007` | PIR + SPI flash + KTD2026 | Reject. Suspect power or the whole I2C bus. |
| `0xD5000100` | Hardware passed, OTAA join failed | Check gateway reach and LNS registration before rejecting the board. |

Ten values. That is the complete list for FSO.

### Reading a code by eye

The last hex digit is the hardware result. Add the parts up:

**PIR = 1, SPI flash = 2, KTD2026 = 4.**

| Digit | Parts |
|-------|-------|
| `1` | PIR |
| `2` | flash |
| `3` | PIR + flash |
| `4` | KTD |
| `5` | PIR + KTD |
| `6` | flash + KTD |
| `7` | all three |

A `1` in the third-from-last position is the join: `0xD5000100`.

### The join rule

**If any of bits 0-2 is set, the join was never attempted.**

`main.c` gates the join on `g_bHwDutPassed`. On a hardware failure, `b_loraJoinFlag`
stays false because nothing tried, not because the join failed. So the join bit is
meaningful only on `0xD5000100`, where the hardware passed.

Report "join not attempted" for any code with a hardware bit set. Never report
"join failed". This is why `0xD5000107` is a code you will never see.

### What a KTD pass does and does not prove

Bit 2 clear means the KTD2026 answered on I2C. **It is not proof the LEDs light.** It
cannot detect a fault in the LED supply path, the CH pins, or the LED itself. A batch
passed this check with dark LEDs on 2026-08-25; the root cause was a missing resistor on
the 3V3 path feeding the LED anode rail.

Label this fault "KTD I2C", not "LED", so `0xD5000000` is never read as an LED pass.

---

## Values that are not a verdict

The rig will see these at `0x20003400`. None of them is a fault code.

| Value | Meaning |
|-------|---------|
| `0x00000000` | DUT still running, or the word was just cleared. Keep polling. |
| `0x00005776` | SBSFU's `uFlowCryptoValue` (`FLOW_CTRL_INIT_VALUE`). SBSFU has not handed over yet. |
| `0x00000001` | **Pre-coded pass.** Firmware built before the coded scheme. Not accepted. |
| `0x00000002` | **Pre-coded fail.** Not accepted. |
| anything else with a high byte that is not `0xD5` | Stale RAM. Not a verdict. |

A signed code carrying a bit the rig has no name for is reported as
`unknown fault bits 0xNNNN` and counts as a **fail**. That is deliberate: newer
firmware read by an older rig must fail loudly rather than pass a board silently.

The pre-coded `1` and `2` are **not** decoded. Only the `0xD5` signature makes a word a
verdict, so a board still holding a pre-coded image runs to `VERDICT TIMEOUT` (exit 5).
The timeout output names the value and tells the operator to reflash. Reason: those
builds are bench-only and are not going to production, and `1` and `2` are ambiguous
against any future scheme that uses small integers.

---

## Memory map around the word

Verified against `FSO.map` and a live SWD read.

| Address | Owner | Notes |
|---------|-------|-------|
| `0x20003400` | `g_u32DutResult` | The verdict. `DUT_RESULT` region, 4 bytes. |
| `0x20003404` | nothing | Dead pad. No section owns it. Holds stale bytes. |
| `0x20003408` | `RAM1` / `.data` | Device RAM starts here. First word is `SystemCoreClock`. |

The pad exists for alignment. RAM1's origin must stay 8-byte aligned, because `.data`
opens with `. = ALIGN(8)`. If that padding is emitted inside the section, the section's
LMA and VMA drift by 4 bytes while `_sidata`/`_sdata` do not, and the startup copy reads
the wrong flash offset. Every initialised global then comes up shifted by one word, with
no build error.

**Do not reclaim the pad** by dropping `DUT_RESULT_RESERVED` to `0x4`. That re-creates
exactly that bug. The pad is available for a future second word at zero cost: raise
`DUT_RESULT_SIZE` to `0x8` and leave `DUT_RESULT_RESERVED` at `0x8`, and RAM1 does not
move.

---

## Script exit codes

### `flash_device.ps1` — one device

| Code | Meaning |
|------|---------|
| 0 | Flashed OK. With `-ReadVerdict`, the DUT passed. |
| 1 | Setup error — bad probe, unreadable UID, missing firmware image |
| 2 | Mass erase failed |
| 3 | Factory page write failed |
| 4 | Firmware write failed |
| 5 | Verdict timeout — no verdict within `-VerdictTimeoutSec` |
| 6 | **DUT fail.** The verdict code says which part. |

Exit code `6` covers every fault combination. Splitting it per fault would need eight
codes. The decoded fault list belongs in the message and the status file instead.

### `bless_rig.ps1` — the whole rig

| Code | Meaning |
|------|---------|
| 0 | Every device passed. With `-NoWait`, every process launched. |
| 1 | Setup or validation error. Nothing was flashed. |
| 2 | At least one device did not pass. |

### `scan_rig.ps1` — read DevEUIs, writes nothing

| Code | Meaning |
|------|---------|
| 0 | Every listed station reported a DevEUI |
| 1 | Setup error |
| 2 | A listed station is empty, or a DevEUI read failed |

A `not listed` probe that reads successfully is a warning. It does not change the exit
code.

---

## Per-station scan states

`scan_rig.ps1` reports one of four states per station.

| State | Meaning |
|-------|---------|
| `ok` | Probe attached, DevEUI read |
| `no probe` | The device list expects this station, but its ST-LINK is absent |
| `not listed` | A probe is attached that `rig_devices.csv` does not describe |
| `read failed` | The probe answered, the UID read did not |

`read failed` covers two different faults, and the message does not separate them: **no
board seated**, and a **wrong serial** in `rig_devices.csv`. Tell them apart with a
direct connect. An empty socket reports a good voltage and `No STM32 target found!`.

---

## Status file fields

Each station rewrites `$StatusDir\station<N>.json` on every step transition. This is the
blessing UI's feed.

| Field | Values |
|-------|--------|
| `step` | `LAUNCH` `START` `DEVEUI` `ERASE` `KEYS` `FLASH` `WAIT_VERDICT` `DONE` |
| `state` | `running` \| `passed` \| `failed` \| `error` |
| `devEui` | Populated from the `DEVEUI` step onward, before any erase |
| `exitCode` | The script exit code above, or `null` while running |
| `verdict` | The raw verdict word as hex, for example `0xD5000007` |
| `faults` | Decoded fault names, for example `["PIR","SPI flash","KTD I2C"]` |

`verdict` and `faults` arrive with the coded scheme. No key material is ever written to
the status file or the logs.
