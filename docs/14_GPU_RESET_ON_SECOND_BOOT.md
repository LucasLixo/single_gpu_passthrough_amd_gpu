# Second VM Boot Hangs (GPU Reset)

## Symptom

| | |
|---|---|
| 1st VM boot | Works fine |
| Shutdown | Host returns to Linux normally, `revert.sh` runs through to `REVERT OK` |
| 2nd VM boot | Black screen / hang / dead GPU until the **host** is rebooted |

This is the classic *AMD reset bug* on Polaris cards (RX 470/480/570/580/590)
— exactly the failure [Vendor Reset](2_VENDOR_RESET.md) exists to prevent.
If you're hitting it anyway, the module is very likely installed but not
actually doing its job yet — see below.

## Root cause

Check which reset method the kernel actually picked for the GPU:

```bash
cat /sys/bus/pci/devices/0000:03:00.0/reset_method
```

```
bus
```

`bus` means *secondary bus reset* — exactly the reset Polaris cards don't
survive. The method that actually works is `device_specific`, which is
what `vendor-reset` implements.

And `vendor-reset` **is** working — this isn't an install problem:

```bash
lsmod | grep vendor_reset
journalctl -k -b | grep -i vendor_reset
dkms status
```

```
vendor_reset          163840  0

vendor_reset: loading out-of-tree module taints kernel.
vendor_reset: module verification failed: signature and/or required key missing
vendor_reset_hook: installed          # ← ftrace hook installed successfully

vendor-reset/0.1.1, 6.18.45-1-MANJARO, x86_64: installed
```

The module loads, the hook installs — and `reset_method` still sits on
`bus`.

## Why fixing module load order doesn't fix this by itself

This is the trap. The kernel builds its list of available reset methods in
`pci_init_reset_methods()`, during **PCI enumeration** — which runs in the
kernel proper, before the initramfs is even decompressed:

```
PCI enumeration  →  reset_method decided  →  initramfs  →  modules load
       ↑                                                         ↑
   already over                                    vendor-reset arrives here
```

No module load order puts `device_specific` on that list. By the time
`vendor-reset` loads — even loaded correctly, even before `amdgpu` — the
probe already happened.

The way out is to **write** to `reset_method`. The kernel's
`reset_method_store()` re-probes the method (it calls
`pci_dev_specific_reset` with `PCI_RESET_PROBE`), and *that's* when the
`vendor-reset` ftrace hook answers and the method gets accepted.

## The fix: set reset_method from the hook

