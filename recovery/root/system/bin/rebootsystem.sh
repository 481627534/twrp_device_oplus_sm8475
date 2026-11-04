#!/system/bin/sh
# PGW110: hook executed by TWFunc::TwReboot(SYSTEM) *before* TWRP sets
# sys.powerctl. TWRP never clears the BCB when rebooting, so a residual
# "boot-recovery" in misc sends the device right back into recovery.
# Clearing here (idempotent with the boot-time clearbcb service) guarantees that
# "Reboot -> System" really boots the main system.
#
# Only the first 32 bytes are zeroed (bootloader_message.command).

MISC=/dev/block/bootdevice/by-name/misc
[ -e "$MISC" ] || MISC=/dev/block/by-name/misc
[ -e "$MISC" ] || exit 0

dd if=/dev/zero of="$MISC" bs=32 count=1 conv=notrunc 2>/dev/null
sync
exit 0
