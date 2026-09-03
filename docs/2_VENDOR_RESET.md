# Vendor Reset

## Why you need it

When you pass a GPU through to a virtual machine, the VM needs to be able to
fully reset the card every time it starts, restarts, or shuts down. Without a
proper reset, the GPU is left in whatever state the previous session left it
in, and the next boot of the VM will usually just hang on a black screen or
crash with Xid/AER errors.

Most GPUs can reset themselves cleanly with a standard **FLR** (Function
Level Reset) or a PCI bus reset. Some AMD GPUs, however — including the
Polaris family (RX 470/480/570/580/590) used in this guide — do **not**
reset correctly with those standard methods. Restarting a VM a second time
without power-cycling the whole host will leave the GPU dead until a full
reboot.

[vendor-reset](https://github.com/gnif/vendor-reset) is a small out-of-tree
kernel module that implements the correct (and often undocumented/complex)
reset sequence for these cards, so the GPU can be handed back and forth
between the host and the VM reliably.

## How it works

The module hooks `pci_dev_specific_reset` via `ftrace`, so it does **not**
require patching or rebuilding the kernel. Loading the module is enough to
enable the correct reset routine for any supported card.

## Kernel requirements

Make sure your kernel has the following options enabled (stock Arch/Manjaro
kernels already ship with these):

```
CONFIG_FTRACE=y
CONFIG_KPROBES=y
CONFIG_PCI_QUIRKS=y
CONFIG_KALLSYMS=y
CONFIG_KALLSYMS_ALL=y
CONFIG_FUNCTION_TRACER=y
```

### Verify with

```sh
# Optional
sudo modprobe configs

zcat /proc/config.gz | grep -E "CONFIG_FTRACE|CONFIG_KPROBES|CONFIG_PCI_QUIRKS|CONFIG_KALLSYMS|CONFIG_FUNCTION_TRACER"
```

## Supported devices

| Vendor | Family     | Common Name(s)                    |
|--------|------------|------------------------------------|
| AMD    | Polaris 10 | **RX 470, 480, 570, 580, 590**    |
| AMD    | Polaris 11 | RX 460, 560                        |
| AMD    | Polaris 12 | RX 540, 550                        |
| AMD    | Vega 10    | Vega 56/64/FE                      |
| AMD    | Vega 20    | Radeon VII                         |
| AMD    | Vega 20    | Instinct MI100                     |
| AMD    | Navi 10    | 5600XT, 5700, 5700XT               |
| AMD    | Navi 10    | 680M Rembrandt                     |
| AMD    | Navi 12    | Pro 5600M                          |
| AMD    | Navi 14    | Pro 5300, RX 5300, 5500XT          |

The RX 580 used throughout this tutorial is a Polaris 10 card, so it is
directly covered by this module.

## Installing on Arch / Manjaro

### Option 1 — AUR package (recommended)

```bash
yay -S vendor-reset-dkms
```

> **Note:** `vendor-reset-dkms-git` does **not** exist in the AUR — trying to
> install it fails with `error: target not found`. The correct (and only)
> package name is `vendor-reset-dkms`.

### Option 2 — Build manually with DKMS

If the AUR package is unavailable, or you prefer building from source:

```bash
# 1. Install build dependencies
sudo pacman -S --needed dkms linux-headers git base-devel

# 2. Clone the official repository
git clone https://github.com/gnif/vendor-reset.git
cd vendor-reset

# 3. Register and build the module with DKMS
sudo dkms install .
```

## Loading the module

### Load it for the current session

```bash
sudo modprobe vendor-reset
```

### Make it persistent across reboots

```bash
echo "vendor-reset" | sudo tee /etc/modules-load.d/vendor-reset.conf
```

### Load it early, before the GPU driver

This is the step that actually matters: `vendor-reset` **must** be loaded
before `amdgpu` binds to the card. If the kernel's default (broken) reset
runs first, the GPU is left in a state this module can no longer recover
from. On Arch/Manjaro (which use `mkinitcpio`), force the load order by
adding the module to your initramfs config:

```bash
sudo nano /etc/mkinitcpio.conf
```

Find the `MODULES=(...)` line and add `vendor-reset` **before** `amdgpu`:

```
MODULES=(vendor-reset amdgpu)
```

Then regenerate the initramfs for every installed kernel:

```bash
sudo mkinitcpio -P
```

Reboot afterwards for the new initramfs to take effect.

## Verifying it's active

```bash
lsmod | grep vendor_reset
```

If this prints a line containing `vendor_reset`, the module is loaded.

## A note on recent kernels

Some claims float around that recent kernels integrate native reset
handling for AMD ASICs directly into `amdgpu`, making `vendor-reset`
unnecessary. **Confirmed false for Polaris on this build:** on kernel
6.18.45 with an RX 580 (Polaris 10), `cat /sys/bus/pci/devices/<gpu>/reset_method`
still reports `bus` with no external module loaded — nothing native
provides `device_specific` for this card. The external module is still
required, full stop. Install and load it regardless of what kernel version
you're on.

Loading the module is also **not the whole fix** by itself — see
[Second VM Boot Hangs (GPU Reset)](14_GPU_RESET_ON_SECOND_BOOT.md) if the
first VM boot works but the second one hangs or black-screens.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `error: target not found: vendor-reset-dkms-git` | That package name doesn't exist in the AUR. Use `vendor-reset-dkms` (Option 1) or build manually (Option 2) |
| VM boots fine the first time, but hangs/black-screens on a second start | Module load order is only part of it — the real fix is writing `device_specific` to the GPU's `reset_method` from the start hook. See [Second VM Boot Hangs (GPU Reset)](14_GPU_RESET_ON_SECOND_BOOT.md) for the full diagnosis and fix |
| `lsmod \| grep vendor_reset` returns nothing after reboot | Confirm `/etc/modules-load.d/vendor-reset.conf` exists and contains `vendor-reset`, and that DKMS actually built the module for your currently running kernel (`dkms status`) |

## References

- [gnif/vendor-reset](https://github.com/gnif/vendor-reset) — upstream
  project and source of the module description/requirements above.
