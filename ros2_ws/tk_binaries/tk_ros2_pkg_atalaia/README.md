# tk_ros2_pkg_atalaia

Compiled ROS 2 driver for the **Theker Atalaia Shield v3** — an in-house
camera-illumination module (two RGB + white LED strips, three fans, on-board
environment / power / thermal telemetry). One node drives any number of Atalaia
EtherCAT slaves: you add one line to your `ecat_bus.yaml`, launch the node, and
control the boards with plain ROS 2 service calls while decoded telemetry streams.

This is the **binary distribution** — the node and control GUI ship compiled
(`.bin` / `.so`); you install it with `tk install`, you do not build it. It
follows the same one-node-N-devices shape as the other Theker Layer 3 device
packages (`tk_ros2_pkg_electrovalves`, `tk_ros2_pkg_smc_modular_block`,
`tk_ros2_pkg_isokernel`).

---

## Overview

`tk_ros2_pkg_atalaia` exposes the Atalaia Shield v3 as a ROS 2 component so
higher-level applications can:

- **Drive the illumination** — per-strip SOLID RGB, per-LED buffers (WS2812),
  and the white LEDs (on/off + analog brightness).
- **Manage the board** — control word / fault reset, effect mode, active-LED
  counts, NTC Beta and other live config, all over acyclic CoE (SDO).
- **Read telemetry** — decoded BME environment, 48 V / 24 V rails, eFuse and
  per-strip white-LED currents, chassis NTC temperatures, fan RPM, and the
  device state / warning / fault bitfields.

**Integration is minimal.** Add one entry to your `ecat_bus.yaml`, launch one
node, and drive the board with plain ROS 2 service calls — `set_color`,
`set_white`, `set_fan`, `fault_reset`, `all_off` — while `AtalaiaState` streams
decoded telemetry. No plugin to build, no unit conversions to manage, and one
node handles any number of boards. The setter services are the easy everyday
surface; the full `AtalaiaCommand` topic is there when you need per-LED control.

The Atalaia is an EtherCAT slave (vendor `0x20A1`, product `0x1`). Its
**cyclic** process data is plain PDO and flows through the EtherCAT master's
passthrough plugin (no custom `.so` — the firmware PDO map is fixed):

| Image | Size | Topic | Direction |
|---|---|---|---|
| RxPDO control | 976 B | `ecat/<name>/command` (`EcatDeviceCommand`) | node → daemon |
| TxPDO telemetry | 32 B | `ecat/<name>/status` (`EcatDeviceState`) | daemon → node |

Its **acyclic** data — control word `0x7000`, status/faults `0x6000`, and
config (incl. NTC Beta `0x2040:04`) — is **not** in the PDO; the node reaches
it through the master's global SDO services `/ecat_read_sdo` /
`/ecat_write_sdo`. The node lives inside a larger cell stack alongside
`tk_ros2_pkg_ethercat_master`, which owns the bus and does the byte-level
scatter/gather between SHM and the slave PDOs.

At startup the node runs a one-time **bring-up** (retried until the slave
accepts it): read the NTC Beta, push the active-LED counts / effect mode /
optional white-current limit, then write the control word from the config
flags to drive the board to READY/ACTIVE. It then polls `0x6000` status/faults
at `sdo_poll_hz` and publishes decoded telemetry as `AtalaiaState`. All byte
(de)serialisation lives in `utils/atalaia_codec.py` (pure, unit-tested).

---

## What ships in this package

This is the installed binary layout, not the source tree. `tk install` drops it
into your workspace's `ros2_ws/tk_binaries/` and wires it onto the ROS 2 path —
the node and GUI arrive **compiled**, so there is nothing to build:

