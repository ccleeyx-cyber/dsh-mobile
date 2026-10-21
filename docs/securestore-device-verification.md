# SecureStore 真机验收清单

> **状态：尚未执行。** 本文是待办清单，不是验收记录。
> 代码侧已经加了观测点（`DshSecure` logcat 标签），但**真机行为一次都没跑过** ——
> 本机没有 Android SDK，见 `README.md` §4「未经真机验证」。

## 为什么需要这一份

`dsh_mobile/lib/services/secure_store.dart` + `android/.../SecureStoreBridge.kt`
是 v1.22 引入的凭据加密存储（Android Keystore，AES-256/GCM，密钥别名
`dsh_mobile_master`，密文落独立 SP 文件 `dsh_secure_store`）。

它有三类**只能真机验证**的行为，静态审查看不出来：

| 行为 | 为什么模拟不出来 |
|---|---|
| 密钥真的不可导出 | `getEncoded()` 返回 null 是 Keystore 服务的行为，不是代码行为 |
| 改锁屏密码后密钥失效 | 依赖 ROM 的 Keystore 生命周期，各厂商不一致 |
| API 21/22 降级路径 | 需要真实低版本设备或带正确系统镜像的模拟器 |

## 前置

```bash
adb devices                       # 确认设备已连
adb logcat -c                     # 清空，保证只看到本次
adb logcat -s DshSecure           # 单开一个窗口盯日志（TAG 已固定在代码里）
```

安装包取自 GitHub Releases（网关自 v1.37 起不再托管 APK）。

## 用例

### 1. 能力探测

打开 App 进配置页，随便填一个网关地址。

| 步骤 | 预期日志 | 预期界面 |
|---|---|---|
| 冷启动 | `call=ping sdk=33` → `ping=true keyExists=false`（首次）或 `true`（已生成） | 无异常提示 |

- API < 23 时预期是 `ping=false reason=below-api-23`，且 App **可用**（走明文兜底）。

### 2. 写入与密文落盘

配对成功后（token 写入）：

```bash
adb shell run-as com.example.dsh_mobile cat shared_prefs/dsh_secure_store.xml
adb shell run-as com.example.dsh_mobile cat shared_prefs/ReactNativeSharedPreferences.xml 2>/dev/null
```

| 预期 | 判据 |
|---|---|
| 日志 | `write ok key=... plainBytes=NN ivBytes=12 ctBytes=NN+16`（GCM 认证标签 16 字节） |
| 密文文件 | `dsh_secure_store.xml` 里有 `secure_*` 键，值形如 `<base64iv>:<base64ct>` |
| 明文文件 | **不得**再出现网关 token 明文 |

> ⚠️ 日志只打长度，不打内容。任何一行日志里出现 token 字符即为**缺陷**，立即记录。

### 3. 读回一致

杀掉 App（`adb shell am force-stop com.example.dsh_mobile`）后重开。

| 预期日志 | 判据 |
|---|---|
| `read key=... hit=true plainBytes=NN` | 字节数与写入时一致 |
| 界面 | 自动重连成功，不需要重新配对 |

### 4. 密钥被清除后的降级（最容易出事的一条）

```bash
adb shell am force-stop com.example.dsh_mobile
# 需要 root 或 debuggable 包；不行就改用「系统设置里改锁屏密码」触发
adb shell su 0 rm -rf /data/misc/keystore/user_0/*dsh_mobile_master* 2>/dev/null
```

然后重开 App。

| 预期 | 判据 |
|---|---|
| 日志 | `read ... hit=false` 或 `failed ... AEADBadTagException` |
| 行为 | **不崩溃**，不静默变成空 token；走明文兜底或提示重新配对 |
| 关键点 | 旧密文解不开时**必须**保留可用状态，不能把用户锁在门外 |

### 5. 改锁屏密码（真实场景，不是人为删密钥）

改锁屏密码 → 重开 App → 看 `keyExists` 与 `read` 结果。

实测结论记进下面这张表（这是唯一能回答"Android 到底怎么处理"的证据）。

### 6. API 21/22 设备

有真机就用真机；没有就用带 5.0/5.1 系统镜像的模拟器。

| 预期 | 判据 |
|---|---|
| 日志 | `ping=false reason=below-api-23` |
| 行为 | App 可用；token 以明文存（这是刻意的降级，不是 bug） |

## 实测结果登记

跑完把结论填进来，本文档即可从"待办"改为"验收记录"：

| 设备 / ROM | API | 密钥生成 | 写读一致 | 改锁屏后 | 删密钥后 | 备注 |
|---|---|---|---|---|---|---|
| _待填_ | | | | | | |

## 已知的取舍（不要在验收时当成缺陷）

- **API 21/22 明文存储**：Keystore AES/GCM 要 API 23+，降级是刻意设计。
- **没有 `setUserAuthenticationRequired(true)`**：网关凭据要在冷启动、无人交互时
  可用（后台重连 WebSocket 也要读），要求生物识别会让"打开 App 就连不上自己的机器"。
- **网络仍是明文**：与本文无关，见 `README.md` §4。
