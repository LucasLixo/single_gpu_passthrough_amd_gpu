# Configure Virtual Machine

With libvirt/QEMU installed and configured, this step creates the actual
Windows VM that the GPU will eventually be passed into.

## Download what you need

| Download | Purpose |
|---|---|
| [Windows 10 ISO](https://www.microsoft.com/en-us/software-download/windows10ISO) | The guest OS installer |
| [virtio-win drivers ISO](https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.302-1/) | Windows has no idea what a VirtIO disk or NIC is out of the box — this ISO is what teaches it |

## Create the VM

Open virt-manager and create a new VM from the Windows 10 ISO.

**Leave the VM's name as the default (`win10`).** This isn't cosmetic —
the libvirt hook scripts used later to bind/unbind the GPU when the VM
starts and stops look for a machine named exactly `win10`. Renaming it here
means updating every hook path to match later, so it's simplest to just
leave it alone.

Before finishing the wizard, check **"Customize configuration before
install"** — the next few steps all happen in that customization screen.

## Firmware: UEFI (OVMF)

In the Overview section, set **Firmware** to a UEFI option.

Older guides point at `/usr/share/edk2-ovmf/x64/OVMF_CODE.fd` or
`/usr/share/edk2/x64/OVMF_CODE.fd` — on current Arch/Manjaro, **neither of
these exact filenames exists**. The `edk2-ovmf` package now ships:

```
/usr/share/edk2/x64/OVMF_CODE.4m.fd
/usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd   # Secure Boot variant
```

If the Firmware field is a dropdown, just pick the entry that reads
something like `UEFI x86_64: /usr/share/edk2/x64/OVMF_CODE.4m.fd`. If
you're browsing for the file manually, point it at that path instead.

If `/usr/share/edk2/` doesn't exist on your system at all, the firmware
package likely failed to install — fix it with:

```bash
sudo pacman -S --needed edk2-ovmf
```

then close and reopen virt-manager so it picks up the new files.

## CPU configuration: host-passthrough

Uncheck **"Copy host CPU configuration"** and set the CPU model to
**`host-passthrough`** manually instead. This exposes the guest to your
real CPU's full feature set and exact model string, rather than a generic
emulated model — it's both a performance win and avoids compatibility
issues some games/anti-cheat have with a masked/generic CPU ID.

## Add the virtio-win driver ISO

Still in the customization screen:

1. Click **Add Hardware** → **Storage**.
2. Select **"Select or create custom storage"** → **Manage...** → **Browse
   Local**, and pick the `virtio-win.iso` you downloaded.
3. Set **Device type** to **CDROM device**.
4. Leave **Bus type** as **SATA** or **IDE** — do **not** pick VirtIO for
   this drive, it needs to be readable by Windows before any VirtIO driver
   is loaded.
5. Click **Finish**.

## Network and disk: switch to VirtIO

Two devices need their model changed to VirtIO — and only these two:

| Device | Field | Value |
|---|---|---|
| Network Interface | Device model | `virtio` |
| Main hard disk (the one Windows will install onto) | Disk Bus | `VirtIO` |

**Leave both CD-ROM drives (the Windows installer ISO and the virtio-win
ISO) on SATA/IDE.** If you switch the CD-ROMs to VirtIO too, Windows won't
be able to read either disc at all — it has no VirtIO driver loaded yet at
that point, which is exactly the chicken-and-egg problem the driver ISO is
there to solve.

## Sizing the system disk

Don't overthink the size here — it can be grown later. With the VM off:

```bash
sudo qemu-img resize /path/to/win10.qcow2 +20G
```

Then, inside Windows, open Disk Management and **Extend Volume** on `C:` to
claim the newly added space. Growing is easy and safe; shrinking a virtual
disk after the fact is complex and risky, so err on the smaller side and
extend as needed rather than guessing high up front.

This system disk is meant for Windows and your applications — a large,
separate game library disk (with its own sparse-file/VirtIO tuning, since
plain shared folders don't play well with Steam or anti-cheat) is its own
topic, covered separately.

## Installing Windows: loading the virtio driver

Boot the VM into the Windows installer. When it says it **can't find any
disk to install to**, click **Load driver**, browse to the virtio-win CD,
and load the driver from:

```
viostor\win10\amd64
```

Once the disk shows up, continue the install normally from there.

## Finish the full install before touching the GPU

Everything from here through the rest of Windows setup (OOBE, first boot,
desktop) still runs on the **emulated** display virt-manager created by
default — a QXL video device shown over Spice. That's expected: it's what
lets you actually see and click through the installer in the first place.
The GPU isn't involved yet, and shouldn't be until Windows is fully up and
running.

Once you're at the desktop:

1. Run the virtio-win guest-tools installer from the same ISO
   (`virtio-win-gt-x64.msi`, in its root folder) to install the rest of the
   VirtIO drivers — network, balloon, and so on — not just the storage
   driver used during setup.
2. Confirm networking actually works (whichever of NAT or the
   [bridge](7_NETWORK_BRIDGE.md) you're using).
3. Optional but recommended: enable Remote Desktop inside Windows
   (**Settings → System → Remote Desktop**) as a fallback way back into the
   VM. The next step removes the emulated display entirely — if GPU
   passthrough doesn't come up cleanly on the first try, RDP is the only
   way to see what's wrong without redoing this whole install.

Only move on to [Prepare vBIOS & GPU XML](8_PREPARE_VBIOS.md) once all of
that is confirmed working — that's the step that removes the emulated
display and hands the GPU to the VM instead.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Firmware dropdown is empty / OVMF files not found | `edk2-ovmf` isn't installed correctly — run `sudo pacman -S --needed edk2-ovmf` and restart virt-manager |
| Windows installer can't see the virtio-win CD at all | Double-check its Bus type is SATA or IDE, not VirtIO |
| VM got renamed by mistake | Rename it back to `win10` before setting up the hook scripts later, to avoid editing every hook path |
| Installer still can't find a disk after loading the driver | Confirm you loaded the driver from the `amd64` (not `x86`) folder matching your Windows edition, and that the main disk's Bus type is actually set to VirtIO |
