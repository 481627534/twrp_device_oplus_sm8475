#!/usr/bin/env python3
"""
PGW110 v0.9 —— 给 system/vold 打上「DE key 解密过程」的 stderr 日志。

背景
────
TWRP 的 recovery 把 libvold 静态链接进主进程（bootable/recovery/Android.bp 里
有 "libvold"），所以 vold 的代码就跑在 recovery 进程内。但 vold 用的是
LOG(INFO) / LOG(ERROR)（libbase → liblog → logd socket），而 recovery 里
根本没有 logd 在跑，这些日志全部被丢掉：

    $ grep -c vold /tmp/recovery.log     → 0

结果就是最关键的 DE key（设备密钥）初始化失败时，日志里只剩两行 printf：

    Attempting to initialize DE keys
    fscrypt_initialize_systemwide_keys returned fail

再往下（是哪一步失败、keymaster 返回什么错误码、GCM 校验过不过）一概看不到。
2026-11-08 排查「/data/media/0 文件名仍是密文」时就卡在这里，只能靠猜。

而 recovery 的 stdout/stderr 是 recovery.cpp 的 redirect_stdio() 重定向到
/tmp/recovery.log 的 —— 所以只要改用 fprintf(stderr, ...)，日志就能落地。

本脚本做的事
────────────
在 KeyStorage.cpp / FsCrypt.cpp 里插入若干 fprintf(stderr, "[volddbg] ...")，
覆盖 DE key 解密的完整链路：

    fscrypt_initialize_systemwide_keys
      → retrieveOrGenerateKey（含 neverGen 语义）
        → retrieveKey
          → 版本文件校验
          → secdiscardable 读取（Android 13+ 的存储绑定输入）
          → appId 生成
          → encrypted_key 读取
          → decryptWithKeystoreKey（keystore2 / keymint，打印 km::ErrorCode）
            或 decryptWithoutKeystore（纯 OpenSSL AES-GCM，打印 GCM tag 校验结果）
      → install_storage_key（含 wrappedkey 重试分支）

失败语义
────────
任何一个锚点在源码里找不到（或出现多次），脚本立刻 exit 1 并在 CI 里显式报错。
理由：静默漏打补丁 = 又白编一版、又白刷一次机。宁可 1 分钟失败，不要 50 分钟白跑。

幂等
────
补丁插入的每一行都带 "[volddbg]" 标记。脚本先检查标记，已存在就整体跳过，
所以重复执行（哪怕源码已打过）也是安全的。

用法
────
    python3 tools/patch_vold_debug.py <源码根目录>

例（CI 里）：
    python3 device/oplus/sm8475/tools/patch_vold_debug.py .
"""

import sys
import os

MARK = "[volddbg]"

