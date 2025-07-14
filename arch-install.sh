#!/bin/bash
set -euo pipefail

# Colors
RED="\e[31m"
GREEN="\e[32m"
CYAN="\e[36m"
RESET="\e[0m"

info()    { echo -e "${CYAN}[INFO]${RESET} $*"; }
success() { echo -e "${GREEN}[OK]${RESET} $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }

# Ensure root
[[ $EUID -ne 0 ]] && { error "Run as root"; exit 1; }

# Globals
BOOT_MODE=""
DISK=""
PART_BOOT=""
PART_ROOT=""
PART_BIOS=""
SWAP_PART=""
SWAP_PART_CREATE=false
SWAP_SIZE_MB=0
FILESYS="ext4"

welcome() {
    echo -e "${CYAN}=== Awesome Arch Installer ===${RESET}"
}

detect_boot_mode() {
    if [ -d /sys/firmware/efi ]; then
        BOOT_MODE="UEFI"
    else
        BOOT_MODE="BIOS"
    fi
    info "Boot mode detected: $BOOT_MODE"
}

select_disk() {
    lsblk -dpno NAME,SIZE | grep -v loop
    read -rp "Enter the full path of the target disk (e.g., /dev/sda): " DISK
    [[ ! -b "$DISK" ]] && { error "Invalid disk"; exit 1; }
    read -rp "This will erase all data on $DISK. Continue? (y/N): " confirm
    [[ $confirm != [yY] ]] && { info "Aborted"; exit 0; }
}

ask_swap() {
    read -rp "Create a swap partition? (y/N): " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        SWAP_PART_CREATE=true
        read -rp "Enter swap size in MiB (e.g., 2048): " SWAP_SIZE_MB
    fi
}

ask_filesystem() {
    echo "Choose filesystem for root partition:"
    select fs in ext4 btrfs xfs f2fs; do
        FILESYS=$fs
        break
    done
}

partition_disk() {
    info "Wiping disk and creating partitions..."
    wipefs -a "$DISK"
    sgdisk --zap-all "$DISK"

    disk_sectors=$(blockdev --getsz "$DISK")
    sector_size=512
    [[ $SWAP_PART_CREATE == true ]] && swap_sectors=$((SWAP_SIZE_MB * 1024 * 1024 / sector_size))

    if [[ "$BOOT_MODE" == "UEFI" ]]; then
        sgdisk -n 1:0:+512M -t 1:ef00 -c 1:"EFI System Partition" "$DISK"
        if $SWAP_PART_CREATE; then
            root_end=$((disk_sectors - swap_sectors - 2048))
            sgdisk -n 2:0:${root_end}s -t 2:8300 -c 2:"Linux root" "$DISK"
        else
            sgdisk -n 2:0:0 -t 2:8300 -c 2:"Linux root" "$DISK"
        fi
        PART_BOOT="${DISK}1"
        PART_ROOT="${DISK}2"
    else
        sgdisk -n 1:0:+1M -t 1:ef02 -c 1:"BIOS Boot" "$DISK"
        if $SWAP_PART_CREATE; then
            root_end=$((disk_sectors - swap_sectors - 2048))
            sgdisk -n 2:0:${root_end}s -t 2:8300 -c 2:"Linux root" "$DISK"
        else
            sgdisk -n 2:0:0 -t 2:8300 -c 2:"Linux root" "$DISK"
        fi
        PART_BIOS="${DISK}1"
        PART_ROOT="${DISK}2"
    fi

    if $SWAP_PART_CREATE; then
        last_end=$(parted "$DISK" unit s print | grep '^ ' | tail -n1 | awk '{print $3}' | sed 's/s//')
        swap_start=$((last_end + 1))
        swap_end=$((swap_start + swap_sectors - 1))

        if (( swap_end > disk_sectors )); then
            error "Not enough space for swap."
            exit 1
        fi

        sgdisk -n 0:${swap_start}s:${swap_end}s -t 0:8200 -c 0:"Swap Partition" "$DISK"
        partprobe "$DISK"
        SWAP_PART=$(lsblk -ln -o NAME,PARTTYPE "$DISK" | grep 8200 | awk '{print "/dev/" $1}' | tail -n1)
    fi

    success "Partitioning complete:"
    lsblk "$DISK"
}

format_and_mount() {
    info "Formatting and mounting root partition"
    mkfs."$FILESYS" "$PART_ROOT"
    mount "$PART_ROOT" /mnt

    if [[ -n "$PART_BOOT" ]]; then
        mkfs.fat -F32 "$PART_BOOT"
        mkdir -p /mnt/boot
        mount "$PART_BOOT" /mnt/boot
    fi

    if [[ -n "$SWAP_PART" ]]; then
        info "Setting up swap"
        mkswap "$SWAP_PART"
        swapon "$SWAP_PART"
    fi
}

install_base() {
    info "Installing base system"
    pacstrap /mnt base linux linux-firmware vim networkmanager grub
}

generate_fstab() {
    genfstab -U /mnt >> /mnt/etc/fstab
    success "fstab generated"
}

post_install_message() {
    echo -e "${GREEN}
Base installation complete!
You can now chroot into /mnt and continue configuration:

    arch-chroot /mnt
    ln -sf /usr/share/zoneinfo/Region/City /etc/localtime
    hwclock --systohc
    echo yourhostname > /etc/hostname
    passwd
    useradd -m -G wheel -s /bin/bash youruser
    passwd youruser
    EDITOR=nano visudo  # Uncomment wheel line
    systemctl enable NetworkManager
    grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB  # or BIOS
    grub-mkconfig -o /boot/grub/grub.cfg

Then reboot and enjoy Arch Linux! 🎉
${RESET}"
}

### Main
main() {
    welcome
    detect_boot_mode
    select_disk
    ask_swap
    ask_filesystem
    partition_disk
    format_and_mount
    install_base
    generate_fstab
    post_install_message
}

main "$@"
