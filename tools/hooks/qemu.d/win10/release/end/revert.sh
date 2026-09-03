#!/bin/bash
set -x
exec > >(tee -a /var/log/vfio-revert.log) 2>&1
echo "===== REVERT $(date) ====="

source "/etc/libvirt/hooks/kvm.conf"
export PATH="/usr/bin:/usr/sbin:$PATH"

# Gives the devices back to amdgpu / snd_hda_intel. amdgpu stays loaded
# (start.sh never unloads it), so this just rebinds the device.
virsh nodedev-reattach $VIRSH_GPU_VIDEO || true
virsh nodedev-reattach $VIRSH_GPU_AUDIO || true
sleep 2

modprobe -r vfio_pci      || true
modprobe -r vfio_pci_core || true
modprobe -r vfio_iommu_type1 || true
modprobe -r vfio          || true
sleep 2

# Safety net: in case the modules aren't resident for some reason.
modprobe amdgpu        || true
modprobe snd_hda_intel || true

# Waits for amdgpu to register the card before bringing up the display
# manager. The minor number can come back as card1 instead of card0, so
# it isn't hardcoded.
for i in $(seq 1 20); do
    ls /dev/dri/card* > /dev/null 2>&1 && break
    sleep 1
done
sleep 2

for vtcon in /sys/class/vtconsole/vtcon*; do
    grep -q "frame buffer device" "$vtcon/name" 2>/dev/null || continue
    echo 1 > "$vtcon/bind" || true
done

systemctl start display-manager

# CPU topology / host core confinement — see docs/11_CPU_TOPOLOGY.md
# systemctl set-property --runtime -- system.slice AllowedCPUs=0-27 || true
# systemctl set-property --runtime -- user.slice   AllowedCPUs=0-27 || true
# systemctl set-property --runtime -- init.scope   AllowedCPUs=0-27 || true

echo "===== REVERT OK ====="
