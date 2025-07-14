#!/bin/bash
set -euo pipefail
shopt -s nocasematch

# ----------------------------------------
# Arch Linux Interactive Installer Script
# Author: ChatGPT Arch Installer v1.0
# ----------------------------------------

# Colors for menu
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

pause() {
    read -rp "${YELLOW}Press Enter to continue...${NC}"
}

info() {
    echo -e "${CYAN}[INFO]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

confirm() {
    while true; do
        read -rp "$1 (y/n): " yn
        case $yn in
            y|Y ) return 0;;
            n|N ) return 1;;
            * ) echo "Please answer y or n.";;
        esac
    done
}

# Detect if UEFI or BIOS
detect_boot_mode() {
    if [ -d /sys/firmware/efi/efivars ]; then
        BOOT_MODE="UEFI"
    else
        BOOT_MODE="BIOS"
    fi
    info "Boot mode detected: $BOOT_MODE"
}

# List available disks for selection
list_disks() {
    echo "Available disks:"
    lsblk -dno NAME,SIZE,MODEL | grep -v sr0 | nl
}

select_disk() {
    while true; do
        list_disks
        read -rp "Enter disk number to install Arch on (e.g., 1): " disknum
        disk=$(lsblk -dno NAME | grep -v sr0 | sed -n "${disknum}p")
        if [[ -b /dev/$disk ]]; then
            DISK="/dev/$disk"
            echo "Selected disk: $DISK"
            if confirm "Are you sure you want to use $DISK? All data will be erased"; then
                break
            fi
        else
            error "Invalid disk selection."
        fi
    done
}

# Partitioning menu
partition_menu() {
    echo "Partitioning methods:"
    echo "1) Automatic GPT partitioning (recommended)"
    echo "2) Manual partitioning (launch cfdisk)"
    while true; do
        read -rp "Select partitioning method (1 or 2): " part_choice
        case $part_choice in
            1) auto_partition; break;;
            2) manual_partition; break;;
            *) echo "Please enter 1 or 2.";;
        esac
    done
}

# Automatic partitioning function (simple GPT scheme)
auto_partition() {
    info "Wiping disk $DISK and creating partitions..."
    # Wipe disk
    wipefs -a "$DISK"
    sgdisk --zap-all "$DISK"

    # Create partitions based on boot mode
    if [[ $BOOT_MODE == "UEFI" ]]; then
        # Partition 1: EFI System Partition 512M
        sgdisk -n 1:0:+512M -t 1:ef00 -c 1:"EFI System Partition" "$DISK"
        # Partition 2: Linux root, rest of disk
        sgdisk -n 2:0:0 -t 2:8300 -c 2:"Linux root" "$DISK"
        PART_BOOT="${DISK}1"
        PART_ROOT="${DISK}2"
    else
        # BIOS MBR scheme:
        # Partition 1: BIOS boot partition 1M (if using GRUB with BIOS boot)
        sgdisk -n 1:0:+1M -t 1:ef02 -c 1:"BIOS boot partition" "$DISK"
        # Partition 2: Linux root (rest of disk)
        sgdisk -n 2:0:0 -t 2:8300 -c 2:"Linux root" "$DISK"
        PART_BIOS="${DISK}1"
        PART_ROOT="${DISK}2"
    fi

    echo "Partitions created:"
    lsblk "$DISK"
}

manual_partition() {
    info "Launching cfdisk for manual partitioning..."
    cfdisk "$DISK"
    echo "Please make sure you have created necessary partitions."
    pause
    # After manual partitioning user will specify partitions later.
}

# Select filesystem type
select_filesystem() {
    echo "Choose filesystem for root partition:"
    echo "1) ext4 (default, stable)"
    echo "2) btrfs (advanced, snapshot support)"
    echo "3) xfs (high performance)"
    while true; do
        read -rp "Filesystem choice (1-3): " fs_choice
        case $fs_choice in
            1) FS_TYPE="ext4"; break;;
            2) FS_TYPE="btrfs"; break;;
            3) FS_TYPE="xfs"; break;;
            *) echo "Invalid choice.";;
        esac
    done
}