# ---------------------------------------------------------------------------
# 补丁表：(相对路径, 说明, 原文, 替换后)
# 每条「原文」必须在文件里恰好出现 1 次，否则整轮失败。
# ---------------------------------------------------------------------------
RULES = [
    # ===================== KeyStorage.cpp =====================
    (
        "system/vold/KeyStorage.cpp",
        "retrieveKey 入口：记录目标目录、认证方式",
        """bool retrieveKey(const std::string& dir, const KeyAuthentication& auth, KeyBuffer* key) {
    LOG(INFO) << "Retrieving key from keymaster";
""",
        """bool retrieveKey(const std::string& dir, const KeyAuthentication& auth, KeyBuffer* key) {
    LOG(INFO) << "Retrieving key from keymaster";
    fprintf(stderr, "[volddbg] retrieveKey enter dir=%s usesKeystore=%d secretLen=%d\\n",
            dir.c_str(), (int)auth.usesKeystore(), (int)auth.secret.size());
""",
    ),
    (
        "system/vold/KeyStorage.cpp",
        "retrieveKey：版本文件校验（版本不符会直接 return false，之前完全静默）",
        """    std::string version;
    if (!readFileToString(dir + "/" + kFn_version, &version)) return false;
    if (version != kCurrentVersion) {
        LOG(ERROR) << "Version mismatch, expected " << kCurrentVersion << " got " << version;
        return false;
    }
""",
        """    std::string version;
    if (!readFileToString(dir + "/" + kFn_version, &version)) {
        fprintf(stderr, "[volddbg] read version file FAILED (%s/%s)\\n", dir.c_str(),
                kFn_version.c_str());
        return false;
    }
    fprintf(stderr, "[volddbg] version read ok, got '%s' expect '%s'\\n", version.c_str(),
            kCurrentVersion.c_str());
    if (version != kCurrentVersion) {
        LOG(ERROR) << "Version mismatch, expected " << kCurrentVersion << " got " << version;
        return false;
    }
""",
    ),
    (
        "system/vold/KeyStorage.cpp",
        "retrieveKey：secdiscardable / appId / encrypted_key（GCM 密钥派生的全部输入）",
        """    std::string secdiscardable_hash;
    if (!readSecdiscardable(dir + "/" + kFn_secdiscardable, &secdiscardable_hash)) return false;
    std::string appId = generateAppId(auth, secdiscardable_hash);
    std::string encryptedMessage;
    if (!readFileToString(dir + "/" + kFn_encrypted_key, &encryptedMessage)) return false;
""",
        """    std::string secdiscardable_hash;
    if (!readSecdiscardable(dir + "/" + kFn_secdiscardable, &secdiscardable_hash)) {
        fprintf(stderr, "[volddbg] readSecdiscardable FAILED (%s/%s)\\n", dir.c_str(),
                kFn_secdiscardable.c_str());
        return false;
    }
    fprintf(stderr, "[volddbg] secdiscardable_hash len=%d first8=", (int)secdiscardable_hash.size());
    for (size_t i = 0; i < secdiscardable_hash.size() && i < 8; i++)
        fprintf(stderr, "%02x", (unsigned char)secdiscardable_hash[i]);
    fprintf(stderr, "\\n");
    std::string appId = generateAppId(auth, secdiscardable_hash);
    fprintf(stderr, "[volddbg] appId len=%d first8=", (int)appId.size());
    for (size_t i = 0; i < appId.size() && i < 8; i++)
        fprintf(stderr, "%02x", (unsigned char)appId[i]);
    fprintf(stderr, "\\n");
    std::string encryptedMessage;
    if (!readFileToString(dir + "/" + kFn_encrypted_key, &encryptedMessage)) {
        fprintf(stderr, "[volddbg] read encrypted_key FAILED (%s/%s)\\n", dir.c_str(),
                kFn_encrypted_key.c_str());
        return false;
    }
    fprintf(stderr, "[volddbg] encrypted_key len=%d (expect nonce%d+body+mac%d)\\n",
            (int)encryptedMessage.size(), (int)GCM_NONCE_BYTES, (int)GCM_MAC_BYTES);
""",
    ),
    (
        "system/vold/KeyStorage.cpp",
        "retrieveKey：两条解密分支的成功/失败都要留痕",
        """    if (auth.usesKeystore()) {
        Keystore keystore;
        if (!keystore) return false;
        km::AuthorizationSet keyParams = beginParams(appId);
        if (!decryptWithKeystoreKey(keystore, dir, keyParams, encryptedMessage, key)) {
            LOG(ERROR) << "decryptWithKeystoreKey failed";
            return false;
        }
    } else {
        if (!decryptWithoutKeystore(appId, encryptedMessage, key)) {
            LOG(ERROR) << "decryptWithoutKeystore failed";
            return false;
        }
    }
""",
        """    if (auth.usesKeystore()) {
        fprintf(stderr, "[volddbg] path=keystore (usesKeystore=true)\\n");
        Keystore keystore;
        if (!keystore) {
            fprintf(stderr, "[volddbg] Keystore ctor FAILED (no IKeystoreSecurityLevel)\\n");
            return false;
        }
        km::AuthorizationSet keyParams = beginParams(appId);
        if (!decryptWithKeystoreKey(keystore, dir, keyParams, encryptedMessage, key)) {
            fprintf(stderr, "[volddbg] decryptWithKeystoreKey FAILED\\n");
            LOG(ERROR) << "decryptWithKeystoreKey failed";
            return false;
        }
        fprintf(stderr, "[volddbg] decryptWithKeystoreKey OK, key len=%d\\n", (int)key->size());
    } else {
        fprintf(stderr, "[volddbg] path=openssl (usesKeystore=false)\\n");
        if (!decryptWithoutKeystore(appId, encryptedMessage, key)) {
            fprintf(stderr, "[volddbg] decryptWithoutKeystore FAILED (GCM tag mismatch?)\\n");
            LOG(ERROR) << "decryptWithoutKeystore failed";
            return false;
        }
        fprintf(stderr, "[volddbg] decryptWithoutKeystore OK, key len=%d\\n", (int)key->size());
    }
""",
    ),
    (
        "system/vold/KeyStorage.cpp",
        "decryptWithKeystoreKey：把 keymaster 的 km::ErrorCode 打出来（-49/-62/-33 的出处）",
        """    auto opHandle = BeginKeystoreOp(keystore, dir, keyParams, opParams, nullptr);
    if (!opHandle) return false;
    if (!opHandle.updateCompletely(bodyAndMac, message)) return false;
    if (!opHandle.finish(nullptr)) return false;
    return true;
""",
        """    auto opHandle = BeginKeystoreOp(keystore, dir, keyParams, opParams, nullptr);
    if (!opHandle) {
        fprintf(stderr, "[volddbg] BeginKeystoreOp FAILED kmErrorCode=%d\\n",
                (int)opHandle.getErrorCode());
        return false;
    }
    if (!opHandle.updateCompletely(bodyAndMac, message)) {
        fprintf(stderr, "[volddbg] keystore update FAILED kmErrorCode=%d\\n",
                (int)opHandle.getErrorCode());
        return false;
    }
    if (!opHandle.finish(nullptr)) {
        fprintf(stderr, "[volddbg] keystore finish FAILED kmErrorCode=%d\\n",
                (int)opHandle.getErrorCode());
        return false;
    }
    fprintf(stderr, "[volddbg] keystore op OK, plaintext len=%d\\n", (int)message->size());
    return true;
""",
    ),
    # ===================== FsCrypt.cpp =====================
    (
        "system/vold/FsCrypt.cpp",
        "fscrypt_initialize_systemwide_keys 入口与两个前置步骤",
        """bool fscrypt_initialize_systemwide_keys() {
    LOG(INFO) << "fscrypt_initialize_systemwide_keys";

    if (!init_data_file_encryption_options()) return false;

    EncryptionOptions options;
    if (!get_volume_file_encryption_options(&options)) return false;
""",
        """bool fscrypt_initialize_systemwide_keys() {
    LOG(INFO) << "fscrypt_initialize_systemwide_keys";
    fprintf(stderr, "[volddbg] ==== fscrypt_initialize_systemwide_keys enter ====\\n");

    if (!init_data_file_encryption_options()) {
        fprintf(stderr, "[volddbg] init_data_file_encryption_options FAILED\\n");
        return false;
    }

    EncryptionOptions options;
    if (!get_volume_file_encryption_options(&options)) {
        fprintf(stderr, "[volddbg] get_volume_file_encryption_options FAILED\\n");
        return false;
    }
    fprintf(stderr, "[volddbg] options: use_hw_wrapped_key=%d\\n",
            (int)options.use_hw_wrapped_key);
""",
    ),
    (
        "system/vold/FsCrypt.cpp",
        "retrieveOrGenerateKey 失败要留痕（这一步失败最常见：DE key 缺失/读不出）",
        """    if (!retrieveOrGenerateKey(device_key_path, device_key_temp, kEmptyAuthentication,
                               android::vold::neverGen(), &device_key))
        return false;
""",
        """    if (!retrieveOrGenerateKey(device_key_path, device_key_temp, kEmptyAuthentication,
                               android::vold::neverGen(), &device_key)) {
        fprintf(stderr, "[volddbg] retrieveOrGenerateKey FAILED (key_path=%s)\\n",
                device_key_path.c_str());
        return false;
    }
    fprintf(stderr, "[volddbg] device_key retrieved, len=%d first8=", (int)device_key.size());
    for (size_t i = 0; i < device_key.size() && i < 8; i++)
        fprintf(stderr, "%02x", (unsigned char)device_key[i]);
    fprintf(stderr, "\\n");
""",
    ),
    (
        "system/vold/FsCrypt.cpp",
        "install_storage_key 失败要留痕，并区分 wrappedkey 试过哪两种",
        """    if (!install_storage_key(DATA_MNT_POINT, s_data_options, device_key, &s_device_policy)) {
        if (retry) {
""",
        """    if (!install_storage_key(DATA_MNT_POINT, s_data_options, device_key, &s_device_policy)) {
        fprintf(stderr, "[volddbg] install_storage_key FAILED (use_hw_wrapped_key=%d retry=%d)\\n",
                (int)options.use_hw_wrapped_key, (int)retry);
        if (retry) {
""",
    ),
]


