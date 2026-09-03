# Prepare vBIOS & GPU XML

With Windows fully installed and the VirtIO drivers in place (from
[Configure Virtual Machine](6_CONFIGURE_VM.md#finish-the-full-install-before-touching-the-gpu)),
this step hands the GPU to the VM for real: removing the emulated display
that got you through setup, dumping a vBIOS for the video function, and
wiring correctly-formed `<hostdev>` entries for the GPU and its HDMI audio
function.

## Remove the emulated display

With the VM shut down, open its details in virt-manager and remove the two
devices that displayed the installer up until now:

1. Select **Video QXL** in the device list → **Remove**.
2. Select **Display Spice** → **Remove**.

Do this in the same sitting as the hostdev changes further down this page.
With the emulated display gone and the GPU not wired in yet, the VM
temporarily has **no display device at all** — that's fine as long as you
finish adding the GPU hostdev before booting again. Don't reboot the VM in
that in-between state expecting to see anything; if you need to check on
it before finishing, RDP (set up in
[Configure Virtual Machine](6_CONFIGURE_VM.md#finish-the-full-install-before-touching-the-gpu))
is your way in.

## Why you need a vBIOS dump

In a proper multi-GPU passthrough, the passed-through card has never been
initialized by the host, so it can POST from its own firmware inside the
VM. In a **single-GPU** setup, the host already initialized the card to
show your desktop before the VM ever starts — so the card needs a copy of
its own vBIOS handed back to it to fake that cold-boot re-init. That's what
`<rom file="...">` provides in the VM's XML.

## Dumping the vBIOS

### Option 1 — Download from TechPowerUp (recommended)

The simplest and safest option — no dumping tools, no risk of reading a
corrupted ROM while the card is in active use.

| Filter | Value |
|---|---|
| Vendor | AMD |
| Model | RX 580 |
| Board Partner | your card's manufacturer (Sapphire, XFX, PowerColor, ...) |

Download from the [TechPowerUp VGA BIOS Collection](https://www.techpowerup.com/vgabios/),
matching your exact board partner, and save it — for this build, as
`rx580.rom`.

### Option 2 — Extract it yourself on Linux

Three ways to pull it directly off the card, roughly in order of
reliability on a **single-GPU** host (where the desktop is actively using
the GPU, which can block ROM reads):

**debugfs**

```bash
sudo mount -t debugfs none /sys/kernel/debug   # skip if already mounted
ls /sys/kernel/debug/dri/                      # find your GPU's index (0, 1, 128...)
sudo cat /sys/kernel/debug/dri/0/amdgpu_vbios > ~/rx580.rom
```

**sysfs** (no debugfs needed)

```bash
lspci | grep -i vga                                          # e.g. 03:00.0
echo 1 | sudo tee /sys/bus/pci/devices/0000:03:00.0/rom
sudo cat /sys/bus/pci/devices/0000:03:00.0/rom > ~/rx580.rom
echo 0 | sudo tee /sys/bus/pci/devices/0000:03:00.0/rom
```

**amdvbflash**

```bash
sudo pacman -S --needed base-devel git libpciaccess pciutils
yay -S amdvbflash --noconfirm
sudo amdvbflash -i             # note the adapter number, usually 0
sudo amdvbflash -s 0 ~/rx580.rom
```

All three can fail with a permission error or a `Failed to read ROM`
message if `amdgpu` is actively driving your display — that's expected on
a single-GPU host. Fall back to Option 1 if that happens.

### Option 3 — Dump via GPU-Z on Windows

If you have a Windows dual-boot on the same machine: open
[GPU-Z](https://www.techpowerup.com/gpuz/), go to the **Graphics Card**
tab, click the save icon next to **BIOS Version**, and save it. Copy the
resulting file over to Linux.

### Verify the dump

```bash
ls -lh ~/rx580.rom
```

Expect roughly **512 KB–1 MB**. If the file is 0 bytes or missing, the
dump failed silently — use Option 1 instead of troubleshooting further.

## Move the file into place & set permissions

```bash
sudo mkdir -p /var/lib/libvirt/vbios
sudo mv ~/rx580.rom /var/lib/libvirt/vbios/rx580.rom
```

Because [Edit Config](5_EDIT_CONFIG.md#etclibvirtqemuconf--run-vms-as-your-user)
already set `qemu.conf` to run VMs as your own user (instead of a dedicated
`libvirt-qemu` system user), ownership just needs to match you — no
special group or world-writable permissions needed:

```bash
sudo chown $USER:$USER /var/lib/libvirt/vbios/rx580.rom
chmod 644 /var/lib/libvirt/vbios/rx580.rom
```

## Finding your GPU's PCI IDs

Before wiring up the XML, find the exact bus:slot.function IDs for your
GPU and its HDMI audio device:

```bash
#!/bin/bash
shopt -s nullglob
for g in /sys/kernel/iommu_groups/*; do
    echo "IOMMU Group ${g##*/}:"
    for d in $g/devices/*; do
        echo -e "\t$(lspci -nns ${d##*/})"
    done
done
```

Look for your GPU's video and audio functions — on real hardware they sit
in the **same PCI slot**, as functions `0` and `1` of the same device, e.g.:

| Function | Example ID |
|---|---|
| Video | `03:00.0` |
| HDMI Audio | `03:00.1` |

## Wire the vBIOS and PCI addresses into the VM XML

```bash
sudo virsh edit win10
```

**Never add `<rom file="...">` to the audio hostdev** — the HDMI audio
function has no vBIOS of its own, only the video function does. Adding it
there is a documented cause of VM boot failures.

The other common mistake: passing the video and audio functions through at
**different** guest PCI addresses. On the real card they're the same slot,
different function — the AMD Windows driver relies on that relationship to
associate HDMI audio with the right video output. Split them across
different guest buses/slots and Windows can't make the connection, so HDMI
audio stays silent even though the device shows up fine.

**What breaks it** — video and audio on different buses:

```xml
<hostdev mode="subsystem" type="pci" managed="yes">
  <source>
    <address domain="0x0000" bus="0x03" slot="0x00" function="0x0"/>
  </source>
  <rom file="/var/lib/libvirt/vbios/rx580.rom"/>
  <address type="pci" domain="0x0000" bus="0x06" slot="0x00" function="0x0"/>
</hostdev>

<hostdev mode="subsystem" type="pci" managed="yes">
  <source>
    <address domain="0x0000" bus="0x03" slot="0x00" function="0x1"/>
  </source>
  <address type="pci" domain="0x0000" bus="0x07" slot="0x00" function="0x0"/>
</hostdev>
```

**The fix** — same guest bus/slot, functions `0x0` and `0x1`,
`multifunction="on"` on the first one, no `<rom>` on the second:

```xml
<hostdev mode="subsystem" type="pci" managed="yes">
  <source>
    <address domain="0x0000" bus="0x03" slot="0x00" function="0x0"/>
  </source>
  <rom file="/var/lib/libvirt/vbios/rx580.rom"/>
  <address type="pci" domain="0x0000" bus="0x06" slot="0x00" function="0x0" multifunction="on"/>
</hostdev>

<hostdev mode="subsystem" type="pci" managed="yes">
  <source>
    <address domain="0x0000" bus="0x03" slot="0x00" function="0x1"/>
  </source>
  <address type="pci" domain="0x0000" bus="0x06" slot="0x00" function="0x1"/>
</hostdev>
```

After applying this, reinstall or restart the AMD driver inside Windows so
it redetects the audio device.

## ROM BAR

In virt-manager's PCI Host Device options for the GPU, leave **ROM BAR**
checked — it needs to stay enabled alongside the `<rom file="...">`
override above (`<rom bar="on"/>` in the XML). Turning it off is a common
source of a GPU that shows up in Device Manager but never actually
initializes.

## No HDMI audio in the guest

If the audio device shows up correctly in the guest but you still get no
sound, it's usually not a passthrough problem:

| Question | Why it matters |
|---|---|
| Is the cable HDMI or DisplayPort? | HDMI audio only travels over HDMI/DisplayPort — analog speakers on the motherboard's own jacks get nothing from it |
| Does your monitor have speakers, or a receiver/soundbar on HDMI? | If neither, there's nowhere for HDMI audio to go, even with a perfect setup |
| Does the device even appear in Windows? | Control Panel → Sound → Playback tab → right-click → **Show Disabled Devices**; enable and set as default if it appears. If nothing shows up at all, install the full AMD Adrenalin driver package inside the VM — it bundles the HDMI audio driver |

**Confirmed fix for this build:** the `virtio-win` drivers loaded during
Windows setup only cover disk/network/etc. — they do **not** include any
GPU or HDMI audio driver. The HDMI audio device stayed silent until the
official AMD driver was installed from
[amd.com](https://www.amd.com/en/support), not just the virtio drivers.
If HDMI audio isn't working, install the real AMD driver package before
troubleshooting anything else.

If you actually want sound through normal speakers instead of an
HDMI-connected display, HDMI audio isn't the right tool. Three options,
roughly by practicality for a single-GPU setup:

| Option | Trade-off |
|---|---|
| Pass through onboard motherboard audio | Only works if it sits alone in its own IOMMU group; the host loses audio entirely |
| USB sound card passthrough | Cheap, simple, doesn't conflict with anything — the most practical option for single-GPU setups |
| Scream / PipeWire network audio | No extra hardware, but adds latency and fiddly setup |

## Troubleshooting

| Symptom | Fix |
|---|---|
| vBIOS dump is 0 bytes or the read fails | `amdgpu` is actively driving your display and blocking the ROM read — this is expected on a single-GPU host. Use [Option 1](#option-1--download-from-techpowerup-recommended) instead |
| `amdvbflash` reports `Failed to read ROM` | Same cause as above — fall back to downloading from TechPowerUp |
| GPU doesn't initialize / VM hangs after adding `<rom file>` | Confirm the `<rom>` tag is only on the **video** hostdev, never on the audio one |
| HDMI audio device visible but silent | Not a passthrough issue — see [No HDMI audio in the guest](#no-hdmi-audio-in-the-guest) above |
