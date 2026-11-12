#!/system/bin/sh
#
# PGW110 v0.7 —— TEE 服务统一启动闸门
#
# 为什么不能像以前那样在 `on init` 里直接 start：
#   init 的阶段顺序是 early-init → init → late-init → early-fs → fs → post-fs → boot。
#   而下面三件事全都发生在 `on init` 之后：
#     1. persist 分区在 `on fs` 才挂载（见 init.recovery.qcom.rc）
#     2. /dev/qseecom 的 chmod 0660 / chown system:drmrpc 也在 `on fs`
#     3. build 三件套属性（release / security_patch / vendor.security_patch）
#        要等 prepdecrypt.vendor 跑完才被 resetprop 改成真机值
#   以前 qseecomd / keymint 都在 `on init` 起来，上面三样都还没就绪：
#     - qseecomd 打 "RPMB_INIT failed, shall not start listener services"
#       ⇒ vendor.sys.listeners.registered 永远不会置 1
#     - libqtikeymint 读到 ro.build.version.release=99.87.36（TWRP 的伪装值）
#       ⇒ 交给 TA 的 KM_TAG_OS_VERSION / KM_TAG_OS_PATCHLEVEL 全是错的
#     - 表现为 keystore 恒定 -49 SECURE_HW_COMMUNICATION_FAILED
#
# 本脚本由 init 在 `on property:crypto.ready=1` 时启动，即 prepdecrypt 完成之后。
# 顺序：qseecomd → 等 listeners.registered → ssgtzd → keymaster@4.1(HIDL) → gatekeeper

LOG_TAG="twrp_tee"

log_it() {
    log -t "$LOG_TAG" "tee_launch: $*"
    echo "tee_launch: $*" >> /tmp/tee_launch.log
}

log_it "begin, crypto.ready=$(getprop crypto.ready)"
log_it "props: release=$(getprop ro.build.version.release) patch=$(getprop ro.build.version.security_patch) vpatch=$(getprop ro.vendor.build.security_patch)"

# ---- 1) qseecomd ----------------------------------------------------------
# 它必须在 persist 已挂载 + /dev/qseecom 权限已设之后启动，否则 RPMB 初始化
# 失败，listener 线程整组不启动。
if [ "$(getprop init.svc.vendor.qseecomd)" = "running" ]; then
    log_it "qseecomd already running, stop and restart it now that persist is mounted"
    setprop ctl.stop vendor.qseecomd
    sleep 1
fi
log_it "starting qseecomd"
setprop ctl.start vendor.qseecomd

i=0
while [ $i -lt 10 ]; do
    [ -e /dev/qseecom ] && break
    i=$((i + 1))
    sleep 1
done
log_it "qseecomd started, /dev/qseecom waited ${i}s"

# /dev/qseecom 是 qseecomd 起来之后才由它创建的，而 init.recovery.qcom.rc 的
# `on fs` 里那两行 chmod/chown 现在会打在空处（节点还不存在）。keymint 以
# user system 身份跑，拿不到 drmrpc 组就打不开这个设备，所以必须在这里补。
if [ -e /dev/qseecom ]; then
    chown system drmrpc /dev/qseecom
    chmod 0660 /dev/qseecom
    log_it "/dev/qseecom perms set: $(ls -l /dev/qseecom)"
else
    log_it "WARNING /dev/qseecom still missing after ${i}s"
fi

# ---- 2) 等 qseecomd 把 TEE listener 注册完 --------------------------------
# Skyward 的 nezha.toml 对这一步的注释：
#   "The secure world reaches back into Android through the listeners this
#    daemon registers; without them the key service cannot use any key."
# 也就是说 keymint 在 listeners.registered=1 之前 open HAL，拿到的会话是死的。
#
# ⚠️ v0.9 修正（v0.7/v0.8 遗留 bug）：这个属性在真机上是**字符串 "true"**，
#   不是 "1"。qseecomd 往 property 里写的是布尔值字面量，读回来就是 "true"。
#   v0.7/v0.8 一直拿它跟 "1" 比 ⇒ 永远不相等 ⇒ 白等满 20 秒。
#   现场证据（2026-11-08 /tmp/tee_launch.log）：
#       tee_launch: WARNING listeners.registered still 'true' after 20s
#   而同一时刻 getprop 读到的是 true，qseecomd 也早就 10 个线程了。
#   这里把 "1" 和 "true"（含大小写变体）都当成功，避免因为写法差异又白等。
listeners_ok() {
    case "$(getprop vendor.sys.listeners.registered)" in
        1|true|TRUE|True) return 0 ;;
        *) return 1 ;;
    esac
}

i=0
while [ $i -lt 20 ]; do
    listeners_ok && break
    i=$((i + 1))
    sleep 1
done
LISTENERS=$(getprop vendor.sys.listeners.registered)
if listeners_ok; then
    log_it "listeners.registered=$LISTENERS (waited ${i}s)"
