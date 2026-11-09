#!/usr/bin/env bash
# =============================================================================
# magisk-patch.sh - Extract and Magisk-patch stock firmware images for:
#
#   * Google Pixel 6a   (codename "bluejay")  - patches boot.img / init_boot.img
#   * Samsung Galaxy Note 10 (SM-N970F, "d1") - patches the AP_*.tar.md5 file
#
# Two patching methods:
#
#   adb  (default)  Fully automatic. Pushes the image plus Magisk's own
#                   boot_patch.sh and binaries (taken from the Magisk APK) to
#                   the phone, runs the patch over `adb shell`, and pulls the
#                   result back. No taps in the Magisk app needed.
#
#   app             Semi-automatic. Pushes the extracted file to the phone's
#                   Download folder, you tap "Install > Select and Patch a
#                   File" in the Magisk app, and the script waits for the
#                   magisk_patched-*.img/.tar to appear and pulls it back.
#
# Requirements (host): bash, unzip, tar, adb (platform-tools), curl
#                      lz4      - Samsung only
#                      fastboot - Pixel only, and only with --flash
# Requirements (phone): USB debugging enabled and this computer authorised.
#
# Usage: ./magisk-patch.sh --device <pixel6a|note10> --firmware <file> [options]
#        ./magisk-patch.sh --help
# =============================================================================
set -euo pipefail

VERSION="1.0.0"
REMOTE_DIR="/data/local/tmp/magisk-patch"
REMOTE_DL="/sdcard/Download"

# ---- defaults ---------------------------------------------------------------
DEVICE=""
FIRMWARE=""
MAGISK_APK=""
METHOD="adb"
PARTITION=""          # pixel: auto-detect init_boot.img / boot.img
OUT_DIR="./magisk-output"
FLASH=false
ASSUME_YES=false
KEEP_WORK=false
export KEEPVERITY="${KEEPVERITY:-true}"
export KEEPFORCEENCRYPT="${KEEPFORCEENCRYPT:-true}"
export PATCHVBMETAFLAG="${PATCHVBMETAFLAG:-false}"

# ---- pretty output ----------------------------------------------------------
if [[ -t 1 ]]; then
  C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[36m'; C_0=$'\e[0m'
else
  C_R=""; C_G=""; C_Y=""; C_B=""; C_0=""
fi
info() { printf '%s[*]%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
magisk-patch.sh v$VERSION - auto extract + Magisk patch for Pixel 6a / Galaxy Note 10

Usage:
  $0 --device <pixel6a|note10> --firmware <file> [options]

Required:
  -d, --device NAME     pixel6a | note10   (aliases: bluejay, n970, d1)
  -f, --firmware FILE   Pixel 6a : factory image zip (bluejay-*-factory-*.zip),
                                   the inner image-bluejay-*.zip, or a raw .img
                        Note 10  : firmware zip (SamFw/Frija/etc.), AP_*.tar.md5,
                                   or AP_*.tar

Options:
  -m, --magisk APK      Magisk APK to take patch scripts/binaries from.
                        Default: download the latest release from GitHub.
  -M, --method M        adb (default, fully automatic) | app (patch in Magisk app)
  -p, --partition P     Pixel only: force boot | init_boot (default: auto)
  -o, --out DIR         Output directory (default: ./magisk-output)
      --flash           Pixel only: flash the patched image with fastboot
  -y, --yes             Do not ask for confirmation before flashing
      --keep-work       Keep the temporary work directory
  -h, --help            Show this help

Environment overrides (passed to Magisk's boot_patch.sh):
  KEEPVERITY=$KEEPVERITY  KEEPFORCEENCRYPT=$KEEPFORCEENCRYPT  PATCHVBMETAFLAG=$PATCHVBMETAFLAG

Examples:
  $0 -d pixel6a -f bluejay-bp2a.250605.031-factory-1234abcd.zip --flash
  $0 -d note10  -f SM-N970F_EUX_N970FXXS8HWB1.zip
  $0 -d note10  -f AP_N970FXXS8HWB1_*.tar.md5 -M app
EOF
}

# ---- arg parsing ------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--device)    DEVICE="${2:-}"; shift 2 ;;
    -f|--firmware)  FIRMWARE="${2:-}"; shift 2 ;;
    -m|--magisk)    MAGISK_APK="${2:-}"; shift 2 ;;
    -M|--method)    METHOD="${2:-}"; shift 2 ;;
    -p|--partition) PARTITION="${2:-}"; shift 2 ;;
    -o|--out)       OUT_DIR="${2:-}"; shift 2 ;;
    --flash)        FLASH=true; shift ;;
    -y|--yes)       ASSUME_YES=true; shift ;;
    --keep-work)    KEEP_WORK=true; shift ;;
    -h|--help)      usage; exit 0 ;;
    *) usage >&2; die "Unknown argument: $1" ;;
  esac
