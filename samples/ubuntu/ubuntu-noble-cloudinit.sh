#! /bin/bash

set -xe

VMID="${VMID:-8500}"
STORAGE="${STORAGE:-local-lvm}"
VMUSER="${VMUSER:-ubuntu}"
VMDISKSIZE="${VMDISKSIZE:-20G}"
VMCORES="${VMCORES:-2}"
VMMEMORY="${VMMEMORY:-2048}"


if [ -z "$SOCKS5_config" ]; then
    echo "Error: SOCKS5_config variable is not set"
    echo "Usage example:"
    echo "  export SOCKS5_config=\"socks5 xxx.xxx.xxx.xxx port_nr username password\""
    exit 1
fi

ESCAPED_SOCKS5=$(echo "$SOCKS5_config" | sed 's/"/\\"/g')

IMG="noble-server-cloudimg-amd64.img"
BASE_URL="https://cloud-images.ubuntu.com/noble/current"
EXPECTED_SHA=$(wget -qO- "$BASE_URL/SHA256SUMS" | awk '/'$IMG'/{print $1}')

download() {
    wget -q "$BASE_URL/$IMG"
}

verify() {
    sha256sum "$IMG" | awk '{print $1}'
}

[ ! -f "$IMG" ] && download

ACTUAL_SHA=$(verify)

if [ "$EXPECTED_SHA" != "$ACTUAL_SHA" ]; then
    rm -f "$IMG"
    download
    ACTUAL_SHA=$(verify)
    [ "$EXPECTED_SHA" != "$ACTUAL_SHA" ] && exit 1
fi

rm -f noble-server-cloudimg-amd64-resized.img
cp noble-server-cloudimg-amd64.img noble-server-cloudimg-amd64-resized.img
qemu-img resize noble-server-cloudimg-amd64-resized.img $VMDISKSIZE

qm destroy $VMID || true
qm create $VMID --name "ubuntu-noble-template" --ostype l26 \
    --memory $VMMEMORY --balloon 0 \
    --agent 1 \
    --bios ovmf --machine q35 --efidisk0 $STORAGE:0,pre-enrolled-keys=0 \
    --cpu host --socket 1 --cores $VMCORES \
    --vga serial0 --serial0 socket  \
    --net0 virtio,bridge=vmbr0
qm importdisk $VMID noble-server-cloudimg-amd64-resized.img $STORAGE
qm set $VMID --scsihw virtio-scsi-pci --virtio0 $STORAGE:vm-$VMID-disk-1,discard=on
qm set $VMID --boot order=virtio0
qm set $VMID --scsi1 $STORAGE:cloudinit

if [ ! -d "/var/lib/vz/snippets" ]; then
  mkdir -p "/var/lib/vz/snippets"
fi

cat << EOF | tee /var/lib/vz/snippets/ubuntu-noble.yaml
#cloud-config
runcmd:
    - apt-get update
    - apt-get install -y qemu-guest-agent
    - apt-get install -y proxychains4
    - sed -i 's/^socks4[[:space:]]\+127\.0\.0\.1[[:space:]]\+[0-9]\+.*/${ESCAPED_SOCKS5}/' /etc/proxychains4.conf
    - proxychains4 curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
    - proxychains4 curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.tailscale-keyring.list | tee /etc/apt/sources.list.d/tailscale.list
    - proxychains4 apt-get update
    - proxychains4 apt-get install -y tailscale
    - ['sh', '-c', "echo 'net.ipv4.ip_forward = 1' | tee -a /etc/sysctl.d/99-tailscale.conf && echo 'net.ipv6.conf.all.forwarding = 1' | tee -a /etc/sysctl.d/99-tailscale.conf && sysctl -p /etc/sysctl.d/99-tailscale.conf" ]
    - systemctl enable ssh    
    - reboot
# Taken from https://forum.proxmox.com/threads/combining-custom-cloud-init-with-auto-generated.59008/page-3#post-428772
EOF

echo "timezone: "$(cat /etc/timezone) | tee -a /var/lib/vz/snippets/ubuntu-noble.yaml
echo "locale: "$LANG | tee -a /var/lib/vz/snippets/ubuntu-noble.yaml

qm set $VMID --cicustom "vendor=local:snippets/ubuntu-noble.yaml"
qm set $VMID --tags ubuntu-template,noble,cloudinit
qm set $VMID --ciuser $VMUSER
qm set $VMID --sshkeys ~/.ssh/authorized_keys
qm set $VMID --ipconfig0 ip=dhcp,ip6=dhcp
qm template $VMID
