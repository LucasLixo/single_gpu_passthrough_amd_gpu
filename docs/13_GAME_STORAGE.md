# Fast Storage for Games

Growing the Windows system disk from [Configure Virtual Machine](6_CONFIGURE_VM.md#sizing-the-system-disk)
to also fit a game library wastes space and mixes concerns — OS and game
installs sharing one disk means neither can be managed independently. This
covers the actual approach this build settled on instead: a dedicated,
sparse VirtIO disk (or one per game) that only takes real disk space for
what's actually installed.

## Why not just share a folder over virtiofs?

The obvious-seeming shortcut — share a host folder into the guest with
virtiofs and install games straight into it — breaks down for a few
concrete reasons:

| Problem | Why |
|---|---|
| Steam refuses to install to it | The virtiofs share shows up as `\\virtiofs\Linux` — Steam detects it as a network drive and blocks installing there, even if you map a drive letter to it |
| Anti-cheat rejects it | EAC and BattlEye both refuse to run executables sitting on what they detect as a network drive |
| I/O latency | Games touch thousands of small files through FUSE, with a `stat()` call per file — load times suffer badly compared to a real block device |
| Files intermittently "disappear" | Usually `<cache mode="none"/>` serving inconsistent directory listings, missing `xattr="on"` (Windows needs to write metadata/ADS), or the virtiofsd process not having permission to the shared folder |

None of this makes virtiofs bad — it's still the right tool for saves,
screenshots, mods, and moving the odd file between host and guest. It's
just the wrong tool for an actual game library.

## Why a truncated raw file beats virt-manager's disk image option

virt-manager's own **"Create a disk image for the virtual machine"** option
generates a `qcow2` file in the default storage pool, and doesn't expose
`discard` configuration well through the UI. Creating the raw file yourself
gives full control over where it lives and how it behaves:

```bash
mkdir -p ~/Games
truncate -s 500G ~/Games/games.img
```

`truncate` creates a **sparse** file — the size above is a ceiling, not
real disk usage. A fresh 500G file takes close to 0 bytes on disk; space is
only claimed as Windows actually writes to it.

If `~/Games` lives on **Btrfs**, disable copy-on-write for the directory
*before* creating any files in it (`+C` only applies to files created
afterward):

```bash
chattr +C ~/Games
```

On ext4 or XFS (this build's filesystem), sparse files work natively with
no extra flag needed — confirm which one you're on with:

```bash
findmnt -no FSTYPE --target ~/Games
```

**Don't size it right up against your real free space.** Windows reports
the full ceiling as free space regardless of what's actually available on
the host disk — if the host disk genuinely fills up mid-write, QEMU either
stalls the VM or the write fails and corrupts the NTFS volume. Leave real
headroom: size it comfortably under your actual free space, not as close
to the limit as possible.

## Add it in virt-manager

1. **Add Hardware** → **Storage**.
2. Select **"Select or create custom storage"** → **Manage...**, and
   browse to the `.img` file you just created.
3. **Device type**: Disk device.
4. **Bus type**: VirtIO.
5. Under **Advanced options**, set:

| Option | Value |
|---|---|
| Cache mode | `none` |
| Discard mode | `unmap` |
| I/O mode | `native` |

If your virt-manager version doesn't expose those fields, finish the
wizard anyway and fix it directly in the disk's **XML** tab afterward:

```xml
<disk type="file" device="disk">
  <driver name="qemu" type="raw" cache="none" io="native" discard="unmap"/>
  <source file="/home/youruser/Games/games.img"/>
  <target dev="vdb" bus="virtio"/>
</disk>
```

Double-check `type="raw"`, not `qcow2` — that's the setting virt-manager's
wizard is most likely to have picked wrong.

Inside Windows: `diskmgmt.msc` → initialize as **GPT** → **New Simple
Volume** → format **NTFS** → assign a drive letter (e.g. `D:`). The file
stays close to 0 bytes on the host disk until you actually install
something into it.

## One shared disk vs. one .img per game

| | One combined disk | One `.img` per game |
|---|---|---|
| Setup | One `truncate` + one `<disk>` entry | One `truncate` + one `<disk>` entry, per game |
| Space | Shared pool — free space reflows automatically between games as you install/uninstall | Fixed ceiling per file; space isn't shared across games |
| Drive letters | One `D:` for everything | A separate letter per game in Windows |
| Safety / isolation | A problem with the file affects every installed game at once | Corruption or a bad restore only touches that one game — much safer to snapshot or back up individually |
| Best for | Most people, most of the time — simpler, space reallocates itself | A specific game you want to isolate for backup/snapshot, or an install you're testing disposably |

Default to one combined disk unless you have a specific reason to isolate
a game. This build actually runs the per-game approach for exactly that
isolation reason:

```bash
truncate -s 128G ~/Games/resident_evil_7_biohazard_fitgirl_repack.img
truncate -s 128G ~/Games/resident_evil_4_2023_fitgirl_repack.img
truncate -s 128G ~/Games/god_of_war_ragnarok_fitgirl_repack.img
truncate -s 128G ~/Games/resident_evil_requiem_fitgirl_repack.img
```

Each one gets added as its own `<disk>` (its own VirtIO target, e.g. `vdb`,
`vdc`, `vdd`...) and shows up as its own drive letter in Windows.

## Permissions: make sure QEMU can actually reach the file

[Edit Config](5_EDIT_CONFIG.md#etclibvirtqemuconf--run-vms-as-your-user)
already set QEMU to run as your own user, but that alone doesn't guarantee
access — **every directory** from your home folder down to the `.img` file
needs at least the traverse (`x`) bit set for QEMU to reach it. A folder
created with a stricter mode somewhere in that chain (e.g. `700`) is enough
to block access silently. This build's actual fix:

```bash
chmod o+x /home/lukaasdev/Games/
```

If the VM can't see the disk at all, check the whole path, not just the
final folder:

```bash
namei -l /home/lukaasdev/Games/games.img
```

Every line should show at least an `x` bit for whichever user/group needs
to pass through it.

## Checking real usage

```bash
du -h --apparent-size ~/Games/games.img   # nominal size (the ceiling)
du -h ~/Games/games.img                    # actual disk usage
```

Real numbers from this build, on a partially-filled game disk:

```
$ du -h --apparent-size god_of_war_ragnarok_fitgirl_repack.img
256G
$ du -h god_of_war_ragnarok_fitgirl_repack.img
177G
```

The 79G gap is space NTFS has already told the host it doesn't need —
`discard="unmap"` in the XML plus Windows' own TRIM keep real usage below
the apparent ceiling as you install and uninstall games.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `chattr +C` fails with an error | You're not on Btrfs — `No_COW` only exists there. ext4/XFS neither support nor need the flag; ignore it and continue. Confirm with `findmnt -no FSTYPE --target ~/Games` |
| Installer fails partway with a corrupted-looking NTFS volume | The `.img` was sized bigger than your real free disk space, and the host disk actually ran out mid-write. Recreate it smaller with real headroom — see the sizing warning above |
| A fresh file doesn't look sparse (`du` shows close to the apparent size immediately) | Your filesystem doesn't support sparse files the way ext4/XFS do — this whole approach needs a different filesystem underneath |
| VM can't see the disk / Windows shows no such device | Check permissions the whole way down the path — see [Permissions](#permissions-make-sure-qemu-can-actually-reach-the-file) above |
| Steam/Epic refuses to install to the drive | Confirm you're pointing it at the NTFS drive letter (the VirtIO disk), not a virtiofs mount — see [Why not just share a folder over virtiofs?](#why-not-just-share-a-folder-over-virtiofs) |
