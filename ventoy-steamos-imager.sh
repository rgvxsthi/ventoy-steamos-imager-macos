#!/bin/bash
#
# ============================================================================
#  Ventoy SteamOS Imager for macOS
# ============================================================================
#  Interactive macOS tool: adds the Steam Deck SteamOS recovery/repair image
#  to an EXISTING Ventoy USB (e.g. made with MActoy), with the boot-chain fix
#  the original Linux add-on lacks - SteamOS partitions are cloned with their
#  ORIGINAL PARTUUIDs and type GUIDs preserved, so SteamOS's grub/steamenv can
#  locate rootfs/var/efi and the image actually boots instead of hanging.
#
#  Uses native macOS dialogs (osascript) for picking the image + USB and for
#  confirmations. Disk work runs with sudo; progress prints in Terminal.
#
#  Requires: macOS, Homebrew + gptfdisk (sgdisk).
#  Fork of PizzaG's Ventoy_SteamOS-Repair_Addon (Linux). MIT - see LICENSE.
#  Ventoy (c) longpanda.  MActoy (c) cashcon57.
# ============================================================================

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

APP_VERSION="1.2.0"
TITLE="Ventoy SteamOS Imager"
RESERVE_GIB=10
VENTOY_REF_VERSION="1.1.16"

SCRIPT="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
SELF_DIR="$(dirname "$SCRIPT")"
ASSETS="$SELF_DIR/assets"

# ------------------------------ output --------------------------------------
say() { printf '\n%s\n' "$*"; }
ok()  { printf '  --> %s\n' "$*"; }
warn(){ printf '\n!! %s\n' "$*"; }

# ------------------------------ GUI layer -----------------------------------
GUI=0
[[ "${VSI_NOGUI:-0}" != "1" ]] && osascript -e 'return' >/dev/null 2>&1 && GUI=1

_esc() { printf '%s' "${1//\"/\\\"}"; }

ui_info() {
    if (( GUI )); then
        osascript -e "display dialog \"$(_esc "$1")\" buttons {\"OK\"} default button 1 with title \"$TITLE\" with icon note" >/dev/null 2>&1
    else say "$1"; fi
}
ui_error() {
    if (( GUI )); then
        osascript -e "display dialog \"$(_esc "$1")\" buttons {\"OK\"} default button 1 with title \"$TITLE\" with icon stop" >/dev/null 2>&1
    fi
    printf '\n** ERROR ** --> %s\n' "$1" >&2
}
die() { ui_error "$1"; echo; read -r -p "Press ENTER to exit " _ 2>/dev/null || true; exit 1; }

ui_confirm() {  # $1 message ; 0 = proceed
    if (( GUI )); then
        osascript -e "button returned of (display dialog \"$(_esc "$1")\" buttons {\"Cancel\",\"Continue\"} default button \"Continue\" cancel button \"Cancel\" with title \"$TITLE\")" >/dev/null 2>&1
    else
        read -r -p "$1 [y/N]: " a; [[ "$a" =~ ^[Yy]$ ]]
    fi
}
ui_danger() {  # scary erase confirm ; 0 = proceed
    if (( GUI )); then
        osascript -e "button returned of (display dialog \"$(_esc "$1")\" buttons {\"Cancel\",\"Erase & Install\"} default button \"Cancel\" cancel button \"Cancel\" with title \"$TITLE\" with icon caution)" >/dev/null 2>&1
    else
        local a; read -r -p "Type WIPE to erase and proceed: " a; [[ "$a" == "WIPE" ]]
    fi
}

# --------------------------- dependencies -----------------------------------
have() { command -v "$1" >/dev/null 2>&1; }
ensure_sgdisk() {
    have sgdisk && return
    if (( GUI )); then
        ui_confirm "sgdisk (gptfdisk) is required and not installed. Install it now with Homebrew?" || die "sgdisk required. Run: brew install gptfdisk"
    fi
    have brew || die "Homebrew not found. Install from https://brew.sh then: brew install gptfdisk"
    say "Installing gptfdisk via Homebrew..."
    brew install gptfdisk || die "brew install gptfdisk failed"
    have sgdisk || die "sgdisk still not found after install"
}