# Swap options
swap_menu() {
    echo "Swap configuration options:"
    echo "1) Swap partition"
    echo "2) Swapfile"
    echo "3) No swap"
    while true; do
        read -rp "Select swap option (1-3): " swap_choice
        case $swap_choice in
            1) SWAP_TYPE="partition"; select_swap_partition; break;;
            2) SWAP_TYPE="file"; break;;
            3) SWAP_TYPE="none"; break;;
            *) echo "Invalid choice.";;
        esac
    done
}

select_swap_partition() {
    info "Select existing swap partition or create manually."
    lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT | grep swap
    read -rp "Enter swap partition device path (e.g., /dev/sda3): " SWAP_PART
    if [[ ! -b $SWAP_PART ]]; then
        error "Invalid swap partition."
        select_swap_partition
    fi
}

# Encryption option
encryption_menu() {
    if confirm "Do you want to enable LUKS encryption for the root partition?"; then
        ENCRYPTION="yes"
        read -rp "Enter passphrase for LUKS encryption: " -s LUKS_PASS
        echo
    else
        ENCRYPTION="no"
    fi
}

# Network setup
network_menu() {
    echo "Network setup options:"
    echo "1) Wired (DHCP)"
    echo "2) Wifi"
    while true; do
        read -rp "Choose network type (1 or 2): " net_choice
        case $net_choice in
            1) NETWORK_TYPE="wired"; break;;
            2) NETWORK_TYPE="wifi"; break;;
            *) echo "Invalid choice.";;
        esac
    done

    if [[ $NETWORK_TYPE == "wifi" ]]; then
        info "Scanning for wifi networks..."
        iw dev | grep Interface | awk '{print $2}' | while read -r iface; do
            WIFI_IFACE="$iface"
        done
        if [[ -z $WIFI_IFACE ]]; then
            error "No wifi interface found."
            NETWORK_TYPE="wired"
            return
        fi

        wifi_scan_and_connect
    fi
}

wifi_scan_and_connect() {
    echo "Available WiFi networks:"
    iw "$WIFI_IFACE" scan | grep SSID | awk -F: '{print $2}' | sed 's/^ *//g' | nl
    while true; do
        read -rp "Enter the number of the WiFi network to connect: " ssid_num
        SSID=$(iw "$WIFI_IFACE" scan | grep SSID | awk -F: '{print $2}' | sed 's/^ *//g' | sed -n "${ssid_num}p")
        if [[ -n $SSID ]]; then
            echo "Selected SSID: $SSID"
            break
        else
            echo "Invalid selection."
        fi
    done

    read -rp "Enter WiFi passphrase for $SSID: " -s WIFI_PASS
    echo

    info "Connecting to WiFi..."
    ip link set "$WIFI_IFACE" up
    wpa_passphrase "$SSID" "$WIFI_PASS" > /etc/wpa_supplicant.conf
    wpa_supplicant -B -i "$WIFI_IFACE" -c /etc/wpa_supplicant.conf
    dhcpcd "$WIFI_IFACE"
    rm /etc/wpa_supplicant.conf
}

# Kernel selection
kernel_menu() {
    echo "Select kernel to install:"
    echo "1) linux (default)"
    echo "2) linux-lts"
    echo "3) linux-hardened"
    while true; do
        read -rp "Kernel choice (1-3): " kernel_choice
        case $kernel_choice in
            1) KERNEL_PKG="linux"; break;;
            2) KERNEL_PKG="linux-lts"; break;;
            3) KERNEL_PKG="linux-hardened"; break;;
            *) echo "Invalid choice.";;
        esac
    done
}

# Bootloader menu
bootloader_menu() {
    echo "Bootloader options:"
    echo "1) GRUB"
    if [[ $BOOT_MODE == "UEFI" ]]; then
        echo "2) systemd-boot (UEFI only)"
    fi
    while true; do
        read -rp "Select bootloader (1 or 2): " boot_choice
        if [[ $boot_choice == "1" ]]; then
            BOOTLOADER="grub"
            break
        elif [[ $boot_choice == "2" && $BOOT_MODE == "UEFI" ]]; then
            BOOTLOADER="systemd-boot"
            break
        else
            echo "Invalid choice."
        fi
    done
}