```bash
tk_ros2_pkg_atalaia/                       # installed by `tk install`
├── atalaia_node.bin                       # atalaia_node — the EtherCAT-bridge node
├── atalaia_gui.bin                         # atalaia_gui — Tkinter control panel
├── utils.cpython-3XX-x86_64-linux-gnu.so   # compiled PDO codec + SDO helper
├── configs/
│   └── atalaia_config.yaml                 # node parameters (copy + edit per project)
├── launch/
│   └── atalaia_launch.py                   # launches the node with the config
├── CHANGELOG.md
└── README.md                               # this file

tk_ros2_pkg_atalaia_interface/             # shipped as SOURCE — colcon builds it on your side
├── msg/  AtalaiaCommand, AtalaiaState
└── srv/  SetColor, SetWhite, SetFan, SetConfig, FaultReset, AllOff
```

Run the entry points with `ros2 run tk_ros2_pkg_atalaia atalaia_node` /
`atalaia_gui` (or the launch file below). Utility stubs for the compiled `utils`
module ship under `tk_binaries/typings/tk_ros2_pkg_atalaia/` for editor
autocomplete. The codec's byte layout is baked into the compiled `.so`; if the
firmware TxPDO layout ever changes, the maintainer rebuilds and re-ships this
package — there is nothing to patch on the consumer side.

---

## Install

Add both the node package and its interface to your project's
`binaries_requirements.txt`, then run `tk install`:

```text
tk_ros2_pkg_atalaia==0.1.0
tk_ros2_pkg_atalaia_interface==0.1.0
tk_ros2_pkg_ethercat_master          # + its interface — required at runtime
```

Dependencies:

- **`tk_ros2_pkg_ethercat_master`** (+ its interface, `EcatDeviceCommand` /
  `EcatDeviceState`, `EcatReadSDO` / `EcatWriteSDO`) — must be running so the
  Atalaia slave is online before `atalaia_node` starts publishing, and so the
  SDO read/write services exist for bring-up, the status poll, `fault_reset`
  and `set_config`.
- **`tk_ros2_pkg_atalaia_interface`** — installed from this release (source),
  built by your workspace's `tk build`.
- **`tkinter`** — only for `atalaia_gui` (standard library; `sudo apt install
  python3-tk` if missing).

No USB / dialout permissions are required — the EtherCAT master owns the raw
socket; this node only talks ROS topics/services. Firmware updates use the
separate `atalaya` FoE updater, not this package.

---

## Custom Message Definitions (msg)

| Message File | Description |
|---|---|
| `AtalaiaCommand.msg` | Full RxPDO control image — RGB, white, fans, per-LED buffers. |
| `AtalaiaState.msg` | Decoded telemetry + device state / warnings / faults. |

`AtalaiaCommand.msg` carries the whole control image; empty per-LED arrays
leave that strip's buffer unchanged. The setter services are convenience
wrappers over the same buffer.

```text
string   device_name
uint8    mode              # 0 SOLID, 1 PER-LED
uint8[3] strip_a_rgb       # SOLID-mode colour, strip A
uint8[3] strip_b_rgb       # SOLID-mode colour, strip B
uint8    white_a_pwm       # white LED enable A (FW 2.0.3: 0=off, >0=on)
uint8    white_b_pwm       # white LED enable B
uint16   white_a_dac       # white LED brightness A (0..3000)
uint16   white_b_dac       # white LED brightness B (0..3000)
uint8[3] fan_duty          # fan 1/2/3 duty (0..255)
uint32[] strip_a_leds      # PER-LED buffer A, 0x00RRGGBB (empty = unchanged)
uint32[] strip_b_leds      # PER-LED buffer B
```

`AtalaiaState.msg` reports only faithful decodes — no derived fields. It also
carries the raw 32 B TxPDO (`raw_tx`) for debugging / cross-checking.

```text
string   device_name
uint8    device_state      # 0 BOOT .. 5 READY 6 ACTIVE .. 8 FAULT 9 RECOVERY 10 FWUPD
uint16   status_word
uint32   warnings
uint32   faults
uint32   latched_faults
float32  bme_temp_c
float32  bme_humidity
uint32   bme_pressure_pa
float32  efuse_current_ma
float32  vin_volts
float32  v24_volts
float32  wled0_current_ma
float32  wled1_current_ma
float32  ntc1_c            # NaN if open/short
float32  ntc2_c
uint16[3] fan_rpm          # currently always 0 — firmware does not report fan RPM yet
uint8    efuse_status
uint8[]  raw_tx            # raw 32 B TxPDO image (debug)
```