check_ventoy_latest() {
    local latest
    latest="$(curl -sL --max-time 12 'https://sourceforge.net/projects/ventoy/rss?path=/' 2>/dev/null \
        | grep -oE 'ventoy-[0-9]+\.[0-9]+\.[0-9]+-linux\.tar\.gz' \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail -1)"
    [[ -n "$latest" ]] && ok "Latest Ventoy online: $latest (verified against $VENTOY_REF_VERSION)"
    ok "MActoy installs/updates Ventoy itself - this tool only adds SteamOS."
}

# sgdisk field readers (need root)
p_type() { sudo sgdisk -i "$2" "$1" | awk -F': ' '/Partition GUID code/{print $2}' | awk '{print $1}'; }
p_uuid() { sudo sgdisk -i "$2" "$1" | awk -F': ' '/Partition unique GUID/{print $2}'; }
p_size() { sudo sgdisk -i "$2" "$1" | awk -F': ' '/Partition size/{print $2}' | awk '{print $1}'; }
p_name() { sudo sgdisk -i "$2" "$1" | sed -n "s/^Partition name: '\(.*\)'/\1/p"; }
p_first(){ sudo sgdisk -i "$2" "$1" | awk -F': ' '/First sector/{print $2}' | awk '{print $1}'; }

# --------------------------- pick repair image ------------------------------
pick_image() {
    local f
    if (( GUI )); then
        f="$(osascript -e 'POSIX path of (choose file with prompt "Select the SteamOS repair .img" of type {"img","public.data"})' 2>/dev/null)"
        [[ -n "$f" && -f "$f" ]] && { IMG="$f"; return; }
    fi
    # fallback: auto-find *repair*.img nearby
    shopt -s nullglob
    local imgs=() c
    for c in "$PWD"/*repair*.img "$SELF_DIR"/*repair*.img; do imgs+=("$c"); done
    shopt -u nullglob
    [[ ${#imgs[@]} -gt 0 ]] || die "No SteamOS repair image selected or found."
    IMG="${imgs[0]}"
    ui_confirm "Use this repair image?\n\n$IMG" || die "No repair image selected."
}

# ------------------------- external disk listing ----------------------------
_ext_disks() {  # emits: /dev/diskN|label
    local d nm sz vt
    for d in $(diskutil list | grep -oE '^/dev/disk[0-9]+'); do
        [[ "$(diskutil info "$d" 2>/dev/null | awk -F: '/Device Location/{gsub(/ /,"",$2);print $2;exit}')" == "External" ]] || continue
        diskutil info "$d" 2>/dev/null | grep -q 'Virtual: *No' || continue
        nm="$(diskutil info "$d" | awk -F: '/Device \/ Media Name/{sub(/^ */,"",$2);print $2;exit}')"
        sz="$(diskutil info "$d" | awk -F: '/Disk Size/{sub(/^ */,"",$2);print $2;exit}' | awk '{print $1" "$2}')"
        if diskutil list "$d" | grep -q VTOYEFI; then vt=" [Ventoy]"; else vt=""; fi
        printf '%s|%s - %s %s%s\n' "$d" "${d#/dev/}" "${nm:-USB}" "$sz" "$vt"
    done
}

