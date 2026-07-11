#!/bin/bash
#
# ============================================================================
#  Ventoy SteamOS Imager for macOS
# ============================================================================
#  Adds the Steam Deck SteamOS recovery/repair image to an EXISTING
#  MActoy-created Ventoy USB, from macOS.
#
#  Includes the boot-chain fix missing from the original Linux add-on:
#  the SteamOS partitions are cloned with their ORIGINAL PARTUUIDs and
#  type GUIDs preserved, so SteamOS's grub/steamenv can locate rootfs,
#  var and efi at boot. Without this, the menu chainloads and then hangs
#  after the countdown (the widely reported bug).
#
#  macOS cannot shrink exFAT in place, so this script frees room by
#  recreating the Ventoy data partition smaller (SAME start sector,
#  SAME PARTUUID/type, re-formatted exFAT). Ventoy's boot code lives in
#  VTOYEFI + reserved sectors and is left untouched. The SteamOS
#  partitions are placed in the freed gap before VTOYEFI.
#
#  Requires: macOS, Homebrew + gptfdisk (sgdisk). Run with sudo.
#
#  Fork of PizzaGntlemn's Ventoy_SteamOS-Repair_Addon (Linux).
#  MIT licensed - see LICENSE. Ventoy (c) longpanda. MActoy (c) cashcon57.
# ============================================================================

set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

APP_VERSION="1.0.0"
RESERVE_GIB=10                 # space carved from data partition for SteamOS
VENTOY_REF_VERSION="1.1.16"    # latest Ventoy Linux verified at release time

# absolute path to this script + its assets, resolved before any sudo re-exec
SCRIPT="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
SELF_DIR="$(dirname "$SCRIPT")"
ASSETS="$SELF_DIR/assets"

# -------------------------------- output ------------------------------------
say() { printf '\n%s\n' "$*"; }
ok()  { printf '  --> %s\n' "$*"; }
warn(){ printf '\n!! %s\n' "$*"; }
die() { printf '\n** ERROR ** --> %s\n' "$*" >&2; echo; read -r -p "Press ENTER to exit "; exit 1; }

# ---------------------------- root / sudo -----------------------------------
if [[ "$(id -u)" -ne 0 ]]; then
    say "This needs root for disk access. Re-running with sudo..."
    exec sudo -E bash "$SCRIPT" "$@"
fi

# ------------------------------- helpers ------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

ensure_sgdisk() {
    have sgdisk && return
    say "sgdisk (gptfdisk) is required but not installed."
    if have brew; then
        read -r -p "Install it now (brew install gptfdisk)? [Y/n]: " a; a=${a:-Y}
        [[ "$a" =~ ^[Yy]$ ]] || die "sgdisk required. Run: brew install gptfdisk"
        sudo -u "${SUDO_USER:-$USER}" brew install gptfdisk || die "brew install failed"
    else
        die "Homebrew not found. Install from https://brew.sh then: brew install gptfdisk"
    fi
    have sgdisk || die "sgdisk still missing after install (check PATH)"
}

check_ventoy_latest() {
    say "Checking latest Ventoy version..."
    local latest
    latest="$(curl -sL --max-time 12 'https://sourceforge.net/projects/ventoy/rss?path=/' 2>/dev/null \
        | grep -oE 'ventoy-[0-9]+\.[0-9]+\.[0-9]+-linux\.tar\.gz' \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail -1)"
    if [[ -n "$latest" ]]; then
        ok "Latest Ventoy release online: $latest  (add-on verified against $VENTOY_REF_VERSION)"
    else
        ok "Could not reach SourceForge; skipping version check."
    fi
    ok "MActoy installs/updates Ventoy itself - this add-on only adds SteamOS."
}

# sgdisk field readers (operate on a whole-disk device or image file)
p_type() { sgdisk -i "$2" "$1" | awk -F': ' '/Partition GUID code/{print $2}' | awk '{print $1}'; }
p_uuid() { sgdisk -i "$2" "$1" | awk -F': ' '/Partition unique GUID/{print $2}'; }
p_size() { sgdisk -i "$2" "$1" | awk -F': ' '/Partition size/{print $2}' | awk '{print $1}'; }
p_name() { sgdisk -i "$2" "$1" | sed -n "s/^Partition name: '\(.*\)'/\1/p"; }
p_first(){ sgdisk -i "$2" "$1" | awk -F': ' '/First sector/{print $2}' | awk '{print $1}'; }

