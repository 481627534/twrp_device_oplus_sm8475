#
# Copyright (C) 2025 The Android Open Source Project
#
# SPDX-License-Identifier: Apache-2.0
#

# Building with minimal manifest
ALLOW_MISSING_DEPENDENCIES                      := true
BUILD_BROKEN_DUP_RULES                          := true
BUILD_BROKEN_ELF_PREBUILT_PRODUCT_COPY_FILES    := true

BUILD_BROKEN_NINJA_USES_ENV_VARS    += RTIC_MPGEN
BUILD_BROKEN_PLUGIN_VALIDATION      := soong-libaosprecovery_defaults soong-libguitwrp_defaults soong-libminuitwrp_defaults soong-vold_defaults

# Architecture
TARGET_ARCH := arm64
TARGET_ARCH_VARIANT := armv8-a
TARGET_CPU_ABI := arm64-v8a
TARGET_CPU_ABI2 := 
TARGET_CPU_VARIANT := generic
TARGET_CPU_VARIANT_RUNTIME := kryo385

TARGET_2ND_ARCH := arm
TARGET_2ND_ARCH_VARIANT := armv7-a-neon
TARGET_2ND_CPU_ABI := armeabi-v7a
TARGET_2ND_CPU_ABI2 := armeabi
TARGET_2ND_CPU_VARIANT := generic
TARGET_2ND_CPU_VARIANT_RUNTIME := cortex-a75

# A/B
AB_OTA_PARTITIONS := \
    boot \
    init_boot \
    vendor_boot \
    dtbo \
    odm \
    odm_dlkm \
    product \
    system \
    system_ext \
    vbmeta \
    vbmeta_system \
    vbmeta_vendor \
    vendor \
    vendor_dlkm

# AB partitions for oplus
AB_OTA_PARTITIONS += \
    my_bigball \
    my_carrier \
    my_company \
    my_engineering \
    my_heytap \
    my_manifest \
    my_preload \
    my_product \
    my_region \
    my_stock

# Bootloader
PRODUCT_PLATFORM                := taro
TARGET_BOOTLOADER_BOARD_NAME    := taro

# Crypto
# 2026-11-04 实测：TWRP 能进界面但解不了 data，日志里
#   I:Keymaster_Ver::Using keymaster version '' for decryption   ← 版本空
#   keystore2: Cannot connect to Keymint → HARDWARE_TYPE_UNAVAILABLE → panic
# 根因：本机 vendor 是 AIDL keymint，而 vendor/etc/vintf/manifest.xml 只声明了
#       gatekeeper；keymint 的声明在 manifest/ 子目录里，TWRP 不读子目录。
#       ⇒ 同时补 FBE 开关（下面）+ 把 keymint 声明合并进主 manifest.xml。
BOARD_USES_METADATA_PARTITION   := true
TW_INCLUDE_CRYPTO               := true
TW_INCLUDE_CRYPTO_FBE           := true
# metadata 解密走 policy 2（本机 ro.crypto.metadata_init_delete_all_keys.enabled=true）
TW_USE_FSCRYPT_POLICY           := 2
# 让 TWRP 用检测到的 keymaster/keymint 版本，而不是回落到默认
TW_FORCE_KEYMASTER_VER          := true

# Debug
TARGET_USES_LOGD                := true
TWRP_INCLUDE_LOGCAT             := true
TARGET_RECOVERY_DEVICE_MODULES  += debuggerd
TARGET_RECOVERY_DEVICE_MODULES  += strace
RECOVERY_BINARY_SOURCE_FILES    += $(TARGET_OUT_EXECUTABLES)/debuggerd
RECOVERY_BINARY_SOURCE_FILES    += $(TARGET_OUT_EXECUTABLES)/strace

# File systems
TARGET_USERIMAGES_USE_F2FS := true
TW_USE_DMCTL               := true

