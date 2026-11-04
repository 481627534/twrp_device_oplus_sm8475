#!/system/bin/sh
# PGW110: clear the residual BCB ("boot-recovery") in the misc partition.
#
# Why this is needed:
#   TWRP's own TWFunc::ClearBootloaderMessage() resolves the misc device through
#   AOSP ReadDefaultFstab(), which expects the standard fs_mgr layout
#   (<device> <mount_point> <type> ...). This device tree uses TWRP's 5-column
#   layout (<mount_point> <type> <device> <device2> <flags>), so no entry ever
#   matches mount_point == "/misc" and the clear silently fails.
#   With a leftover BCB the bootloader hands control to recovery on every boot,
#   which is why "Reboot -> System" inside TWRP kept coming back to TWRP.
#
# Safety: only the first 32 bytes are zeroed. That is the whole
# bootloader_message.command field; misc is 1 MiB and the rest (including
# bootloader_message_ab @2048 and OPPO private fields) is left untouched.
# Verified on this device: clearing 32 bytes alone boots the main system while
# recovery_b still holds TWRP.

MISC=/dev/block/bootdevice/by-name/misc
[ -e "$MISC" ] || MISC=/dev/block/by-name/misc
[ -e "$MISC" ] || exit 1

dd if=/dev/zero of="$MISC" bs=32 count=1 conv=notrunc 2>/dev/null
sync
exit 0
