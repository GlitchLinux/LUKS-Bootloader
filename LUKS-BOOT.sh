#!/bin/bash

# URL of the file to download
FILE_URL="https://glitchlinux.wtf/FILES/LUKS-BOOTLOADER-BIOS-UEFI-50MB.img"
TEMP_FILE="/tmp/LUKS-BOOTLOADER-BIOS-UEFI-50MB.img"
LUKS_MAPPER_NAME="glitch_luks"

# Function to clean up temporary files and LUKS mapping
cleanup() {
    # Unmount if mounted
    if mountpoint -q "/mnt/${LUKS_MAPPER_NAME}"; then
        echo "Unmounting /mnt/${LUKS_MAPPER_NAME}..."
        sudo umount "/mnt/${LUKS_MAPPER_NAME}"
    fi
    
    # Close LUKS if it's open
    if cryptsetup status "$LUKS_MAPPER_NAME" &>/dev/null; then
        echo "Closing LUKS device..."
        sudo cryptsetup close "$LUKS_MAPPER_NAME"
    fi
    
    # Remove temporary file
    if [ -f "$TEMP_FILE" ]; then
        rm -f "$TEMP_FILE"
        echo "Removed temporary file: $TEMP_FILE"
    fi
}

# Trap to ensure cleanup happens on script exit
trap cleanup EXIT

# Download the file
echo "Downloading the image file..."
wget "$FILE_URL" -O "$TEMP_FILE" || {
    echo "Failed to download the file. Please check the URL and your internet connection."
    exit 1
}

# Verify the file was downloaded
if [ ! -f "$TEMP_FILE" ]; then
    echo "Downloaded file not found. Exiting."
    exit 1
fi

# List available disks
echo ""
echo "Available disks on your system:"
lsblk -d -o NAME,SIZE,MODEL | grep -v "NAME"
echo ""

# Prompt user for target device
read -p "Enter the target device to flash to (e.g., /dev/sdX): " TARGET_DEVICE

# Verify the target device exists
if [ ! -b "$TARGET_DEVICE" ]; then
    echo "Device $TARGET_DEVICE does not exist or is not a block device. Please check and try again."
    exit 1
fi

# Confirm the operation
echo ""
echo "WARNING: This will overwrite all data on $TARGET_DEVICE!"
read -p "Are you sure you want to proceed? (yes/no): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    echo "Operation cancelled by user."
    exit 0
fi

# Flash the image
echo "Flashing image to $TARGET_DEVICE..."
sudo dd if="$TEMP_FILE" of="$TARGET_DEVICE" bs=4M status=progress && sync

if [ $? -ne 0 ]; then
    echo "Flash operation failed. Please check the device and try again."
    exit 1
fi

echo "Flash operation completed successfully."

# Fix GPT table to use all available space
echo "Fixing GPT table to use all available space..."
sudo sgdisk -e "$TARGET_DEVICE"

# Refresh partition table
echo "Refreshing partition table..."
sudo partprobe "$TARGET_DEVICE"
sleep 2

# Determine the second partition
if [[ "$TARGET_DEVICE" =~ "nvme" ]]; then
    SECOND_PARTITION="${TARGET_DEVICE}p2"
else
    SECOND_PARTITION="${TARGET_DEVICE}2"
fi

# Verify the second partition exists
if [ ! -b "$SECOND_PARTITION" ]; then
    echo "Second partition ($SECOND_PARTITION) not found. Cannot proceed with LUKS open."
    exit 1
fi

# Resize the partition to fill available space using sgdisk (non-interactive)
echo "Resizing partition to fill available disk space..."
sudo sgdisk -d 2 "$TARGET_DEVICE"  # Delete partition 2
sudo sgdisk -n 2:0:0 "$TARGET_DEVICE"  # Recreate partition 2 using all remaining space
sudo sgdisk -t 2:8300 "$TARGET_DEVICE"  # Set partition type to Linux filesystem

# Refresh partition table again
echo "Refreshing partition table after resize..."
sudo partprobe "$TARGET_DEVICE"
sleep 2

# Attempt to open the LUKS partition
echo "Attempting to open LUKS partition $SECOND_PARTITION as $LUKS_MAPPER_NAME..."
sudo cryptsetup luksOpen "$SECOND_PARTITION" "$LUKS_MAPPER_NAME"

if [ $? -ne 0 ]; then
    echo "Failed to open LUKS partition. It may require a passphrase or the partition may not be LUKS formatted."
    exit 1
fi

echo "LUKS partition opened successfully at /dev/mapper/$LUKS_MAPPER_NAME"

# Resize the LUKS container to fill the partition
echo "Resizing LUKS container to fill partition..."
sudo cryptsetup resize "$LUKS_MAPPER_NAME"

# Check filesystem type (should be ext4)
FS_TYPE=$(sudo blkid -o value -s TYPE "/dev/mapper/$LUKS_MAPPER_NAME")
if [ "$FS_TYPE" != "ext4" ]; then
    echo "Filesystem is not ext4 (found $FS_TYPE). Cannot resize."
    exit 1
fi

# Resize the filesystem to fill the LUKS container
echo "Resizing ext4 filesystem to fill LUKS container..."
sudo e2fsck -f "/dev/mapper/$LUKS_MAPPER_NAME"
sudo resize2fs "/dev/mapper/$LUKS_MAPPER_NAME"

# Verify the new size
echo "New filesystem size:"
sudo df -h "/dev/mapper/$LUKS_MAPPER_NAME"

# Create mount point and mount for verification
MOUNT_POINT="/mnt/${LUKS_MAPPER_NAME}"
sudo mkdir -p "$MOUNT_POINT"
sudo mount "/dev/mapper/$LUKS_MAPPER_NAME" "$MOUNT_POINT"

if [ $? -eq 0 ]; then
    echo "Filesystem successfully resized and mounted at $MOUNT_POINT"
    echo "You can access the filesystem at $MOUNT_POINT"
    echo ""
    echo "When finished, you can unmount and close with:"
    echo "sudo umount $MOUNT_POINT"
    echo "sudo cryptsetup close $LUKS_MAPPER_NAME"
else
    echo "Filesystem resized but could not be mounted for verification."
fi
