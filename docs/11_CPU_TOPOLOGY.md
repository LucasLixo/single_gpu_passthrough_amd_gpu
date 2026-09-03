# CPU Topology

Beyond `host-passthrough` (set back in
[Configure Virtual Machine](6_CONFIGURE_VM.md#cpu-configuration-host-passthrough)),
this build pins each vCPU to a specific host thread and tells the guest the
real hyperthreading layout it's getting — instead of leaving scheduling to
chance. This is its own topic, split out from
[Preparation for Our Scripts](10_PREPARE_SCRIPTS.md), which only covers the
GPU detach/reattach hooks now.

The full, current `<cputune>`/`<cpu>` block from this build's actual VM
definition (`virsh dumpxml win10`) is checked into
[`tools/cpu-topology.xml`](../tools/cpu-topology.xml).

## Why pin CPUs at all

Without pinning, the host scheduler is free to bounce the VM's vCPU threads
across any physical core, including migrating a guest "vCPU pair" that's
supposed to be one physical core's two hyperthreads onto unrelated cores.
That costs cache locality and shows up as inconsistent frame times/stutter
in the guest, even when average CPU usage looks fine. Pinning fixes each
vCPU to one specific host thread, and telling the guest the real
core/thread topology lets Windows' own scheduler make good decisions too
(e.g. not putting two unrelated threads on what it thinks are two
independent cores but are actually hyperthread siblings).

## Map your host's core/thread topology

Find which logical CPUs are hyperthread siblings of which physical core:

```bash
lscpu -e
```

For this build's Xeon E5-2680 v4, logical CPU `N` and `N+14` are always the
two threads of the same physical core. One extra wrinkle worth knowing
about before you assume a clean sequential layout: the physical **core
IDs** skip `7` — they go `0–6`, then `8–14`. That's normal on this Xeon:
the die ships with one core disabled.

## Split host and VM cores

| | Physical cores | Logical CPUs |
|---|---|---|
| Host | 0–4 (5 cores) | `0-4,14-18` (10 threads) |
| VM | 5–13 (9 cores) | `5-13,19-27` (18 threads) |

The VM gets 9 full physical cores (18 threads with HT), leaving 5 cores for
the host to run its own desktop/background load without contending with
the guest.

## Declare the topology in the VM XML

```bash
sudo virsh edit win10
```

Add a `<cputune>` block right after `<vcpu placement="static">18</vcpu>`,
pinning **consecutive vCPU pairs to sibling threads of the same physical
core** — this is what lets Windows see the hyperthreading layout correctly
— and pin the emulator thread itself to the host's reserved cores:

```xml
<cputune>
  <vcpupin vcpu="0"  cpuset="5"/>
  <vcpupin vcpu="1"  cpuset="19"/>
  <vcpupin vcpu="2"  cpuset="6"/>
  <vcpupin vcpu="3"  cpuset="20"/>
  <vcpupin vcpu="4"  cpuset="7"/>
  <vcpupin vcpu="5"  cpuset="21"/>
  <vcpupin vcpu="6"  cpuset="8"/>
  <vcpupin vcpu="7"  cpuset="22"/>
  <vcpupin vcpu="8"  cpuset="9"/>
  <vcpupin vcpu="9"  cpuset="23"/>
  <vcpupin vcpu="10" cpuset="10"/>
  <vcpupin vcpu="11" cpuset="24"/>
  <vcpupin vcpu="12" cpuset="11"/>
  <vcpupin vcpu="13" cpuset="25"/>
  <vcpupin vcpu="14" cpuset="12"/>
  <vcpupin vcpu="15" cpuset="26"/>
  <vcpupin vcpu="16" cpuset="13"/>
  <vcpupin vcpu="17" cpuset="27"/>
  <emulatorpin cpuset="0-4,14-18"/>
</cputune>
```

Then update `<cpu mode="host-passthrough" .../>` to declare the matching
topology instead of leaving it self-closing:

```xml
<cpu mode="host-passthrough" check="none" migratable="on">
  <topology sockets="1" dies="1" clusters="1" cores="9" threads="2"/>
  <feature policy="disable" name="hypervisor"/>
</cpu>
```

Replace every ID above with your own host's mapping from
[Map your host's core/thread topology](#map-your-hosts-corethread-topology)
— these values are specific to this CPU and won't match yours.

## Dynamically confine the host while the VM runs (optional)

Pinning above controls where the *VM's* threads run — it says nothing
about the host's own processes potentially still running on those same
cores. [Preparation for Our Scripts](10_PREPARE_SCRIPTS.md) ships `start.sh`
and `revert.sh` with this piece **commented out**, since it's this doc's
territory, not the GPU-detach hooks'. To also confine the host's own
processes off the VM's cores while it's running, in `start.sh` (before
`systemctl stop display-manager`):

```bash
systemctl set-property --runtime -- system.slice AllowedCPUs=0-4,14-18
systemctl set-property --runtime -- user.slice   AllowedCPUs=0-4,14-18
systemctl set-property --runtime -- init.scope   AllowedCPUs=0-4,14-18
```

And in `revert.sh` (at the end, to undo it):

```bash
systemctl set-property --runtime -- system.slice AllowedCPUs=0-27
systemctl set-property --runtime -- user.slice   AllowedCPUs=0-27
systemctl set-property --runtime -- init.scope   AllowedCPUs=0-27
```

`--runtime` means neither change persists across a reboot — if anything
goes wrong, a reboot alone puts the host back to using every core.

## Verifying

```bash
sudo virsh vcpupin win10
```

confirms the active pinning. With the VM running, `htop` should show host
cores `0-4`/`14-18` mostly idle and the rest under load from the guest.

## Is it worth it?

Worth measuring before investing much further effort: with an RX 580,
GPU-bound games (e.g. Resident Evil 4 Remake) will saturate the GPU well
before the CPU becomes the bottleneck. Pinning mainly improves frame-time
consistency and reduces stutter — it won't raise average FPS if the card
is already the limiting factor. Compare before/after with an in-game
overlay like MangoHud rather than assuming it helped.