def apply_rule(root, path, desc, old, new):
    full = os.path.join(root, path)
    if not os.path.exists(full):
        raise SystemExit("[patch_vold_debug] 源文件不存在: %s" % full)

    with open(full, "r", encoding="utf-8", errors="surrogateescape") as f:
        text = f.read()

    # 行尾归一化（双保险）。CI 在 Linux 上，上游源码本来就是 LF；但本脚本自身
    # 如果被 checkout 成 CRLF，三元引号里的锚点就会带 "\r\n"，跟目标文件对不上。
    # 两处都归一化，谁也坑不到谁。
    text = text.replace("\r\n", "\n")
    old = old.replace("\r\n", "\n")
    new = new.replace("\r\n", "\n")

    # 幂等判断必须用 new 而不是 old：本脚本有多条规则是"纯追加"（new 以 old 开头），
    # 用 old 判断的话打完补丁 old 仍是子串，会判定为"没打过"而重复插入。
    if new in text:
        print("[skip] %-22s %s（已打过）" % (os.path.basename(path), desc))
        return False

    hits = text.count(old)
    if hits != 1:
        raise SystemExit(
            "[patch_vold_debug] 锚点失配: %s / %s\n"
            "  期望出现 1 次，实际 %d 次。\n"
            "  上游可能改过这段代码，请打开文件核对后再更新本脚本。"
            % (path, desc, hits)
        )

    with open(full, "w", encoding="utf-8", errors="surrogateescape", newline="") as f:
        f.write(text.replace(old, new, 1))
    print("[ ok ] %-22s %s" % (os.path.basename(path), desc))
    return True


def main():
    if len(sys.argv) < 2:
        raise SystemExit("用法: python3 patch_vold_debug.py <源码根目录>")

    root = sys.argv[1]
    target = os.path.join(root, "system/vold/KeyStorage.cpp")
    if not os.path.exists(target):
        raise SystemExit("[patch_vold_debug] 找不到 %s —— 源码根目录参数错了？" % target)

    changed = 0
    for path, desc, old, new in RULES:
        if apply_rule(root, path, desc, old, new):
            changed += 1

    print("[patch_vold_debug] 完成：%d/%d 处改动写入" % (changed, len(RULES)))
    if changed == 0:
        print("[patch_vold_debug] 全部已存在，幂等跳过")


if __name__ == "__main__":
    main()
