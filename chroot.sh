#!/bin/bash
set -e

# K3S Ubuntu Image Builder - NBD version (Fixed)
# Requires: privileged container + host /dev mount

# Install required tools if missing
if ! command -v growpart &> /dev/null; then
    echo "Installing cloud-guest-utils for growpart..."
    apt-get update -qq && apt-get install -y -qq cloud-guest-utils
fi

# Configuration
UBUNTU_VERSION="${UBUNTU_RELEASE:-jammy}"
IMAGE_URL="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
OUTPUT_IMAGE="${OUTPUT_IMAGE:-ubuntu.raw}"
IMAGE_SIZE="${DISK_SIZE:-10G}"
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

# Reload partitions on existing NBD devices
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
    wget -q --show-progress -O ubuntu-base.img "$IMAGE_URL"
fi

# Create working copy
echo "Creating working image..."
# Check source format
SOURCE_FORMAT=$(qemu-img info ubuntu-base.img | grep "file format:" | awk '{print $3}')
echo "Source image format: $SOURCE_FORMAT"

# Convert to raw if needed
if [ "$SOURCE_FORMAT" != "raw" ]; then
    qemu-img convert -f "$SOURCE_FORMAT" -O raw ubuntu-base.img "$OUTPUT_IMAGE"
else
    cp ubuntu-base.img "$OUTPUT_IMAGE"
fi

# Resize the image file
echo "Resizing image to ${IMAGE_SIZE}..."
truncate -s "$IMAGE_SIZE" "$OUTPUT_IMAGE"

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
# Handle dangling symlink
if [ -L "$MOUNT_DIR/etc/resolv.conf" ]; then
    rm "$MOUNT_DIR/etc/resolv.conf"
fi
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

ACTIVE_KERNEL=$(ls /lib/modules/ | sort -V | tail -1)
echo "=== Active kernel detected: $ACTIVE_KERNEL ==="
if [ -z "$ACTIVE_KERNEL" ]; then
    echo "ERROR: Could not detect kernel in /lib/modules/"
    exit 1
fi

echo "=== Installing packages ==="
apt-get install -y \
    curl wget htop sudo \
    nfs-common open-iscsi conntrack dbus iptables logrotate vim \
    s3cmd sqlite3 software-properties-common \
    build-essential cmake linux-headers-${ACTIVE_KERNEL} libnl-3-dev \
    python3 python3-docutils openssh-server chrony linux-modules-extra-${ACTIVE_KERNEL} infiniband-diags\
    e2fsprogs xfsprogs util-linux isc-dhcp-client \
    xterm

echo 'mlx5_ib' >> /etc/modules

# Get UUID FIRST, before any update-grub
ROOT_UUID=$(blkid -s UUID -o value $(findmnt -n -o SOURCE /))
if [ -z "$ROOT_UUID" ]; then
    echo "ERROR: Could not determine root filesystem UUID"
    exit 1
fi

echo "Root filesystem UUID: $ROOT_UUID"

echo "=== Configuring kernel parameters ==="
# Include the UUID in the GRUB command line
sed -i "s|GRUB_CMDLINE_LINUX=\"\"|GRUB_CMDLINE_LINUX=\"root=UUID=${ROOT_UUID} systemd.unified_cgroup_hierarchy=1 cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory\"|" /etc/default/grub
update-grub

echo "=== Installing CNI plugins ==="
mkdir -p /opt/cni/bin
wget -q -O /tmp/cni.tgz https://github.com/containernetworking/plugins/releases/download/v1.3.0/cni-plugins-linux-amd64-v1.3.0.tgz
tar -xzf /tmp/cni.tgz -C /opt/cni/bin
rm /tmp/cni.tgz

echo "=== Installing K3S ==="
curl -L K3S_URL_PLACEHOLDER -o /usr/bin/k3s
chmod +x /usr/bin/k3s
ln -sf /usr/bin/k3s /usr/bin/kubectl
ln -sf /usr/bin/k3s /usr/bin/crictl
ln -sf /usr/bin/k3s /usr/bin/ctr

echo "=== Creating K3S systemd service ==="
cat > /etc/systemd/system/k3s.service <<'EOF'
[Unit]
Description=Lightweight Kubernetes
Documentation=https://k3s.io
Wants=network-online.target
After=network-online.target

