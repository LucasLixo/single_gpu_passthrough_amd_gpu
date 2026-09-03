# Hide That This Is a VM

Some software checks CPUID/DMI signals to detect whether it's running
inside a virtual machine. This is a set of hypervisor-level flags — nothing
installed inside Windows — so they take effect immediately once added to
the VM's XML, no guest-side reinstall needed.

**Shut the VM down before editing**, then apply changes with:

```bash
sudo virsh edit win10
```

Apply one change at a time and test — if the VM stops booting, `sudo virsh
start win10` prints the specific error, which is much easier to trace back
to a single edit than to five at once.

## What this can and can't hide

| | |
|---|---|
| **Won't fool** | Modern kernel-level anti-cheat — Vanguard (Valorant), EasyAntiCheat, and BattlEye in strict mode detect VMs via instruction timing, TSC behavior, and other signals no XML edit can mask. If your goal is playing anti-cheat-protected games, this likely won't work, and attempting to circumvent it can get your account banned |
| **Works well for** | Software that only checks CPUID and DMI — some DRM, corporate/licensing software, benchmarks |

## Hide the KVM CPUID leaf

The single most important change — removes the CPUID bit that announces
"this is a VM" outright. Inside `<features>`:

```xml
<kvm>
  <hidden state="on"/>
</kvm>
```

## Fake the hypervisor vendor ID

Inside `<hyperv>`, add a vendor ID string that isn't recognizable as
QEMU/KVM (any 12-character string works — `AuthenticAMD`, `GenuineIntel`,
or a random string are all common choices):

```xml
<vendor_id state="on" value="AuthenticAMD"/>
```

Combined with hiding Hyper-V enlightenments and enabling SMM, the full
`<features>` block looks like this:

```xml
<hyperv mode="custom">
  <!-- ...your existing hyperv feature flags... -->
  <vendor_id state="on" value="AuthenticAMD"/>
</hyperv>
<kvm>
  <hidden state="on"/>
</kvm>
<smm state="on"/>
```

## Remove obvious virtual hardware tells

A few devices and values in a default libvirt XML are dead giveaways —
none of them exist on real desktop hardware:

| Current | Change to | Why |
|---|---|---|
| `<memballoon model="virtio"/>` | `<memballoon model="none"/>` | Memory ballooning is a virtualization-only mechanism; no real machine has this device |
| `<watchdog model="itco"/>` (or the even more obvious `i6300esb`) | Remove it entirely | Hardware watchdog devices like this don't show up on consumer desktop boards |
| Network MAC starting with `52:54:00` | A normal-looking MAC, e.g. `00:1A:2B:3C:4D:5E` | `52:54:00` is QEMU's reserved OUI prefix — an instant fingerprint for anything that checks it |

## Spoof SMBIOS/DMI to match real hardware

The easiest detection vector of all: by default, DMI reports the vendor as
`QEMU` and the system model as `Standard PC`. Pull your real hardware's
values first:

```bash
sudo dmidecode -t 1 -t 2 -t 0
```

Then wire them into the XML, replacing the example values below with what
`dmidecode` printed for your own board:

```xml
<os firmware="efi">
  <!-- ...existing os config... -->
  <smbios mode="sysinfo"/>
</os>
<sysinfo type="smbios">
  <bios>
    <entry name="vendor">American Megatrends Inc.</entry>
    <entry name="version">5.11</entry>
  </bios>
  <system>
    <entry name="manufacturer">ASUS</entry>
    <entry name="product">X99-A</entry>
    <entry name="version">Rev 1.xx</entry>
    <entry name="serial">Nao-use-sequencial</entry>
  </system>
  <baseBoard>
    <entry name="manufacturer">ASUSTeK COMPUTER INC.</entry>
    <entry name="product">X99-A</entry>
  </baseBoard>
</sysinfo>
```

## Applying changes safely

1. Apply **one** block above at a time.
2. Start the VM and confirm it boots.
3. Move to the next block.

If a change breaks boot, revert just that block rather than guessing which
of several edits caused it.

## Troubleshooting

| Symptom | Fix |
|---|---|
| VM fails to boot after an XML edit | Check the specific error with `sudo virsh start win10` — this only tells you something useful if you changed one block at a time |
| Games with kernel-level anti-cheat still detect the VM (or ban the account) | Expected — see [What this can and can't hide](#what-this-can-and-cant-hide). No XML-level change defeats strict anti-cheat; don't attempt further workarounds for this specific case |
