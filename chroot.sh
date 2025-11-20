#!/bin/bash
set -e

# K3S Ubuntu Image Builder - NBD version (like Alpine workflow)
# Requires: privileged container + host /dev mount

# Configuration
UBUNTU_VERSION="${UBUNTU_RELEASE:-jammy}"
IMAGE_URL="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
OUTPUT_IMAGE="${OUTPUT_IMAGE:-ubuntu.raw}"
IMAGE_SIZE="${DISK_SIZE:-4G}"
K3S_VERSION="${K3S_VERSION:-1.32.5}"
K3S_URL="https://github.com/k3s-io/k3s/releases/download/v${K3S_VERSION}+k3s1/k3s"

MOUNT_DIR="/tmp/image-mount"
NBD_DEV=""

echo "=== K3S Ubuntu Image Builder (NBD version) ==="
echo "K3S Version: ${K3S_VERSION}"
echo "Ubuntu Release: ${UBUNTU_VERSION}"
echo "Output: ${OUTPUT_IMAGE}"

# Cleanup function
cleanup() {
    echo "Cleaning up..."
    set +e
    if [ -d "$MOUNT_DIR" ]; then
        umount -R "$MOUNT_DIR" 2>/dev/null || true
        rmdir "$MOUNT_DIR" 2>/dev/null || true
    fi
    if [ -n "$NBD_DEV" ] && [ -b "$NBD_DEV" ]; then
        qemu-nbd --disconnect "$NBD_DEV" 2>/dev/null || true
    fi
}

trap cleanup EXIT

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo "Please run as root"
    exit 1
fi

# Function to get available NBD device
get_available_nbd() {
    local dev
    for dev in $(find /dev -maxdepth 2 -name 'nbd[0-9]*' 2>/dev/null); do
        if [ "$(blockdev --getsize64 "$dev" 2>/dev/null || echo 1)" -eq 0 ]; then
            echo "$dev"
            return 0
        fi
    done
    return 1
}

# Reload partitions on existing NBD devices (like Alpine workflow does)
echo "Reloading partitions on existing NBD devices..."
for dev in $(find /dev -maxdepth 2 -name 'nbd[0-9]*' 2>/dev/null); do
    partprobe "$dev" 2>/dev/null || true
done

# Load NBD module if not already loaded
echo "Ensuring NBD module is loaded..."
if ! lsmod | grep -q nbd; then
    modprobe nbd max_part=16 || {
        echo "WARNING: Could not load NBD module. Trying to continue..."
    }
fi

# Find available NBD device
echo "Finding available NBD device..."
NBD_DEV=$(get_available_nbd) || {
    echo "ERROR: No available NBD device found"
    echo "Available devices:"
    ls -la /dev/nbd* 2>/dev/null || echo "No NBD devices found"
    exit 1
}

echo "Using NBD device: $NBD_DEV"

# Download base image
echo "Downloading Ubuntu cloud image..."
if [ ! -f "ubuntu-base.img" ]; then
    wget -q -O ubuntu-base.img "$IMAGE_URL"
fi

# Create working copy
echo "Creating working image..."
qemu-img convert -O raw ubuntu-base.img "$OUTPUT_IMAGE"

# Resize the image file
echo "Resizing image to ${IMAGE_SIZE}..."
qemu-img resize "$OUTPUT_IMAGE" "$IMAGE_SIZE"

# Connect to NBD device
echo "Connecting image to NBD device..."
qemu-nbd --connect="$NBD_DEV" --cache=writeback --format=raw "$OUTPUT_IMAGE"

# Wait for device to be ready
sleep 2

# Refresh partition table
echo "Refreshing partition table..."
partprobe "$NBD_DEV" || true
sleep 1

# Determine partition device
if [ -b "${NBD_DEV}p1" ]; then
    ROOT_DEV="${NBD_DEV}p1"
elif [ -b "${NBD_DEV}1" ]; then
    ROOT_DEV="${NBD_DEV}1"
else
    echo "ERROR: Cannot find partition on NBD device"
    echo "Available partitions:"
    ls -la "${NBD_DEV}"* 2>/dev/null || true
    qemu-nbd --disconnect "$NBD_DEV"
    exit 1
fi

echo "Using root device: $ROOT_DEV"

# Wait for partition device to be ready
sleep 2

# Resize partition and filesystem
echo "Resizing partition..."
growpart "$NBD_DEV" 1 || echo "growpart completed with code $?"

echo "Checking filesystem..."
e2fsck -f "$ROOT_DEV" -y || echo "fsck completed with code $?"

echo "Resizing filesystem..."
resize2fs "$ROOT_DEV" || echo "resize2fs completed with code $?"

# Mount the image
echo "Mounting root filesystem..."
mkdir -p "$MOUNT_DIR"
mount "$ROOT_DEV" "$MOUNT_DIR"

# Mount necessary filesystems for chroot
echo "Setting up chroot environment..."
mount --bind /dev "$MOUNT_DIR/dev"
mount --bind /proc "$MOUNT_DIR/proc"
mount --bind /sys "$MOUNT_DIR/sys"
mount --bind /dev/pts "$MOUNT_DIR/dev/pts"