[Service]
Type=notify
EnvironmentFile=-/etc/environment
EnvironmentFile=-/etc/rancher/k3s/k3s.env
KillMode=process
Delegate=yes
LimitNOFILE=1048576
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
TimeoutStartSec=0
Restart=always
RestartSec=5s
ExecStartPre=/bin/sh -c 'rm -f /tmp/k3s.*'
ExecStartPre=/bin/sh -c 'mount --make-rshared /'
ExecStartPre=/bin/sh -xc '! /usr/bin/systemctl is-enabled --quiet nm-cloud-setup.service'
ExecStartPre=-/sbin/modprobe br_netfilter
ExecStartPre=-/sbin/modprobe overlay
ExecStart=/usr/bin/k3s server --kubelet-arg='kube-reserved=cpu=180m,memory=500Mi,ephemeral-storage=2Gi' --kubelet-arg='eviction-hard=memory.available<100Mi,nodefs.available<10%,nodefs.inodesFree<5%,pid.available<10%'
StandardOutput=append:/var/log/k3s.log
StandardError=append:/var/log/k3s.log

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

echo "=== Creating K3S OpenRC init script (for Alpine compatibility) ==="
mkdir -p /etc/init.d
cat > /etc/init.d/k3s <<'EOF'
#!/sbin/openrc-run

depend() {
    need net cgroups dbus
    want cgroups
}

start_pre() {
    rm -f /tmp/k3s.*
    mount --make-rshared /
}

supervisor=supervise-daemon
name=k3s
command="/usr/bin/k3s"
command_args="server --kubelet-arg='kube-reserved=cpu=180m,memory=500Mi,ephemeral-storage=2Gi' \
--kubelet-arg='eviction-hard=memory.available<100Mi,nodefs.available<10%,nodefs.inodesFree<5%,pid.available<10%' \
>>/var/log/k3s.log 2>&1"

output_log=/var/log/k3s.log
error_log=/var/log/k3s.log

pidfile="/var/run/k3s.pid"
respawn_delay=5
respawn_max=0

rc_ulimit="${K3S_ULIMIT:--c unlimited -n 1048576 -u unlimited}"

set -o allexport
if [ -f /etc/environment ]; then source /etc/environment; fi
if [ -f /etc/rancher/k3s/k3s.env ]; then source /etc/rancher/k3s/k3s.env; fi
set +o allexport
EOF

chmod +x /etc/init.d/k3s

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

echo "=== Configuring S3 Backup Infrastructure ==="
# Create S3 configuration for Wasabi
cat > /root/.s3cfg <<EOF
[default]
host_base = s3.wasabisys.com
host_bucket = %(bucket)s.s3.wasabisys.com
use_https = True
EOF

# Create backup script
cat > /etc/backup.sh <<'BACKUP_EOF'
#!/bin/bash
set -e

# Load environment variables
if [ -f /etc/backup.env ]; then
    source /etc/backup.env
else
    echo "Error: /etc/backup.env not found"
    exit 1
fi

# Configuration
K3S_DB_PATH="/var/lib/rancher/k3s/server/db/state.db"
K3S_TOKEN_PATH="/var/lib/rancher/k3s/server/token"
BACKUP_DIR="/tmp/k3s-backup"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_NAME="k3s-backup-${TIMESTAMP}"
S3_BUCKET="civo-tenant-k3s-backups"

# Validate required environment variables
for var in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY REGION TENANT_ID; do
    if [ -z "${!var}" ]; then
        echo "Error: $var is not set"
        exit 1
    fi
done

# Create backup directory
mkdir -p "${BACKUP_DIR}"

# Dump K3S SQLite database
if [ -f "${K3S_DB_PATH}" ]; then
    echo "Dumping K3S database..."
    sqlite3 "${K3S_DB_PATH}" ".backup '${BACKUP_DIR}/state.db'"
else
    echo "Warning: K3S database not found at ${K3S_DB_PATH}"
fi

# Copy node token
if [ -f "${K3S_TOKEN_PATH}" ]; then
    echo "Copying node token..."
    cp "${K3S_TOKEN_PATH}" "${BACKUP_DIR}/token"
