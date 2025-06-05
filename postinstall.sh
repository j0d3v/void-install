#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# 1. INSTALL DESKTOP AND AUDIO PACKAGES
# ==============================================================================
echo "1. Installing desktop and audio-related packages..."
xbps-install -S $(cat packages)

# ==============================================================================
# 2. CREATE AUDIO GROUPS (IF MISSING)
# ==============================================================================
echo "2. Creating required audio groups if missing..."
for group in pipewire pulse pulse-access; do
	if ! getent group "$group" >/dev/null; then
		groupadd "$group"
		echo "=> Group '$group' created."
	else
		echo "=> Group '$group' already exists. Skipping."
	fi
done

# ==============================================================================
# 3. PIPEWIRE & ALSA CONFIGURATION
# ==============================================================================
echo "3. Configuring PipeWire and ALSA..."
install -d /etc/pipewire/pipewire.conf.d
install -d /etc/alsa/conf.d

WP_CONF="/usr/share/examples/wireplumber/10-wireplumber.conf"
[ -f "$WP_CONF" ] && ln -sf "$WP_CONF" /etc/pipewire/pipewire.conf.d/

for file in 50-pipewire.conf 99-pipewire-default.conf; do
	src="/usr/share/alsa/alsa.conf.d/$file"
	dst="/etc/alsa/conf.d/$file"
	[ -f "$src" ] && ln -sf "$src" "$dst"
done

echo "/usr/lib/pipewire-0.3/jack" >/etc/ld.so.conf.d/pipewire-jack.conf
ldconfig

# ==============================================================================
# 4. ENABLE ESSENTIAL SERVICES
# ==============================================================================
echo "4. Enabling essential services (elogind and lightdm)..."
for svc in elogind lightdm; do
	ln -sf "/etc/sv/${svc}" "/var/service/${svc}"
done

# ==============================================================================
# 5. CONFIGURE X11 KEYBOARD LAYOUT
# ==============================================================================
echo "5. Configuring X11 keyboard layout (fr, nodeadkeys)..."
install -d /etc/X11/xorg.conf.d

cat >/etc/X11/xorg.conf.d/00-keyboard.conf <<EOF
Section "InputClass"
    Identifier "keyboard"
    MatchIsKeyboard "yes"
    Option "XkbLayout" "fr"
    Option "XkbVariant" "nodeadkeys"
EndSection
EOF

# ==============================================================================
# ✅ DONE
# ==============================================================================
echo "✅ Setup complete."
