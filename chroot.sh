#!/bin/bash
set -euo pipefail

# ==============================================================================
# VARIABLE DEFINITIONS
# ==============================================================================
DISK="/dev/nvme0n1"
EFI_PART="${DISK}p1"
ROOT_PART="${DISK}p2"

CRYPT_NAME="cryptvoid"
MAPPER_PATH="/dev/mapper/${CRYPT_NAME}"

BTRFS_OPTS="rw,noatime,compress=zstd,discard=async"

NEW_USER="linus"

TIMEZONE="Europe/London"
LOCALE="en_US.UTF-8"
KEYMAP="fr"

HOSTNAME="xps"

SWAP_SUBVOL="/var/swap"
SWAP_FILE="${SWAP_SUBVOL}/swapfile"
SWAP_SIZE_GB=10

# ==============================================================================
# 1. TIMEZONE, LOCALE, AND KEYMAP
# ==============================================================================
echo "1. Configuring timezone, locale, and keymap..."
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime

sed -i 's/^# *\(en_US\.UTF-8\)/\1/' /etc/default/libc-locales
echo "LANG=${LOCALE}" >/etc/locale.conf

echo "KEYMAP='${KEYMAP}'" >/etc/rc.conf

xbps-reconfigure -f glibc-locales

# ==============================================================================
# 2. HOSTNAME AND /etc/hosts
# ==============================================================================
echo "2. Setting hostname and /etc/hosts..."
echo "${HOSTNAME}" >/etc/hostname

cat >/etc/hosts <<EOF
127.0.0.1       localhost
::1             localhost
127.0.1.1       ${HOSTNAME}.localdomain ${HOSTNAME}
EOF

# ==============================================================================
# 3. ENABLE NONFREE & MULTILIB REPOSITORIES
# ==============================================================================
echo "3. Enabling non-free and multilib repositories..."
xbps-install -Sy void-repo-nonfree void-repo-multilib xmirror
xmirror

# ==============================================================================
# 4. INSTALL ESSENTIAL PACKAGES
# ==============================================================================

echo "4. Installing essential packages..."
xbps-install -Sy \
	iwd \
	NetworkManager \
	openresolv \
	opendoas \
	grub-x86_64-efi \
	dracut \
	gcc \
	intel-ucode \
	dbus

# ==============================================================================
# 5. USER CREATION AND ROOT LOCKDOWN
# ==============================================================================
echo "5. Creating user and locking down root..."
useradd -m "${NEW_USER}"
passwd "${NEW_USER}"
usermod -aG wheel,video,audio,lp "${NEW_USER}"

# Disable direct root login
usermod -s /sbin/nologin root
passwd -l root

# Enable wheel group for doas
# (Creates /etc/doas.conf if it doesn't exist, then grants :wheel permission)
if [ ! -f /etc/doas.conf ]; then
	touch /etc/doas.conf
	chmod 600 /etc/doas.conf
fi

cat <<EOF >/etc/doas.conf
# Allow the user to use doas with password caching
permit persist $NEW_USER as root

# Allow only certain environment variables to be set (e.g., for graphical apps)
permit setenv { XAUTHORITY LANG LC_ALL } $NEW_USER

# Deny root from using doas entirely
deny root
EOF

# ==============================================================================
# 6. NETWORK CONFIGURATION
# ==============================================================================
echo "6. Configuring networking (iwd + NetworkManager)..."
mkdir -p /etc/NetworkManager/conf.d

cat >/etc/NetworkManager/conf.d/10-iwd.conf <<EOF
[device]
wifi.backend=iwd
EOF

cat >/etc/iwd/main.conf <<EOF
[General]
UseDefaultInterface=true
EnableNetworkConfiguration=true

[Network]
NameResolvingService=resolvconf
EOF

ln -s /etc/sv/dbus /var/service/
ln -s /etc/sv/iwd /var/service/
ln -s /etc/sv/NetworkManager /var/service/

if [ -e /var/service/wpa_supplicant ]; then
	unlink /var/service/wpa_supplicant
fi

if [ -e /var/service/dhcpcd ]; then
	unlink /var/service/dhcpcd
fi

