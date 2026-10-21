#!/usr/bin/env bash
# Clean up failed or incomplete builds

echo "Cleaning up zero-client build artifacts..."

# Unmount every stacked /mnt/zero-img mount. Each one is made one-way first, so unmounting its
# /sys and /dev bind mounts never unmounts the host's own.
while mountpoint -q /mnt/zero-img 2>/dev/null; do
    echo "Unmounting /mnt/zero-img..."
    mount --make-rslave /mnt/zero-img 2>/dev/null || true
    umount -R /mnt/zero-img 2>/dev/null || umount -R -l /mnt/zero-img || break
done

# Detach only the loop devices backed by the build image, not the host's own (snaps)
echo "Detaching zero-client loop devices..."
losetup -l -n -O NAME,BACK-FILE | awk '/zero-client\.img/ {print $1}' | xargs -r -n1 losetup -d 2>/dev/null || true

# Remove the mount directory only when empty: never rm -rf a path that may still hold the host's /dev or /sys
if [ -d /mnt/zero-img ]; then
    echo "Removing mount directory..."
    rmdir /mnt/zero-img 2>/dev/null || echo "WARNING: /mnt/zero-img is not empty, left in place"
fi

# Remove image file
if [ -f zero-client.img ]; then
    echo "Removing zero-client.img..."
    rm -f zero-client.img
fi

# Check for any remaining mounts
REMAINING_MOUNTS=$(mount | grep "/mnt/zero-img" || true)
if [ -n "$REMAINING_MOUNTS" ]; then
    echo "WARNING: Some mounts still remain:"
    echo "$REMAINING_MOUNTS"
else
    echo "All mounts cleaned up successfully."
fi

# Check for any remaining loop devices
REMAINING_LOOPS=$(losetup -l | grep zero-client || true)
if [ -n "$REMAINING_LOOPS" ]; then
    echo "WARNING: Some loop devices still remain:"
    echo "$REMAINING_LOOPS"
else
    echo "All loop devices cleaned up successfully."
fi

echo "Cleanup complete!"