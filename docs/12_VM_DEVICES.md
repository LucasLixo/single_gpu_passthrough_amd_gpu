# Input & Audio Devices

virt-manager's default new-VM template adds an emulated USB tablet and an
`ich9` sound card — reasonable defaults for a plain VM viewed over
SPICE/VNC, but this build's own setup removes the reason for both. Both
edits below go through:

```bash
sudo virsh edit win10
```

## Remove the emulated tablet

The default **USB Tablet** input device reports absolute pointer
coordinates so a SPICE/VNC viewer's cursor lines up without needing to
"grab" the pointer. Once a real USB mouse is passed straight through as a
`<hostdev type="usb">` — common in single-GPU builds, so the pointer just
works without a viewer window at all — the emulated tablet becomes
redundant. Both devices report position to the guest at once, and they
fight each other for cursor control: expect an offset cursor or a visible
double pointer.

Find and delete this block entirely:

```xml
<input type="tablet" bus="usb">
  <address type="usb" bus="0" port="1"/>
</input>
```

## Replace the emulated sound card with PipeWire audio

The emulated `ich9` sound card paired with the default `<audio type="none">`
backend has nowhere to actually send audio — it's either silent or needs
extra plumbing to go anywhere. Simpler: point the guest's audio straight at
the host's PipeWire server instead, no dedicated hardware or extra guest
driver required.

Delete the sound device block:

```xml
<sound model="ich9">
  <audio id="1"/>
  <address type="pci" domain="0x0000" bus="0x00" slot="0x1b" function="0x0"/>
</sound>
```

And replace the `<audio>` element with:

```xml
<audio id="1" type="pipewire" runtimeDir="/run/user/1000"/>
```

`runtimeDir` has to match **your own** user's runtime directory — find your
UID with `id -u` and substitute it in the path (`/run/user/<uid>`). This
only works because [Edit Config](5_EDIT_CONFIG.md#etclibvirtqemuconf--run-vms-as-your-user)
already set QEMU to run as your own user instead of a dedicated system
account — that's what lets it reach your desktop session's PipeWire socket
directly.

## This complements, not replaces, HDMI audio

This is a separate audio path from the GPU's own HDMI audio hostdev
covered in [Prepare vBIOS & GPU XML](8_PREPARE_VBIOS.md#no-hdmi-audio-in-the-guest).
HDMI audio only reaches whatever's connected over HDMI/DisplayPort (a
monitor's speakers, or a receiver/soundbar); this PipeWire-backed device
routes straight to the host's normal audio output — regular speakers or
headphones — with no extra hardware needed, unlike the USB sound card
option mentioned there.

## Verifying

```bash
virsh dumpxml win10 | grep -i tablet    # should print nothing
virsh dumpxml win10 | grep -i audio     # should show type='pipewire'
```

With the VM running and playing something, `wpctl status` (or `pw-top`) on
the host should list the QEMU process as an active PipeWire client.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Cursor still offset or doubled after removing the tablet | Confirm your USB mouse is actually passed through as a `<hostdev type="usb">`, and that the entire `<input type="tablet">` block was removed, not just part of it |
| No audio in the guest after switching to PipeWire | Check `runtimeDir` matches `id -u` for the user QEMU runs as (see [Edit Config](5_EDIT_CONFIG.md#etclibvirtqemuconf--run-vms-as-your-user)), and fully restart the VM (not just edit the XML) after the change |
| `virsh edit` complains about the `<audio>` element | Its `id` must match whatever any remaining `<sound>` device references via `<audio id="X"/>` — with no sound device left in this build, `id="1"` simply stands on its own |