done

case "${DEVICE,,}" in
  pixel6a|pixel-6a|6a|bluejay)           DEVICE="pixel6a" ;;
  note10|note-10|n970|n970f|d1|sm-n970f) DEVICE="note10" ;;
  "") usage >&2; die "--device is required" ;;
  *)  die "Unsupported device '$DEVICE' (use pixel6a or note10)" ;;
esac
[[ -n "$FIRMWARE" ]] || { usage >&2; die "--firmware is required"; }
[[ -f "$FIRMWARE" ]] || die "Firmware file not found: $FIRMWARE"
[[ "$METHOD" == adb || "$METHOD" == app ]] || die "--method must be 'adb' or 'app'"
[[ -z "$PARTITION" || "$PARTITION" == boot || "$PARTITION" == init_boot ]] \
  || die "--partition must be 'boot' or 'init_boot'"
if [[ "$FLASH" == true && "$DEVICE" != pixel6a ]]; then
  warn "--flash is ignored for the Note 10: flash the patched tar with Odin (see below)."
  FLASH=false
fi

FIRMWARE="$(cd "$(dirname "$FIRMWARE")" && pwd)/$(basename "$FIRMWARE")"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/magisk-patch.XXXXXX")"
cleanup() {
  if [[ "$KEEP_WORK" == true ]]; then info "Work dir kept: $WORK"; else rm -rf "$WORK"; fi
}
trap cleanup EXIT

need() { command -v "$1" >/dev/null 2>&1 || die "Missing required tool: $1 ${2:-}"; }
need unzip
need tar
need adb "(install Android platform-tools)"
[[ "$DEVICE" == note10 ]] && need lz4 "(e.g. apt install lz4 / brew install lz4)"
[[ "$FLASH" == true ]] && need fastboot "(install Android platform-tools)"

confirm() {
  [[ "$ASSUME_YES" == true ]] && return 0
  local ans; read -r -p "$1 [y/N] " ans
  [[ "${ans,,}" == y || "${ans,,}" == yes ]]
}

# =============================================================================
# Firmware extraction
# =============================================================================

# Print the first entry of a zip whose basename matches an extended regex.
zip_find() { unzip -Z1 "$1" 2>/dev/null | grep -E "(^|/)$2\$" | head -n1 || true; }

# Pixel 6a: produce $WORK/<partition>.img, echo its path.
extract_pixel() {
  local fw="$FIRMWARE" inner part img

  case "$fw" in
    *.img)
      info "Using raw image $(basename "$fw")" >&2
      cp "$fw" "$WORK/$(basename "$fw")"; echo "$WORK/$(basename "$fw")"; return ;;
    *.zip) ;;
    *) die "Pixel firmware must be a .zip or .img" ;;
  esac

  if unzip -Z1 "$fw" | grep -q '^payload\.bin$'; then
    die "This is an OTA zip (payload.bin). Download the *factory image* from
    https://developers.google.com/android/images#bluejay
    (or extract boot.img with payload-dumper-go and pass it with -f boot.img)."
  fi

  # Factory zip contains a nested image-bluejay-*.zip; the inner zip has the imgs.
  inner="$(zip_find "$fw" 'image-[a-z]+-[^/]*\.zip')"
  if [[ -n "$inner" ]]; then
    case "$inner" in */image-bluejay-*|image-bluejay-*) ;;
      *) warn "Image zip '$inner' is not for bluejay (Pixel 6a)!"
         confirm "Continue anyway?" || die "Aborted." ;;
    esac
    info "Extracting $inner from factory zip..." >&2
    unzip -o -q -j "$fw" "$inner" -d "$WORK" >&2
    fw="$WORK/$(basename "$inner")"
  fi

  # Pixel 6a launched on Android 12 so Magisk patches boot.img. init_boot.img is
  # only used if a build ever ships one (or if forced with --partition).
  if [[ -n "$PARTITION" ]]; then
    part="$PARTITION"
  elif [[ -n "$(zip_find "$fw" 'init_boot\.img')" ]]; then
    part="init_boot"
  else
    part="boot"
  fi
  img="$(zip_find "$fw" "${part}\.img")"
  [[ -n "$img" ]] || die "${part}.img not found in $(basename "$fw")"

  info "Extracting ${part}.img..." >&2
  unzip -o -q -j "$fw" "$img" -d "$WORK" >&2
  echo "$WORK/${part}.img"
}

