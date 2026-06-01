#!/bin/bash
set -euo pipefail

BACKTITLE="Void Linux Installer"
REPO="https://repo-fi.voidlinux.org/current"
ARCH="x86_64"

[[ "${EUID}" -eq 0 ]] || { echo "ERROR: Run as root."; exit 1; }

# ------------------------------------------------------------------------------
# PRE-FLIGHT CHECKS
# ------------------------------------------------------------------------------
preflight_checks() {
	local errors=() warnings=()

	[[ -d /sys/firmware/efi/efivars ]] \
		|| errors+=("Not booted in UEFI mode. This installer requires UEFI.")

	ping -c1 -W3 repo-fi.voidlinux.org &>/dev/null \
		|| errors+=("No internet access. Cannot reach repo-fi.voidlinux.org.")

	for cmd in lsblk parted mkfs.fat mkfs.btrfs mount chroot; do
		command -v "${cmd}" &>/dev/null \
			|| errors+=("Required command not found: ${cmd}")
	done

	[[ -d /usr/share/zoneinfo ]] \
		|| errors+=("Timezone data not found at /usr/share/zoneinfo.")

	[[ -f /etc/default/libc-locales ]] \
		|| warnings+=("/etc/default/libc-locales not found — locale selection may be empty.")

	[[ -d /usr/share/kbd/keymaps ]] \
		|| warnings+=("/usr/share/kbd/keymaps not found — keymap selection may be empty.")

	if [[ ${#errors[@]} -gt 0 ]]; then
		local msg="Pre-flight checks FAILED:\n\n"
		for e in "${errors[@]}"; do msg+="  * ${e}\n"; done
		[[ ${#warnings[@]} -gt 0 ]] && {
			msg+="\nWarnings:\n"
			for w in "${warnings[@]}"; do msg+="  ! ${w}\n"; done
		}
		printf '%b' "${msg}"
		exit 1
	fi

	if [[ ${#warnings[@]} -gt 0 ]]; then
		local msg="Pre-flight warnings (non-fatal):\n\n"
		for w in "${warnings[@]}"; do msg+="  ! ${w}\n"; done
		msg+="\nContinue anyway?"
		dialog --backtitle "${BACKTITLE}" --title " Pre-flight Warnings " \
			--yesno "${msg}" 16 65 || { clear; echo "Aborted."; exit 1; }
	fi
}

# ------------------------------------------------------------------------------
# DIALOG THEME
# ------------------------------------------------------------------------------
DIALOGRC_FILE=$(mktemp)
export DIALOGRC="${DIALOGRC_FILE}"

cat > "${DIALOGRC_FILE}" << 'EOF'
use_colors = ON
use_shadow = ON
screen_color = (GREEN,BLACK,ON)
shadow_color = (BLACK,BLACK,ON)
dialog_color = (GREEN,BLACK,OFF)
title_color = (GREEN,BLACK,ON)
border_color = (GREEN,BLACK,ON)
button_active_color = (BLACK,GREEN,ON)
button_inactive_color = (GREEN,BLACK,OFF)
button_key_active_color = (BLACK,GREEN,ON)
button_key_inactive_color = (GREEN,BLACK,OFF)
button_label_active_color = (BLACK,GREEN,ON)
button_label_inactive_color = (GREEN,BLACK,OFF)
inputbox_color = (GREEN,BLACK,OFF)
inputbox_border_color = (GREEN,BLACK,ON)
searchbox_color = (GREEN,BLACK,OFF)
searchbox_title_color = (GREEN,BLACK,ON)
searchbox_border_color = (GREEN,BLACK,ON)
position_indicator_color = (GREEN,BLACK,ON)
menubox_color = (GREEN,BLACK,OFF)
menubox_border_color = (GREEN,BLACK,ON)
item_color = (GREEN,BLACK,OFF)
item_selected_color = (BLACK,GREEN,ON)
tag_color = (GREEN,BLACK,ON)
tag_selected_color = (BLACK,GREEN,ON)
tag_key_color = (GREEN,BLACK,OFF)
tag_key_selected_color = (BLACK,GREEN,ON)
check_color = (GREEN,BLACK,OFF)
check_selected_color = (BLACK,GREEN,ON)
uarrow_color = (GREEN,BLACK,ON)
darrow_color = (GREEN,BLACK,ON)
itemhelp_color = (GREEN,BLACK,OFF)
form_active_text_color = (BLACK,GREEN,ON)
form_text_color = (GREEN,BLACK,OFF)
form_item_readonly_color = (GREEN,BLACK,ON)
gauge_color = (BLACK,GREEN,ON)
EOF

# ------------------------------------------------------------------------------
# DIALOG HELPERS
# ------------------------------------------------------------------------------
msg() {
	dialog --backtitle "${BACKTITLE}" --title "${1}" --msgbox "${2}" 8 60
}

confirm() {
	local height="${3:-10}" width="${4:-65}"
	dialog --backtitle "${BACKTITLE}" --title "${1}" --yesno "${2}" "${height}" "${width}"
}

infobox() {
	dialog --backtitle "${BACKTITLE}" --title "${1}" --infobox "${2}" 5 60
}

inputbox() {
	local title="$1" prompt="$2" default="${3:-}"
	dialog --backtitle "${BACKTITLE}" --title "${title}" \
		--inputbox "${prompt}" 8 60 "${default}" 3>&1 1>&2 2>&3
}

passwordbox() {
	local title="$1" prompt="$2"
	dialog --backtitle "${BACKTITLE}" --title "${title}" \
		--passwordbox "${prompt}" 8 60 3>&1 1>&2 2>&3
}

pick_menu() {
	local title="$1" prompt="$2"
	shift 2
	local menu_args=()
	for item in "$@"; do
		menu_args+=("${item}" "")
	done
	dialog --backtitle "${BACKTITLE}" --title "${title}" \
		--menu "${prompt}" 22 65 16 "${menu_args[@]}" 3>&1 1>&2 2>&3
}

# ------------------------------------------------------------------------------
# BOOTSTRAP
# ------------------------------------------------------------------------------
command -v dialog &>/dev/null || { echo "Installing dialog..."; xbps-install -Sy dialog >/dev/null; }

preflight_checks

# ------------------------------------------------------------------------------
# WELCOME
# ------------------------------------------------------------------------------
dialog --backtitle "${BACKTITLE}" \
	--title " Welcome " \
	--msgbox "\n  Void Linux Installer\n\n  This will install Void Linux with:\n\n    Btrfs  — subvolumes, zstd compression\n    Sway   — Wayland compositor\n    iwd    — WiFi backend\n    lidm   — login manager\n    No swap (16 GB RAM)\n\n  Press OK to begin." \
	16 60

# ------------------------------------------------------------------------------
# GATHER CONFIGURATION
# ------------------------------------------------------------------------------

# Disk
MENU_ITEMS=()
while IFS= read -r line; do
	read -r name size model <<< "$(awk '{name=$1; size=$2; $1=$2=""; gsub(/^[[:space:]]+/,"",$0); print name, size, $0}' <<<"${line}")"
	MENU_ITEMS+=("/dev/${name}" "${size} — ${model}")
done < <(lsblk -d -o NAME,SIZE,MODEL --noheadings | grep -v loop)

[[ ${#MENU_ITEMS[@]} -gt 0 ]] || { clear; echo "ERROR: No block devices found."; exit 1; }

DISK=$(dialog --backtitle "${BACKTITLE}" --title "Select Disk" \
	--menu "Select the target disk.\nWARNING: All data on this disk will be destroyed." \
	20 70 10 "${MENU_ITEMS[@]}" 3>&1 1>&2 2>&3) || { clear; echo "Aborted."; exit 1; }

[[ -b "${DISK}" ]] || { clear; echo "ERROR: '${DISK}' is not a valid block device."; exit 1; }

if [[ "${DISK}" =~ nvme|mmcblk ]]; then
	PART="${DISK}p"
else
	PART="${DISK}"
fi

EFI_PART="${PART}1"
ROOT_PART="${PART}2"

# Username
while true; do
	NEW_USER=$(inputbox "Username" "Enter new username:") \
		|| { clear; echo "Aborted."; exit 1; }
	[[ "${NEW_USER}" != "root" ]] && [[ "${NEW_USER}" =~ ^[a-z_][a-z0-9_-]*$ ]] && break
	msg "Username" "Invalid username '${NEW_USER}'.\nUse lowercase letters, digits, hyphens, or underscores."
done

# Password
while true; do
	USER_PASS=$(passwordbox "Password" "Enter password for ${NEW_USER}:") \
		|| { clear; echo "Aborted."; exit 1; }
	USER_PASS2=$(passwordbox "Password" "Confirm password for ${NEW_USER}:") \
		|| { clear; echo "Aborted."; exit 1; }
	[[ "${USER_PASS}" == "${USER_PASS2}" ]] && { unset USER_PASS2; break; }
	msg "Password" "Passwords do not match. Try again."
done

USER_PASS_B64=$(printf '%s' "${USER_PASS}" | base64)
unset USER_PASS

# Hostname
while true; do
	HOSTNAME=$(inputbox "Hostname" "Enter system hostname:") \
		|| { clear; echo "Aborted."; exit 1; }
	[[ -n "${HOSTNAME}" ]] && break
	msg "Hostname" "Hostname cannot be empty."
done

# Timezone
mapfile -t TZ_REGIONS < <(
	find /usr/share/zoneinfo/ -maxdepth 1 -mindepth 1 -type d \
		| sed 's|.*/||' \
		| grep -vE '^(Factory|SECURITY)' \
		| sort
)
[[ ${#TZ_REGIONS[@]} -gt 0 ]] || { msg "Error" "No timezone regions found."; exit 1; }

TZ_REGION=$(pick_menu "Timezone" "Select timezone region:" "${TZ_REGIONS[@]}") \
	|| { clear; echo "Aborted."; exit 1; }

if [[ -d "/usr/share/zoneinfo/${TZ_REGION}" ]]; then
	mapfile -t TZ_ZONES < <(
		find "/usr/share/zoneinfo/${TZ_REGION}" -type f \
			| sed "s|/usr/share/zoneinfo/${TZ_REGION}/||" \
			| sort
	)
	[[ ${#TZ_ZONES[@]} -gt 0 ]] || { msg "Error" "No zones found under ${TZ_REGION}."; exit 1; }
	TZ_ZONE=$(pick_menu "Timezone" "Select timezone (${TZ_REGION}):" "${TZ_ZONES[@]}") \
		|| { clear; echo "Aborted."; exit 1; }
	TIMEZONE="${TZ_REGION}/${TZ_ZONE}"
else
	TIMEZONE="${TZ_REGION}"
fi

# Locale
mapfile -t LOCALE_LIST < <(
	grep -E '^#?[a-z]' /etc/default/libc-locales \
		| sed 's/^#[[:space:]]*//' \
		| awk '{print $1}' \
		| sort -u
)
[[ ${#LOCALE_LIST[@]} -gt 0 ]] || { msg "Error" "No locales found."; exit 1; }

LOCALE=$(pick_menu "Locale" "Select system locale:" "${LOCALE_LIST[@]}") \
	|| { clear; echo "Aborted."; exit 1; }

# Keymap
mapfile -t KEYMAP_LIST < <(
	find /usr/share/kbd/keymaps -name "*.map.gz" \
		| sed 's|.*/||; s|\.map\.gz$||' \
		| sort
)
[[ ${#KEYMAP_LIST[@]} -gt 0 ]] || { msg "Error" "No keymaps found."; exit 1; }

KEYMAP=$(pick_menu "Keymap" "Select keyboard layout:" "${KEYMAP_LIST[@]}") \
	|| { clear; echo "Aborted."; exit 1; }

# Summary confirmation
confirm " Confirm Installation " \
	"Disk:      ${DISK}\nUser:      ${NEW_USER}\nHostname:  ${HOSTNAME}\nTimezone:  ${TIMEZONE}\nLocale:    ${LOCALE}\nKeymap:    ${KEYMAP}\n\nAll data on ${DISK} will be DESTROYED.\n\nProceed?" \
	|| { clear; echo "Aborted."; exit 1; }

# ------------------------------------------------------------------------------
# CLEANUP TRAP
# ------------------------------------------------------------------------------
cleanup() {
	umount -R /mnt 2>/dev/null || true
	rm -f "${DIALOGRC_FILE}"
}
trap cleanup EXIT

clear

# ------------------------------------------------------------------------------
# UPDATE XBPS + LIVE TOOLS
# ------------------------------------------------------------------------------
echo "==> Updating xbps and installing tools..."
xbps-install -Syu xbps &>/dev/null
xbps-install -Sy parted xtools nvme-cli btrfs-progs dialog &>/dev/null

# ------------------------------------------------------------------------------
# STEP 1/4 — DISK ERASE & PARTITION
# ------------------------------------------------------------------------------
confirm " Step 1 of 4: Disk Erase & Partition " \
	"About to ERASE and REPARTITION:\n\n  ${DISK}\n\nThis is IRREVERSIBLE. All existing data will be lost.\n\nProceed?" \
	12 70 || { clear; echo "Aborted."; exit 1; }

if [[ "${DISK}" =~ nvme ]]; then
	if confirm "Secure Erase" "Securely erase ${DISK} with nvme format?\n\nRecommended for fresh installs."; then
		infobox "Secure Erase" "Running NVMe secure erase on ${DISK}..."
		nvme format "${DISK}" --ses=1 --force
		msg "Secure Erase" "Secure erase complete."
	else
		infobox "Secure Erase" "Wiping signatures on ${DISK}..."
		wipefs -a "${DISK}"
	fi
else
	infobox "Secure Erase" "Wiping signatures on ${DISK}..."
	wipefs -a "${DISK}"
fi

infobox "Partitioning" "Creating partitions on ${DISK}..."
parted -s "${DISK}" \
	mklabel gpt \
	mkpart ESP fat32 1MiB 513MiB \
	set 1 boot on \
	mkpart root btrfs 513MiB 100%

partprobe "${DISK}"
udevadm settle

infobox "Formatting" "Formatting partitions..."
mkfs.fat -F32 -n EFI "${EFI_PART}"
mkfs.btrfs -L VoidRoot -f "${ROOT_PART}"

# ------------------------------------------------------------------------------
# STEP 2/4 — BTRFS SUBVOLUMES & MOUNTS
# ------------------------------------------------------------------------------
confirm " Step 2 of 4: Btrfs Setup " \
	"Disk partitioned and formatted.\n\nAbout to create Btrfs subvolumes and mount the filesystem.\n\nProceed?" \
	10 65 || { clear; echo "Aborted."; exit 1; }

infobox "Btrfs" "Creating subvolumes..."
mount "${ROOT_PART}" /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@var_cache
umount /mnt

infobox "Mounting" "Mounting subvolumes..."
BTRFS_OPTS="noatime,compress=zstd,space_cache=v2"
mount -o "${BTRFS_OPTS},subvol=@"          "${ROOT_PART}" /mnt
mkdir -p /mnt/{home,.snapshots,var/cache,boot/efi}
mount -o "${BTRFS_OPTS},subvol=@home"      "${ROOT_PART}" /mnt/home
mount -o "${BTRFS_OPTS},subvol=@snapshots" "${ROOT_PART}" /mnt/.snapshots
mount -o "${BTRFS_OPTS},subvol=@var_cache" "${ROOT_PART}" /mnt/var/cache
mount -o rw,noatime                        "${EFI_PART}"  /mnt/boot/efi

# ------------------------------------------------------------------------------
# STEP 3/4 — BASE SYSTEM
# ------------------------------------------------------------------------------
confirm " Step 3 of 4: Base System Install " \
	"Filesystem ready.\n\nAbout to download and install the Void Linux base system.\nThis requires internet and may take a while.\n\nProceed?" \
	10 65 || { clear; echo "Aborted."; exit 1; }

infobox "Base System" "Installing base system — this may take a while..."
mkdir -p /mnt/var/db/xbps/keys
cp /var/db/xbps/keys/* /mnt/var/db/xbps/keys/

mkdir -p /tmp/xbps.d /mnt/etc/xbps.d
cat > /tmp/xbps.d/10-ignorepkg.conf << 'PKGEOF'
ignorepkg=linux-firmware-intel,linux-firmware-nvidia,linux-firmware-broadcom,sof-firmware,ipw2100-firmware,ipw2200-firmware,zd1211-firmware
PKGEOF
cp /tmp/xbps.d/10-ignorepkg.conf /mnt/etc/xbps.d/10-ignorepkg.conf

XBPS_ARCH="${ARCH}" xbps-install -Sy -C /tmp/xbps.d -R "${REPO}" -r /mnt base-system

infobox "fstab" "Generating fstab..."
xgenfstab -U /mnt > /mnt/etc/fstab
sed -i '/\/boot\/efi/ s/[0-9]*$/0/' /mnt/etc/fstab

# ------------------------------------------------------------------------------
# STEP 4/4 — CHROOT SETUP
# ------------------------------------------------------------------------------
confirm " Step 4 of 4: System Configuration " \
	"Base system installed.\n\nAbout to configure the system inside chroot:\n  packages, user, bootloader, services.\n\nProceed?" \
	10 65 || { clear; echo "Aborted."; exit 1; }

infobox "Chroot" "Setting up chroot environment..."
for dir in dev proc sys run; do
	mount --rbind "/${dir}" "/mnt/${dir}"
	mount --make-rslave "/mnt/${dir}"
done

[[ -d /sys/firmware/efi/efivars ]] && \
	mount -t efivarfs none /mnt/sys/firmware/efi/efivars 2>/dev/null || true

cp /etc/resolv.conf /mnt/etc/resolv.conf

# Variable block — values expand here
cat > /mnt/root/setup.sh << VAREOF
#!/bin/bash
set -euo pipefail
NEW_USER="${NEW_USER}"
HOSTNAME="${HOSTNAME}"
TIMEZONE="${TIMEZONE}"
LOCALE="${LOCALE}"
KEYMAP="${KEYMAP}"
USER_PASS_B64="${USER_PASS_B64}"
VAREOF

# Setup logic — no expansion, runtime variables used
cat >> /mnt/root/setup.sh << 'SETUP_EOF'

USER_PASS=$(printf '%s' "${USER_PASS_B64}" | base64 -d)
unset USER_PASS_B64

echo "  Timezone / locale / keymap..."
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime

LOCALE_ESCAPED="${LOCALE//./\\.}"
sed -i "s|^#[[:space:]]*\(${LOCALE_ESCAPED}\)|\1|" /etc/default/libc-locales
echo "LANG=${LOCALE}" > /etc/locale.conf

cat > /etc/rc.conf << CONF_EOF
TIMEZONE="${TIMEZONE}"
HARDWARECLOCK="UTC"
KEYMAP="${KEYMAP}"
CONF_EOF

xbps-reconfigure -f glibc-locales

echo "  Hostname..."
echo "${HOSTNAME}" > /etc/hostname

cat > /etc/hosts << HOSTS_EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
HOSTS_EOF

echo "  Non-free repository..."
xbps-install -Sy void-repo-nonfree

echo "  Essential packages..."
xbps-install -Sy \
	iwd \
	NetworkManager \
	openresolv \
	grub-x86_64-efi \
	efibootmgr \
	dracut \
	linux-firmware-amd

echo "  Desktop packages..."
xbps-install -Sy \
    alsa-pipewire btrfs-progs bat btop \
    chrony curl dejavu-fonts-ttf engrampa \
    exa fastfetch flatpak foot \
    git gnome-disk-utility gnome-keyring grim \
    gtklock gvfs-mtp htop imv \
    keepassxc lidm light lm_sensors \
    mako mate-polkit mesa-dri mesa-vaapi \
    mesa-vulkan-radeon mpv neovim network-manager-applet \
    noto-fonts-emoji ntfs-3g nwg-look openssh \
    pamixer pcmanfm pipewire slurp \
    starship sway swaybg swayidle \
    swaylock tlp ufw unzip \
    void-repo-nonfree Waybar wget wireplumber \
    wl-clipboard wlr-randr wofi xdg-desktop-portal \
    xdg-desktop-portal-wlr xdg-user-dirs xdg-utils xhost \
    xmirror xwayland-satellite xz yt-dlp \
    zathura zathura-pdf-poppler zip zsh

echo "  User and sudo..."
useradd -m -s /bin/bash -d "/home/${NEW_USER}" -G wheel,video,audio,lp,input "${NEW_USER}"
printf '%s:%s' "${NEW_USER}" "${USER_PASS}" | chpasswd
unset USER_PASS

echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel
chmod 440 /etc/sudoers.d/wheel
passwd -l root

echo "  User groups..."
getent group pipewire >/dev/null || groupadd pipewire
usermod -aG pipewire "${NEW_USER}"
su - "${NEW_USER}" -c "xdg-user-dirs-update" 2>/dev/null || true

echo "  PipeWire / ALSA..."
install -d /etc/pipewire/pipewire.conf.d
install -d /etc/alsa/conf.d

WP_CONF="/usr/share/examples/wireplumber/10-wireplumber.conf"
[[ -f "${WP_CONF}" ]] && ln -sf "${WP_CONF}" /etc/pipewire/pipewire.conf.d/

for file in 50-pipewire.conf 99-pipewire-default.conf; do
	src="/usr/share/alsa/alsa.conf.d/${file}"
	[[ -f "${src}" ]] && ln -sf "${src}" "/etc/alsa/conf.d/${file}"
done

echo "/usr/lib/pipewire-0.3/jack" >> /etc/ld.so.conf
ldconfig

echo "  Networking..."
mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/10-iwd.conf << NM_EOF
[device]
wifi.backend=iwd
NM_EOF

mkdir -p /etc/iwd
cat > /etc/iwd/main.conf << IWD_EOF
[General]
UseDefaultInterface=true
EnableNetworkConfiguration=false
IWD_EOF

echo "  Dracut..."
mkdir -p /etc/dracut.conf.d
cat > /etc/dracut.conf.d/00-hostonly.conf << DRAC_EOF
hostonly=yes
hostonly_cmdline=yes
DRAC_EOF
echo "tmpdir=/tmp" > /etc/dracut.conf.d/30-tmpfs.conf

echo "  Final reconfigure (builds initramfs)..."
xbps-reconfigure -fa

echo "  GRUB..."
mountpoint -q /sys/firmware/efi/efivars || \
	mount -t efivarfs none /sys/firmware/efi/efivars
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id="Void"
grub-mkconfig -o /boot/grub/grub.cfg

echo "  Enabling services..."
for svc in udevd agetty-tty1 agetty-tty2 dbus iwd NetworkManager chrony elogind lidm polkit tlp; do
	ln -sf "/etc/sv/${svc}" /etc/runit/runsvdir/default/
done

echo "  Setup complete."
SETUP_EOF

chmod +x /mnt/root/setup.sh

infobox "Installing" "Running full system setup inside chroot..."
chroot /mnt /root/setup.sh
rm /mnt/root/setup.sh

# ------------------------------------------------------------------------------
# DONE
# ------------------------------------------------------------------------------
trap - EXIT
cleanup

dialog --backtitle "${BACKTITLE}" \
	--title " Installation Complete " \
	--msgbox "\n  Void Linux has been installed successfully!\n\n  You can now reboot into your new system.\n  lidm will present the login screen —\n  select Sway from the session menu.\n\n  Press OK to exit." \
	14 60

clear
echo "Done. Reboot when ready."
