#!/bin/bash
set -euo pipefail

# ==============================================================================
# CONFIGURATION
# ==============================================================================
DISK="/dev/nvme0n1"
EFI_PART="${DISK}p1"
SWAP_PART="${DISK}p2"
ROOT_PART="${DISK}p3"
HOME_PART="${DISK}p4"

REPO="https://repo-fi.voidlinux.org/current"
ARCH="x86_64"

# ==============================================================================
# SAFETY GUARD
# ==============================================================================
echo "WARNING: This will completely erase ${DISK}."
read -rp "Type YES to continue: " _confirm
[[ "${_confirm}" == "YES" ]] || { echo "Aborted."; exit 1; }

cleanup() {
	swapoff "${SWAP_PART}" 2>/dev/null || true
	umount -R /mnt 2>/dev/null || true
}
trap cleanup EXIT

# ==============================================================================
# 0. UPDATE XBPS AND INSTALL TOOLS
# ==============================================================================
echo "0. Updating XBPS package index and installing tools..."
xbps-install -Syu xbps
xbps-install -Sy parted xtools

# ==============================================================================
# 1. WIPE EXISTING SIGNATURES
# ==============================================================================
echo "1. Wiping existing disk signatures..."
wipefs -a "${DISK}"

# ==============================================================================
# 2. PARTITIONING (FIXED FOR HIBERNATION)
# ==============================================================================
echo "2. Creating partitions for hibernation (16GB RAM)..."
parted -s "${DISK}" \
	mklabel gpt \
	mkpart ESP fat32 1MiB 513MiB \
	set 1 boot on \
	mkpart primary linux-swap 513MiB 17.5GiB \
	mkpart primary ext4 17.5GiB 80GiB \
	mkpart primary ext4 80GiB 100%

# Re-read partition table before formatting.
partprobe "${DISK}"
udevadm settle

# ==============================================================================
# 3. FORMAT PARTITIONS
# ==============================================================================
echo "3. Formatting partitions..."
mkfs.fat -F32 -n EFI "${EFI_PART}"
mkswap -L VoidSwap "${SWAP_PART}"
mkfs.ext4 -L VoidRoot "${ROOT_PART}"
mkfs.ext4 -L VoidHome "${HOME_PART}"

# ==============================================================================
# 4. MOUNT PARTITIONS
# ==============================================================================
echo "4. Mounting partitions..."
mount "${ROOT_PART}" /mnt
mkdir -p /mnt/boot/efi
mkdir -p /mnt/home

mount "${HOME_PART}" /mnt/home
mount -o rw,noatime "${EFI_PART}" /mnt/boot/efi
swapon "${SWAP_PART}"

# ==============================================================================
# 5. BASE SYSTEM INSTALLATION
# ==============================================================================
echo "5. Installing base system..."
mkdir -p /mnt/var/db/xbps/keys
cp /var/db/xbps/keys/* /mnt/var/db/xbps/keys/

# grub-x86_64-efi is installed inside the chroot (see chroot script).
XBPS_ARCH="${ARCH}" xbps-install -Sy -R "${REPO}" -r /mnt \
	base-system \
	e2fsprogs

# ==============================================================================
# 6. GENERATE FSTAB
# ==============================================================================
echo "6. Generating fstab..."
xgenfstab -U /mnt > /mnt/etc/fstab
sed -i '/\/boot\/efi/{s/ [0-9]$/ 0/}' /mnt/etc/fstab

# ==============================================================================
# 7. SETUP CHROOT ENVIRONMENT
# ==============================================================================
echo "7. Setting up chroot environment..."
for dir in dev proc sys run; do
	mount --rbind "/${dir}" "/mnt/${dir}"
	mount --make-rslave "/mnt/${dir}"
done

# Required for grub-install to write EFI vars.
if [[ -d /sys/firmware/efi/efivars ]]; then
	mount -t efivarfs none /mnt/sys/firmware/efi/efivars 2>/dev/null || true
fi

cp /etc/resolv.conf /mnt/etc/resolv.conf

trap - EXIT
echo "Done! Run the chroot script next."