# Copy resolv.conf for network access
cp /etc/resolv.conf "$MOUNT_DIR/etc/resolv.conf"

echo "Customizing system..."

# Create provisioning script to run in chroot
cat > "$MOUNT_DIR/tmp/provision.sh" <<'PROVISION_EOF'
#!/bin/bash
set -e

export DEBIAN_FRONTEND=noninteractive

echo "=== Updating system ==="
apt-get update
apt-get upgrade -y

echo "=== Installing packages ==="
apt-get install -y \
    curl wget htop sudo \
    nfs-common open-iscsi conntrack dbus iptables logrotate vim \
    s3cmd sqlite3 software-properties-common \
    build-essential cmake linux-headers-generic libnl-3-dev \
    python3 python3-docutils openssh-server chrony \
    e2fsprogs xfsprogs util-linux dhclient

echo "=== Configuring kernel parameters ==="
sed -i 's/GRUB_CMDLINE_LINUX=""/GRUB_CMDLINE_LINUX="systemd.unified_cgroup_hierarchy=1 cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory"/' /etc/default/grub
update-grub

echo "=== Installing CNI plugins ==="
mkdir -p /opt/cni/bin
wget -q -O /tmp/cni.tgz https://github.com/containernetworking/plugins/releases/download/v1.3.0/cni-plugins-linux-amd64-v1.3.0.tgz
tar -xzf /tmp/cni.tgz -C /opt/cni/bin
rm /tmp/cni.tgz

echo "=== Installing K3S ==="
curl -L K3S_URL_PLACEHOLDER -o /usr/local/bin/k3s
chmod +x /usr/local/bin/k3s
ln -sf /usr/local/bin/k3s /usr/local/bin/kubectl
ln -sf /usr/local/bin/k3s /usr/local/bin/crictl
ln -sf /usr/local/bin/k3s /usr/local/bin/ctr

echo "=== Installing Litestream ==="
wget -q https://github.com/benbjohnson/litestream/releases/download/v0.3.8/litestream-v0.3.8-linux-amd64-static.tar.gz -O /tmp/litestream.tgz
cd /tmp && tar xvf litestream.tgz
mv litestream /usr/bin/litestream
chmod +x /usr/bin/litestream
rm /tmp/litestream.tgz

echo "=== Installing Helm ==="
wget -q https://get.helm.sh/helm-v3.9.1-linux-amd64.tar.gz -O /tmp/helm.tgz
cd /tmp && tar xvf helm.tgz
mv linux-amd64/helm /usr/local/bin/helm
rm -rf /tmp/helm.tgz /tmp/linux-amd64

echo "=== Installing Node Problem Detector ==="
mkdir -p /opt/node-problem-detector/
wget -q https://github.com/kubernetes/node-problem-detector/releases/download/v0.8.15/node-problem-detector-v0.8.15-linux_amd64.tar.gz -O /tmp/npd.tgz
tar -xzf /tmp/npd.tgz -C /opt/node-problem-detector/
rm /tmp/npd.tgz
rm -rf /opt/node-problem-detector/test

echo "=== Configuring system ==="
mkdir -p /etc/systemd/system.conf.d
cat > /etc/systemd/system.conf.d/cgroup.conf <<EOF
[Manager]
DefaultCPUAccounting=yes
DefaultMemoryAccounting=yes
DefaultIOAccounting=yes
EOF

echo 'PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/cni/bin"' > /etc/environment

mkdir -p /etc/cloud/cloud.cfg.d
echo "datasource_list: [ NoCloud, ConfigDrive, OpenStack, None ]" > /etc/cloud/cloud.cfg.d/91-dib-cloud-init-datasources.cfg

mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/50-cloud-init.conf <<EOF
PermitRootLogin yes
UsePAM yes
AllowTcpForwarding yes
EOF

echo "=== Enabling services ==="
systemctl enable ssh
systemctl enable chrony

echo "=== Cleaning up ==="
apt-get autoremove -y
apt-get clean
rm -rf /var/lib/apt/lists/*
rm -rf /tmp/*

# Reset machine ID
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -s /etc/machine-id /var/lib/dbus/machine-id

echo "=== Provisioning complete ==="
PROVISION_EOF

# Replace placeholder with actual K3S URL
sed -i "s|K3S_URL_PLACEHOLDER|$K3S_URL|g" "$MOUNT_DIR/tmp/provision.sh"

# Make script executable
chmod +x "$MOUNT_DIR/tmp/provision.sh"

# Run provisioning script in chroot
echo "Running provisioning in chroot..."
chroot "$MOUNT_DIR" /tmp/provision.sh

# Clean up provisioning script
rm "$MOUNT_DIR/tmp/provision.sh"

# Sync and unmount
echo "Syncing filesystems..."
sync

echo "Unmounting filesystems..."
umount -R "$MOUNT_DIR" || true
rmdir "$MOUNT_DIR" || true

# Disconnect NBD
echo "Disconnecting NBD device..."
qemu-nbd --disconnect "$NBD_DEV"

echo ""
echo "=== Build Complete ==="
echo "Output image: $OUTPUT_IMAGE"
echo ""
echo "Image details:"
ls -lh "$OUTPUT_IMAGE"