else
    log_it "WARNING listeners.registered still '$LISTENERS' after ${i}s, continuing anyway"
fi

# ---- 3) ssgtzd（smcinvoke / TZD 网关） ------------------------------------
log_it "starting ssgtzd"
setprop ctl.start vendor.ssgtzd

i=0
while [ $i -lt 10 ]; do
    [ -e /dev/socket/ssgtzd ] && break
    i=$((i + 1))
    sleep 1
done
log_it "ssgtzd socket waited ${i}s"
sleep 1

# ---- 4) keymaster@4.1（HIDL —— keystore2 的 Legacy wrapper 就连它） --------
# v0.14 改动：原来是 `ctl.start vendor.keymint-qti`（AIDL），换成 HIDL keymaster。
#
# 为什么换（经验 059）：keystore2 找钥匙顺序
#     globals.rs:245 genuine KeyMint（AIDL）→ :259 compat → :268 Legacy wrapper（HIDL）
# 本机 AIDL keymint 注册时被 servicemanager 用 VINTF 白名单拒掉
#     Could not find android.hardware.security.keymint.IKeyMintDevice/default
#     in the VINTF manifest.  →  Failed CHECK in addService, line 46
# compat 那条又需要 android.security.compat（本机没有），所以只剩 Legacy wrapper。
# 同 SoC 一加10Pro 的 TWRP 正是只跑 HIDL keymaster@4.1，输 PIN 就能解开本机 data。
#
# AIDL keymint 那行保留在下面（注释状态），需要回滚时对调两行即可。
log_it "starting keymaster-4-1 (HIDL)"
setprop ctl.start vendor.keymaster-4-1
sleep 1
KM_PID=$(ps -A -o PID,NAME 2>/dev/null | grep "keymaster@4.1" | grep -v grep | awk '{print $1}' | head -1)
log_it "keymaster-4-1 pid='${KM_PID}' svc=$(getprop init.svc.vendor.keymaster-4-1)"

# v0.13 及以前走 AIDL keymint，注册必被 VINTF 白名单拒，留着只会多一条 CHECK 失败日志。
# log_it "starting keymint (AIDL)"
# setprop ctl.start vendor.keymint-qti
# sleep 1

# ---- 5) gatekeeper（用户凭据 / FBE，metadata 解密不依赖它） ---------------
# v0.10 换成了**真实的 HIDL 1.0 服务**（服务名 gatekeeper-1-0）。
# 旧供体那份是 AIDL 版，在本机 TA 上必崩：
#     F android.hardware.gatekeeper-service-qti: Check failed: status == STATUS_OK
#
# 它是 HIDL，注册要走 hwservicemanager（不是 servicemanager）。后者在 `on init`
# 就起来了（system/etc/init/hwservicemanager.rc）。
#
# ⚠️ v0.9~v0.11 的教训：只要 hwservicemanager 启动时在 VINTF 里查不到自己
# （android.hidl.manager@1.2），它会写下 hwservicemanager.disabled=true 然后躺平，
# 该属性被 libhidlbase 在进程内 once_flag **永久缓存**；之后所有进程都判定
# "没有 hwservicemanager"，注册必然被拒：
#     E HidlServiceManagement: Service ... must be in VINTF manifest in order to register/get.
# v0.12 把 /system/etc/vintf/manifest.xml 换回官方 framework 原版（含 hidl.manager），
# 它就不会再退休了。这里仍然等一下 ready，避免抢跑。
i=0
while [ $i -lt 10 ]; do
    [ "$(getprop hwservicemanager.ready)" = "true" ] && break
    i=$((i + 1))
    sleep 1
done
log_it "hwservicemanager.ready=$(getprop hwservicemanager.ready) (waited ${i}s)"

log_it "starting gatekeeper-1-0"
setprop ctl.start gatekeeper-1-0
sleep 2

# 注册失败时 HIDL 生成的 main 会直接退出，所以「进程还活着」= 注册成功。
# 这条判据比看 init.svc 可靠：init.svc 在服务反复重启时也会显示 running。
# 用 ps 而不是 pidof —— comm 只有 15 字符，这个二进制名太长会被截断。
GK_PID=$(ps -A -o PID,NAME 2>/dev/null | grep "gatekeeper@1.0" | grep -v grep | awk '{print $1}' | head -1)
log_it "gatekeeper pid='${GK_PID}' svc=$(getprop init.svc.gatekeeper-1-0)"

log_it "done: qseecomd=$(getprop init.svc.vendor.qseecomd) ssgtzd=$(getprop init.svc.vendor.ssgtzd) keymaster=$(getprop init.svc.vendor.keymaster-4-1) km_pid=${KM_PID} gatekeeper=$(getprop init.svc.gatekeeper-1-0) gk_pid=${GK_PID}"

exit 0
