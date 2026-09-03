# Install All Tools

With the BIOS and boot parameters sorted, the next step is installing the
virtualization stack itself: QEMU/KVM, libvirt, and virt-manager.

## Why you need these tools

| Package | Purpose |
|---|---|
| `qemu-full` | The actual hypervisor/emulator that runs the VM (QEMU/KVM) |
| `libvirt` | Daemon and toolset (`virsh`, `libvirtd`) that manages VMs, virtual networks, and storage on top of QEMU |
| `virt-manager` | GUI used to create and configure the VM |
| `dnsmasq`, `iptables-nft`/`nftables`, `ebtables`, `vde2` | Used by libvirt's default NAT network to hand out DHCP leases and route VM traffic |
| `ovmf` | UEFI firmware for the VM — needed to boot with OVMF instead of legacy BIOS (required later for GPU ROM handling) |

## Corrected package list (Arch/Manjaro)

The install command commonly seen in older guides is:

```bash
sudo pacman -S virt-manager qemu vde2 ebtables iptables-nft nftables dnsmasq bridge-utils ovmf
```

This fails today with:

```
erro: alvo não encontrado: bridge-utils
```

`bridge-utils` was discontinued in Arch/Manjaro — its functionality (`brctl`
and friends) was absorbed into `iproute2`, which already ships by default.
Because pacman aborts the **entire** transaction when any target can't be
found, nothing in the list gets installed when this happens — which is also
why `/etc/libvirt/libvirtd.conf` won't exist yet if you hit this error:
libvirt itself was never actually installed.

Corrected command — drop `bridge-utils`, add `libvirt` explicitly instead
of relying on it being pulled in as a dependency, and use `qemu-full`
instead of a bare `qemu` (a bare `qemu` on current Arch/Manjaro prompts you
to choose between `qemu-base`, `qemu-desktop`, and `qemu-full` — just
install the one you actually want directly):

```bash
sudo pacman -S --needed virt-manager qemu-full vde2 ebtables iptables-nft nftables dnsmasq ovmf libvirt
```

## Enable libvirtd

```bash
sudo systemctl enable --now libvirtd
```

This starts the libvirt daemon now and on every future boot — it's what
generates `/etc/libvirt/libvirtd.conf` and the rest of libvirt's config
tree, so run this before trying to edit those files.

## Add yourself to the libvirt group

```bash
sudo usermod -aG libvirt $USER
```

Log out and back in (or reboot) for this to take effect. Skip this and
virt-manager will keep asking for your root password every time you open
it.

## Start the default virtual network

```bash
sudo virsh net-autostart default
sudo virsh net-start default
```

This brings up libvirt's default NAT network, giving VMs internet access
out of the box.

## Network bridge prerequisites

If you plan on giving the VM a real **bridged** connection later — so it
shows up as its own device on your LAN instead of sitting behind NAT — no
extra packages are needed beyond what's already installed above. Bridging
on Manjaro is done through NetworkManager (`nmcli`), which ships by
default, plus the `libvirt`/`qemu-full`/`dnsmasq`/`iptables-nft` packages
you already installed in this step.

The one hard requirement worth flagging now: **bridging only works over
Ethernet**. Wi-Fi cannot bridge, due to a fundamental limitation of 802.11 —
if your host is on Wi-Fi, you'd need `macvtap` instead, which is a
different setup. Full bridge configuration (creating `br0`, moving your
wired connection into it, pointing the VM at it) is covered in
[Configure Network Bridge](7_NETWORK_BRIDGE.md); this step is just making
sure the tools are in place ahead of time.

## Verifying the install

```bash
pacman -Qi libvirt virt-manager qemu-full 2>/dev/null | grep -E "^Name|^Version"
systemctl is-active libvirtd
virsh net-list --all
```

`systemctl is-active libvirtd` should print `active`, and `virsh net-list
--all` should show the `default` network as `active`/`yes` for autostart.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `error: target not found: bridge-utils` | That package no longer exists on Arch/Manjaro. Use the corrected command above, which drops it |
| `/etc/libvirt/libvirtd.conf` doesn't exist | libvirt was never installed because a previous `pacman -S` transaction aborted (see above). Re-run the corrected install command, then `sudo systemctl enable --now libvirtd` to generate the config tree |
| virt-manager keeps asking for a password | Your user was added to the `libvirt` group, but the current login session doesn't have it yet — log out and back in, or reboot |