> **Note:** `fan_rpm` currently reads **0** for all three fans — the firmware
> does not report fan tachometer data yet. Fan control (`set_fan` / `fan_auto`)
> is unaffected; only the RPM readback is a placeholder.

---

## Custom Service Definitions (srv)

| Service File | Service | Description |
|---|---|---|
| `SetColor.srv` | `atalaia/<name>/set_color` | SOLID RGB for strip `a` / `b` / `both`. |
| `SetWhite.srv` | `atalaia/<name>/set_white` | White LED — `pwm` on/off (0-1) + `dac` brightness (0-3000). |
| `SetFan.srv` | `atalaia/<name>/set_fan` | Fan duty; `fan_index` 1-3, or 0 = all. |
| `SetConfig.srv` | `atalaia/<name>/set_config` | Write one live config knob over SDO (clamped, see below). |
| `FaultReset.srv` | `atalaia/<name>/fault_reset` | Rising-edge `FAULT_RESET` on `0x7000:01`. |
| `AllOff.srv` | `atalaia/all_off` | Darken all outputs (device name, or empty = all). |

`set_config` writes one clamped knob per call (field name → OD entry, range in
`codec.CONFIG_FIELDS`): `fan_pwm_freq`, `led_count_a/b`, `ntc_beta`,
`white_current_limit`, and `effect_mode`. (`white_pwm_freq` / `0x2002` was
removed — deprecated in FW 2.0.3; see
[White-LED control](#white-led-control-fw-203).)

**Firmware effect patterns** are the `effect_mode` knob (`0x2001`): `1` = THEKER
wave (free-run), `2` = THEKER wave (phase-locked), `3` = blinking-RED
emergency, `0` = off (master/RGB-policy owns strips). The GUI exposes these as
buttons in an **Effects** section. Effects render only while the firmware owns
RGB — i.e. control-word `RGB_MASTER` off (`rgb_master: false`); with it set, the
master's solid / per-LED image wins.

---

## Topics & Services

All topics/services are namespaced per device by the slave `<name>` (except the
shared `atalaia/all_off`).

| Kind | Name | Type |
|---|---|---|
| Sub | `atalaia/<name>/command` | `AtalaiaCommand` — full RxPDO control |
| Pub | `atalaia/<name>/state` | `AtalaiaState` — decoded telemetry + status |
| Srv | `atalaia/<name>/set_color` | `SetColor` |
| Srv | `atalaia/<name>/set_white` | `SetWhite` |
| Srv | `atalaia/<name>/set_fan` | `SetFan` |
| Srv | `atalaia/<name>/set_config` | `SetConfig` |
| Srv | `atalaia/<name>/fault_reset` | `FaultReset` |
| Srv | `atalaia/all_off` | `AllOff` |

---

## Configuration Files

### `configs/atalaia_config.yaml` (this package)

Flat, ROS 2-compatible, one block per device keyed by the slave name (must
match `ecat_bus.yaml` and `device_names`):

| Key | Meaning |
|---|---|
| `publish_hz` | `AtalaiaState` publish rate |
| `heartbeat_hz` | RxPDO re-publish rate (keep > 5 Hz so the daemon never zeroes the command) |
| `sdo_poll_hz` | rate for the `0x6000` status/fault poll |
| `active_led_count_a/b` | LEDs lit per strip, written to `0x2000` at bring-up (see below) |
| `white_enable` / `fan_auto` / `buck_request` / `rgb_master` | control-word bring-up flags (`0x7000:01`) |
| `effect_mode` | firmware effect generator (`0x2001`): 0 off / 1 wave / 2 wave-synced / 3 blink-red |
| `white_current_limit_ma` | optional one-time SDO push; `-1` keeps firmware default |

Set `fan_auto: false` to drive fan duty manually via `set_fan` (otherwise the
firmware owns the temperature → fan curve and `set_fan` is ignored).

**Active-LED count is config-driven — it cannot be autodetected.** WS2812
strips give the MCU no back-channel to count LEDs, so there is nothing to read;
`active_led_count_a/b` (per strip) is the source of truth and the node writes it
to `0x2000:01/02` over SDO at bring-up. The RxPDO buffer always holds 120 slots
(`codec.LEDS_PER_STRIP`) regardless — that is fixed and unrelated to panel size.

### No pinned PDO map (FW ≥ the 32-byte-mapping rebuild)

Atalaia is a **plain passthrough** device: the EtherCAT master's SII/CoE
auto-discovery reads the full PDO map (976 B RxPDO @ SM2, 32 B TxPDO @ SM3)
straight from the slave — **no `pdo_map` is needed in `ecat_bus.yaml`, and no
map ships in the package.** This requires firmware that advertises all 32
TxPDO bytes in its CoE mapping (`0x1A00` = 15 entries `0x6000:01–0f`). Older
firmware under-reported **18 of 32** bytes (`0x1A00` = 8 entries), which
truncated telemetry and forced a pinned map; that was firmware issue #4, now
**resolved** (firmware issue #4). Boards still on
the old firmware must be updated, or telemetry past byte 18 reads as zero.

---

## Getting Started

Add a slave entry to your `ecat_bus.yaml`. That's the whole entry — **no
`pdo_map`, no `plugin`, nothing else** (the master auto-discovers the full PDO
map straight from the slave):

```yaml
  - device_name: "atalaia_1"        # must match device_names in atalaia_config.yaml
    position: 0                     # bus order — set to where the board is wired
    publish_rate_hz: 100.0
    heartbeat_timeout_ms: 500
```

Then, in order:

1. Wire the board and set its `position` in `ecat_bus.yaml`.
2. Bring the board up **once** via its own `atalaya_start.sh` and let it settle
   — do **not** spam `ethercat slaves` / `rescan` while it is booting (see
   [Bring-up gotchas](#bring-up-gotchas)).
3. Start the EtherCAT daemon + bridge (`tk_ros2_pkg_ethercat_master`).
4. Launch the node (below).

---

## Launch

```bash
# launch the node (waits for all slaves OP by default):
ros2 launch tk_ros2_pkg_atalaia atalaia_launch.py
# or run it with an interactive bench CLI:
ros2 run tk_ros2_pkg_atalaia atalaia_node --cli
# or drive everything from the control GUI (node must be running):
ros2 run tk_ros2_pkg_atalaia atalaia_gui          # add: -- --device atalaia_1
```

The GUI gives you Lights ON / ALL OFF, per-strip RGB + white-brightness
sliders, fan sliders, a Config panel (SDO knobs), an **Effects** section
(THEKER wave / blinking-RED emergency / off), a Fault Reset button, and a live
telemetry readout.

```bash
# light strip A solid blue, full white on both strips:
ros2 service call /atalaia/atalaia_1/set_color \
  tk_ros2_pkg_atalaia_interface/srv/SetColor "{strip: a, r: 0, g: 0, b: 255}"
ros2 service call /atalaia/atalaia_1/set_white \
  tk_ros2_pkg_atalaia_interface/srv/SetWhite "{strip: both, pwm: 1, dac: 3000}"
# watch telemetry (temps, currents, rails, fan rpm, faults):
ros2 topic echo /atalaia/atalaia_1/state
```

---

## White-LED control (FW 2.0.3)

Since firmware **2.0.3** the white LEDs dim **only through the analog DAC**;
the PWM stage is now a plain on/off gate:

- **`pwm` (RxPDO byte 6/7)** — on/off enable. `0` = off, any non-zero = on; the
  codec normalises it to `0`/`1`.
- **`dac` (RxPDO byte 8-11)** — brightness, `0..3000` (`codec.DAC_MAX`); the
  firmware hard-caps the DAC request at 3000 for eFuse headroom.
- **`0x2002` white PWM-freq SDO** — **deprecated** (writes are a firmware
  no-op). It is no longer exposed as a config knob; removing it also retired the
  old "&lt;375 Hz latches a fault" workaround (there is no PWM dimming path left
  to fault).

---

## Checking a board

With the daemon + bridge + node running, confirm a board end-to-end by commanding
the lights on and watching telemetry respond:

```bash
ros2 service call /atalaia/atalaia_1/set_white \
  tk_ros2_pkg_atalaia_interface/srv/SetWhite "{strip: both, pwm: 1, dac: 3000}"
# white-LED current should rise, proving the RxPDO reaches the board:
ros2 topic echo /atalaia/atalaia_1/state
```

`AtalaiaState.raw_tx` carries the raw 32 B TxPDO image for byte-level debugging.
The decode was verified on hardware against FW 2.0.3 on every SDO-mirrored field.

> The maintainer bench harnesses `atalaia_validate` (end-to-end PASS/FAIL) and
> `atalaia_telemetry_check` (TxPDO-decode vs SDO-mirror cross-check) are **not
> part of this binary** — they live in the source repo and are run when
> qualifying firmware, not by consumers of the package.

---

## Bring-up gotchas

- **FW 2.0.0 boots flap** the LAN9252 identity (`0x20A1 ↔ 0x0`). Bring the board
  up **once** via its own `atalaya_start.sh` and let it settle — do **not** spam
  `ethercat slaves` / `ethercat rescan` while it is booting. Flashing
  **FW ≥ 2.0.1** removes this at the source.
- **Verify the working counter** (slave at OP) before trusting telemetry.
- **`FAULT_RESET` is edge-triggered** — the `fault_reset` service pulses it
  (clear → set → clear); it does not hold.
- Config written over SDO applies live but only **persists across reboot** after
  a `0x1010:01` save (not done automatically by this node).

---

## Known limitations

These are **firmware-side** issues observed on hardware. The node
decodes/forwards faithfully — the fixes belong in the slave firmware, **not** in
this package (we deliberately do not paper over them with correction factors).
The full maintainer report (symptoms, evidence, requested fixes, workarounds)
lives with the source repo; summary below.

- **eFuse load current (TxPDO byte 8 / `0x2000`-family IMON) reads ~2.28× high.**
  Measured: PDO 1434 mA vs a true 48 V input of 630 mA. The factor equals the
  rail ratio `21 V / 48 V = 0.4375`, and power balances (48 V × 0.63 A ≈ 30 W ≈
  21 V × 1.434 A). So the firmware is either scaling AIN0 IMON with the wrong
  gain/R_sense or reporting a downstream ~21 V rail current while labelling it as
  the 48 V eFuse input. **Fix in firmware** so byte 8 reports true 48 V input mA.
  (The WLED current sensors are consistent PDO↔SDO and are not affected.)

- ~~**White-LED PWM freq `0x2002:01` < ~375 Hz latches a fault.**~~ **Resolved in
  FW 2.0.3** — white dimming moved entirely to the analog DAC path and the PWM
  stage became a plain on/off gate, so there is no low-frequency PWM dimming path
  left to fault. `0x2002` is now a deprecated no-op (see
  [White-LED control](#white-led-control-fw-203)).

**Active LED count `0x2000:01/02` — handled in software, not a firmware report.**
The panel has **40 physical LEDs/strip** (the RxPDO buffer holds 120 slots, only
the first N light). The node navigates the firmware's quirks: counts **1..40**
are written over SDO (firmware rejects >40 clamping and a **0** write); a
requested count of **0** is emulated by **blanking that strip** (all LEDs black
= 0 lit, no SDO 0 write); and because a new count only re-renders on the next
RGB image the firmware acts on — and the WS2812s latch their colors — the node
**re-sends the current RxPDO right after the count SDO** (in `_on_set_config`
and at bring-up) so the change applies immediately.

## Version

**0.1.0**

## Maintainers

- **THEKER Robotics Engineering Team**
- **Raul Adell Segarra** — (r.adell@theker.eu)
