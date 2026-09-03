# Boot Parameters (GRUB)

With [VT-d/AMD-Vi enabled in the BIOS](1_BIOS_SETTINGS.md#enabling-iommu-vt-d--amd-vi),
the firmware side is done — but the kernel still needs to be told to
actually use IOMMU. That's done with a boot parameter, which for GRUB means
editing `/etc/default/grub`.

## Why you need this

Enabling VT-d/AMD-Vi in the BIOS only makes IOMMU *available*. The kernel
won't turn on device isolation, and `/sys/kernel/iommu_groups/` will stay
empty, until you pass `intel_iommu=on` (or `amd_iommu=on`) plus `iommu=pt`
on the kernel command line.

## Edit /etc/default/grub

```bash
sudo nano /etc/default/grub
```

Find the `GRUB_CMDLINE_LINUX_DEFAULT` line and add the parameter for your
CPU vendor inside the quotes.

### Intel — this build's CPU (Xeon E5-2680 v4)

```
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash intel_iommu=on iommu=pt"
```

### AMD

```
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash amd_iommu=on iommu=pt"
```

`iommu=pt` puts non-passthrough devices in "passthrough mode" so the host
doesn't pay the translation overhead for hardware you're not virtualizing —
you want this regardless of CPU vendor.

## A parameter to avoid: video=efifb:off

Some guides (including the upstream tutorial this project is based on)
suggest also adding `video=efifb:off`, meant to help with black-screen
issues when the VM grabs the GPU. Two things worth knowing before you add
it:

- It's easy to typo — `video=efif:off` (missing the `b`) is a silent no-op,
  the kernel just ignores the unknown parameter.
- On a **single-GPU** setup like this one, disabling the EFI framebuffer
  disables your only display output from the moment the kernel boots, until
  whatever graphical session takes over — meaning a black screen on every
  boot, with no console visible in between. The libvirt hook scripts
  (covered in a later doc) already handle detaching/reattaching the GPU
  driver dynamically when the VM starts and stops, so this flag isn't
  actually needed to make passthrough work.

**Recommendation:** leave `video=efifb:off` out entirely. Only consider it
later, as a targeted fix, if you run into a specific black-screen problem
that traces back to the EFI framebuffer.

## Optional flags

`disable_idle_d3=1` is sometimes suggested alongside the IOMMU parameters
to help with GPUs that fail to wake up cleanly after being idle (stuck in a
D3cold power state). It's optional and situational — not required for a
working setup, but harmless to add if you hit that specific symptom later:

```
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash intel_iommu=on iommu=pt disable_idle_d3=1"
```

## Applying the change (update-grub)

Editing the file alone does nothing — GRUB reads a generated `grub.cfg`,
not `/etc/default/grub` directly. On Manjaro:

```bash
sudo update-grub
```

On vanilla Arch Linux, which doesn't ship the `update-grub` wrapper, use
the underlying command instead:

```bash
sudo grub-mkconfig -o /boot/grub/grub.cfg
```

Then reboot for the new command line to take effect:

```bash
sudo reboot
```

## systemd-boot (alternative)

If your system boots with systemd-boot instead of GRUB, there's no
`/etc/default/grub` — edit your loader entry directly, e.g.
`/boot/loader/entries/<your-entry>.conf` (list them with
`ls /boot/loader/entries/` if you're not sure of the name), and append the
same parameters to the `options` line. This path wasn't exercised on this
particular build (GRUB was used throughout), so double-check against the
[Arch Wiki](https://wiki.archlinux.org/title/systemd-boot) if you go this
route.

## Verifying it worked

After rebooting, check for DMAR/IOMMU related lines:

```bash
dmesg | grep -i -e DMAR -e IOMMU
```

Careful with this one: DMAR lines can show up here purely because the BIOS
exposes the ACPI DMAR table (i.e. VT-d is enabled in firmware) — **even
before** the kernel parameter is set correctly. It's not proof the kernel
parameter took effect.

The real check is whether IOMMU groups actually got populated:

```bash
ls /sys/kernel/iommu_groups/
```

If this lists numbered directories (`0`, `1`, `2`, ...), the kernel is
using IOMMU and you're ready to move on. If it's empty, the boot parameter
isn't active yet — see troubleshooting below. Enumerating which PCI devices
landed in which group (to confirm your GPU is properly isolated) is covered
in the next doc.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `/sys/kernel/iommu_groups/` exists but is empty, even though `dmesg` shows DMAR lines | BIOS side is fine, but the kernel parameter isn't active. Re-check `GRUB_CMDLINE_LINUX_DEFAULT` in `/etc/default/grub` for typos, re-run `sudo update-grub`, and reboot — editing the file alone changes nothing without that step |
| Typo'd `video=efif:off` | Correct name is `video=efifb:off`, but per above it's better to just leave this flag out on a single-GPU setup |
| Looking for `/usr/kernel/` | The correct path is always `/sys/kernel/` — `/usr/kernel/` doesn't exist |