pick_disk() {
    local lines=() ids=() labels=() line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        ids+=("${line%%|*}"); labels+=("${line#*|}"); lines+=("$line")
    done < <(_ext_disks)
    [[ ${#ids[@]} -gt 0 ]] || die "No external USB disks found. Plug in your Ventoy USB and retry."

    if (( GUI )); then
        local applelist chosen i
        applelist=""
        for i in "${!labels[@]}"; do
            applelist+="\"$(_esc "${labels[$i]}")\""
            (( i < ${#labels[@]}-1 )) && applelist+=", "
        done
        chosen="$(osascript -e "set r to choose from list {$applelist} with title \"$TITLE\" with prompt \"Select the target Ventoy USB:\" without multiple selections allowed" 2>/dev/null)"
        [[ -z "$chosen" || "$chosen" == "false" ]] && die "No USB selected."
        for i in "${!labels[@]}"; do [[ "${labels[$i]}" == "$chosen" ]] && { DISK="${ids[$i]}"; break; }; done
    else
        local i
        say "External disks:"
        for i in "${!labels[@]}"; do echo "  [$i] ${labels[$i]}"; done
        read -r -p "Select disk number: " i
        DISK="${ids[$i]:-}"
    fi
    [[ -n "${DISK:-}" && -e "$DISK" ]] || die "Invalid disk selection."
}

# ================================ START =====================================
clear
say "=========================================================="
say " $TITLE   v${APP_VERSION}"
say "=========================================================="
check_ventoy_latest

if (( GUI )); then
    ui_confirm "This adds the SteamOS repair image to a Ventoy USB.\n\nYou'll pick the .img and the USB next.\n\nWARNING: the USB's data partition will be ERASED - back up any ISOs first." \
        || { say "Cancelled."; exit 0; }
fi

ensure_sgdisk

# admin rights (password prompt appears in Terminal), kept alive during long dd
say "Administrator access is required for disk operations."
sudo -v || die "Could not obtain administrator rights."
( while true; do sudo -n -v 2>/dev/null; sleep 30; done ) & KEEPALIVE=$!

pick_image
pick_disk

# safety
[[ "$(diskutil info "$DISK" | awk -F: '/Device Location/{gsub(/ /,"",$2);print $2;exit}')" == "External" ]] \
    || die "$DISK is INTERNAL. Refusing."
diskutil list "$DISK" | grep -q VTOYEFI || {
    ui_confirm "$DISK has no VTOYEFI partition - it may not be a Ventoy USB.\nContinue anyway?" || die "Not a Ventoy USB."
}

RAW="${DISK/disk/rdisk}"

# USB geometry
SECTOR="$(diskutil info "$DISK" | awk -F: '/Device Block Size/{print $2}' | grep -oE '[0-9]+' | head -1)"; SECTOR="${SECTOR:-512}"
P1_START="$(p_first "$DISK" 1)"; P1_TYPE="$(p_type "$DISK" 1)"; P1_UUID="$(p_uuid "$DISK" 1)"
P2_START="$(p_first "$DISK" 2)"
[[ -n "$P1_START" && -n "$P2_START" ]] || die "Could not read Ventoy partition geometry."

# source image geometry
say "Reading SteamOS repair image..."
ATTACH_OUT="$(hdiutil attach -nomount -readonly "$IMG")" || die "Failed to attach image."
SRC="$(echo "$ATTACH_OUT" | awk '/GUID_partition_scheme/{print $1; exit}')"
[[ -n "$SRC" ]] || { echo "$ATTACH_OUT"; die "Failed to attach image."; }
SRCRAW="${SRC/disk/rdisk}"
cleanup() { [[ -n "${SRC:-}" ]] && hdiutil detach "$SRC" >/dev/null 2>&1; kill "${KEEPALIVE:-}" 2>/dev/null; }
trap cleanup EXIT

declare -a S_TYPE S_UUID S_SIZE S_NAME; TOTAL_SRC=0
for s in 1 2 3 4 5; do
    S_TYPE[$s]="$(p_type "$SRC" $s)"; S_UUID[$s]="$(p_uuid "$SRC" $s)"
    S_SIZE[$s]="$(p_size "$SRC" $s)"; S_NAME[$s]="$(p_name "$SRC" $s)"
    [[ -n "${S_SIZE[$s]}" ]] || die "Could not read source partition $s (is this a SteamOS repair image?)"
    TOTAL_SRC=$(( TOTAL_SRC + S_SIZE[$s] ))
done

# layout math
RESERVE_SECTORS=$(( RESERVE_GIB * 1024 * 1024 * 1024 / SECTOR ))
NEEDED=$(( TOTAL_SRC + 5 * 2048 + 2048 ))
(( RESERVE_SECTORS < NEEDED )) && RESERVE_SECTORS=$(( ( NEEDED / 2048 + 2 ) * 2048 ))
NEW_P1_END=$(( P2_START - RESERVE_SECTORS - 1 ))
NEW_P1_END=$(( ( (NEW_P1_END + 1) / 2048 ) * 2048 - 1 ))
GAP=$(( P2_START - NEW_P1_END - 1 ))
(( NEW_P1_END > P1_START + 2048 )) || die "Disk too small to carve out SteamOS space."
(( GAP >= NEEDED )) || die "Not enough room before VTOYEFI."
NEW_P1_GIB=$(( (NEW_P1_END - P1_START) * SECTOR / 1024/1024/1024 ))
RES_GIB=$(( RESERVE_SECTORS * SECTOR /1024/1024/1024 ))

PLAN="Target USB : $DISK
Repair image : $(basename "$IMG")

Data partition : recreate exFAT, ~${NEW_P1_GIB} GiB
SteamOS space  : ~${RES_GIB} GiB before VTOYEFI
New partitions : esp, efi-A, rootfs-A, var-A, home (original PARTUUIDs kept)
VTOYEFI        : untouched"

say "===================== PLAN ====================="; printf '%s\n' "$PLAN"; say "================================================"
ui_confirm "$PLAN" || die "Aborted."
ui_danger "FINAL WARNING

The data partition on $DISK will be ERASED and recreated.
Any ISOs on it will be lost.

Proceed?" || die "Aborted."

# ------------------------------ execute -------------------------------------
say "Unmounting $DISK..."; sudo diskutil unmountDisk force "$DISK" >/dev/null || die "Could not unmount $DISK"

say "Shrinking + recreating Ventoy data partition..."
sudo sgdisk -d 1 "$DISK" >/dev/null
sudo sgdisk -n 1:${P1_START}:${NEW_P1_END} -t 1:${P1_TYPE:-0700} -u 1:${P1_UUID} -c 1:"Ventoy" "$DISK" >/dev/null

say "Creating SteamOS partitions (cloning type + PARTUUID)..."
tgt=3
for s in 1 2 3 4 5; do
    sudo sgdisk -n ${tgt}:0:+${S_SIZE[$s]}s -t ${tgt}:${S_TYPE[$s]} -u ${tgt}:${S_UUID[$s]} -c ${tgt}:"${S_NAME[$s]}" "$DISK" >/dev/null
    ok "p${tgt}  ${S_NAME[$s]}  ${S_UUID[$s]}"
    tgt=$(( tgt + 1 ))
done

sync
say "Re-reading partition table..."
sudo diskutil unmountDisk force "$DISK" >/dev/null 2>&1 || true
for i in $(seq 1 15); do [[ -e "${DISK}s7" ]] && break; sleep 1; done
[[ -e "${DISK}s7" ]] || die "New partitions did not appear. Unplug/replug the USB and re-run."

say "Formatting data partition as exFAT..."
sudo newfs_exfat -v Ventoy "${RAW}s1" >/dev/null 2>&1 || sudo diskutil eraseVolume ExFAT Ventoy "${DISK}s1" >/dev/null

say "Writing SteamOS images (minutes; press Ctrl-T for dd progress)..."
tgt=3
for s in 1 2 3 4 5; do
    ok "p${tgt} <- source ${s} (${S_NAME[$s]})"
    sudo dd if="${SRCRAW}s${s}" of="${RAW}s${tgt}" bs=4m 2>/dev/null
    tgt=$(( tgt + 1 ))
done
sync
hdiutil detach "$SRC" >/dev/null 2>&1; SRC=""

say "Installing Ventoy menu entry, config and theme..."
diskutil mount "${DISK}s1" >/dev/null || die "Could not mount data partition"
MP="$(diskutil info "${DISK}s1" | awk -F: '/Mount Point/{sub(/^ */,"",$2);print $2; exit}')"
[[ -d "$MP" ]] || die "Mount point not found"
mkdir -p "$MP/ventoy/themes"
cp "$ASSETS/ventoy_grub.cfg" "$MP/ventoy/ventoy_grub.cfg"
cp "$ASSETS/ventoy.json"     "$MP/ventoy/ventoy.json"
cp -R "$ASSETS/themes/A-Team" "$MP/ventoy/themes/A-Team"
sync
# leave the Ventoy data partition MOUNTED so more ISOs can be added
diskutil mount "${DISK}s1" >/dev/null 2>&1 || true
MP="$(diskutil info "${DISK}s1" | awk -F: '/Mount Point/{sub(/^ */,"",$2);print $2; exit}')"

say "=========================================================="
say " SUCCESS - SteamOS added to your Ventoy USB"
say "=========================================================="
ui_info "Done!\n\nBoot the USB, press F6, and choose 'SteamOS Repair / Install'.\n\nThe Ventoy drive is still mounted at:\n${MP:-/Volumes/Ventoy}\n\nDrag more ISOs there anytime, then eject from Finder when done."
ok "Ventoy drive mounted at: ${MP:-/Volumes/Ventoy}  (add ISOs here)"
ok "Eject when finished:  diskutil eject $DISK"
echo
read -r -p "Press ENTER to exit " _ 2>/dev/null || true
exit 0
