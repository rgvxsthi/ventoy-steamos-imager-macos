# Ventoy SteamOS Imager for macOS

Adds the **Steam Deck SteamOS recovery/repair image** to an existing
[MActoy](https://github.com/cashcon57/mactoy)-created Ventoy USB — **from macOS** —
and **fixes the boot-chain bug** that made the original Linux add-on hang.

This is a macOS fork of [PizzaGntlemn's `Ventoy_SteamOS-Repair_Addon`](https://github.com/)
(Linux). It does the same job (clone the 5 SteamOS partitions onto the Ventoy USB
and add a custom GRUB entry) but:

- **runs on macOS** (the original is Linux-only), and
- **actually boots** — it preserves each SteamOS partition's original **PARTUUID**
  and type GUID.

## The bug it fixes

The original script created the SteamOS partitions with `sgdisk -n`, which assigns
**random new PARTUUIDs**, then `dd`'d the data in. `dd` preserves the filesystem
UUID (so GRUB's menu shows and the countdown runs), but SteamOS boots via its
`steamenv` GRUB module, which locates `rootfs`/`var`/`efi` **by PARTUUID** (from
`/SteamOS/partsets/*`). Wrong PARTUUIDs → steamenv can't find its partitions →
**hangs right after the countdown**. This is the widely reported
"hangs after selecting SteamOS Repair / Install" issue.

**Fix:** clone each partition with its original PARTUUID and type GUID intact
(`sgdisk -u` / `-t`), read straight from the source image at runtime.

## Requirements

- macOS (Apple Silicon or Intel)
- A Ventoy USB already made with **MActoy** (data partition + `VTOYEFI`)
- [Homebrew](https://brew.sh) + `gptfdisk` — the script offers to `brew install gptfdisk`
- A SteamOS repair image whose filename contains `repair` and ends in `.img`
  (download from Valve's recovery page)
- ~10 GB free reserved on the USB (the script carves this out)

## Why it works differently from the Linux version

macOS **cannot shrink exFAT in place** (`diskutil` refuses). So instead of
shrinking + physically moving partitions, this script **recreates the Ventoy data
partition smaller** — same start sector, same PARTUUID/type, re-formatted exFAT —
and drops the SteamOS partitions into the freed gap before `VTOYEFI`. Ventoy's boot
code (in `VTOYEFI` + reserved sectors) is never touched, so Ventoy keeps working.

⚠️ **This wipes the Ventoy data partition.** Back up any ISOs on it first.

## Usage

```bash
# put the repair image next to the script, e.g.
#   steamdeck-...-repair-....img
cd ventoy-steamos-imager-macos
sudo ./ventoy-steamos-imager.sh
```

Then: pick the USB → review the plan → type `WIPE` to confirm. When it finishes,
boot the USB, press **F6**, and choose **SteamOS Repair / Install**.

## Layout it produces

```
p1  Ventoy    exFAT data (shrunk, ~reserve smaller)   <- recreated
    [ gap: SteamOS partitions ]
p3  esp        EFI system   (orig PARTUUID)
p4  efi-A      FAT /EFI/steamos/grubx64.efi (orig PARTUUID)
p5  rootfs-A   btrfs root   (orig PARTUUID)
p6  var-A      /var         (orig PARTUUID)
p7  home       /home        (orig PARTUUID)
p2  VTOYEFI    Ventoy EFI   <- untouched
```

## Status / caveats

- Script logic is validated; **the actual Steam Deck boot must be tested by you**
  (needs the hardware).
- Only tested against GPT Ventoy USBs. MBR untested.
- If the new partitions don't appear after repartitioning, unplug/replug the USB
  and re-run.

## Credits

- Original Linux add-on: **PizzaGntlemn** (A-Team Digital Solutions)
- Ventoy: **longpanda** — <https://www.ventoy.net>
- MActoy: **cashcon57** — <https://github.com/cashcon57/mactoy>

MIT licensed — see [LICENSE](LICENSE).
