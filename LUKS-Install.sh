#!/bin/bash

# Configuration
FILE_URL="https://glitchlinux.wtf/FILES/LUKS-BOOTLOADER-BIOS-UEFI-50MB.img"
TEMP_FILE="/tmp/LUKS-BOOTLOADER-BIOS-UEFI-50MB.img"
LUKS_MAPPER_NAME="glitch_luks"
TARGET_MOUNT="/mnt/glitch_install"
EXCLUDE_FILE="/tmp/rsync_excludes.txt"

# Function to clean up
cleanup() {
    echo "Cleaning up..."
    
    # Unmount all mounted filesystems
    if mountpoint -q "${TARGET_MOUNT}/dev"; then sudo umount -R "${TARGET_MOUNT}/dev"; fi
    if mountpoint -q "${TARGET_MOUNT}/proc"; then sudo umount -R "${TARGET_MOUNT}/proc"; fi
    if mountpoint -q "${TARGET_MOUNT}/sys"; then sudo umount -R "${TARGET_MOUNT}/sys"; fi
    if mountpoint -q "${TARGET_MOUNT}/run"; then sudo umount -R "${TARGET_MOUNT}/run"; fi
    
    # Unmount the main filesystem
    if mountpoint -q "$TARGET_MOUNT"; then sudo umount -R "$TARGET_MOUNT"; fi
    
    # Close LUKS if open
    if cryptsetup status "$LUKS_MAPPER_NAME" &>/dev/null; then
        sudo cryptsetup close "$LUKS_MAPPER_NAME"
    fi
    
    # Remove temp files
    [ -f "$TEMP_FILE" ] && rm -f "$TEMP_FILE"
    [ -f "$EXCLUDE_FILE" ] && rm -f "$EXCLUDE_FILE"
    
    # Remove mount point if empty
    [ -d "$TARGET_MOUNT" ] && rmdir "$TARGET_MOUNT" 2>/dev/null
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

install_system() {
    local target_dev="$1"
    
    echo "Preparing to install system to $target_dev..."
    
    # Create mount point
    sudo mkdir -p "$TARGET_MOUNT"
    
    # Mount the target filesystem
    sudo mount "/dev/mapper/$LUKS_MAPPER_NAME" "$TARGET_MOUNT"
    
    # Create basic directory structure
    sudo mkdir -p "${TARGET_MOUNT}/"{dev,proc,sys,run}
    
    # Copy the system using rsync
    echo "Copying system files (this may take a while)..."
    sudo rsync -aAXH --info=progress2 --exclude-from="$EXCLUDE_FILE" / "$TARGET_MOUNT"
    
    # Generate fstab
    echo "Generating fstab..."
    sudo genfstab -U "$TARGET_MOUNT" | sudo tee "$TARGET_MOUNT/etc/fstab"
    
    # Prepare chroot
    echo "Setting up chroot environment..."
    sudo mount --bind /dev "${TARGET_MOUNT}/dev"
    sudo mount -t proc proc "${TARGET_MOUNT}/proc"
    sudo mount -t sysfs sys "${TARGET_MOUNT}/sys"
    sudo mount -t tmpfs tmpfs "${TARGET_MOUNT}/run"
    
    # Copy DNS info
    if [ -e "/etc/resolv.conf" ]; then
        sudo cp --dereference /etc/resolv.conf "${TARGET_MOUNT}/etc/"
    fi
    
    echo "System installed successfully!"
    echo "You can now chroot into the new system with:"
    echo "sudo chroot $TARGET_MOUNT"
}

main_install() {
    # List available disks
    echo -e "\nAvailable disks on your system:"
    lsblk -d -o NAME,SIZE,MODEL | grep -v "NAME"
    echo ""

    # Prompt for target device
    read -p "Enter the target device (e.g., /dev/sdX): " TARGET_DEVICE
    [ ! -b "$TARGET_DEVICE" ] && { echo "Invalid device!"; exit 1; }

    # Confirm
    read -p "This will ERASE ALL DATA on $TARGET_DEVICE! Continue? (yes/no): " CONFIRM
    [ "$CONFIRM" != "yes" ] && exit 0

    # Download and flash the image
    echo -e "\nDownloading and flashing image..."
    wget "$FILE_URL" -O "$TEMP_FILE" || { echo "Download failed!"; exit 1; }
    sudo dd if="$TEMP_FILE" of="$TARGET_DEVICE" bs=4M status=progress && sync

    # Fix GPT and resize partitions
    echo -e "\nResizing partitions..."
    sudo sgdisk -e "$TARGET_DEVICE"
    
    # Determine partition naming
    if [[ "$TARGET_DEVICE" =~ "nvme" ]]; then
        SECOND_PART="${TARGET_DEVICE}p2"
    else
        SECOND_PART="${TARGET_DEVICE}2"
    fi
    
    # Wait for partitions to settle
    sleep 2
    sudo partprobe "$TARGET_DEVICE"
    sleep 2
    
    # Ensure partition is not mounted
    if mount | grep -q "$SECOND_PART"; then
        echo "Unmounting $SECOND_PART..."
        sudo umount "$SECOND_PART"
    fi
    
    # Delete and recreate partition
    echo "Recreating partition to maximize space..."
    sudo sgdisk -d 2 "$TARGET_DEVICE"
    sudo sgdisk -n 2:0:0 -t 2:8300 "$TARGET_DEVICE"
    
    # Refresh partition table
    sudo partprobe "$TARGET_DEVICE"
    sleep 2
    
    # Open LUKS
    echo -e "\nOpening LUKS container..."
    sudo cryptsetup luksOpen "$SECOND_PART" "$LUKS_MAPPER_NAME"
    [ $? -ne 0 ] && { echo "Failed to open LUKS!"; exit 1; }

    # Resize filesystem
    echo -e "\nResizing filesystem..."
    sudo cryptsetup resize "$LUKS_MAPPER_NAME"
    sudo e2fsck -f "/dev/mapper/$LUKS_MAPPER_NAME"
    sudo resize2fs "/dev/mapper/$LUKS_MAPPER_NAME"

    # Create exclude file
    create_exclude_file

    # Install system
    install_system "$TARGET_DEVICE"

    echo -e "\nInstallation complete! You can now:"
    echo "1. Chroot into the new system to make changes"
    echo "2. Reboot into your new encrypted system"
    echo ""
    echo "To chroot: sudo chroot $TARGET_MOUNT"
}

# Run main installation
main_install
