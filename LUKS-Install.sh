#!/bin/bash

# Configuration
FILE_URL="https://glitchlinux.wtf/FILES/LUKS-BOOTLOADER-BIOS-UEFI-50MB.img"
TEMP_FILE="/tmp/LUKS-BOOTLOADER-BIOS-UEFI-50MB.img"
LUKS_MAPPER_NAME="glitch_luks"
TARGET_MOUNT="/mnt/glitch_install"
EXCLUDE_FILE="/tmp/rsync_excludes.txt"

# Required dependencies
DEPENDENCIES="wget cryptsetup-bin grub-common grub-pc-bin grub-efi-amd64-bin parted rsync dosfstools mtools"

# LUKS partition UUID
LUKS_UUID="f7142c98-aacf-4ced-ad7f-1cb4eb2d1ee6"
BOOT_PARTITION="hd0,gpt2"

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root!" >&2
    exit 1
fi

# Install dependencies
echo "Installing required dependencies..."
apt update && apt install -y $DEPENDENCIES || {
    echo "Failed to install dependencies!" >&2
    exit 1
}

# Function to clean up only if requested
cleanup() {
    echo -e "\nCleanup options:"
    echo "1) Keep mounts active for chroot access"
    echo "2) Clean up everything and exit"
    read -p "Choose option [1-2]: " CLEANUP_CHOICE
    
    case $CLEANUP_CHOICE in
        1)
            echo "Keeping mounts active. Remember to manually clean up later!"
            echo "Use: umount -R $TARGET_MOUNT && cryptsetup close $LUKS_MAPPER_NAME"
            ;;
        2)
            echo "Cleaning up..."
            # Unmount all mounted filesystems
            for mountpoint in "${TARGET_MOUNT}/dev/pts" "${TARGET_MOUNT}/dev" "${TARGET_MOUNT}/proc" \
                            "${TARGET_MOUNT}/sys" "${TARGET_MOUNT}/run"; do
                if mountpoint -q "$mountpoint"; then
                    umount -R "$mountpoint" 2>/dev/null
                fi
            done
            
            # Unmount the main filesystem
            if mountpoint -q "$TARGET_MOUNT"; then
                umount -R "$TARGET_MOUNT" 2>/dev/null
            fi
            
            # Close LUKS if open
            if cryptsetup status "$LUKS_MAPPER_NAME" &>/dev/null; then
                cryptsetup close "$LUKS_MAPPER_NAME"
            fi
            
            # Remove temp files
            [ -f "$TEMP_FILE" ] && rm -f "$TEMP_FILE"
            [ -f "$EXCLUDE_FILE" ] && rm -f "$EXCLUDE_FILE"
            
            # Remove mount point if empty
            [ -d "$TARGET_MOUNT" ] && rmdir "$TARGET_MOUNT" 2>/dev/null
            ;;
        *)
            echo "Invalid choice, keeping mounts active."
            ;;
    esac
}

trap cleanup EXIT

