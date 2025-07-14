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

    if [[ "$BOOT_MODE" == "UEFI" ]]; then
        parted "$DISK" --script mklabel gpt
        parted "$DISK" --script mkpart ESP fat32 1MiB 513MiB
        parted "$DISK" --script set 1 esp on
        parted "$DISK" --script mkpart primary 513MiB 100%
        EFI_PART="${DISK}1"
        ROOT_PART="${DISK}2"

    else
        echo "BIOS boot detected. Choose partition table type:"
        select TABLE_TYPE in GPT MBR; do
            [[ -n "$TABLE_TYPE" ]] && break
        done

        if [[ "$TABLE_TYPE" == "GPT" ]]; then
            parted "$DISK" --script mklabel gpt
            parted "$DISK" --script mkpart biosboot 1MiB 3MiB
            parted "$DISK" --script set 1 bios_grub on
            parted "$DISK" --script mkpart primary 3MiB 100%
            ROOT_PART="${DISK}2"
        else
            parted "$DISK" --script mklabel msdos
            parted "$DISK" --script mkpart primary ext4 1MiB 100%
            parted "$DISK" --script set 1 boot on
            ROOT_PART="${DISK}1"
        fi
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
    mkdir -p /mnt/boot
    mount "$EFI_PART" /mnt/boot
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
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
hwclock --systohc

echo "$HOSTNAME" > /etc/hostname
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# User creation
useradd -m "$USERNAME"
echo "$USERNAME:$PASSWORD" | chpasswd

# Sudo
if [[ "$INSTALL_SUDO" == "y" || "$INSTALL_SUDO" == "Y" ]]; then
    pacman -S --noconfirm sudo
    usermod -aG wheel "$USERNAME"
    sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
fi

# Desktop Environment
case $DE in
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

# Networking
if [[ "$INSTALL_NET" == "y" || "$INSTALL_NET" == "Y" ]]; then
    pacman -S --noconfirm networkmanager
    systemctl enable NetworkManager
fi

# Bootloader
if [[ "$BOOT_MODE" == "UEFI" ]]; then
    pacman -S --noconfirm grub efibootmgr
    grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
else
    pacman -S --noconfirm grub
    grub-install --target=i386-pc "$DISK"
fi

grub-mkconfig -o /boot/grub/grub.cfg
EOF

# === 13. Done ===
echo "Installation complete!"
echo "You can chroot to your system with: arch-chroot /mnt"
