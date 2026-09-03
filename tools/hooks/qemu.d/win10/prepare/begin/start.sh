#!/bin/bash
set -x
exec > >(tee -a /var/log/vfio-start.log) 2>&1
echo "===== START $(date) ====="

source "/etc/libvirt/hooks/kvm.conf"
export PATH="/usr/bin:/usr/sbin:$PATH"

# CPU topology / host core confinement — see docs/11_CPU_TOPOLOGY.md
# HOST_CPUS_VM="0-4,14-18"
# HOST_CPUS_ALL="0-27"

# pci_0000_03_00_0 -> 0000:03:00.0
nodedev_to_pci() {
    sed -E 's/^pci_([0-9a-f]{4})_([0-9a-f]{2})_([0-9a-f]{2})_([0-9a-f])$/\1:\2:\3.\4/' <<< "$1"
}

PCI_VIDEO="$(nodedev_to_pci "$VIRSH_GPU_VIDEO")"
PCI_AUDIO="$(nodedev_to_pci "$VIRSH_GPU_AUDIO")"

driver_of() {
    local link="/sys/bus/pci/devices/$1/driver"
    if [ -L "$link" ]; then
        basename "$(readlink -f "$link")"
    else
        echo none
    fi
}

# CPU topology / host core confinement — see docs/11_CPU_TOPOLOGY.md
# confine_host() {
#     systemctl set-property --runtime -- system.slice AllowedCPUs="$1" || true
#     systemctl set-property --runtime -- user.slice   AllowedCPUs="$1" || true
#     systemctl set-property --runtime -- init.scope   AllowedCPUs="$1" || true
# }

restore_host() {
    echo "ERROR: $* Restoring the host."
    virsh nodedev-reattach "$VIRSH_GPU_VIDEO" || true
    virsh nodedev-reattach "$VIRSH_GPU_AUDIO" || true
    # confine_host "$HOST_CPUS_ALL"
    systemctl start display-manager
    exit 1
}

# Confines the host to cores 0-4 / 14-18 — see docs/11_CPU_TOPOLOGY.md
# confine_host "$HOST_CPUS_VM"

systemctl stop display-manager || true

# Stopping the display manager alone isn't enough: on Plasma 6 Wayland the
# session runs under user@UID.service (kwin_wayland, plasmashell) and
# app.slice (browser, editor), outside of sddm.service. Without ending the
# user session, those processes keep /dev/dri/* open and the GPU won't let go.
for uid in $(loginctl list-sessions --no-legend | awk '{print $2}' | sort -u); do
    [ "$uid" -ge 1000 ] 2>/dev/null || continue
    loginctl terminate-user "$uid" || true
done

# Waits for the DRM/KFD nodes to free up. Needs to cover renderD* (Chromium/
# Electron processes only hold the render node) and /dev/kfd (compute/ROCm).
for i in $(seq 1 30); do
    fuser -s /dev/dri/card* /dev/dri/renderD* /dev/kfd 2>/dev/null || break
    sleep 1
done
sleep 2

# If fbcon has taken over the console, release it. On this kernel
# FRAMEBUFFER_CONSOLE_DEFERRED_TAKEOVER=y keeps the console on the dummy
# vtcon0, and only vtcon0 exists — so this is normally a no-op. The vtcon1
# from the original guide doesn't exist on this machine.
for vtcon in /sys/class/vtconsole/vtcon*; do
    grep -q "frame buffer device" "$vtcon/name" 2>/dev/null || continue
    echo 0 > "$vtcon/bind" || true
done

# We do NOT try "modprobe -r amdgpu". The module registers the "amdgpudrmfb"
# fbdev (/dev/fb0) and holds an internal reference that doesn't drop even
# with no userspace process holding /dev/dri — that's why the unload kept
# failing 10 times in a row. What matters for passthrough is unbinding the
# PCI *device* from amdgpu, and nodedev-detach does that with the module
# still loaded.

# The kernel decides each device's reset_method during PCI enumeration,
# long before this hook (or even the initramfs) runs — module load order
# alone never gets "device_specific" onto that list for Polaris cards.
# Writing to reset_method forces a re-probe, which is what the vendor-reset
# ftrace hook actually answers. See docs/14_GPU_RESET_ON_SECOND_BOOT.md.
modprobe vendor_reset || true
if echo device_specific > "/sys/bus/pci/devices/$PCI_VIDEO/reset_method" 2>/dev/null; then
    echo "reset_method($PCI_VIDEO) = $(cat "/sys/bus/pci/devices/$PCI_VIDEO/reset_method")"
else
    echo "WARNING: could not set device_specific on $PCI_VIDEO."
    echo "WARNING: current reset_method = $(cat "/sys/bus/pci/devices/$PCI_VIDEO/reset_method" 2>&1)"
    echo "WARNING: the VM should still boot, but the second start may hang."
fi

# vfio-pci needs to exist BEFORE the detach.
modprobe vfio
modprobe vfio_pci
modprobe vfio_iommu_type1

virsh nodedev-detach "$VIRSH_GPU_VIDEO" || restore_host "nodedev-detach of the video device failed."
virsh nodedev-detach "$VIRSH_GPU_AUDIO" || restore_host "nodedev-detach of the audio device failed."

# Real guard: the device has to actually be bound to vfio-pci. Checking
# whether the amdgpu module is loaded says nothing about the device binding.
for i in $(seq 1 10); do
    [ "$(driver_of "$PCI_VIDEO")" = vfio-pci ] &&
    [ "$(driver_of "$PCI_AUDIO")" = vfio-pci ] && break
    sleep 1
done

if [ "$(driver_of "$PCI_VIDEO")" != vfio-pci ] || [ "$(driver_of "$PCI_AUDIO")" != vfio-pci ]; then
    restore_host "GPU did not end up on vfio-pci (video=$(driver_of "$PCI_VIDEO") audio=$(driver_of "$PCI_AUDIO"))."
fi

echo "===== START OK ====="
