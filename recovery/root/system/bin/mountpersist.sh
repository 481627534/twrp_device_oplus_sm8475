#!/system/bin/sh
# PGW110: 把 persist 常驻挂到 /mnt/vendor/persist，让 TWRP 的设置真正落盘。
#
# 背景（05_经验总结 054 / 055）：
#   TWRP 的设置文件路径写死在 <TW_PERSIST_DIR>/.twrp_settings
#   = /mnt/vendor/persist/TWRP/.twrp_settings，但它自己既挂不上也不卸：
#     - MountByPath() 先用 TWFunc::GetRootPath() 把路径截成第一级 "/mnt"，
#       精确比对匹配不到任何分区 ⇒ 不挂；
#     - twPersistUnMount() 的函数体在上游被整行注释 ⇒ 也不卸。
#   所以必须由 init 侧把 persist 挂起来。v0.4 直接在 `on fs` 里写 mount 失败，
#   判断是 ueventd 的 by-name 符号链接还没就绪，故这里做等待 + 重试 + 留证。
#
# 本脚本在 init 的 `exec` 里同步执行（init 会 waitpid），所以它跑完之前
# TWRP 主进程不会启动，挂载一定早于 InfoManager::LoadValues 读设置。

LOG=/tmp/mountpersist.log
DEV=/dev/block/bootdevice/by-name/persist
MNT=/mnt/vendor/persist

: > "$LOG" 2>/dev/null

if grep -q " $MNT " /proc/mounts 2>/dev/null; then
  echo "already_mounted_by_init" >> "$LOG"
else
  i=0
  while [ ! -e "$DEV" ] && [ "$i" -lt 5 ]; do
    sleep 1
    i=$((i + 1))
  done
  if [ -e "$DEV" ]; then
    echo "dev_ok_wait_loops=$i" >> "$LOG"
  else
    echo "dev_missing_after_${i}s" >> "$LOG"
  fi

  mkdir -p "$MNT" 2>>"$LOG"
  /system/bin/mount -t ext4 -o noatime,nosuid,nodev,barrier=1 "$DEV" "$MNT" 2>>"$LOG"
  echo "mount_rc=$?" >> "$LOG"
fi

grep " $MNT " /proc/mounts >> "$LOG" 2>&1

# 建 TWRP 设置目录（mount 失败时落在 ramdisk，不影响启动）
if [ -d "$MNT" ]; then
  [ -d "$MNT/TWRP" ] || mkdir "$MNT/TWRP" 2>>"$LOG"
  chmod 0775 "$MNT/TWRP" 2>>"$LOG"
  echo "twrp_dir=$( [ -d "$MNT/TWRP" ] && echo ok || echo missing )" >> "$LOG"
  echo "fs=$( stat -f -c %T "$MNT" 2>/dev/null || echo unknown )" >> "$LOG"
fi

exit 0
