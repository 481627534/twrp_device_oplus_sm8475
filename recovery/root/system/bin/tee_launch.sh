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
# 顺序：qseecomd → 等 listeners.registered → ssgtzd → keymint → gatekeeper

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
i=0
while [ $i -lt 20 ]; do
    [ "$(getprop vendor.sys.listeners.registered)" = "1" ] && break
    i=$((i + 1))
    sleep 1
done
LISTENERS=$(getprop vendor.sys.listeners.registered)
if [ "$LISTENERS" = "1" ]; then
    log_it "listeners.registered=1 (waited ${i}s)"
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

# ---- 4) keymint（metadata 解密要的就是它） --------------------------------
log_it "starting keymint"
setprop ctl.start vendor.keymint-qti
sleep 1

# ---- 5) gatekeeper（用户凭据 / FBE，metadata 解密不依赖它） ---------------
log_it "starting gatekeeper"
setprop ctl.start vendor.gatekeeper_default

sleep 1
log_it "done: qseecomd=$(getprop init.svc.vendor.qseecomd) ssgtzd=$(getprop init.svc.vendor.ssgtzd) keymint=$(getprop init.svc.vendor.keymint-qti) gatekeeper=$(getprop init.svc.vendor.gatekeeper_default)"

exit 0
