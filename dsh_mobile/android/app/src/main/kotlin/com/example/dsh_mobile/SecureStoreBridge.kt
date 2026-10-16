package com.example.dsh_mobile

import android.annotation.SuppressLint
import android.content.Context
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * `dsh_mobile/secure` 的实现：把一段字符串加密存起来 / 取回来 / 删掉。
 *
 * 为什么手写而不是用 flutter_secure_storage：那个包会把 `js` 拖到 ^0.6.x，
 * 与 `speech_to_text: 6.6.2` 钉住的 `js ^0.7.1` 直接冲突（README §4）。而这里
 * 真正需要的只是「AndroidKeyStore 里一把不可导出的密钥 + AES/GCM」，没有别的。
 * 不引入新依赖，也就不必为了让一个存字符串的能力去放开版本钉、连带升级 Flutter。
 *
 * 密钥与密文的分工：
 *   * 密钥：`KeyGenParameterSpec` 生成的 AES-256 密钥**永远不离开 Keystore**。
 *     进程里拿到的 `SecretKey` 只是句柄，`getEncoded()` 返回 null；adb backup、
 *     root 读文件、备份还原都拿不到密钥材料。
 *   * 密文：`iv:ct` 两段 Base64，落在独立的 SharedPreferences 文件
 *     （[PREFS_FILE]）里。密文本身不需要保密 —— 没有那把密钥它什么都不是。
 *
 * 为什么**不**加密非敏感字段（host/port/name…）：它们不是凭据，加密只会让
 * 出问题时更难排查，且 `loadProfiles` 这类高频路径要额外跨通道。
 *
 * 版本兼容：AndroidKeyStore 的 AES/GCM 要到 **API 23** 才齐全，而本项目
 * `minSdk = 21`。所以 [onMethodCall] 先判版本：21/22 上 `ping` 直接回 false，
 * Dart 侧据此走降级（内存 + 明文兜底），而不是让 App 在这两台机器上崩掉 ——
 * 一台 Android 5.x 手机能连上网关，比"无法加密所以连不上"重要得多。
 */
class SecureStoreBridge(private val context: Context) : MethodChannel.MethodCallHandler {

    @SuppressLint("NewApi") // onMethodCall 里已判 SDK_INT；见类注释「版本兼容」
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            // 能力不存在：ping 如实回 false 让 Dart 侧立刻降级；其余方法回错误，
            // 由 Dart 侧的兜底逻辑处理（它不会把异常抛给业务代码）。
            if (call.method == "ping") {
                result.success(false)
            } else {
                result.error("secure-unavailable", "AndroidKeyStore AES 需要 API 23+", null)
            }
            return
        }
        try {
            when (call.method) {
                "ping" -> result.success(true)

                "write" -> {
                    val key = call.argument<String>("key")
                    val value = call.argument<String>("value")
                    if (key.isNullOrBlank() || value == null) {
                        result.error("bad-args", "key and value are required", null)
                        return
                    }
                    // 每次写入都新建 Cipher：GCM 复用 (key, iv) 会直接破坏机密性，
                    // 所以这里既不复用 Cipher 实例，也不复用 IV。
                    val encryptor = Cipher.getInstance(TRANSFORM)
                    encryptor.init(Cipher.ENCRYPT_MODE, masterKey())
                    val iv = encryptor.iv
                    val ct = encryptor.doFinal(value.toByteArray(Charsets.UTF_8))
                    prefs().edit()
                        .putString(
                            PREFIX + key,
                            Base64.encodeToString(iv, Base64.NO_WRAP) + ":" +
                                Base64.encodeToString(ct, Base64.NO_WRAP)
                        )
                        .apply()
                    result.success(true)
                }

                "read" -> {
                    val key = call.argument<String>("key")
                    if (key.isNullOrBlank()) {
                        result.error("bad-args", "key is required", null)
                        return
                    }
                    result.success(read(key))
                }

                "delete" -> {
                    val key = call.argument<String>("key")
                    if (key.isNullOrBlank()) {
                        result.error("bad-args", "key is required", null)
                        return
                    }
                    prefs().edit().remove(PREFIX + key).apply()
                    result.success(true)
                }

                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            // 任何失败都如实回给 Dart 侧：它会降级到内存/明文路径，
            // 绝不因为加密不可用就丢掉用户的网关凭据。
            result.error("secure-failed", e.message ?: e.javaClass.simpleName, null)
        }
    }

    /**
     * 取（必要时生成）Keystore 里的主密钥。
     *
     * 为什么用固定别名：别名只在本 App 的 Keystore 命名空间里可见，猜不到也不需要
     * 保密 —— 真正保密的是密钥材料本身，而它不可导出。
     *
     * `setUserAuthenticationRequired(false)`：网关凭据要在冷启动、无人交互时可用
     * （后台保活服务重连 WebSocket 也要读），要求生物识别会让"打开 App 就连不上
     * 自己的机器"。
     *
     * 密钥被系统清掉（改锁屏密码、恢复出厂、部分 ROM 的清理策略）时 `getKey`
     * 返回 null，这里重新生成一把 —— 旧密文届时解不开（GCM 认证失败），Dart 侧
     * 据此走降级路径并保留明文兜底，不会出现"读不出来就静默变成空 token"。
     */
    private fun masterKey(): SecretKey {
        val ks = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        (ks.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE)
        gen.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(KEY_SIZE_BITS)
                .setUserAuthenticationRequired(false)
                .build()
        )
        return gen.generateKey()
    }

    /** 解密读回。没写过 / 格式不对 / 密钥不匹配一律回 null，由 Dart 侧降级。 */
    private fun read(key: String): String? {
        val stored = prefs().getString(PREFIX + key, null) ?: return null
        val sep = stored.indexOf(':')
        if (sep <= 0) return null
        val iv = Base64.decode(stored.substring(0, sep), Base64.NO_WRAP)
        val ct = Base64.decode(stored.substring(sep + 1), Base64.NO_WRAP)
        val decryptor = Cipher.getInstance(TRANSFORM)
        decryptor.init(
            Cipher.DECRYPT_MODE,
            masterKey(),
            GCMParameterSpec(TAG_BITS, iv)
        )
        return String(decryptor.doFinal(ct), Charsets.UTF_8)
    }

    /**
     * 密文文件。刻意与应用默认的 SharedPreferences 分开：明文配置和密文混在同一个
     * 文件里，审计时反而看不清哪些字段是敏感的。
     */
    private fun prefs() = context.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)

    companion object {
        /** AndroidKeyStore 是平台固定的 provider 名，不是可配置项。 */
        private const val KEYSTORE = "AndroidKeyStore"

        /** 主密钥别名。改动它等于让所有已存密文无法解密，绝不能在版本间改。 */
        private const val KEY_ALIAS = "dsh_mobile_master"

        /** AES/GCM：带认证标签，密文被篡改会抛异常而不是返回一段垃圾明文。 */
        private const val TRANSFORM = "AES/GCM/NoPadding"

        /** GCM 推荐的 128 位认证标签。 */
        private const val TAG_BITS = 128

        private const val KEY_SIZE_BITS = 256

        private const val PREFS_FILE = "dsh_secure_store"
        private const val PREFIX = "secure_"
    }
}
