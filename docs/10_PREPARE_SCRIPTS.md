# Preparation for Our Scripts

This step wires up the libvirt hook scripts that actually flip the GPU
between host and guest — detaching it from `amdgpu` right before the VM
starts, and handing it back when the VM shuts down. The scripts referenced
below are the **actual, currently-running scripts from this build**,
checked into this repo at [`tools/hooks/`](../tools/hooks/) — not the
simpler starter versions from the original upstream guide.

## How the hook system works

libvirt calls a single dispatcher script named exactly `qemu` for every VM
lifecycle event. That dispatcher then looks for per-VM scripts under a
matching `qemu.d/<vm-name>/<hook-name>/<state-name>/` path:

| Path | Purpose |
|---|---|
| [`tools/hooks/qemu`](../tools/hooks/qemu) | Dispatcher — finds and runs the right per-VM script for the given lifecycle event |
| [`tools/hooks/kvm.conf`](../tools/hooks/kvm.conf) | Shared config — this build's GPU PCI IDs, sourced by both scripts below |
| [`tools/hooks/qemu.d/win10/prepare/begin/start.sh`](../tools/hooks/qemu.d/win10/prepare/begin/start.sh) | Runs right before the VM starts — detaches the GPU from the host |
| [`tools/hooks/qemu.d/win10/release/end/revert.sh`](../tools/hooks/qemu.d/win10/release/end/revert.sh) | Runs after the VM shuts down — gives the GPU back to the host |