# Note 10: produce $WORK/AP_*.tar, echo its path.
extract_note10() {
  local fw="$FIRMWARE" ap

  case "$fw" in
    *.tar.md5|*.tar) ;;
    *.zip)
      ap="$(zip_find "$fw" 'AP_[^/]*\.tar(\.md5)?')"
      [[ -n "$ap" ]] || die "No AP_*.tar.md5 found inside $(basename "$fw")"
      info "Extracting $(basename "$ap") from firmware zip (this is ~5 GB, be patient)..." >&2
      unzip -o -q -j "$fw" "$ap" -d "$WORK" >&2
      fw="$WORK/$(basename "$ap")" ;;
    *) die "Note 10 firmware must be a .zip, AP_*.tar.md5 or AP_*.tar" ;;
  esac

  case "$(basename "$fw")" in
    AP_N970*) ;;
    AP_N971*) warn "This looks like a Note 10 5G (SM-N971N) AP. Proceeding." ;;
    AP_*)     warn "$(basename "$fw") does not look like a Note 10 (SM-N970*) AP!"
              confirm "Continue anyway?" || die "Aborted." ;;
    *)        warn "File name doesn't start with AP_ - make sure this is the AP file." ;;
  esac

  # .tar.md5 is a plain tar with an md5 line appended; verify it if possible.
  if [[ "$fw" == *.md5 ]] && command -v md5sum >/dev/null; then
    info "Verifying AP md5 checksum..." >&2
    local want got size
    want="$(tail -c 200 "$fw" | grep -aoE '^[0-9a-f]{32}' | tail -n1 || true)"
    if [[ -n "$want" ]]; then
      size=$(( $(stat -c%s "$fw" 2>/dev/null || stat -f%z "$fw") - $(tail -n1 "$fw" | wc -c) ))
      got="$(head -c "$size" "$fw" | md5sum | cut -d' ' -f1)"
      [[ "$got" == "$want" ]] || die "AP checksum mismatch (corrupt download?) want=$want got=$got"
      ok "AP checksum OK" >&2
    fi
  fi

  if [[ "$fw" != "$WORK"/* ]]; then
    cp "$fw" "$WORK/"
    fw="$WORK/$(basename "$fw")"
  fi
  echo "$fw"
}

# =============================================================================
# Magisk APK + device prep
# =============================================================================
get_magisk_apk() {
  if [[ -n "$MAGISK_APK" ]]; then
    [[ -f "$MAGISK_APK" ]] || die "Magisk APK not found: $MAGISK_APK"
    return
  fi
  need curl
  info "Fetching latest Magisk release from GitHub..."
  local url
  url="$(curl -fsSL https://api.github.com/repos/topjohnwu/Magisk/releases/latest \
        | grep -oE '"browser_download_url": *"[^"]+Magisk[^"]*\.apk"' \
        | head -n1 | sed -E 's/.*"(https[^"]+)"/\1/')" || true
  [[ -n "$url" ]] || die "Could not find the Magisk APK. Download it manually and pass -m Magisk.apk"
  MAGISK_APK="$OUT_DIR/$(basename "$url")"
  if [[ ! -f "$MAGISK_APK" ]]; then
    curl -fL --progress-bar -o "$MAGISK_APK.part" "$url" && mv "$MAGISK_APK.part" "$MAGISK_APK"
  fi
  ok "Magisk APK: $(basename "$MAGISK_APK")"
}

wait_for_adb() {
  info "Waiting for device over adb (enable USB debugging and accept the prompt)..."
  adb wait-for-device
  local state; state="$(adb get-state 2>/dev/null || true)"
  [[ "$state" == device ]] || die "adb device state is '$state' (unauthorised?)"
  local model; model="$(adb shell getprop ro.product.model | tr -d '\r')"
  local codename; codename="$(adb shell getprop ro.product.device | tr -d '\r')"
  ok "Connected: $model ($codename)"
  case "$DEVICE:$codename" in
    pixel6a:bluejay|note10:d1|note10:d1x|note10:d1q) ;;
    *) warn "Connected device '$codename' does not match --device $DEVICE."
       warn "The patch runs on this phone, but the image is for $DEVICE."
       confirm "Continue anyway?" || die "Aborted." ;;
  esac
}

# Unpack boot_patch.sh, util_functions.sh, stub.apk and arm64 binaries from the
# APK into $WORK/magisk, then push to $REMOTE_DIR on the phone.
push_magisk_tools() {
  local d="$WORK/magisk" f n abi
  mkdir -p "$d"
  unzip -o -q "$MAGISK_APK" 'assets/*' 'lib/*' -d "$WORK/apk"
  for f in boot_patch.sh util_functions.sh stub.apk; do
    [[ -f "$WORK/apk/assets/$f" ]] && cp "$WORK/apk/assets/$f" "$d/"
  done
  [[ -f "$d/boot_patch.sh" ]] || die "boot_patch.sh missing from APK - is this a real Magisk APK?"

  abi="$(adb shell getprop ro.product.cpu.abi | tr -d '\r')"
  [[ -d "$WORK/apk/lib/$abi" ]] || abi="arm64-v8a"
  # libmagiskboot.so -> magiskboot, libbusybox.so -> busybox, libinit-ld.so -> init-ld ...
  for f in "$WORK/apk/lib/$abi"/lib*.so; do
    n="$(basename "$f" .so)"; cp "$f" "$d/${n#lib}"
  done
  # 64-bit devices also get the 32-bit magisk binary, like the app does.
  for f in "$WORK/apk/lib/armeabi-v7a/libmagisk32.so" "$WORK/apk/lib/armeabi-v7a/libmagisk.so"; do
    [[ -f "$f" && "$abi" == arm64-v8a ]] && { cp "$f" "$d/magisk32"; break; }
  done
  [[ -f "$d/magiskboot" && -f "$d/busybox" ]] || die "magiskboot/busybox missing from APK for ABI $abi"

  info "Pushing Magisk tools to $REMOTE_DIR..."
  adb shell "rm -rf $REMOTE_DIR && mkdir -p $REMOTE_DIR" >/dev/null
  adb push "$d/." "$REMOTE_DIR/" >/dev/null
  adb shell "chmod 755 $REMOTE_DIR/*" >/dev/null
}

# Run Magisk's boot_patch.sh on the phone. $1 = local image, $2 = local output,
# $3 = RECOVERYMODE (true/false)
remote_patch_image() {
  local img="$1" out="$2" recovery="${3:-false}" name rc
  name="$(basename "$img")"
  info "Pushing $name..."
  adb push "$img" "$REMOTE_DIR/$name" >/dev/null
  info "Running Magisk boot_patch.sh on device (KEEPVERITY=$KEEPVERITY KEEPFORCEENCRYPT=$KEEPFORCEENCRYPT PATCHVBMETAFLAG=$PATCHVBMETAFLAG RECOVERYMODE=$recovery)"
  set +e
  adb shell "cd $REMOTE_DIR && \
    KEEPVERITY=$KEEPVERITY KEEPFORCEENCRYPT=$KEEPFORCEENCRYPT \
    PATCHVBMETAFLAG=$PATCHVBMETAFLAG RECOVERYMODE=$recovery \
    ./busybox sh ./boot_patch.sh $REMOTE_DIR/$name; echo __RC=\$?" \
    | tr -d '\r' | tee "$WORK/patch.log" | grep -v '^__RC='
  rc="$(grep -oE '^__RC=[0-9]+' "$WORK/patch.log" | cut -d= -f2)"
  set -e
  [[ "$rc" == 0 ]] || die "boot_patch.sh failed (exit ${rc:-?}). Log: $WORK/patch.log (use --keep-work)"
  adb pull "$REMOTE_DIR/new-boot.img" "$out" >/dev/null
  adb shell "rm -f $REMOTE_DIR/new-boot.img $REMOTE_DIR/$name" >/dev/null
  ok "Patched image: $out"
}

# Push a file to Download/, let the user patch it in the Magisk app, pull result.
app_patch_file() {
  local file="$1" before newest out
  info "Pushing $(basename "$file") to $REMOTE_DL/ ..."
  adb push "$file" "$REMOTE_DL/" >/dev/null
  before="$(adb shell "ls -1 $REMOTE_DL/magisk_patched-* 2>/dev/null" | tr -d '\r' || true)"

  if ! adb shell pm list packages 2>/dev/null | grep -q 'com.topjohnwu.magisk'; then
    info "Installing Magisk app..."
    adb install -r "$MAGISK_APK" >/dev/null || warn "Could not install the Magisk app automatically."
  fi
  adb shell monkey -p com.topjohnwu.magisk -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true

  cat <<EOF

  ${C_Y}On the phone, in the Magisk app:${C_0}
    1. Tap  Install  (next to "Magisk")
    2. Choose  "Select and Patch a File"
    3. Pick  Download/$(basename "$file")
    4. Tap  LET'S GO
  The script will pull the result automatically when it's done.

EOF
  info "Waiting for magisk_patched-* in $REMOTE_DL (Ctrl+C to cancel)..."
  while :; do
    newest="$(adb shell "ls -1t $REMOTE_DL/magisk_patched-* 2>/dev/null" | tr -d '\r' | head -n1 || true)"
    if [[ -n "$newest" ]] && ! grep -qxF "$newest" <<<"$before"; then
      # Wait until the file stops growing (the app may still be writing it).
      local s1 s2
      s1="$(adb shell stat -c%s "$newest" | tr -d '\r')"; sleep 3
      s2="$(adb shell stat -c%s "$newest" | tr -d '\r')"
      [[ "$s1" == "$s2" && "$s1" != 0 ]] && break
    fi
    sleep 3
  done
  out="$OUT_DIR/$(basename "$newest")"
  adb pull "$newest" "$out" >/dev/null
  ok "Patched file: $out"
  PATCHED="$out"
}

# =============================================================================
# Samsung AP repack (adb method)
# =============================================================================
# Set the AVB "verification disabled | hashtree disabled" flags (offset 120,
# big-endian u32) in a vbmeta image - same as Magisk's app does for Samsung.
patch_vbmeta_flags() {
  local img="$1"
  [[ "$(head -c4 "$img")" == "AVB0" ]] || { warn "vbmeta.img has no AVB0 magic, leaving untouched"; return; }
  printf '\x00\x00\x00\x03' | dd of="$img" bs=1 seek=120 count=4 conv=notrunc status=none
}

patch_note10_ap_adb() {
  local ap="$1" x="$WORK/ap" names
  mkdir -p "$x"
  info "Unpacking AP tar..."
  tar -xf "$ap" -C "$x"
  names="$(tar -tf "$ap")"

  # Note 10 (SAR, no ramdisk in boot) -> Magisk lives in recovery.
  local rec_lz4="$x/recovery.img.lz4"
  [[ -f "$rec_lz4" ]] || die "recovery.img.lz4 not found in AP - not a Note 10 AP?"
  info "Decompressing recovery.img.lz4..."
  lz4 -d -f -q "$rec_lz4" "$WORK/recovery.img"
  remote_patch_image "$WORK/recovery.img" "$WORK/recovery-patched.img" true

  # Rebuild the full AP tar (same entries, same order) with the patched
  # recovery and a vbmeta that has verification disabled - the same output the
  # Magisk app produces, so it is flashed in Odin exactly like that one.
  lz4 -B6 --content-size -f -q "$WORK/recovery-patched.img" "$rec_lz4"
  if [[ -f "$x/vbmeta.img.lz4" ]]; then
    lz4 -d -f -q "$x/vbmeta.img.lz4" "$WORK/vbmeta.img"
    patch_vbmeta_flags "$WORK/vbmeta.img"
    lz4 -B6 --content-size -f -q "$WORK/vbmeta.img" "$x/vbmeta.img.lz4"
  elif [[ -f "$x/vbmeta.img" ]]; then
    patch_vbmeta_flags "$x/vbmeta.img"
  else
    warn "No vbmeta image in AP; only recovery was patched."
  fi

  local tag; tag="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c5 || true)"
  PATCHED="$OUT_DIR/magisk_patched-$tag.tar"
  info "Repacking AP as $(basename "$PATCHED")..."
  printf '%s\n' "$names" > "$WORK/ap-files.txt"
  tar --format=ustar -cf "$PATCHED" -C "$x" -T "$WORK/ap-files.txt"
  ok "Patched Odin tar: $PATCHED"
  tar -tvf "$PATCHED" | sed 's/^/      /'
}

# =============================================================================
# Main
# =============================================================================
PATCHED=""
info "Device: $DEVICE   Method: $METHOD   Firmware: $(basename "$FIRMWARE")"

if [[ "$DEVICE" == pixel6a ]]; then
  IMG="$(extract_pixel)"
  cp "$IMG" "$OUT_DIR/stock-$(basename "$IMG")"
  ok "Stock image saved: $OUT_DIR/stock-$(basename "$IMG")"
else
  IMG="$(extract_note10)"
  ok "AP file ready: $(basename "$IMG")"
fi

get_magisk_apk
wait_for_adb

if [[ "$METHOD" == app ]]; then
  app_patch_file "$IMG"
elif [[ "$DEVICE" == pixel6a ]]; then
  push_magisk_tools
  PATCHED="$OUT_DIR/magisk_patched-$(basename "$IMG")"
  remote_patch_image "$IMG" "$PATCHED" false
else
  push_magisk_tools
  patch_note10_ap_adb "$IMG"
fi
[[ "$METHOD" == adb ]] && adb shell "rm -rf $REMOTE_DIR" >/dev/null 2>&1 || true

# ---- flashing / next steps --------------------------------------------------
echo
if [[ "$DEVICE" == pixel6a ]]; then
  PART="$(basename "$IMG" .img)"
  if [[ "$FLASH" == true ]]; then
    warn "The bootloader must already be unlocked (fastboot flashing unlock)."
    if confirm "Reboot to bootloader and flash $(basename "$PATCHED") to '$PART'?"; then
      adb reboot bootloader || true
      info "Waiting for fastboot..."
      until fastboot devices | grep -q .; do sleep 1; done
      fastboot flash "$PART" "$PATCHED"
      fastboot reboot
      ok "Flashed. Open the Magisk app after boot to finish setup."
    else
      info "Skipped flashing."
    fi
  else
    cat <<EOF
${C_G}Done!${C_0} To flash (bootloader must be unlocked):
    adb reboot bootloader
    fastboot flash $PART "$PATCHED"
    fastboot reboot
To undo:  fastboot flash $PART "$OUT_DIR/stock-$PART.img"
EOF
  fi
else
  cat <<EOF
${C_G}Done!${C_0} Flash with Odin on Windows (bootloader unlocked, OEM unlocking on):
    1. Copy $(basename "$PATCHED") to your PC.
    2. In Odin load: BL, CP and CSC from the same stock firmware, and
       $(basename "$PATCHED") in the AP slot.
       Use CSC (not HOME_CSC) the first time - it wipes data, which is
       required after vbmeta verification is disabled.
    3. In Odin Options UNTICK "Auto Reboot", then Start.
    4. When it says PASS: hold Vol Down + Power to leave download mode, then
       right away hold Vol Up + Power. At the bootloader-unlocked warning,
       RELEASE all buttons -> the phone boots into system *with* Magisk.
       (Keep holding Vol Up instead to reach the real stock recovery.)
    5. Magisk lives in recovery on the Note 10, so every reboot must use
       Vol Up + Power (release at the warning). A normal boot has no root.
Note: US/Canada Snapdragon models (SM-N970U/U1/W) have locked bootloaders
      and cannot be rooted. Exynos SM-N970F (and SM-N971N) are supported.
EOF
fi