# Kernel
BOARD_KERNEL_IMAGE_NAME     := Image
BOARD_BOOT_HEADER_VERSION   := 4
BOARD_KERNEL_PAGESIZE       := 4096
BOARD_MKBOOTIMG_ARGS        += --header_version $(BOARD_BOOT_HEADER_VERSION)
BOARD_MKBOOTIMG_ARGS        += --pagesize $(BOARD_KERNEL_PAGESIZE)

BOARD_RAMDISK_USE_LZ4       := true

# Partitions
BOARD_PROPERTY_OVERRIDES_SPLIT_ENABLED  := true
BOARD_RECOVERYIMAGE_PARTITION_SIZE      := 0x6400000

BOARD_SUPER_PARTITION_SIZE                  := 15243395072
BOARD_SUPER_PARTITION_GROUPS                := qti_dynamic_partitions
BOARD_QTI_DYNAMIC_PARTITIONS_SIZE           := 11270094848
BOARD_QTI_DYNAMIC_PARTITIONS_PARTITION_LIST := system system_ext product vendor vendor_dlkm odm odm_dlkm
BOARD_QTI_DYNAMIC_PARTITIONS_PARTITION_LIST += my_bigball my_carrier my_company my_engineering my_heytap my_manifest my_preload my_product my_region my_stock

BOARD_ODMIMAGE_FILE_SYSTEM_TYPE := ext4
TARGET_COPY_OUT_ODM             := odm
TARGET_COPY_OUT_VENDOR          := vendor

# Platform
TARGET_BOARD_PLATFORM   := sm8475
QCOM_BOARD_PLATFORMS    += sm8475

# Recovery
BOARD_EXCLUDE_KERNEL_FROM_RECOVERY_IMAGE    := true
TARGET_RECOVERY_PIXEL_FORMAT                := RGBX_8888
TW_INCLUDE_FASTBOOTD                        := true

# Tool
TW_ENABLE_ALL_PARTITION_TOOLS := true
TW_INCLUDE_7ZA                := true
TW_INCLUDE_REPACKTOOLS        := true
TW_INCLUDE_RESETPROP          := true
TW_USE_TOOLBOX                := true

# TWRP display
# 2026-11-04 实机采集（主系统 adb 实测）：
#   背光节点 /sys/class/backlight/panel0-backlight/ 存在，max_brightness = 4095 ✅
#   CPU 温度 thermal_zone25 = cpuss-0，实测 36400 ✅
#   ⇒ 这两个路径原本就是对的，黑屏不是它们的问题（见下方 TW_LOAD_VENDOR_MODULES）
TW_BRIGHTNESS_PATH      := /sys/class/backlight/panel0-backlight/brightness
TW_DEFAULT_BRIGHTNESS   := 2048
TW_FRAMERATE            := 120
TW_MAX_BRIGHTNESS       := 4095
# 关掉开机自动息屏：否则"显示链路已通"和"根本没显示"在肉眼上无法区分，
# 排查时会白烧一轮构建额度。
TW_SCREEN_BLANK_ON_BOOT := false
TW_THEME                := portrait_hdpi

# TWRP file system
RECOVERY_SDCARD_ON_DATA     := true
TARGET_USES_MKE2FS          := true
TW_ENABLE_FS_COMPRESSION    := true
TW_INCLUDE_FUSE_EXFAT       := true
TW_INCLUDE_FUSE_NTFS        := true
TW_INCLUDE_NTFS_3G          := true
TW_NO_EXFAT_FUSE            := true

# Version
PLATFORM_VERSION                := 99.87.36
PLATFORM_VERSION_LAST_STABLE    := $(PLATFORM_VERSION)
PLATFORM_SECURITY_PATCH         := 2099-12-31
VENDOR_SECURITY_PATCH           := $(PLATFORM_SECURITY_PATCH)
TW_DEVICE_VERSION               := PGW110

# Verified Boot
BOARD_AVB_ENABLE := true

# Vibrator
# 2026-11-04 实测：设 true 时 vendor.oplus.vibrator 服务无限重启（init.svc 一直是 restarting），
# 表现为「进 TWRP 后一直震」。本机震动是 AIDL（vendor.oplus.hardware.vibrator），
# 该实现在 recovery 下不工作 ⇒ 关掉，宁可没震动，不能一直震。
TW_SUPPORT_INPUT_AIDL_HAPTICS := false

