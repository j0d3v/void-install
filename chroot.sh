#!/bin/bash
set -euo pipefail

# ==============================================================================
# VARIABLE DEFINITIONS
# ==============================================================================
SWAP_PART="/dev/nvme0n1p2"

NEW_USER="jo" # To be changed !

TIMEZONE="Europe/London"
LOCALE="en_US.UTF-8"
KEYMAP="fr"

HOSTNAME="void"

# Resolve swap UUID early — blkid requires /dev to be bind-mounted (done by bootstrap).
# Validated immediately so a missing UUID aborts before any changes are made.
SWAP_UUID="$(blkid -s UUID -o value "${SWAP_PART}")"
[[ -n "${SWAP_UUID}" ]] || { echo "ERROR: Could not resolve UUID for ${SWAP_PART}"; exit 1; }

# ==============================================================================
# 1. TIMEZONE, LOCALE, AND KEYMAP
# ==============================================================================
echo "1. Configuring timezone, locale, and keymap..."
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime

sed -i 's/^# *\(en_US\.UTF-8\)/\1/' /etc/default/libc-locales
echo "LANG=${LOCALE}" >/etc/locale.conf

cat >/etc/rc.conf <<EOF
TIMEZONE="${TIMEZONE}"
HARDWARECLOCK="UTC"
KEYMAP="${KEYMAP}"
EOF

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
# 3. ENABLE NONFREE REPOSITORY
# ==============================================================================
echo "3. Enabling non-free repository..."
xbps-install -Sy void-repo-nonfree

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
	efibootmgr \
	dracut \
	linux-firmware-amd \
	dbus

# ==============================================================================
# 5. USER CREATION
# ==============================================================================
echo "5. Creating user..."
useradd -m -G wheel,video,audio,lp "${NEW_USER}"
echo "Set password for ${NEW_USER}:"
passwd "${NEW_USER}"

cat >/etc/doas.conf <<EOF
permit persist :wheel
permit setenv { XAUTHORITY LANG LC_ALL } :wheel
EOF
chmod 400 /etc/doas.conf

# ==============================================================================
# 6. ROOT PASSWORD
# ==============================================================================
echo "6. Setting root password..."
passwd root

# ==============================================================================
# 7. NETWORK CONFIGURATION
# ==============================================================================
echo "7. Configuring networking (iwd + NetworkManager)..."
mkdir -p /etc/NetworkManager/conf.d
cat >/etc/NetworkManager/conf.d/10-iwd.conf <<EOF
[device]
wifi.backend=iwd

[main]
dns=none
EOF

mkdir -p /etc/iwd
cat >/etc/iwd/main.conf <<EOF
[General]
UseDefaultInterface=true
EnableNetworkConfiguration=true

[Network]
NameResolvingService=resolvconf
EOF

# Enable networking services.
ln -sf /etc/sv/dbus        /etc/runit/runsvdir/default/
ln -sf /etc/sv/iwd         /etc/runit/runsvdir/default/
ln -sf /etc/sv/NetworkManager /etc/runit/runsvdir/default/

# ==============================================================================
# 8. GRUB CONFIGURATION
# ==============================================================================
echo "8. Configuring GRUB..."
# Guard against duplicate resume= on re-runs.
if ! grep -q "resume=UUID=" /etc/default/grub; then
	sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=\"/GRUB_CMDLINE_LINUX_DEFAULT=\"resume=UUID=${SWAP_UUID} /" \
		/etc/default/grub
fi

# ==============================================================================
# 9. DRACUT CONFIGURATION (INITRAMFS)
# ==============================================================================
echo "9. Configuring dracut..."
mkdir -p /etc/dracut.conf.d

cat >/etc/dracut.conf.d/00-hostonly.conf <<EOF
hostonly=yes
hostonly_cmdline=yes
EOF

cat >/etc/dracut.conf.d/20-addmodules.conf <<EOF
add_dracutmodules+=" resume "
EOF

echo "tmpdir=/tmp" >/etc/dracut.conf.d/30-tmpfs.conf

# ==============================================================================
# 10. GRUB INSTALL
# ==============================================================================
echo "10. Installing GRUB..."
mountpoint -q /sys/firmware/efi/efivars || \
	mount -t efivarfs none /sys/firmware/efi/efivars

grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id="Void"

# ==============================================================================
# 11. FINAL RECONFIGURATION
# Rebuilds initramfs (dracut) and regenerates grub.cfg in one pass.
# ==============================================================================
echo "11. Finalizing system configuration..."
xbps-reconfigure -fa

echo "Chroot configuration complete!"