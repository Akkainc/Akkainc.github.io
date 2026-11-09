# Magisk auto-patcher: Pixel 6a and Galaxy Note 10

`magisk-patch.sh` takes the firmware you downloaded and:

1. finds and extracts the file Magisk needs to patch, and
2. patches it with Magisk on your phone (over adb), then
3. copies the patched file back to your computer, ready to flash.

| Device | Firmware to download | What gets patched | How you flash it |
|---|---|---|---|
| **Pixel 6a** (`bluejay`) | Factory image zip from [developers.google.com/android/images](https://developers.google.com/android/images#bluejay) | `boot.img` (or `init_boot.img` if the build has one) | `fastboot` (the script can flash it for you with `--flash`) |
| **Galaxy Note 10** (Exynos `SM-N970F`, `d1`) | Full firmware zip for your CSC (SamFw, Frija, Bifrost and so on) | `AP_*.tar.md5`: `recovery.img` plus `vbmeta` flags | Odin (Windows) |

> ⚠️ You must unlock the bootloader first, and unlocking **wipes the phone**.
> US and Canada Snapdragon Note 10 models (`SM-N970U/U1/W`) can't be unlocked, so they can't be rooted.
> Use firmware that **exactly** matches the build on your phone.

## Requirements

- Linux or macOS with `bash`, `unzip`, `tar` and `curl`
- [Android platform-tools](https://developer.android.com/tools/releases/platform-tools) (`adb`, plus `fastboot` for the Pixel)
- `lz4` for the Note 10 (`sudo apt install lz4` or `brew install lz4`)
- On the phone: USB debugging turned on, with this computer allowed

## Usage

```bash
chmod +x magisk-patch.sh

# Pixel 6a: extract, patch, then flash right away
./magisk-patch.sh -d pixel6a -f bluejay-<build>-factory-<hash>.zip --flash

# Galaxy Note 10: extract the AP from the firmware zip and patch it
./magisk-patch.sh -d note10 -f SM-N970F_<CSC>_<build>.zip
```

Results go to `./magisk-output/`. For the Pixel this also includes a `stock-boot.img` you can flash to undo the change.

### Options

| Flag | Meaning |
|---|---|
| `-d, --device` | `pixel6a` or `note10` |
| `-f, --firmware` | Firmware zip. You can also pass the inner `image-bluejay-*.zip`, a raw `.img`, or `AP_*.tar(.md5)` |
| `-m, --magisk` | Magisk APK to use. By default the latest release is downloaded from GitHub |
| `-M, --method` | `adb` (default): patches fully automatically through Magisk's own `boot_patch.sh`.<br>`app`: pushes the file to `Download/`; you tap **Install → Select and Patch a File** in the Magisk app, and the script picks up the result |
| `-p, --partition` | Pixel only: force `boot` or `init_boot` |
| `-o, --out` | Output folder |
| `--flash` | Pixel only: reboots to the bootloader and runs `fastboot flash` |
| `-y, --yes` | Skips confirmation prompts |

Magisk patch options can be overridden with environment variables. For example:
`KEEPVERITY=false ./magisk-patch.sh ...` (`KEEPVERITY`, `KEEPFORCEENCRYPT`, `PATCHVBMETAFLAG`).

## Flashing the Note 10 patch in Odin

1. In Odin, load **BL**, **CP** and **CSC** from the same firmware, and put `magisk_patched-XXXXX.tar` in the **AP** slot.
   Use `CSC`, not `HOME_CSC`, the first time. This wipes the phone, which is required.
2. Untick **Auto Reboot**, then press Start.
3. When Odin shows PASS, hold **Vol Down + Power** to leave download mode. Then right away hold **Vol Up + Power**, and let go of every button when the "bootloader unlocked" warning appears. The phone now boots with Magisk.
4. On the Note 10, Magisk is installed in the recovery partition. **Boot this way every time** (Vol Up + Power, release at the warning) to keep root. A normal boot starts without Magisk.

## How it works

- **Pixel:** the script pulls the nested `image-bluejay-*.zip` out of the factory zip, then pulls `boot.img` out of that.
- **Note 10:** it extracts `AP_*.tar.md5` from the firmware zip and checks its embedded MD5. Then it unpacks `recovery.img.lz4`, patches it with `RECOVERYMODE=true` (the Note 10's boot image has no ramdisk), and sets the AVB "verification disabled" flags in `vbmeta.img`. Finally it rebuilds the full AP as a ustar tar that Odin accepts.
- **Patching** runs on the phone, using the `boot_patch.sh`, `magiskboot`, `magiskinit` and other binaries from the official Magisk APK. These are the same steps the Magisk app runs.