# 2026-11-05（老板要求）：进 TWRP 一律不震，不用每次手动去设置里拉三条滑杆。
# 上游总开关 TW_NO_HAPTICS 一开，下面四件事同时发生（都不需要改 recovery 源码）：
#   1) data.cpp 不再写入三个默认值 tw_button_vibrate=80 / tw_keyboard_vibrate=40 /
#      tw_action_vibrate=160，且 consts_["tw_disable_haptics"] = true；
#   2) DataManager::Vibrate() 整函数体被 #ifndef 掏空，成了空函数；
#   3) twrpminui 的 vibrate() 与 haptics_available() 不编译，返回 0；
#   4) twrp_hardware_settings::has_haptics() = (tw_disable_haptics == 0) ⇒ false，
#      所有 vibrate() 调用在第一行就 return。
# ⚠️ 这比「把三项默认值改成 0ms」更彻底：0ms 仍会走完调用链并写 sysfs，
#    TW_NO_HAPTICS 是根本不写。代价：GUI 的「震动」设置页会消失，要恢复震动只能删掉这行重编。
# ⚠️ 另注：v0.4 在 init.recovery.qcom.rc 里加的 `setprop tw_disable_haptics 1` 是无效的
#    —— 那是 Android property，而 GUI 读的是 DataManager 的 const，两套系统不通。
TW_NO_HAPTICS := true

# Other TWRP Configurations
TARGET_RECOVERY_QCOM_RTC_FIX            := true
TW_CUSTOM_CPU_TEMP_PATH                 := "/sys/class/thermal/thermal_zone25/temp"
TW_EXCLUDE_APEX                         := true
TW_EXCLUDE_DEFAULT_USB_INIT             := true
TW_EXTRA_LANGUAGES                      := true
# ★ 黑屏根因修复（2026-11-04 实机采集后定案）
# 现象：TWRP 能启动、adb/root/USB 全通，但屏幕全黑。
# 根因：msm_drm.ko 是「模块」（8,113,096 B），面板驱动编在它里面，没有独立的 panel_*.ko。
#       原来 TW_LOAD_VENDOR_MODULES 为空 + EXCLUDE_GKI=true ⇒ msm_drm 从未被加载
#       ⇒ 无 DRM 节点 ⇒ 屏幕不亮，而内核 / adbd / USB 一切正常。
# 依据：modinfo msm_drm.ko → depends 25 个模块；
#       /vendor/lib/modules/modules.load 里原厂自己的加载顺序（msm_drm 排最后）。
# 说明：只需列「入口」，modules.dep 存在 ⇒ modprobe 自动按依赖加载其余 30 多个。
#       顺序照抄原厂 modules.load —— msm_drm 永远最后一个（依赖全在前面）。
#       ⚠️ 必须写单行：make 的 `\` 续行会在引号内插入空格。
# ⚠️ 不能改成全量加载：382 个模块共 152 MB，recovery 分区只有 100 MiB，必爆。
# ⚠️ 模块文件在 vendor_dlkm 分区、不在 ramdisk ⇒ recovery.fstab 的 /vendor_dlkm 条目必须有效。
TW_LOAD_VENDOR_MODULES                  := "panel_event_notifier.ko oplus_bsp_tp_custom.ko oplus_bsp_tp_comon.ko oplus_bsp_tp_notify.ko oplus_bsp_tp_tcm_S3910.ko oplus_bsp_tp_syna_comnon.ko msm_drm.ko"
TW_LOAD_VENDOR_MODULES_EXCLUDE_GKI      := false

# 触摸设备名（实测 /proc/bus/input/devices → Name="touchpanel"，Handlers=event5）
TW_WHITELIST_INPUT                      := "touchpanel"
TW_NO_SCREEN_BLANK                      := true
TW_USE_SERIALNO_PROPERTY_FOR_DEVICE_ID  := true