# ==============================================================================
# 7. FSTAB GENERATION (BTRFS + EFI + TMPFS)
# ==============================================================================
echo "7. Generating /etc/fstab..."
EFI_UUID=$(blkid -s UUID -o value "${EFI_PART}")
ROOT_UUID=$(blkid -s UUID -o value "${MAPPER_PATH}")
LUKS_UUID=$(blkid -s UUID -o value "${ROOT_PART}")

cat >/etc/fstab <<EOF
UUID=${ROOT_UUID}  /           btrfs   ${BTRFS_OPTS},subvol=@        0 1
UUID=${ROOT_UUID}  /home       btrfs   ${BTRFS_OPTS},subvol=@home    0 2
UUID=${ROOT_UUID}  /.snapshots btrfs   ${BTRFS_OPTS},subvol=@snapshots 0 2
UUID=${EFI_UUID}   /efi        vfat    defaults,noatime          0 2
tmpfs              /tmp        tmpfs   defaults,nosuid,nodev      0 0
EOF

# ==============================================================================
# 8. GRUB CONFIGURATION FOR LUKS AND BTRFS
# ==============================================================================
echo "8. Configuring GRUB for LUKS and Btrfs..."
echo "GRUB_ENABLE_CRYPTODISK=y" >>/etc/default/grub

# ==============================================================================
# 9. KEYFILE CREATION AND /etc/crypttab
# ==============================================================================
echo "9. Creating keyfile for LUKS unlocking..."
dd if=/dev/urandom of=/boot/keyfile.bin bs=512 count=4 status=none
chmod 000 /boot/keyfile.bin

cryptsetup luksAddKey "${ROOT_PART}" /boot/keyfile.bin

cat >/etc/crypttab <<EOF
${CRYPT_NAME} UUID=${LUKS_UUID} /boot/keyfile.bin luks
EOF

# ==============================================================================
# 10. DRACUT CONFIGURATION (INITRAMFS)
# ==============================================================================
echo "10. Configuring dracut..."
mkdir -p /etc/dracut.conf.d

cat >/etc/dracut.conf.d/00-hostonly.conf <<EOF
hostonly=yes
hostonly_cmdline=yes
EOF

cat >/etc/dracut.conf.d/10-crypt.conf <<EOF
install_items+="/boot/keyfile.bin /etc/crypttab"
EOF

cat >/etc/dracut.conf.d/20-addmodules.conf <<EOF
add_dracutmodules+=" crypt btrfs resume "
EOF

echo "tmpdir=/tmp" >/etc/dracut.conf.d/30-tmpfs.conf

dracut --regenerate-all --force --hostonly

# ==============================================================================
# 11. BTRFS SWAPFILE AND HIBERNATION
# ==============================================================================
echo "11. Setting up Btrfs swapfile and resume support..."
btrfs subvolume create "${SWAP_SUBVOL}"

# Disable CoW on swapfile parent directory, then create file
chattr +C "${SWAP_SUBVOL}"
truncate -s 0 "${SWAP_FILE}"
chmod 600 "${SWAP_FILE}"
dd if=/dev/zero of="${SWAP_FILE}" bs=1G count=${SWAP_SIZE_GB} status=progress

mkswap "${SWAP_FILE}"
swapon "${SWAP_FILE}"

# Build helper to calculate resume_offset
RESUME_OFFSET=$(filefrag -v ${SWAP_FILE} | awk 'NR==4 {print $4}' | cut -d. -f1)

sed -i '/^GRUB_CMDLINE_LINUX_DEFAULT=/d' /etc/default/grub
echo "GRUB_CMDLINE_LINUX_DEFAULT=\"rd.auto=1 rd.luks.name=${LUKS_UUID}=${CRYPT_NAME} rd.luks.allow-discards=${LUKS_UUID} resume=UUID=${ROOT_UUID} resume_offset=${RESUME_OFFSET}\"" >>/etc/default/grub

grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id="Void"
grub-mkconfig -o /boot/grub/grub.cfg

echo "${SWAP_FILE} none swap defaults 0 0" >>/etc/fstab

# ==============================================================================
# 12. FINAL RECONFIGURATION
# ==============================================================================
echo "12. Finalizing system configuration..."
xbps-reconfigure -fa

echo "Chroot configuration complete!"