# Desktop Environment menu
desktop_menu() {
    echo "Select Desktop Environment:"
    echo "1) None (CLI only)"
    echo "2) i3"
    echo "3) GNOME"
    echo "4) KDE Plasma"
    echo "5) XFCE"
    while true; do
        read -rp "Choice (1-5): " de_choice
        case $de_choice in
            1) DESKTOP_ENV="none"; break;;
            2) DESKTOP_ENV="i3"; break;;
            3) DESKTOP_ENV="gnome"; break;;
            4) DESKTOP_ENV="kde"; break;;
            5) DESKTOP_ENV="xfce"; break;;
            *) echo "Invalid choice.";;
        esac
    done
}

# Extra packages menu
extra_packages_menu() {
    echo "Select additional package groups to install:"
    echo "1) None"
    echo "2) Development tools (gcc, make, git)"
    echo "3) Multimedia (vlc, mpv, pulseaudio)"
    echo "4) Networking tools (nmap, net-tools)"
    echo "You can select multiple by entering numbers separated by spaces (e.g. '2 3'):"
    read -rp "Your selection: " pkg_choices

    EXTRA_PKGS=()
    for choice in $pkg_choices; do
        case $choice in
            1) break;;
            2) EXTRA_PKGS+=(base-devel git) ;;
            3) EXTRA_PKGS+=(vlc mpv pulseaudio pulseaudio-alsa pavucontrol) ;;
            4) EXTRA_PKGS+=(nmap net-tools) ;;
            *) echo "Ignoring invalid choice $choice";;
        esac
    done
}

# Locale and timezone
locale_timezone_menu() {
    echo "Select your timezone:"
    timedatectl list-timezones | nl | head -50
    read -rp "Enter timezone (e.g., Europe/London): " TZONE
    if ! timedatectl list-timezones | grep -q "^$TZONE$"; then
        error "Invalid timezone. Using UTC."
        TZONE="UTC"
    fi

    read -rp "Enter your locale (e.g., en_US.UTF-8): " LOCALE
    if [[ -z $LOCALE ]]; then
        LOCALE="en_US.UTF-8"
    fi

    read -rp "Enter your hostname: " HOSTNAME
    if [[ -z $HOSTNAME ]]; then
        HOSTNAME="archlinux"
    fi
}

# Create user account
create_user() {
    read -rp "Enter username to create: " USERNAME
    while true; do
        read -rsp "Enter password for $USERNAME: " PASS1; echo
        read -rsp "Confirm password: " PASS2; echo
        [[ $PASS1 == "$PASS2" ]] && break || echo "Passwords do not match. Try again."
    done
}

# Format, mount and install base system
install_base_system() {
    info "Starting installation..."

    # Format partitions
    if [[ $ENCRYPTION == "yes" ]]; then
        info "Setting up LUKS encryption on root partition $PART_ROOT"
        echo -n "$LUKS_PASS" | cryptsetup luksFormat "$PART_ROOT" -
        echo -n "$LUKS_PASS" | cryptsetup open "$PART_ROOT" cryptroot -
        ROOT_MAPPER="/dev/mapper/cryptroot"
    else
        ROOT_MAPPER="$PART_ROOT"
    fi

    info "Formatting root partition ($ROOT_MAPPER) as $FS_TYPE"
    case $FS_TYPE in
        ext4) mkfs.ext4 "$ROOT_MAPPER" ;;
        btrfs) mkfs.btrfs "$ROOT_MAPPER" ;;
        xfs) mkfs.xfs "$ROOT_MAPPER" ;;
    esac

    # Mount root
    mount "$ROOT_MAPPER" /mnt

    # EFI partition mount
    if [[ $BOOT_MODE == "UEFI" ]]; then
        info "Formatting EFI partition $PART_BOOT as FAT32"
        mkfs.fat -F32 "$PART_BOOT"
        mkdir -p /mnt/boot
        mount "$PART_BOOT" /mnt/boot
    fi

    # Swap setup
    case $SWAP_TYPE in
        partition)
            info "Setting up swap partition $SWAP_PART"
            mkswap "$SWAP_PART"
            swapon "$SWAP_PART"
            ;;
        file)
            info "Creating swapfile on root"
            fallocate -l 2G /mnt/swapfile
            chmod 600 /mnt/swapfile
            mkswap /mnt/swapfile
            swapon /mnt/swapfile
            ;;
        none) info "No swap will be configured";;
    esac

    # Install base system
    info "Installing base system..."
    pacstrap /mnt base linux linux-firmware "$KERNEL_PKG" sudo vim

    # Generate fstab
    info "Generating fstab..."
    genfstab -U /mnt >> /mnt/etc/fstab

    # Configure system inside chroot
    arch-chroot /mnt /bin/bash <<EOF
