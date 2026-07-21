# Changelog

All notable changes to `tk_ros2_pkg_atalaia` are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com); newest first.

## [0.1.0] — 2026-07-02

Initial release — Layer 3 EtherCAT driver for the Theker Atalaia Shield v3
(two RGB + white LED strips, three fans, on-board telemetry). One node drives
any number of Atalaia slaves.

### Added
- **`atalaia_node`** — EtherCAT-bridge node; one instance drives any number of
  Atalaia slaves via the master's passthrough plugin.
- **`atalaia/<name>/set_color`** — SOLID RGB for strip `a` / `b` / `both`.
- **`atalaia/<name>/set_white`** — white LEDs: `pwm` on/off gate + `dac`
  brightness (0..3000).
- **`atalaia/<name>/set_fan`** — fan duty (`fan_index` 1-3, or 0 = all); set
  `fan_auto: false` to drive fans manually.
- **`atalaia/<name>/set_config`** — one clamped live config knob per call over
  SDO (`led_count_a/b`, `ntc_beta`, `effect_mode`, `white_current_limit`,
  `fan_pwm_freq`).
- **`atalaia/<name>/fault_reset`** — edge-triggered `FAULT_RESET` on `0x7000:01`.
- **`atalaia/all_off`** — darken all outputs (device name, or empty = all).
- **`atalaia/<name>/command`** (`AtalaiaCommand`) — full RxPDO control image
  including per-LED WS2812 buffers.
- **`atalaia/<name>/state`** (`AtalaiaState`) — faithfully decoded telemetry
  (BME environment, 48 V/24 V rails, eFuse + WLED currents, chassis NTC, fan
  RPM, device state / warning / fault bitfields) plus the raw 32 B TxPDO.
- **Firmware effect patterns** — `effect_mode` (`0x2001`) exposes THEKER wave /
  emergency / off; surfaced as an Effects panel in `atalaia_gui`.
- **`atalaia_gui`** — Tkinter control panel shipped alongside the node.

### Notes
- Plain passthrough device: no Layer 2 plugin and no pinned PDO map — the master
  auto-discovers the map from the slave. **Requires firmware that advertises all
  32 TxPDO bytes** (issue #4 build); older firmware truncates telemetry past
  byte 18.