create_exclude_file() {
    cat > "$EXCLUDE_FILE" << 'EOF'
/dev/*
/proc/*
/sys/*
/run/*
/tmp/*
/lost+found
/mnt/*
/media/*
/var/cache/*
/var/tmp/*
${TARGET_MOUNT}/*
EOF
}

find_kernel_initrd() {
    local target_root="$1"
    
    KERNEL_VERSION=$(ls -1 "${target_root}/boot" | grep -E "vmlinuz-[0-9]" | sort -V | tail -n1 | sed 's/vmlinuz-//')
    [ -z "$KERNEL_VERSION" ] && { echo "ERROR: Kernel not found!" >&2; exit 1; }
    
    INITRD=""
    for pattern in "initrd.img-${KERNEL_VERSION}" "initramfs-${KERNEL_VERSION}.img" "initrd-${KERNEL_VERSION}.gz"; do
        [ -f "${target_root}/boot/${pattern}" ] && INITRD="$pattern" && break
    done
    [ -z "$INITRD" ] && { echo "ERROR: Initrd not found for kernel ${KERNEL_VERSION}" >&2; exit 1; }
    
    echo "Found kernel: vmlinuz-${KERNEL_VERSION}"
    echo "Found initrd: ${INITRD}"
}

update_grub_config() {
    local target_root="$1"
    find_kernel_initrd "$target_root"
    
    # Create directories for additional GRUB components
    mkdir -p "${target_root}/boot/grub/locale"
    mkdir -p "${target_root}/boot/grub/grub_multiarch"
    mkdir -p "${target_root}/boot/grub/netboot.xyz"
    mkdir -p "${target_root}/EFI/GRUB-FM"
    mkdir -p "${target_root}/EFI/rEFInd"
    
    cat > "${target_root}/boot/grub/grub.cfg" << EOF
set gfxmode=640x480
load_video
insmod gfxterm
set locale_dir=/boot/grub/locale
set lang=C
insmod gettext
background_image -m stretch /boot/grub/grub.png
terminal_output gfxterm
insmod png
if background_image /boot/grub/splash.png; then
    true
else
    set menu_color_normal=cyan/blue
    set menu_color_highlight=white/blue
fi

menuentry "Glitch Linux" {
    cryptomount -u $LUKS_UUID
    set root=(crypto0)
    linux /boot/vmlinuz-${KERNEL_VERSION} root=UUID=$LUKS_UUID cryptdevice=UUID=$LUKS_UUID:$LUKS_MAPPER_NAME ro quiet
    initrd /boot/${INITRD}
}

menuentry "Glitch Linux (recovery mode)" {
    cryptomount -u $LUKS_UUID
    set root=(crypto0)
    linux /boot/vmlinuz-${KERNEL_VERSION} root=UUID=$LUKS_UUID cryptdevice=UUID=$LUKS_UUID:$LUKS_MAPPER_NAME ro single
    initrd /boot/${INITRD}
}

menuentry "Grub-Multiarch (BIOS)" {
    insmod multiboot
    multiboot /boot/grub/grub_multiarch/grubfm.elf
    boot
}

menuentry "Netboot.xyz (BIOS)" {
    linux16 /boot/grub/netboot.xyz/netboot.xyz.lkrn
}

menuentry "Netboot.xyz (UEFI)" {
    chainloader /boot/grub/netboot.xyz/EFI/BOOT/BOOTX64.EFI
}

menuentry "GRUBFM (UEFI)" {
    chainloader /EFI/GRUB-FM/E2B-bootx64.efi
}

menuentry "rEFInd (UEFI)" {
    chainloader /EFI/rEFInd/bootx64.efi
}
EOF

    echo "GRUB configuration updated with full menu entries!"
}

prepare_chroot() {
    local target_root="$1"
    
    mount --bind /dev "${target_root}/dev"
    mount --bind /dev/pts "${target_root}/dev/pts"
    mount -t proc proc "${target_root}/proc"
    mount -t sysfs sys "${target_root}/sys"
    mount -t tmpfs tmpfs "${target_root}/run"
    
    [ -e "/etc/resolv.conf" ] && cp --dereference /etc/resolv.conf "${target_root}/etc/"
    
    cat > "${target_root}/chroot_prep.sh" << 'EOF'
#!/bin/bash
# Set up basic system
echo "glitch" > /etc/hostname
echo "127.0.1.1 glitch" >> /etc/hosts

# Install GRUB (both BIOS and UEFI)
grub-install ${TARGET_DEVICE}
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
update-grub

# Clean up
rm -f /chroot_prep.sh
EOF
    chmod +x "${target_root}/chroot_prep.sh"
    
    echo -e "\nChroot environment ready! To complete setup:"
    echo "1. chroot ${target_root}"
    echo "2. Run /chroot_prep.sh"
    echo "3. Exit and reboot"
}

main_install() {
    # List available disks
    echo -e "\nAvailable disks:"
    lsblk -d -o NAME,SIZE,MODEL | grep -v "NAME"
    
    # Get target device
    read -p "Enter target device (e.g., /dev/sdX): " TARGET_DEVICE
    [ ! -b "$TARGET_DEVICE" ] && { echo "Invalid device!"; exit 1; }
    read -p "This will ERASE ${TARGET_DEVICE}! Continue? (yes/no): " CONFIRM
    [ "$CONFIRM" != "yes" ] && exit 0

    # Flash image
    echo -e "\nDownloading and flashing image..."
    wget "$FILE_URL" -O "$TEMP_FILE" || { echo "Download failed!"; exit 1; }
    dd if="$TEMP_FILE" of="$TARGET_DEVICE" bs=4M status=progress && sync

    # Resize partitions
    echo -e "\nResizing partitions..."
    sgdisk -e "$TARGET_DEVICE"
    if [[ "$TARGET_DEVICE" =~ "nvme" ]]; then
        SECOND_PART="${TARGET_DEVICE}p2"
    else
        SECOND_PART="${TARGET_DEVICE}2"
    fi
    
    sleep 2; partprobe "$TARGET_DEVICE"; sleep 2
    mount | grep -q "$SECOND_PART" && umount "$SECOND_PART"
    
    sgdisk -d 2 "$TARGET_DEVICE"
    sgdisk -n 2:0:0 -t 2:8300 "$TARGET_DEVICE"
    partprobe "$TARGET_DEVICE"; sleep 2

    # Setup LUKS
    echo -e "\nSetting up LUKS..."
    cryptsetup luksOpen "$SECOND_PART" "$LUKS_MAPPER_NAME" || { echo "Failed to open LUKS!"; exit 1; }
    cryptsetup resize "$LUKS_MAPPER_NAME"
    e2fsck -f "/dev/mapper/$LUKS_MAPPER_NAME"
    resize2fs "/dev/mapper/$LUKS_MAPPER_NAME"

    # Install system
    echo -e "\nInstalling system..."
    create_exclude_file
    mkdir -p "$TARGET_MOUNT"
    mount "/dev/mapper/$LUKS_MAPPER_NAME" "$TARGET_MOUNT"
    mkdir -p "${TARGET_MOUNT}/"{boot/grub,dev,proc,sys,run}
    
    rsync -aAXH --info=progress2 --exclude-from="$EXCLUDE_FILE" / "$TARGET_MOUNT"
    genfstab -U "$TARGET_MOUNT" > "${TARGET_MOUNT}/etc/fstab"
    update_grub_config "$TARGET_MOUNT"
    prepare_chroot "$TARGET_MOUNT"

    # Keep system running for chroot access
    while true; do
        read -p "Enter 'exit' when done with chroot to cleanup: " cmd
        [ "$cmd" = "exit" ] && break
    done
}

main_install