# ---------------------------- find repair image -----------------------------
find_repair_image() {
    shopt -s nullglob
    local c imgs=()
    for c in "$PWD"/*repair*.img "$SELF_DIR"/*repair*.img; do imgs+=("$c"); done
    shopt -u nullglob
    [[ ${#imgs[@]} -eq 0 ]] && die "No SteamOS repair image (*repair*.img) found in $PWD or $SELF_DIR"
    local seen="" u=()
    for c in "${imgs[@]}"; do [[ "$seen" == *"|$c|"* ]] || { u+=("$c"); seen+="|$c|"; }; done
    for c in "${u[@]}"; do
        say "Found repair image:"; ok "$c"
        read -r -p "Use this image? [Y/n]: " a; a=${a:-Y}
        [[ "$a" =~ ^[Yy]$ ]] && { IMG="$c"; return; }
    done
    die "No repair image selected."
}

# ---------------------------- detect ventoy usb -----------------------------
detect_usb() {
    local d internal
    for d in $(diskutil list | grep -oE '^/dev/disk[0-9]+'); do
        internal="$(diskutil info "$d" 2>/dev/null | awk -F: '/Internal/{gsub(/ /,"",$2);print $2; exit}')"
        [[ "$internal" == "No" ]] || continue
        diskutil list "$d" 2>/dev/null | grep -q VTOYEFI && { echo "$d"; return 0; }
    done
    return 1
}

# ================================ START =====================================
clear
say "=========================================================="
say " Ventoy SteamOS Imager for macOS   v${APP_VERSION}"
say "=========================================================="

ensure_sgdisk
check_ventoy_latest
find_repair_image

# ---- locate + confirm the USB ----
say "Looking for a MActoy / Ventoy USB (partition labelled VTOYEFI)..."
if ! DISK="$(detect_usb)"; then
    say "No Ventoy USB auto-detected. External disks:"
    diskutil list external physical
    read -r -p "Enter the target disk (e.g. /dev/disk6): " DISK
fi
[[ -b "$DISK" || -e "$DISK" ]] || die "Disk not found: $DISK"

# safety: must be external + physical, must look like Ventoy
INTERNAL="$(diskutil info "$DISK" | awk -F: '/Internal/{gsub(/ /,"",$2);print $2; exit}')"
[[ "$INTERNAL" == "No" ]] || die "$DISK is an INTERNAL disk. Refusing. (SteamOS install targets USB only.)"
diskutil list "$DISK" | grep -q VTOYEFI || die "$DISK has no VTOYEFI partition - not a Ventoy USB."

say "Target USB:"
diskutil list "$DISK"

RAW="${DISK/disk/rdisk}"

# ---- read USB geometry ----
SECTOR="$(diskutil info "$DISK" | awk -F: '/Device Block Size/{print $2}' | grep -oE '[0-9]+' | head -1)"
SECTOR="${SECTOR:-512}"
P1_START="$(p_first "$DISK" 1)"
P1_TYPE="$(p_type  "$DISK" 1)"
P1_UUID="$(p_uuid  "$DISK" 1)"
P2_START="$(p_first "$DISK" 2)"
[[ -n "$P1_START" && -n "$P2_START" ]] || die "Could not read Ventoy partition geometry."

# ---- read source image geometry (attach read-only) ----
say "Reading SteamOS repair image layout..."
ATTACH_OUT="$(hdiutil attach -nomount -readonly "$IMG")"
SRC="$(echo "$ATTACH_OUT" | awk '/GUID_partition_scheme/{print $1; exit}')"
[[ -n "$SRC" ]] || { echo "$ATTACH_OUT"; die "Failed to attach repair image."; }
SRCRAW="${SRC/disk/rdisk}"
cleanup_src() { hdiutil detach "$SRC" >/dev/null 2>&1 || true; }
trap cleanup_src EXIT

declare -a S_TYPE S_UUID S_SIZE S_NAME
TOTAL_SRC=0
for s in 1 2 3 4 5; do
    S_TYPE[$s]="$(p_type "$SRC" $s)"
    S_UUID[$s]="$(p_uuid "$SRC" $s)"
    S_SIZE[$s]="$(p_size "$SRC" $s)"
    S_NAME[$s]="$(p_name "$SRC" $s)"
    [[ -n "${S_SIZE[$s]}" ]] || die "Could not read source partition $s"
    TOTAL_SRC=$(( TOTAL_SRC + S_SIZE[$s] ))
done

# ---- compute new layout ----
RESERVE_SECTORS=$(( RESERVE_GIB * 1024 * 1024 * 1024 / SECTOR ))
NEEDED=$(( TOTAL_SRC + 5 * 2048 + 2048 ))          # source data + alignment slack
if (( RESERVE_SECTORS < NEEDED )); then
    RESERVE_SECTORS=$(( ( NEEDED / 2048 + 2 ) * 2048 ))
    warn "Reserve bumped up to fit the image (~$(( RESERVE_SECTORS * SECTOR / 1024/1024/1024 )) GiB)."
fi
NEW_P1_END=$(( P2_START - RESERVE_SECTORS - 1 ))
NEW_P1_END=$(( ( (NEW_P1_END + 1) / 2048 ) * 2048 - 1 ))   # align
GAP=$(( P2_START - NEW_P1_END - 1 ))
(( NEW_P1_END > P1_START + 2048 )) || die "Disk too small to carve out SteamOS space."
(( GAP >= NEEDED )) || die "Not enough room before VTOYEFI (need $NEEDED sectors, have $GAP)."

NEW_P1_GIB=$(( (NEW_P1_END - P1_START) * SECTOR / 1024/1024/1024 ))

# ------------------------------ the plan ------------------------------------
say "=========================== PLAN ==========================="
ok "USB              : $DISK  (sector ${SECTOR}B)"
ok "Repair image     : $IMG"
ok "Data partition   : recreate exFAT, keep start @ $P1_START, ~${NEW_P1_GIB} GiB"
ok "SteamOS space    : ~$(( RESERVE_SECTORS * SECTOR /1024/1024/1024 )) GiB in gap before VTOYEFI"
ok "New partitions   : p3 esp, p4 efi-A, p5 rootfs-A, p6 var-A, p7 home (orig PARTUUIDs preserved)"
ok "VTOYEFI (p2)     : untouched"
say "============================================================"
warn "This WIPES the Ventoy data partition ($DISK). Back up any ISOs FIRST."
echo
read -r -p "Type WIPE to proceed, anything else to abort: " CONFIRM
[[ "$CONFIRM" == "WIPE" ]] || die "Aborted by user."

# ------------------------------ execute -------------------------------------
say "Unmounting $DISK..."
diskutil unmountDisk force "$DISK" >/dev/null || die "Could not unmount $DISK"

say "Shrinking + recreating Ventoy data partition (p1)..."
sgdisk -d 1 "$DISK" >/dev/null
sgdisk -n 1:${P1_START}:${NEW_P1_END} -t 1:${P1_TYPE:-0700} -u 1:${P1_UUID} -c 1:"Ventoy" "$DISK" >/dev/null
ok "p1 recreated."

say "Creating SteamOS partitions (cloning type + PARTUUID from image)..."
tgt=3
for s in 1 2 3 4 5; do
    sgdisk -n ${tgt}:0:+${S_SIZE[$s]}s \
           -t ${tgt}:${S_TYPE[$s]} \
           -u ${tgt}:${S_UUID[$s]} \
           -c ${tgt}:"${S_NAME[$s]}" "$DISK" >/dev/null
    ok "p${tgt}  ${S_NAME[$s]}  uuid ${S_UUID[$s]}"
    tgt=$(( tgt + 1 ))
done

sync
say "Re-reading partition table..."
diskutil unmountDisk force "$DISK" >/dev/null 2>&1 || true
for i in $(seq 1 15); do
    [[ -e "${DISK}s7" ]] && break
    sleep 1
done
[[ -e "${DISK}s7" ]] || die "New partitions did not appear. Unplug/replug the USB and re-run (it will resume cleanly)."

say "Formatting new Ventoy data partition as exFAT..."
newfs_exfat -v Ventoy "${RAW}s1" >/dev/null 2>&1 || diskutil eraseVolume ExFAT Ventoy "${DISK}s1" >/dev/null

say "Writing SteamOS partition images (this takes a few minutes; press Ctrl-T for dd progress)..."
tgt=3
for s in 1 2 3 4 5; do
    ok "p${tgt}  <-  source partition ${s}  (${S_NAME[$s]})"
    dd if="${SRCRAW}s${s}" of="${RAW}s${tgt}" bs=4m 2>/dev/null
    tgt=$(( tgt + 1 ))
done
sync
cleanup_src; trap - EXIT

say "Installing Ventoy menu entry, config and theme..."
diskutil mount "${DISK}s1" >/dev/null || die "Could not mount data partition"
MP="$(diskutil info "${DISK}s1" | awk -F: '/Mount Point/{sub(/^ */,"",$2);print $2; exit}')"
[[ -d "$MP" ]] || die "Mount point not found"
mkdir -p "$MP/ventoy/themes"
cp "$ASSETS/ventoy_grub.cfg" "$MP/ventoy/ventoy_grub.cfg"
cp "$ASSETS/ventoy.json"     "$MP/ventoy/ventoy.json"
cp -R "$ASSETS/themes/A-Team" "$MP/ventoy/themes/A-Team"
sync
diskutil unmount "${DISK}s1" >/dev/null || true
ok "Done."

say "=========================================================="
say " SUCCESS - SteamOS added to your Ventoy USB"
say "=========================================================="
ok "Boot the USB (Ventoy), press F6, choose 'SteamOS Repair / Install'."
ok "You can safely eject now:  diskutil eject $DISK"
echo
read -r -p "Press ENTER to exit "
exit 0