else
    echo "Warning: K3S token not found at ${K3S_TOKEN_PATH}"
fi

# Create compressed archive
echo "Creating backup archive..."
cd /tmp
tar -czvf "${BACKUP_NAME}.tar.gz" -C "${BACKUP_DIR}" .

# Upload to S3
echo "Uploading to S3..."
s3cmd put "${BACKUP_NAME}.tar.gz" \
    "s3://${S3_BUCKET}/${REGION}/${TENANT_ID}/${BACKUP_NAME}.tar.gz" \
    --access_key="${AWS_ACCESS_KEY_ID}" \
    --secret_key="${AWS_SECRET_ACCESS_KEY}"

# Cleanup
rm -rf "${BACKUP_DIR}" "/tmp/${BACKUP_NAME}.tar.gz"

echo "Backup completed successfully: ${BACKUP_NAME}"
BACKUP_EOF

chmod +x /etc/backup.sh

echo "=== Installing NVIDIA Container Toolkit ==="
# Install prerequisites
apt-get install -y --no-install-recommends curl gnupg2

# Configure the production repository
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

# Update and install NVIDIA Container Toolkit
apt-get update
NVIDIA_CONTAINER_TOOLKIT_VERSION=1.18.2-1
apt-get install -y \
    nvidia-container-toolkit=${NVIDIA_CONTAINER_TOOLKIT_VERSION} \
    nvidia-container-toolkit-base=${NVIDIA_CONTAINER_TOOLKIT_VERSION} \
    libnvidia-container-tools=${NVIDIA_CONTAINER_TOOLKIT_VERSION} \
    libnvidia-container1=${NVIDIA_CONTAINER_TOOLKIT_VERSION}

# Configure containerd for Kubernetes (K3s uses containerd)
nvidia-ctk runtime configure --runtime=containerd

sed -i 's|#root = "/run/nvidia/driver"|root = "/run/nvidia/driver"|' \
    /etc/nvidia-container-runtime/config.toml
    
# echo "=== Installing NVIDIA Driver 570.158.01 ==="
# NVIDIA_DRIVER_VERSION="570.158.01"

# # Blacklist nouveau
# cat > /etc/modprobe.d/blacklist-nouveau.conf << EOF
# blacklist nouveau
# options nouveau modeset=0
# EOF
# update-initramfs -u

# # Download and install driver
# wget -q --show-progress \
#     "https://us.download.nvidia.com/tesla/${NVIDIA_DRIVER_VERSION}/NVIDIA-Linux-x86_64-${NVIDIA_DRIVER_VERSION}.run" \
#     -O /tmp/nvidia-driver.run
# sh /tmp/nvidia-driver.run --silent --dkms --install-libglvnd \
#     --kernel-name=${ACTIVE_KERNEL} \
#     --kernel-source-path=/usr/src/linux-headers-${ACTIVE_KERNEL} \
#     --no-cc-version-check
# rm /tmp/nvidia-driver.run

# # nvidia-smi won't work in chroot without GPU - verify driver files instead
# ls /usr/bin/nvidia-smi /usr/lib/x86_64-linux-gnu/libnvidia* 2>/dev/null || { echo "ERROR: NVIDIA driver installation failed - no driver files found"; exit 1; }
# echo "NVIDIA driver files installed successfully"

# echo "=== Installing nvlsm ==="
# NVLSM_VERSION="2025.03.1.1-1"

# # Add CUDA repo (needed for libibumad3 and fabricmanager)
# wget -q https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.0-1_all.deb \
#     -O /tmp/cuda-keyring.deb
# dpkg -i /tmp/cuda-keyring.deb
# rm /tmp/cuda-keyring.deb
# apt-get update

# # Install dependencies
# add-apt-repository -y universe
# apt-get update
# apt-get install -y libibumad3 rdma-core

# # Install nvlsm
# wget -q "https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/nvlsm_${NVLSM_VERSION}_amd64.deb" \
#     -O /tmp/nvlsm.deb
# dpkg -i /tmp/nvlsm.deb
# apt-get install -f -y
# rm /tmp/nvlsm.deb

