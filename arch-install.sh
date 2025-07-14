#!/bin/bash
set -euo pipefail

# === 0. Welcome & Time Sync ===
echo "=== Arch Linux Interactive Installer ==="
timedatectl set-ntp true

# === 1. Disk Selection ===
echo "Available disks:"
lsblk -d -e 7,11 -o NAME,SIZE,MODEL
read -rp "Enter the target disk (e.g., /dev/sda): " DISK

# === 2. Boot Mode Detection ===
if [ -d /sys/firmware/efi ]; then
    BOOT_MODE="UEFI"
else
    BOOT_MODE="BIOS"
fi
echo "Boot mode detected: $BOOT_MODE"

# === 3. Partitioning ===
read -rp "Use automatic partitioning? [y/N]: " AUTO_PART

if [[ "$AUTO_PART" =~ ^[Yy]$ ]]; then
    echo "Wiping and partitioning $DISK..."
    wipefs -af "$DISK"
    sgdisk -Z "$DISK"

    if [[ "$BOOT_MODE" == "UEFI" ]]; then
        sgdisk -n 1:0:+512M -t 1:ef00 "$DISK"  # EFI
        sgdisk -n 2:0:0     -t 2:8300 "$DISK"  # root
        EFI_PART="${DISK}1"
        ROOT_PART="${DISK}2"
    else
        sgdisk -n 1:0:0 -t 1:8300 "$DISK"
        ROOT_PART="${DISK}1"
    fi
else
    echo "Please partition your disk manually (use cgdisk, fdisk, etc.), then press Enter."
    read -rp "Enter root partition (e.g., /dev/sda2): " ROOT_PART
    if [[ "$BOOT_MODE" == "UEFI" ]]; then
        read -rp "Enter EFI partition (e.g., /dev/sda1): " EFI_PART
    fi
fi

# === 4. Filesystem ===
echo "Choose filesystem for root partition:"
select FILESYSTEM in ext4 btrfs xfs; do
    [[ -n "$FILESYSTEM" ]] && break
done
echo "Formatting $ROOT_PART as $FILESYSTEM..."
mkfs."$FILESYSTEM" "$ROOT_PART"

if [[ "$BOOT_MODE" == "UEFI" ]]; then
    echo "Formatting $EFI_PART as FAT32..."
    mkfs.fat -F32 "$EFI_PART"
fi

# === 5. Mount Partitions ===
mount "$ROOT_PART" /mnt

if [[ "$BOOT_MODE" == "UEFI" ]]; then
    mkdir -p /mnt/boot/efi
    mount "$EFI_PART" /mnt/boot/efi
else
    mkdir -p /mnt/boot
fi

# === 6. Hostname ===
read -rp "Enter hostname: " HOSTNAME

# === 7. User Creation ===
read -rp "Enter username: " USERNAME
read -rsp "Enter password for $USERNAME: " PASSWORD
echo

# === 8. Desktop Environment ===
echo "Choose desktop environment:"
select DE in GNOME KDE XFCE i3 None; do
    [[ -n "$DE" ]] && break
done

# === 9. Sudo ===
read -rp "Install sudo and allow wheel group? [y/N]: " INSTALL_SUDO

# === 10. Networking ===
read -rp "Install NetworkManager? [y/N]: " INSTALL_NET

# === 11. Base Install ===
echo "Installing base system..."
pacstrap /mnt base linux linux-firmware vim grub os-prober

genfstab -U /mnt >> /mnt/etc/fstab

# === 12. Chroot Configuration ===
arch-chroot /mnt /bin/bash <<EOF
set -e

export DISK="$DISK"
export BOOT_MODE="$BOOT_MODE"
export EFI_PART="${EFI_PART:-}"
export USERNAME="$USERNAME"
export PASSWORD="$PASSWORD"
export HOSTNAME="$HOSTNAME"
export INSTALL_SUDO="$INSTALL_SUDO"
export INSTALL_NET="$INSTALL_NET"
export DE="$DE"

ln -sf /usr/share/zoneinfo/UTC /etc/localtime
hwclock --systohc

echo "\$HOSTNAME" > /etc/hostname
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# User creation
useradd -m "\$USERNAME"
echo "\$USERNAME:\$PASSWORD" | chpasswd

# Sudo setup
if [[ "\$INSTALL_SUDO" =~ ^[Yy]$ ]]; then
    pacman -S --noconfirm sudo
    usermod -aG wheel "\$USERNAME"
    sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
fi

# Desktop Environment install & enable display manager
case \$DE in
    GNOME)
        pacman -S --noconfirm gnome gdm
        systemctl enable gdm
        ;;
    KDE)
        pacman -S --noconfirm plasma kde-applications sddm
        systemctl enable sddm
        ;;
    XFCE)
        pacman -S --noconfirm xfce4 xfce4-goodies lightdm lightdm-gtk-greeter
        systemctl enable lightdm
        ;;
    i3)
        pacman -S --noconfirm i3 xorg xterm lightdm lightdm-gtk-greeter
        systemctl enable lightdm
        ;;
esac

# Networking setup
if [[ "\$INSTALL_NET" =~ ^[Yy]$ ]]; then
    pacman -S --noconfirm networkmanager
    systemctl enable NetworkManager
fi

# Bootloader install
if [[ "\$BOOT_MODE" == "UEFI" ]]; then
    pacman -S --noconfirm grub efibootmgr
    mkdir -p /boot/efi
    mount "\$EFI_PART" /boot/efi
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --removable
else
    pacman -S --noconfirm grub
    grub-install --target=i386-pc "\$DISK"
fi

grub-mkconfig -o /boot/grub/grub.cfg
EOF

# === 13. Done ===
echo "Installation complete!"
echo "You can chroot to your system with: arch-chroot /mnt"
