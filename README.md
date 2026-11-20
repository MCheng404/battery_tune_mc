# Battery Tune MC

A Magisk / KernelSU / APatch module for the **Xiaomi 15 Pro (haotian)**.

`battery_tune_mc` combines charge-limit tuning, cloud-control bypass, adaptive charging-current learning, thermal and dynamic charge policies, four refresh-rate modes, 300 Hz touch sampling, and a seasonal WebUI.

> **Device support:** Xiaomi 15 Pro (`ro.product.device=haotian`) only. Installation aborts on every other device.
>
> **Requirements:** unlocked bootloader and a working root manager (Magisk, KernelSU, or APatch).

---

## Features

### Charge and power

- **Charge-limit unlock** through DTBO charge parameters: higher charge voltage, higher full-current thresholds, relaxed FCC/FV degradation, and expanded temperature windows.
- **Cloud-control bypass** for charging policy interference.
- **APL adaptive power ramp** (`scripts/apl.sh`): learns the real charger/device ceiling per SOC band, stores the target in `state/apl_target_ma`, and avoids the usual "power falls into a straight line and never recovers" behavior.
- **Thermal wall** (`scripts/charge_policy.sh`): optional pause/resume of charge input with hysteresis, using Xiaomi `IMiCharge.setInputSuspendState`.
- **Dynamic charge policy**: optional SOC/temperature/voltage-based current limiting with four profiles: gentle, balanced, aggressive, and berserk.
- **Public PPS support**: optional toggle for third-party PD/PPS chargers; replug the charger after changing it.
- **BAA payloads** for haotian, expanded at install time.
- **Cycle-count masking**: optional, configurable from the WebUI.

### Display and touch

- **Four refresh-rate modes:** 120, 132, 144, and 165 Hz.
- **156 Hz timing is embedded in the 165 Hz payload only.** There is no separate 156 Hz menu entry or button.
- **300 Hz touch sampling** by default, bound at boot through `post-fs-data.sh`; can be disabled in the WebUI and takes effect after reboot.
- **No o2 `partial-update` property**: the stable 144/165 configurations do not use `qcom,partial-update-enabled = "single_roi"`.

### WebUI

- Live power, current, voltage, and temperature data with layered refresh intervals.
- Refresh-rate switcher that builds and flashes the selected payload on demand.
- Charge policy, APL, touch sampling, cycle count, and device status controls.
- Seasonal and festival-aware color themes.
- Optional WeChat/Alipay sponsor QR codes on the About page.

---

## Refresh-rate payloads

The 120 Hz base is kept stock. Higher modes are added as cumulative timing nodes.

| Mode | Cell index | Panel clock | Transfer window | Jitter | BA |
| --- | --- | --- | --- | --- | --- |
| 120 Hz | native 0-4 | `0x4CA6CD80` | stock | stock | stock |
| 132 Hz | 5 | `0x54511540` | `0x19EC` (6636 us) | `3:1` | `0x0A` |
| 144 Hz | 6 | `0x5BFB5D00` | `0x17C3` (6083 us) | `3:1` | `0x06` |
| 165 Hz | 7 | `0x69655A90` | `0x14BD` (5309 us) | `3:1` | `0x07` |

Design rules:

- The panel clock must scale exactly with the target refresh rate. A lower clock can report a mode successfully while the panel actually runs at about 136 Hz or 159 Hz.
- The transfer window is calculated as `7300 * 120 / hz`.
- The stock `qcom,mdss-dsi-panel-phy-timings` property is preserved.
- Do not add `qcom,partial-update-enabled = "single_roi"` to the o2 panel. It keeps 120 Hz working but causes visible stutter at 144/165 Hz.
- The 165 Hz payload includes the 156 Hz timing block for compatibility; it is not exposed as a separate mode.

---

## Installation

1. Download the module zip.
2. Flash it in Magisk, KernelSU, or APatch.
3. The installer checks `ro.product.device`. If it is not `haotian`, installation stops before touching DTBO or BAA.
4. Choose a refresh rate with the volume keys:
   - **Volume Up:** move to the next mode.
   - **Volume Down:** confirm the current mode.
