# Configure Network Bridge

By default the VM sits behind libvirt's `default` NAT network (from
[Install All Tools](4_INSTALL_TOOLS.md#start-the-default-virtual-network)) —
it gets internet access, but the host is doing NAT/port-translation in
between. A **bridge** instead puts the VM directly on your physical LAN, as
if it were its own machine plugged into the router: same subnet, its own
DHCP lease, reachable by IP from every other device on the network (game
consoles, phones, other PCs), not just reachable outbound.

## Why bridge instead of NAT

| | NAT (`default` network) | Bridge (`br0`) |
|---|---|---|
| VM's IP | Private, host-only range | Same subnet as the rest of your LAN |
| Reachable from other LAN devices | No, without manual port forwarding | Yes, directly |
| Typical use case | Just needs outbound internet | LAN gaming, file sharing, RDP from another device, hosting anything on the VM |

## Prerequisites

**Bridging only works over Ethernet** — Wi-Fi cannot bridge, a hard
limitation of 802.11. If your host is on Wi-Fi, skip to
[Wi-Fi hosts](#wi-fi-hosts) below instead of following the steps below as-is.

Package-wise, everything needed was already installed in
[Install All Tools](4_INSTALL_TOOLS.md#network-bridge-prerequisites) —
`libvirt`, `qemu-full`, `dnsmasq`, `iptables-nft`, and NetworkManager
(`nmcli`), which ships by default on Manjaro.

## Find your interface and current profile

```bash
nmcli device status
nmcli connection show
```

Note your Ethernet device name (e.g. `enp7s0`) and the name of its current
connection profile (e.g. `Conexão cabeada 1` / `Wired connection 1`) — both
are used in every command below. Ignore `docker0` and `virbr0` in the
output if present; they don't interfere with this.

Also worth noting your current IP/gateway before touching anything, in
case you need to sanity-check afterward:

```bash
ip -br addr show enp7s0
ip route | grep default
```

## Create the bridge

```bash
sudo nmcli connection add type bridge ifname br0 con-name br0 stp no
sudo nmcli connection modify br0 ipv4.method auto connection.autoconnect yes

sudo nmcli connection add type ethernet ifname enp7s0 controller br0 con-name br0-port-enp7s0
sudo nmcli connection modify br0-port-enp7s0 connection.autoconnect yes
```

Older `nmcli` versions don't recognize `controller` — use `master br0`
instead if you get an error there.

Optional: pin the host to a static IP on the bridge instead of DHCP
(`ipv4.method auto` above):

```bash
sudo nmcli connection modify br0 \
  ipv4.method manual \
  ipv4.addresses 192.168.0.50/24 \
  ipv4.gateway 192.168.0.1 \
  ipv4.dns "192.168.0.1,1.1.1.1"
```

## Switch the active connection over

**Do this on the machine's own keyboard, not over SSH** — the network
drops for a couple of seconds during the switch.

```bash
sudo nmcli connection modify "Conexão cabeada 1" connection.autoconnect no
sudo nmcli connection down "Conexão cabeada 1"
sudo nmcli connection up br0
```

Confirm it came up correctly:

```bash
ip -br addr show br0     # should have an IP
bridge link               # enp7s0 should show as attached to br0
ping -c2 1.1.1.1
```

If the host loses network entirely, revert immediately:

```bash
sudo nmcli connection up "Conexão cabeada 1"
```

## Register the bridge with libvirt

Not strictly required — virt-manager can point straight at `br0` as a
device — but this declares it properly with autostart, matching how the
`default` network already behaves:

```bash
cat > /tmp/br0.xml <<'EOF'
<network>
  <name>br0</name>
  <forward mode="bridge"/>
  <bridge name="br0"/>
</network>
EOF

sudo virsh net-define /tmp/br0.xml
sudo virsh net-start br0
sudo virsh net-autostart br0
sudo virsh net-list --all
```

## Point the VM at the bridge

With the VM off:

```bash
sudo virsh edit win10
```

Replace the `<interface>` block with:

```xml
<interface type="bridge">
  <source bridge="br0"/>
  <model type="virtio"/>
</interface>
```

If Windows shows no network adapter at all after this, the VirtIO NIC
driver (`NetKVM`, from the `virtio-win` ISO) isn't installed — either
install it, or swap `model type="virtio"` for `type="e1000e"`, which
Windows 10 recognizes natively at the cost of some performance.

## Inside Windows

Leave networking on DHCP — it picks up an IP straight from your router, in
the same range as the rest of your LAN. From here the VM behaves like any
other real machine on the network: ping in both directions, file sharing,
RDP, game consoles finding it on the local network, all of it.

## Why this survives a reboot

| Piece | What guarantees it |
|---|---|
| `br0` and `br0-port-enp7s0` | `connection.autoconnect yes` in NetworkManager |
| libvirt's `br0` network | `virsh net-autostart br0` |
| `libvirtd` itself | `systemctl enable libvirtd` (from [Install All Tools](4_INSTALL_TOOLS.md#enable-libvirtd)) |
| The VM's network config | `virsh edit` writes straight to `/etc/libvirt/qemu/win10.xml` |

Nothing here is a runtime-only command (`ip link add`, `brctl`) — those are
exactly what wouldn't survive a reboot.

## Wi-Fi hosts

Real bridging isn't possible over Wi-Fi. Two alternatives instead:

| Option | Trade-off |
|---|---|
| `macvtap` in Bridge mode over `wlan0` | The VM can talk to the rest of the LAN, but not to the host itself |
| Stay on the `default` NAT network | Simplest — no LAN-visibility, but nothing extra to configure |

## Undoing it

```bash
sudo nmcli connection down br0
sudo nmcli connection delete br0 br0-port-enp7s0
sudo nmcli connection modify "Conexão cabeada 1" connection.autoconnect yes
sudo nmcli connection up "Conexão cabeada 1"
sudo virsh net-destroy br0 && sudo virsh net-undefine br0
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| Host loses network entirely after switching to `br0` | Bring the old profile back immediately: `sudo nmcli connection up "Conexão cabeada 1"`, then re-check the `br0`/`br0-port-*` setup for typos in the interface name |
| `nmcli` errors on `controller` | You're on an older `nmcli` — use `master br0` instead |
| VM gets an IP but can't reach the internet | If Docker is installed, `docker0` alters iptables `FORWARD` rules — bridge traffic is L2 and normally isn't affected, but it's the first thing to rule out: `sudo systemctl stop docker` and retest |
| Windows shows no network adapter | The VirtIO NIC driver isn't installed in the guest — install `NetKVM` from the `virtio-win` ISO, or switch the model to `e1000e` as a fallback |
| Using `qemu:///session` instead of `qemu:///system` | The bridge helper needs to be explicitly allowed: `echo 'allow br0' \| sudo tee /etc/qemu/bridge.conf`. Not needed on `qemu:///system` (virt-manager's default, running as root), which is what this build uses |
| Firewall blocks traffic on `br0` | If `firewalld`/`ufw` is active, bridge traffic can be dropped — disable temporarily to confirm before adjusting rules |
