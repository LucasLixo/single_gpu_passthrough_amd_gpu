# Edit Config

With [the tools installed](4_INSTALL_TOOLS.md), two config files need small
edits before creating the VM: `libvirtd.conf` (so your regular user can
actually talk to libvirt) and `qemu.conf` (so the VM doesn't run as root).

## Why this matters

By default, `libvirtd`'s socket and the QEMU processes it spawns are locked
down to root. That's fine for a server, but for a desktop passthrough setup
it means typing your root password for every `virsh`/virt-manager action,
and VM-owned files (disk images, the GPU's vBIOS dump) ending up owned by
root. Both of the edits below fix that.

## /etc/libvirt/libvirtd.conf — socket permissions

```bash
sudo nano /etc/libvirt/libvirtd.conf
```

Find the following two lines and remove the leading `#` to uncomment them:

```
unix_sock_group = "libvirt"
unix_sock_rw_perms = "0770"
```

This lets any user in the `libvirt` group (which you already joined in
[Install All Tools](4_INSTALL_TOOLS.md#add-yourself-to-the-libvirt-group))
talk to libvirtd's socket read-write, instead of every action needing root.

## Optional: enable QEMU logging

Still in the same file, add these two lines at the end:

```
log_filters="1:qemu"
log_outputs="1:file:/var/log/libvirt/libvirtd.log"
```

This isn't required, but it's worth turning on now rather than after
something breaks: GPU passthrough failures are much easier to diagnose with
QEMU-level logs already being written to `/var/log/libvirt/libvirtd.log`
than trying to reproduce the issue after adding logging retroactively.

Save and exit.

## /etc/libvirt/qemu.conf — run VMs as your user

```bash
sudo nano /etc/libvirt/qemu.conf
```

Find these two lines:

```
#user = "root"
#group = "root"
```

Uncomment them and replace `root` with your own username (check it with
`whoami` if unsure):

```
user = "youruser"
group = "youruser"
```

This makes the actual QEMU process for your VMs run as your user instead of
root. It matters for passthrough specifically because the VM process needs
read/write access to the GPU's vBIOS dump and other files you'll set up
under your own user later — without this change you'd otherwise have to
chown everything to root.

## Apply the changes

```bash
sudo systemctl restart libvirtd
```

If you haven't enabled/started `libvirtd`, joined the `libvirt` group, or
started the default network yet, that's covered in
[Install All Tools](4_INSTALL_TOOLS.md) — this restart just picks up the
edits made here.

## Verifying

```bash
groups $USER | grep libvirt
virsh list --all
```

`virsh list --all` should run without asking for a password and without
`sudo`. If you enabled logging, confirm the log file is being written to:

```bash
ls -la /var/log/libvirt/libvirtd.log
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| `virsh list --all` still needs `sudo` / permission denied on the socket | Either your user isn't actually in the `libvirt` group yet (log out and back in after `usermod -aG libvirt`), or `unix_sock_group`/`unix_sock_rw_perms` are still commented out |
| Editing the file seemed to do nothing | Make sure you actually removed the leading `#` — a common mistake is changing the value while leaving the line commented out |
| VM process still shows as owned by `root` (check with `ps aux \| grep qemu-system`) | `qemu.conf` wasn't saved correctly, or `libvirtd` wasn't restarted after the edit |
