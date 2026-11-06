#!/system/bin/sh
#
# PGW110 v0.7 —— TEE 启动闸门的兜底
#
# tee_launch 依赖 prepdecrypt.vendor 设 crypto.ready=1 才被拉起。这条链条上
# 任何一环断掉（variant-script 没跑完 / prepdecrypt 提前 exit / 属性没传到），
# TEE 服务就一个都不会起 —— 那比改之前更糟（改之前至少 keymint 是起着的）。
#
# 所以这里再压一道：`on boot` 之后等 ANTICIPATE 秒，若 keymint 还没 running，
# 就无条件走一遍完整启动（含 persist 检查）。宁可时序不够完美，也不能让
# TWRP 落进「什么 TEE 服务都没有」的状态。

LOG_TAG="twrp_tee"
ANTICIPATE=30

log_it() {
    log -t "$LOG_TAG" "tee_watchdog: $*"
    echo "tee_watchdog: $*" >> /tmp/tee_launch.log
}

i=0
while [ $i -lt $ANTICIPATE ]; do
    if [ "$(getprop init.svc.vendor.keymint-qti)" = "running" ]; then
        log_it "keymint already up after ${i}s, nothing to do"
        exit 0
    fi
    i=$((i + 1))
    sleep 1
done

log_it "keymint still down after ${ANTICIPATE}s — crypto.ready=$(getprop crypto.ready); forcing full launch"

# 直接在这里做，不依赖 tee_launch 的 oneshot 状态（它可能正卡在等 listener）
[ "$(getprop init.svc.vendor.qseecomd)" = "running" ] || setprop ctl.start vendor.qseecomd
sleep 3
[ "$(getprop init.svc.vendor.ssgtzd)" = "running" ] || setprop ctl.start vendor.ssgtzd
sleep 1
[ "$(getprop init.svc.vendor.keymint-qti)" = "running" ] || setprop ctl.start vendor.keymint-qti
sleep 1
[ "$(getprop init.svc.vendor.gatekeeper_default)" = "running" ] || setprop ctl.start vendor.gatekeeper_default

sleep 1
log_it "forced start done: qseecomd=$(getprop init.svc.vendor.qseecomd) ssgtzd=$(getprop init.svc.vendor.ssgtzd) keymint=$(getprop init.svc.vendor.keymint-qti)"

exit 0
