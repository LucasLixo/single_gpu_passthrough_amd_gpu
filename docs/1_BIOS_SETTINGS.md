# BIOS / UEFI Settings

Before touching Linux at all, GPU passthrough needs a few things enabled at
the firmware level. If these are off, the kernel can never see IOMMU groups,
no matter what boot parameters you set later — so this has to be step one.

## Why this matters

Passthrough relies on **IOMMU** (I/O Memory Management Unit) to isolate the
GPU (and its audio device) into its own group, so the hypervisor can hand it
to the VM directly instead of emulating it. IOMMU support exists in the CPU
and chipset, but it ships **disabled** on most boards and has to be turned
on manually in the BIOS/UEFI setup before the OS can use it.

Enabling it in the BIOS is only half the job — the kernel also needs to be
told to use it via boot parameters (`intel_iommu=on` / `amd_iommu=on`,
covered in a separate doc). If IOMMU groups don't show up later, come back
here first and double check these settings actually saved.

## Enabling IOMMU (VT-d / AMD-Vi)

### Intel — this build's CPU (Xeon E5-2680 v4)

Enable both of the following:

| Setting | Also labeled | Purpose |
|---|---|---|
| `Intel VT-x` | "Intel Virtualization Technology", "Virtualization" | Required for KVM |
| `Intel VT-d` | "Virtualization Technology for Directed I/O" | Actually enables IOMMU |

Usually found under `Advanced` → `CPU Configuration`, or on
server/workstation boards (X99/C612 chipset, which is what E5 v4 Xeons run
on) under `Advanced` → `Chipset Configuration` / `System Agent (SA)
Configuration`. Exact menu naming and location varies a lot between
motherboard vendors — if you can't find it under CPU settings, check the
chipset/north bridge section.

### AMD

If you're following this guide on an AMD CPU instead, enable:

| Setting | Purpose | Typical location |
|---|---|---|
| `SVM Mode` | AMD's equivalent of VT-x | `Advanced` → `AMD CBS` (AM4/AM5 boards) |
| `IOMMU` / `AMD-Vi` | Enables device isolation | `Advanced` → `AMD CBS` (AM4/AM5 boards) |

## Above 4G Decoding

Enable **Above 4G Decoding** if your board has it. This lets the firmware
map PCI device memory (BARs) above the 4GB address boundary, which is
commonly needed for the GPU's VRAM aperture to map correctly when it's
handed to the VM with OVMF. This is unrelated to Resizable BAR — the RX 580
(Polaris) doesn't support Resizable BAR at all, but Above 4G Decoding still
matters for a clean passthrough and is safe to leave on either way.

## CSM and Secure Boot

| Setting | Action | Why |
|---|---|---|
| CSM (Compatibility Support Module) | Disable — boot the host in pure UEFI mode | Passthrough uses OVMF (UEFI firmware) for the VM; a host booted in legacy/CSM mode can leave the GPU's ROM in a state that causes problems before the VM even starts |
| Secure Boot | Disable | The [vendor-reset](2_VENDOR_RESET.md) module is built out-of-tree via DKMS and unsigned by default — Secure Boot refuses to load it (or any unsigned kernel module) unless you set up your own MOK (Machine Owner Key) signing |

## Verifying after reboot

Save and exit, then boot back into Linux. A quick sanity check that VT-d /
AMD-Vi actually took effect:

```bash
dmesg | grep -i -e DMAR -e IOMMU
```

You should see DMAR/IOMMU related lines (device remapping, DRHD entries,
etc.). If the command returns nothing, go back into the BIOS and confirm
VT-d/SVM and IOMMU are actually enabled and saved — some boards reset these
toggles after a firmware update.

Note that `/sys/kernel/iommu_groups/` will still be **empty** at this point
even with everything enabled correctly in the BIOS — populating it requires
the matching kernel boot parameter, which is covered next.