# ls /opt/nvidia/nvlsm/sbin/nvlsm || { echo "ERROR: nvlsm installation failed"; exit 1; }

# echo "=== Installing NVIDIA Fabric Manager ==="
# FABRIC_MANAGER_VERSION="570.158.01"

# wget -q "https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/nvidia-fabricmanager-570_${FABRIC_MANAGER_VERSION}-1_amd64.deb" \
#     -O /tmp/fabricmanager.deb
# dpkg -i /tmp/fabricmanager.deb
# apt-get install -f -y
# rm /tmp/fabricmanager.deb

# systemctl enable nvidia-fabricmanager

# # ↓ ADD THIS
# echo "=== Pinning NVIDIA packages to prevent auto-upgrade ==="
# apt-mark hold \
#     nvidia-fabricmanager-570 \
#     nvidia-driver-570 \
#     nvidia-utils-570

# echo "=== Disabling auto-upgrades ==="
# # chroot-safe: mask the service via symlink instead of systemctl
# ln -sf /dev/null /etc/systemd/system/unattended-upgrades.service

# cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
# APT::Periodic::Update-Package-Lists "0";
# APT::Periodic::Download-Upgradeable-Packages "0";
# APT::Periodic::AutocleanInterval "0";
# APT::Periodic::Unattended-Upgrade "0";
# EOF

# # Also blacklist nvidia from unattended-upgrades
# cat >> /etc/apt/apt.conf.d/50unattended-upgrades <<EOF
# Unattended-Upgrade::Package-Blacklist {
#     "nvidia-*";
#     "libnvidia-*";
# };
# EOF

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

echo "=== Configuring terminal for console access ==="
# Enable serial console
systemctl enable serial-getty@ttyS0.service

# Add terminal fixes to bashrc
cat >> /etc/bash.bashrc <<EOF

# Terminal fixes for VM console (KVM/libvirt)
if [ -t 0 ]; then
    export TERM=linux
    # Reset terminal to sane state
    stty sane 2>/dev/null || true
    # Set proper terminal size if resize is available
    command -v resize >/dev/null 2>&1 && eval \$(resize) 2>/dev/null || true
fi
EOF

# Add to root's bashrc as well
cat >> /root/.bashrc <<EOF

# Terminal fixes for VM console
export TERM=linux
stty sane 2>/dev/null || true
command -v resize >/dev/null 2>&1 && eval \$(resize) 2>/dev/null || true
EOF

echo "=== Configuring boot for generic block devices ==="
# Ensure fstab uses UUID
ROOT_UUID=$(blkid -s UUID -o value $(findmnt -n -o SOURCE /))
if [ -n "$ROOT_UUID" ]; then
    cat > /etc/fstab <<EOF
# <file system> <mount point> <type> <options> <dump> <pass>
UUID=${ROOT_UUID} / ext4 defaults 0 1
EOF
fi

# Rebuild initramfs to detect devices properly
update-initramfs -u -k all

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
rm -f "$MOUNT_DIR/tmp/provision.sh"

# ============================================
# CONFIGURE DNS - Simple approach
# ============================================
echo "=== Configuring final DNS settings ==="

# Remove symlink if exists
if [ -L "$MOUNT_DIR/etc/resolv.conf" ]; then
    rm "$MOUNT_DIR/etc/resolv.conf"
fi

# Write final DNS configuration
cat > "$MOUNT_DIR/etc/resolv.conf" <<EOF
# Default nameservers
search cluster.local
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF

# Sync and unmount
echo "Syncing filesystems..."
sync

echo "Unmounting filesystems..."
umount -R "$MOUNT_DIR" || true
rmdir "$MOUNT_DIR" || true

# Disconnect NBD
echo "Disconnecting NBD device..."
qemu-nbd --disconnect "$NBD_DEV"

# Generate MANIFEST file (removed from inside the script, will be done in Argo workflow)
echo ""
echo "=== Build Complete ==="
echo "Output image: $OUTPUT_IMAGE"
echo ""
echo "Image details:"
ls -lh "$OUTPUT_IMAGE"
echo ""
echo "SHA256: $(sha256sum "$OUTPUT_IMAGE" | awk '{print $1}')"
