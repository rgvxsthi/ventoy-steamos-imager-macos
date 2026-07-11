# Changelog

## v1.2.0
- Leave the Ventoy data partition mounted at the end (was ejected) so more
  ISOs can be added right away; success message points to the mount path.

## v1.1.1
- Fix "No external USB disks found": macOS whole-disk info has no `Internal`
  field; detect via `Device Location: External` + `Virtual: No` (excludes
  disk images / simulators).

## v1.1.0
- Interactive macOS UI: double-clickable `.command`, native dialogs (osascript)
  for choosing the repair image and USB and for confirmations; disk progress
  shown in Terminal. Terminal-menu fallback when run headless.

## v1.0.0
- Initial macOS fork of the Linux Ventoy SteamOS Repair Add-on.
- Runs entirely on macOS (diskutil / hdiutil / sgdisk / newfs_exfat).
- **Boot-chain fix:** SteamOS partitions cloned with original PARTUUIDs and
  type GUIDs preserved, so `steamenv` locates rootfs/var/efi and SteamOS boots
  instead of hanging after the countdown.
- Frees space by recreating the exFAT data partition smaller (macOS can't
  resize exFAT in place); VTOYEFI + Ventoy boot code left untouched.
- Auto-installs sgdisk via Homebrew, checks latest Ventoy version, validates
  target is an external Ventoy USB, requires typed WIPE confirmation.
- Reserve size default 10 GiB (auto-bumps if the image is larger).