The dispatcher resolves its target path using the VM's own name
(`$GUEST_NAME`) — this is the actual reason the VM has to be named exactly
`win10`, as flagged back in
[Configure Virtual Machine](6_CONFIGURE_VM.md#create-the-vm).

## Install the scripts

Run from the root of this repo:

```bash
sudo cp -r tools/hooks/. /etc/libvirt/hooks/
sudo chmod +x /etc/libvirt/hooks/qemu \
              /etc/libvirt/hooks/qemu.d/win10/prepare/begin/start.sh \
              /etc/libvirt/hooks/qemu.d/win10/release/end/revert.sh
sudo systemctl restart libvirtd
```

## Script permissions

The `chmod +x` in the install command above isn't optional busywork — the
dispatcher itself decides whether to run a hook based on one condition,
straight from [`tools/hooks/qemu`](../tools/hooks/qemu):

```bash
if [ -f "$HOOKPATH" ] && [ -s "$HOOKPATH" ] && [ -x "$HOOKPATH" ]; then
```

If a hook script isn't executable, that check is simply false — the
dispatcher moves on silently, no error, no log line. The VM starts or stops
exactly as if the hook didn't exist at all, which makes a missing `+x` one
of the more confusing failure modes here: nothing looks broken until you
notice the GPU never actually detached.

| File | Needs `+x`? | Why |
|---|---|---|
| `qemu` | Yes | Executed directly by libvirtd for every VM lifecycle event |
| `start.sh` / `revert.sh` | Yes | Found and executed by the dispatcher via that same `-x` test |
| `kvm.conf` | No | Only ever `source`d by the other two scripts, never executed directly — `chmod +x` on it has no effect either way |

Confirm the bits actually landed before testing:

```bash
ls -l /etc/libvirt/hooks/qemu /etc/libvirt/hooks/qemu.d/win10/*/*/*.sh
```

Every line should show `rwxr-xr-x` (or at least an `x` for the owner).

## kvm.conf — your GPU's PCI IDs

```
VIRSH_GPU_VIDEO=pci_0000_03_00_0
VIRSH_GPU_AUDIO=pci_0000_03_00_1
```

This is libvirt's node-device naming, not the `03:00.0` PCI address format
— convert with the pattern `pci_0000_<bus>_<slot>_<function>`. Replace both
lines with your own GPU's IDs, found with the IOMMU groups script from
[Prepare vBIOS & GPU XML](8_PREPARE_VBIOS.md#finding-your-gpus-pci-ids).

## start.sh — what happens right before the VM boots

| Step | What it does | Why |
|---|---|---|
| Logs to `/var/log/vfio-start.log` | `exec > >(tee -a ...)` | Every run's output is captured, not just what scrolled by in a terminal — the first place to check when something breaks |
| Stops the display manager, then terminates every user session | `systemctl stop display-manager` + `loginctl terminate-user` for each logged-in UID ≥ 1000 | Stopping the display manager alone isn't enough on Wayland/Plasma — session processes like `kwin_wayland` and `plasmashell` run outside `sddm.service` and keep `/dev/dri/*` open until the user session itself is terminated |
| Waits for `/dev/dri` and `/dev/kfd` to free up | polls with `fuser` for up to 30s | Covers render-node holders (e.g. Chromium/Electron processes) and compute/ROCm users, not just the primary display handle |
| Releases the console framebuffer, if bound | writes `0` to `/sys/class/vtconsole/vtconX/bind` | Only matters if `fbcon` grabbed the console; on this kernel's deferred takeover it's usually already a no-op |
| Forces the video function's `reset_method` to `device_specific` | `modprobe vendor_reset` then `echo device_specific > .../reset_method` | The kernel decides `reset_method` during PCI enumeration, before this hook ever runs — module load order alone can't fix it. Writing to it forces a re-probe the vendor-reset hook actually answers. Without this, the VM's *second* boot hangs — see [Second VM Boot Hangs (GPU Reset)](14_GPU_RESET_ON_SECOND_BOOT.md) |
| Loads `vfio`, `vfio_pci`, `vfio_iommu_type1` | `modprobe` | These must exist *before* the detach — `vfio-pci` is the driver about to claim the device |
| Detaches the GPU and its audio function | `virsh nodedev-detach` | Unbinds the PCI devices from `amdgpu`/`snd_hda_intel` without unloading either kernel module |
| Verifies the driver actually changed | polls the device's real driver binding against `vfio-pci` for up to 10s | `amdgpu` still being loaded says nothing about whether the *device* detached cleanly — if it never lands on `vfio-pci`, the script rolls back and reattaches everything instead of leaving the host half-broken |

`start.sh` also ships with a commented-out `confine_host()` block that pins
the host's own processes off the VM's reserved cores while it runs — that's
CPU topology/pinning territory, covered separately in
[CPU Topology](11_CPU_TOPOLOGY.md#dynamically-confine-the-host-while-the-vm-runs-optional).

Deliberately **not** done: `modprobe -r amdgpu`. The module holds an
internal framebuffer (`amdgpudrmfb`) reference that doesn't drop even with
nothing in userspace holding `/dev/dri`, so unloading it outright was
unreliable. Detaching just the PCI *device* via `nodedev-detach`, with the
module still resident, is what actually works.

## revert.sh — what happens after the VM shuts down

| Step | What it does | Why |
|---|---|---|
| Logs to `/var/log/vfio-revert.log` | same as `start.sh` | Same reasoning as above |
| Reattaches the GPU and audio | `virsh nodedev-reattach` | Gives the PCI devices back to whatever driver claims them — `amdgpu` was never unloaded, so this just re-binds |
| Unloads the vfio modules | `modprobe -r vfio_pci vfio_pci_core vfio_iommu_type1 vfio` | Cleans up now that nothing needs them |
| Reloads `amdgpu` / `snd_hda_intel` as a safety net | `modprobe amdgpu` / `modprobe snd_hda_intel` | In case either module wasn't actually resident anymore |
| Waits for `/dev/dri/card*` to reappear | polls for up to 20s | The card can re-register as `card1` instead of `card0` — the script deliberately doesn't hardcode a minor number |
| Rebinds the console framebuffer | writes `1` to the matching `vtconX/bind` | Mirror of the unbind in `start.sh` |
| Starts the display manager | `systemctl start display-manager` | Hands the desktop back |

`revert.sh` similarly ships with its matching CPU-restore lines commented
out at the end — see [CPU Topology](11_CPU_TOPOLOGY.md#dynamically-confine-the-host-while-the-vm-runs-optional)
if you want to re-enable that pairing.

## Customize for your own hardware

| What to change | File | Notes |
|---|---|---|
| GPU PCI IDs | `kvm.conf` | Find yours with the IOMMU groups script — see [Finding your GPU's PCI IDs](8_PREPARE_VBIOS.md#finding-your-gpus-pci-ids) |
| VM name in the `qemu.d/` path | directory structure | Only needed if you didn't keep the VM named `win10` |
| CPU pinning / core ranges | commented out in `start.sh`/`revert.sh` | Its own topic — see [CPU Topology](11_CPU_TOPOLOGY.md) |

## Troubleshooting

| Symptom | Fix |
|---|---|
| Hook doesn't run at all | Confirm the VM is actually named `win10` (the dispatcher resolves its path from the VM name), and that `/etc/libvirt/hooks/qemu` is executable |
| VM start hangs or rolls back with a `nodedev-detach` failure | Something still holds the GPU — check `fuser /dev/dri/* /dev/kfd` and confirm no other display session is running |
| Display doesn't come back after shutting down the VM | Check `/var/log/vfio-revert.log` — usually `/dev/dri/card*` took longer than the poll window to reappear, or `amdgpu`/`snd_hda_intel` didn't reload |
| Host feels sluggish while the VM is running | Only expected if you re-enabled the commented-out `confine_host` block — see [CPU Topology](11_CPU_TOPOLOGY.md#dynamically-confine-the-host-while-the-vm-runs-optional) |
