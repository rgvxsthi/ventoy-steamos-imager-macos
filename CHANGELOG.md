# Changelog

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