5. Choose whether to flash the DTBO immediately:
   - **Volume Up:** back up the current DTBO, build the image, flash it, and verify the full partition by SHA-256.
   - **Volume Down:** skip now; flash later from the WebUI.
6. Reboot. DTBO changes only take effect after a reboot.

There is no installation time limit; the installer waits for the volume-key choice.

### Changing the refresh rate later

Use the WebUI refresh-rate page, or run:

```sh
su -c 'sh /data/adb/modules/battery_tune_mc/scripts/dtbo.sh build <hz> [slot]'
```

Supported values are `120`, `132`, `144`, and `165`.

### OTA updates

A system OTA restores the stock DTBO. After an OTA, open the WebUI and flash the desired refresh-rate payload again.

### Backups

The installer backs up the current DTBO to:

```text
/sdcard/Download/dtbo_backup/
```

A backup can be restored from the WebUI or with `dtbo.sh flash <backup.img>`.

---

## WebUI and CLI

Open the WebUI from the root manager's module page. The module also exposes these command-line tools:

```sh
# Charge policy
charge_policy.sh status
charge_policy.sh tw on|off|limit 42|resume 38|power 25
charge_policy.sh dyn on|off|mode gentle|balanced|aggressive|berserk

# APL control
apl_ctl.sh status|reset|boost|freeze

# Touch sampling
touch.sh on|off|boot|status
```

Settings and runtime state are stored under the module directory:

```text
/data/adb/modules/battery_tune_mc/config/settings.conf
/data/adb/modules/battery_tune_mc/state/
```

Upgrading the module preserves `config/settings.conf` and `state/`.

---

## Repository layout

```text
.
+-- action.sh
+-- customize.sh
+-- post-fs-data.sh
+-- service.sh
+-- uninstall.sh
+-- module.prop
+-- config/
|   +-- settings.conf
+-- scripts/
|   +-- apl.sh
|   +-- apl_ctl.sh
|   +-- baa_ops.sh
|   +-- battery_info.sh
|   +-- build_dtbo.sh
|   +-- charge_guard.sh
|   +-- charge_policy.sh
|   +-- cloud_guard.sh
|   +-- common.sh
|   +-- cycle_guard.sh
|   +-- diag.sh
|   +-- diag_log.sh
|   +-- dtbo.sh
|   +-- freepps.sh
|   +-- fv_guard.sh
|   +-- fv_handler.sh
|   +-- guard_watchdog.sh
|   +-- menu.sh
|   +-- status_kv.sh
|   +-- status_live.sh
|   +-- touch.sh
|   +-- unlock.sh
+-- dtbo/
|   +-- 120hz.dtb
|   +-- 132hz.dtb
|   +-- 144hz.dtb
|   +-- 165hz.dtb
+-- baa/
+-- bin/
|   +-- freepps
+-- webroot/
|   +-- index.html
|   +-- assets/
```

The DTBO payloads are prebuilt. At flash time, `scripts/build_dtbo.sh` wraps the selected DTB into a padded DTBO image and checks the image header; no `dtc` or `mkdtimg` is required on the device.

---

## Safety notes

- The charge configuration is intentionally aggressive: up to 4580 mV and 17600 mA on wired charging. Heat and battery aging will be higher than stock. Avoid long gaming sessions while charging.
- Refresh-rate overclocking changes panel and DSD timing. If an app shows stripes, flicker, or a black screen, switch back to 120 Hz.
- The embedded 156 Hz timing cannot be selected independently.
- Keep a DTBO backup. A bad or mismatched DTBO can cause display problems until the backup is restored.
- This module is not affiliated with Xiaomi. Use it at your own risk.

---

## Credits and license

- Author: **MaoCat** (`@Maocat`)
- Based on the MIT-licensed **Dimples1337** upstream project. Upstream copyright remains with its original authors.
- License: **MIT**. See `LICENSE`.

This README is repository documentation only and is not included in the module zip.