[`tools/hooks/qemu.d/win10/prepare/begin/start.sh`](../tools/hooks/qemu.d/win10/prepare/begin/start.sh)
already ships with this block in place — if you installed the scripts from
[Preparation for Our Scripts](10_PREPARE_SCRIPTS.md#install-the-scripts),
you already have it. Added to `start.sh`, right before the
`modprobe vfio*` lines:

```bash
modprobe vendor_reset || true
if echo device_specific > "/sys/bus/pci/devices/$PCI_VIDEO/reset_method" 2>/dev/null; then
    echo "reset_method($PCI_VIDEO) = $(cat "/sys/bus/pci/devices/$PCI_VIDEO/reset_method")"
else
    echo "WARNING: could not set device_specific on $PCI_VIDEO."
    echo "WARNING: current reset_method = $(cat "/sys/bus/pci/devices/$PCI_VIDEO/reset_method" 2>&1)"
    echo "WARNING: the VM should still boot, but the second start may hang."
fi
```

| Why in the hook, not a systemd unit | |
|---|---|
| Timing | `vendor_reset` is already loaded by the time the hook runs — no dependency on boot ordering |
| Idempotent | Rewriting it on every start costs nothing |
| Persistence | The setting lives on `struct pci_dev`, and survives the driver bind/unbind that happens every VM start/stop |
| Fails soft | Only logs a warning — doesn't block the 1st boot, which works fine on `bus` anyway |

Only the video function (`03:00.0`) needs this — the HDMI audio function
(`03:00.1`) resets normally on its own.

### Manual test (confirms it in 2 seconds)

```bash
echo device_specific | sudo tee /sys/bus/pci/devices/0000:03:00.0/reset_method
cat /sys/bus/pci/devices/0000:03:00.0/reset_method
```

| Output | Meaning |
|---|---|
| `device_specific` | The vendor-reset hook answered — this is the fix |
| `Invalid argument` | The hook doesn't catch this device; the problem is something else |

## Secondary fixes worth checking at the same time

### 1. Confirm mkinitcpio -P actually ran

```bash
stat -c '%y  %n' /boot/initramfs-*-x86_64.img /etc/mkinitcpio.conf
```

If the initramfs file is **older** than your last edit to
`mkinitcpio.conf`, adding `vendor-reset` to `MODULES=(...)` there did
nothing — the image on disk was never regenerated. Confirm in the boot log:

```bash
journalctl -k -b | grep -E "amdgpu 0000:03:00.0: initializing|vendor_reset_hook"
```

If `amdgpu` initializes *before* `vendor_reset_hook: installed` shows up,
`vendor-reset` is loading late — via `/etc/modules-load.d/`, well after
udev already bound `amdgpu` — instead of through the initramfs at all.
Fix:

```bash
sudo mkinitcpio -P
sudo reboot
```

This doesn't fix `reset_method` by itself — the kernel already decided it
during PCI enumeration regardless of module order (see above) — but it's
what the vendor-reset project itself recommends, and it avoids the
kernel's broken default reset running before the hook even exists.

### 2. disable_idle_d3=1 in the wrong place

This is a `vfio-pci` **module** parameter, not a kernel boot parameter —
sitting loose on the kernel command line, it's silently ignored:

```bash
cat /proc/cmdline
```

Since `revert.sh` unloads `vfio_pci` on every VM shutdown, the correct
place for it is `modprobe.d`, so it's reapplied every time the module
loads. This repo ships that file at
[`tools/modprobe.d/vfio.conf`](../tools/modprobe.d/vfio.conf):

```bash
sudo cp tools/modprobe.d/vfio.conf /etc/modprobe.d/vfio.conf
```

Verify after starting the VM once:

```bash
cat /sys/module/vfio_pci/parameters/disable_idle_d3   # should read Y
```

`/sys/module/vfio_pci/` only exists while the VM is running —
`revert.sh` unloads the module on shutdown.

### 3. video=efif:off — an old typo, never actually removed

Missing the `b` (`efifb` = EFI framebuffer) — flagged back in
[Boot Parameters](3_BOOT_PARAMETERS.md#a-parameter-to-avoid-videoefifboff),
but easy to forget to actually go back and remove from
`/etc/default/grub`. Being an invalid driver name, the kernel just ignores
it — harmless, but pointless to leave in.

**Don't fix the typo — remove the parameter entirely**, per the reasoning
in Boot Parameters: on a single-GPU host, `video=efifb:off` *working*
means a black screen from the moment the kernel boots, before any
graphical session starts. The libvirt hooks are what detach the GPU at
runtime; this flag was never needed.

```bash
sudo nano /etc/default/grub    # remove video=efif:off entirely
sudo update-grub
```

## Correcting earlier guidance

[Vendor Reset](2_VENDOR_RESET.md#a-note-on-recent-kernels) previously
hedged on whether recent kernels ship native reset handling for Polaris.
On this machine that's settled: **kernel 6.18.45, RX 580 (Polaris 10),
`reset_method` sits on `bus` with no external module loaded** — there is
nothing native providing `device_specific` for this card. The external
`vendor-reset` module (plus the `reset_method` write above) is still
required, full stop.

## Checklist

```bash
# 1. module loaded, hook installed
lsmod | grep vendor_reset
journalctl -k -b | grep vendor_reset_hook

# 2. correct reset method — this is what actually matters
cat /sys/bus/pci/devices/0000:03:00.0/reset_method     # → device_specific

# 3. initramfs newer than your last mkinitcpio.conf edit
stat -c '%y  %n' /boot/initramfs-*-x86_64.img /etc/mkinitcpio.conf

# 4. hook log, on every VM start
grep reset_method /var/log/vfio-start.log
```

The real test isn't the 1st boot — it's booting the VM, shutting it down,
and booting it **again**. That second boot is what proves the fix.

## References

- [gnif/vendor-reset](https://github.com/gnif/vendor-reset)
- [Vendor Reset](2_VENDOR_RESET.md) — its troubleshooting entry for this
  exact symptom previously pointed only at module load order, which is
  incomplete without the `reset_method` piece above.
