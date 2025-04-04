#!/bin/bash

# URL of the file to download
FILE_URL="https://glitchlinux.wtf/FILES/LUKS-BOOTLOADER-BIOS-UEFI-50MB.img"
TEMP_FILE="/tmp/LUKS-BOOTLOADER-BIOS-UEFI-50MB.img"

# Function to clean up temporary files
cleanup() {
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

if [ $? -eq 0 ]; then
    echo "Flash operation completed successfully."
else
    echo "Flash operation failed. Please check the device and try again."
    exit 1
fi
