#!/bin/bash
set -euo pipefail

# ==============================================================================
# CONFIGURATION
# ==============================================================================
DISK="/dev/nvme0n1"
EFI_PART="${DISK}p1"
ROOT_PART="${DISK}p2"

CRYPT_NAME="cryptvoid"
MAPPER_PATH="/dev/mapper/${CRYPT_NAME}"

BTRFS_OPTS="rw,noatime,compress=zstd,discard=async"

REPO="https://repo-fi.voidlinux.org/current"
ARCH="x86_64"

# ==============================================================================
# 0. UPDATE XBPS AND INSTALL PARTED
# ==============================================================================
echo "0. Updating XBPS package index and installing parted..."
xbps-install -Syu xbps
xbps-install -S parted

# ==============================================================================
# 1. WIPE EXISTING SIGNATURES
# ==============================================================================
echo "1. Wiping existing disk signatures..."
wipefs -a "${DISK}"

# ==============================================================================
# 2. PARTITIONING
# ==============================================================================
parted -s "${DISK}" \
	mklabel gpt \
	mkpart ESP fat32 1MiB 513MiB \
	set 1 boot on \
	mkpart primary btrfs 513MiB 100%

# ==============================================================================
# 3. ENCRYPT ROOT PARTITION
# ==============================================================================
echo "3. Encrypting the root partition with LUKS1..."
cryptsetup luksFormat --type luks1 "${ROOT_PART}"
cryptsetup open "${ROOT_PART}" "${CRYPT_NAME}"

# ==============================================================================
# 4. FORMAT PARTITIONS
# ==============================================================================
echo "4. Formatting EFI and root partitions..."
mkfs.fat -F32 -n EFI "${EFI_PART}"
mkfs.btrfs -L Void "${MAPPER_PATH}"

# ==============================================================================
# 5. CREATE TOP-LEVEL BTRFS SUBVOLUMES
# ==============================================================================
echo "5. Creating top-level Btrfs subvolumes..."
mount -o "${BTRFS_OPTS}" "${MAPPER_PATH}" /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
umount /mnt

# ==============================================================================
# 6. MOUNT TOP-LEVEL SUBVOLUMES
# ==============================================================================
echo "6. Mounting top-level subvolumes..."
mount -o "${BTRFS_OPTS},subvol=@" "${MAPPER_PATH}" /mnt
mkdir -p /mnt/{home,.snapshots,var/cache,efi}

mount -o "${BTRFS_OPTS},subvol=@home" "${MAPPER_PATH}" /mnt/home
mount -o "${BTRFS_OPTS},subvol=@snapshots" "${MAPPER_PATH}" /mnt/.snapshots

# ==============================================================================
# 7. CREATE ADDITIONAL SUBVOLUMES INSIDE @
# ==============================================================================
echo "7. Creating additional subvolumes inside @..."
btrfs subvolume create /mnt/var/cache/xbps
btrfs subvolume create /mnt/var/tmp
btrfs subvolume create /mnt/var/log
btrfs subvolume create /mnt/srv

# ==============================================================================
# 8. MOUNT EFI PARTITION
# ==============================================================================
echo "8. Mounting EFI partition..."
mount -o rw,noatime "${EFI_PART}" /mnt/efi

# ==============================================================================
# 9. BASE SYSTEM INSTALLATION
# ==============================================================================
echo "9. Installing base system into chroot..."
mkdir -p /mnt/var/db/xbps/keys
cp /var/db/xbps/keys/* /mnt/var/db/xbps/keys/

# Use the voidlinux mirror, target architecture, and install essential packages
XBPS_ARCH="${ARCH}" xbps-install -Sy -R "${REPO}" -r /mnt \
	base-system \
	btrfs-progs \
	cryptsetup

# ==============================================================================
# 10. SETUP CHROOT ENVIRONMENT
# ==============================================================================
echo "10. Setting up chroot environment..."
for dir in dev proc sys run; do
	mount --rbind "/${dir}" "/mnt/${dir}"
	mount --make-rslave "/mnt/${dir}"
done

cp /etc/resolv.conf /mnt/etc/

# ==============================================================================
# 11. ENTER CHROOT
# ==============================================================================
echo "11. Entering chroot..."
chroot /mnt /bin/bash