set -e
echo "$HOSTNAME" > /etc/hostname
ln -sf /usr/share/zoneinfo/$TZONE /etc/localtime
hwclock --systohc
echo "$LOCALE UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf
echo "KEYMAP=us" > /etc/vconsole.conf
useradd -m -G wheel "$USERNAME"
echo "$USERNAME:$PASS1" | chpasswd
echo "root:$PASS1" | chpasswd
echo "%wheel ALL=(ALL) ALL" > /etc/sudoers.d/wheel
chmod 440 /etc/sudoers.d/wheel

if [[ "$ENCRYPTION" == "yes" ]]; then
    # Configure mkinitcpio for LUKS
    sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block encrypt filesystems keyboard fsck)/' /etc/mkinitcpio.conf
fi

mkinitcpio -P

pacman -S --noconfirm $KERNEL_PKG base linux-firmware sudo vim

# Install extra packages if any
if [[ ${#EXTRA_PKGS[@]} -gt 0 ]]; then
    pacman -S --noconfirm ${EXTRA_PKGS[@]}
fi

# Bootloader installation
if [[ "$BOOTLOADER" == "grub" ]]; then
    pacman -S --noconfirm grub
    if [[ "$BOOT_MODE" == "UEFI" ]]; then
        pacman -S --noconfirm efibootmgr
        mkdir -p /boot/EFI
        grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
    else
        grub-install --target=i386-pc "$DISK"
    fi
    grub-mkconfig -o /boot/grub/grub.cfg
elif [[ "$BOOTLOADER" == "systemd-boot" ]]; then
    bootctl install
    cat <<SYSTEMD_BOOT_CONF > /boot/loader/loader.conf
default arch
timeout 3
editor 0
SYSTEMD_BOOT_CONF

    cat <<ENTRY > /boot/loader/entries/arch.conf
title   Arch Linux
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options cryptdevice=UUID=$(blkid -s UUID -o value $PART_ROOT):cryptroot root=/dev/mapper/cryptroot rw
ENTRY
fi

# Desktop Environment installation
case $DESKTOP_ENV in
    i3)
        pacman -S --noconfirm xorg-server xorg-apps xorg-xinit i3
        ;;
    gnome)
        pacman -S --noconfirm gnome gnome-extra gdm
        systemctl enable gdm
        ;;
    kde)
        pacman -S --noconfirm plasma kde-applications sddm
        systemctl enable sddm
        ;;
    xfce)
        pacman -S --noconfirm xfce4 xfce4-goodies lightdm lightdm-gtk-greeter
        systemctl enable lightdm
        ;;
    none)
        ;;
esac
EOF

    info "Installation complete! You can now reboot."
}

# Main script starts here
clear
echo -e "${GREEN}Welcome to the Awesome Arch Linux Installer!${NC}"

detect_boot_mode
select_disk
partition_menu
select_filesystem
swap_menu
encryption_menu
network_menu
kernel_menu
bootloader_menu
desktop_menu
extra_packages_menu
locale_timezone_menu
create_user
install_base_system
