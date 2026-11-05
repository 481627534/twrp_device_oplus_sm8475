#!/usr/bin/env python3
"""PGW110 TWRP —— 修复「电池电量恒显 100%」。

根因（2026-11-05 实测确认）：
  TWRP 的 recovery 二进制链接 android.hardware.health-V4-ndk.so（V4 客户端），
  但 recovery_utils/battery_utils.cpp 里仍调用 health->getCapacity()。
  AOSP 从 Health AIDL V3 起把 getCapacity() 改成固定返回
  EX_UNSUPPORTED_OPERATION（官方要求改用 getHealthInfo().batteryCapacity），
  于是 capacity 保持 INT32_MIN，被下面的「无电池设备」分支硬编码成 100。

  日志实证：
    W recovery: Unable to call getCapacity: Status(-7, EX_UNSUPPORTED_OPERATION)
    W recovery: Using fake battery capacity 100.

做法：
  在 GetBatteryInfo() 的 fake-100 分支之前插入 sysfs 兜底，直接读
  /sys/class/power_supply/battery/capacity（内核节点，PGW110 上实测存在且值正确）。

  不改 health HAL、不换任何 .so，只动一个 .cpp，无跨代库风险。

用法：
  python3 tools/patch_battery_capacity.py bootable/recovery/recovery_utils/battery_utils.cpp
"""

import pathlib
import sys

# 锚点：AOSP/TWRP 原文的 fake-100 分支，注释文字在多个版本里稳定存在
ANCHOR = """    // If we can't read battery percentage, it may be a device without battery. In this
    // situation, use 100 as a fake battery percentage.
    if (capacity == INT32_MIN) {"""

MARKER = "PGW110 patch: Health AIDL V3+"

INSERT = """    // \u2605 PGW110 patch: Health AIDL V3+ deprecates getCapacity() and makes it return
    // EX_UNSUPPORTED_OPERATION, which drops us into the fake-100 branch below.
    // Read the kernel power_supply node directly instead.
    if (capacity == INT32_MIN) {
      std::string cap_str;
      if (android::base::ReadFileToString("/sys/class/power_supply/battery/capacity",
                                          &cap_str)) {
        int v = atoi(cap_str.c_str());
        if (v >= 0 && v <= 100) {
          LOG(INFO) << "getCapacity unsupported; using sysfs capacity " << v;
          capacity = v;
        }
      }
    }

"""

INC_ANCHOR = "#include <unistd.h>\n"
INC_ADD = "\n#include <stdlib.h>\n\n#include <android-base/file.h>\n"


def main():
    if len(sys.argv) != 2:
        print("usage: patch_battery_capacity.py <path to battery_utils.cpp>", file=sys.stderr)
        return 2

    p = pathlib.Path(sys.argv[1])
    if not p.is_file():
        print(f"[patch] ERROR: file not found: {p}", file=sys.stderr)
        return 1

    # 用 bytes 读写，原样保留行尾（write_text 在 Windows 上会把 LF 转 CRLF）
    src = p.read_bytes().decode("utf-8")

    if MARKER in src:
        print(f"[patch] already applied, skip: {p}")
        return 0

    if ANCHOR not in src:
        print("[patch] ERROR: fake-100 anchor not found — upstream source changed.",
              file=sys.stderr)
        print("[patch] 请检查电池分支是否被 AOSP 改写后再更新本脚本。", file=sys.stderr)
        return 1

    if INC_ANCHOR not in src:
        print(f"[patch] ERROR: include anchor {INC_ANCHOR!r} not found.", file=sys.stderr)
        return 1

    # 1) 补 include（ReadFileToString / atoi）
    if "android-base/file.h" not in src:
        src = src.replace(INC_ANCHOR, INC_ANCHOR + INC_ADD, 1)

    # 2) 插入 sysfs 兜底
    src = src.replace(ANCHOR, INSERT + ANCHOR, 1)

    p.write_bytes(src.encode("utf-8"))
    print(f"[patch] applied sysfs battery fallback -> {p}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
