package app.sourin.sourin_spike

import android.app.PictureInPictureParams
import android.content.pm.PackageManager
import android.os.Build
import android.util.Rational
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 主 Activity —— 额外提供「设备能力」查询通道
 *
 * # 为什么需要这个（2026-09-22）
 *
 * TV 适配必须知道「这是不是电视」，否则：
 * ```
 * · 焦点环不画         → 遥控器用户看不出焦点在哪
 * · 字号不放大         → 3 米外看不清（10 英尺原则）
 * · 操作提示被隐藏     → 因为被当成手机（手机端不显示提示）
 * ```
 * 最后一条最糟：**TV 用户最需要知道遥控器怎么用，却什么都看不到。**
 *
 * # 为什么不能像原版那样用 CSS 能力位
 *
 * 原版跑在 WebView 里，可以用：
 * ```
 * window.matchMedia("(hover: hover)")
 * window.matchMedia("(pointer: fine)")
 * window.matchMedia("(pointer: coarse)")
 * ```
 * 真机实测结论（原版 device.ts 注释记录）：
 * ```
 *            hover   coarse   fine
 * 桌面         true    false    true
 * 手机         false   true     false
 * TV           false   false    true   <- 精确但无悬停 = 遥控器
 * ```
 * **但 Flutter 没有等价 API** —— 拿不到 hover / pointer 这些能力位。
 *
 * # 所以改用 Android 系统 feature（更准）
 *
 * ```
 * android.software.leanback     -> 设备声明自己是 TV（有遥控器）
 * android.hardware.touchscreen  -> 设备有触摸屏
 * ```
 * 这比猜 UA 或猜屏幕尺寸准得多，而且是**系统级的确定事实**。
 *
 * 注意 `hasSystemFeature` 与 manifest 的 `uses-feature required=false`
 * 是两件事：前者查**设备能力**，后者声明**应用需求**。互不影响。
 */
class MainActivity : FlutterActivity() {

    /** 记录 Flutter 侧请求的比例，onUserLeaveHint 时复用 */
    private var lastAspectRatio: Rational = Rational(16, 9)

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "sourin/device"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "features" -> {
                    val pm: PackageManager = packageManager
                    result.success(
                        mapOf(
                            // TV 判据：设备声明支持 leanback（即遥控器操作）
                            "leanback" to pm.hasSystemFeature(
                                PackageManager.FEATURE_LEANBACK
                            ),
                            // 有无触摸屏 —— 与 leanback 一起足以判定设备类型
                            "touchscreen" to pm.hasSystemFeature(
                                PackageManager.FEATURE_TOUCHSCREEN
                            ),
                            // 补充信息，便于诊断（不参与判定）
                            "leanbackOnly" to pm.hasSystemFeature(
                                "android.software.leanback_only"
                            ),
                            "television" to pm.hasSystemFeature(
                                PackageManager.FEATURE_TELEVISION
                            ),
                        )
                    )
                }
                else -> result.notImplemented()
            }
        }

        /*
         * ── 通道二：画中画 ──
         *
         * 原版跑在 WebView 里，用浏览器的 `<video>.requestPictureInPicture()`
         * —— 那是浏览器白送的。**media_kit 没有内置 PiP**（翻过源码确认），
         * 所以必须走 Android 原生的 `enterPictureInPictureMode`。
         */
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "sourin/pip"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "isPipSupported" -> result.success(isPipSupported())

                "enterPip" -> {
                    val ar = call.argument<Double>("aspectRatio") ?: (16.0 / 9.0)
                    result.success(enterPip(ar))
                }

                "exitPip" -> {
                    /*
                     * Android 的 PiP 退出由**系统**控制（用户点小窗的 X）。
                     * 应用侧没有"强制退出"的公开 API —— 只能把自己带回前台，
                     * 那会让整个 Activity 回到全屏。
                     *
                     * 所以这里只返回 true，真实状态由
                     * onPictureInPictureModeChanged 回调同步给 Flutter。
                     */
                    result.success(true)
                }

                else -> result.notImplemented()
            }
        }

        /*
         * ── 通道三：组播锁（投屏 SSDP 用）──
         *
         * Android 默认不把组播包交给应用（省电）。DLNA/UPnP 的设备发现靠
         * M-SEARCH 组播，所以扫描期间必须持有 WifiManager.MulticastLock，
         * 否则**收不到任何组播应答**（表现为「扫不到设备」）。
         *
         * 权限 android.permission.CHANGE_WIFI_MULTICAST_STATE 已在
         * AndroidManifest.xml 声明 —— 没有它这里会抛 SecurityException。
         *
         * ⚠️ 这把锁只在 Wi-Fi 上有意义：以太网/模拟器上 createMulticastLock
         *    可能返回 null 或一个 no-op 锁，调用方应当把「拿不到」当成正常
         *    情况（不要因此报错，组播路径会自然退化）。
         */
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "sourin/net"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "acquireMulticastLock" -> result.success(acquireMulticastLock())
                "releaseMulticastLock" -> {
                    releaseMulticastLock()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    /** 当前持有的组播锁；null = 没持有（扫描结束后归 null） */
    private var multicastLock: android.net.wifi.WifiManager.MulticastLock? = null

    /**
     * 申请组播锁。返回是否**真的**拿到了（拿不到不算错误，见通道三注释）。
     *
     * 幂等：已经持有时直接返回 true，不会重复 acquire。
     */
    private fun acquireMulticastLock(): Boolean {
        if (multicastLock?.isHeld == true) return true
        return try {
            val wifi = applicationContext.getSystemService(
                android.content.Context.WIFI_SERVICE
            ) as? android.net.wifi.WifiManager ?: return false
            val lock = wifi.createMulticastLock("sourin-ssdp").apply {
                setReferenceCounted(false)
            }
            lock.acquire()
            multicastLock = lock
            true
        } catch (e: Exception) {
            // 没 Wi-Fi 硬件 / 权限被拒 —— 都当作「拿不到」，交给 Dart 侧决定要不要继续
            android.util.Log.w("SourinNet", "组播锁申请失败（不影响非组播路径）", e)
            false
        }
    }

    /** 释放组播锁。没持有时是 no-op（幂等）。 */
    private fun releaseMulticastLock() {
        try {
            multicastLock?.let { if (it.isHeld) it.release() }
        } catch (e: Exception) {
            android.util.Log.w("SourinNet", "组播锁释放失败", e)
        } finally {
            multicastLock = null
        }
    }

    /**
     * 是否支持画中画
     *
     * ⚠️ 必须查 **API >= 26**（O），不是 24（N）
     * ```
     * API 24 (N)  Activity.enterPictureInPictureMode()   无参数版
     * API 26 (O)  PictureInPictureParams                 带比例，能正常用
     * ```
     * 用无参数版在 24/25 上小窗比例是固定的、体验很差，
     * 而且 `setPictureInPictureParams` 根本不存在 —— 会崩。
     *
     * # ★★★ 为什么**两个都要查**（实测踩到的完整链路）
     *
     * 我一度以为 `FEATURE_PICTURE_IN_PICTURE` 不可靠，把它删掉了 ——
     * **那是错的**。真相是 AOSP 自己就用这个 feature 做系统级判据：
     * ```java
     * // ActivityTaskManagerService 构造时
     * mSupportsPictureInPicture =
     *     pm.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE);
     *
     * // 每次请求进 PiP 时第一件事
     * boolean checkEnterPictureInPictureState(...) {
     *     if (!supportsPictureInPicture()) return false;   // ← 直接拒
     *     ...
     * }
     * ```
     *
     * 也就是说：**设备没声明这个 feature 时，
     * `enterPictureInPictureMode()` 会静默返回 `false`，
     * 不抛异常、不打日志** —— 极难定位。
     *
     * # 实测数据（两种设备的行为差异）
     *
     * ```text
     * Android TV 模拟器 (API 36)  pm list features | grep picture → 空
     *                             → enterPip 返回 false（静默）
     * 手机形态 (BlueStacks)       声明了该 feature
     *                             → enterPip 返回 true
     * ```
     * 所以这不是"模拟器的 bug"，而是 **TV 设备形态本身可能不支持 PiP**
     * （Google 的 TV 设计里小窗是另一套 TvPipController 机制）。
     *
     * # 结论
     *
     * 两个条件都要查：API 版本（能不能调）+ 系统 feature（让不让调）。
     * 前者保证 API 存在，后者与 AOSP 的判据**完全一致** ——
     * 这样 Flutter 侧就能在**按钮显示之前**知道答案，
     * 而不是等用户点了才发现没反应。
     */
    private fun isPipSupported(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        return packageManager.hasSystemFeature(
            PackageManager.FEATURE_PICTURE_IN_PICTURE
        )
    }

    private fun enterPip(aspectRatio: Double): Boolean {
        if (!isPipSupported()) return false
        return try {
            lastAspectRatio = rationalFrom(aspectRatio)
            val params = PictureInPictureParams.Builder()
                .setAspectRatio(lastAspectRatio)
                .build()
            enterPictureInPictureMode(params)
        } catch (e: Exception) {
            android.util.Log.w("SourinPip", "进入画中画失败", e)
            false
        }
    }

    /**
     * 把 double 比例转成 Android 的 Rational
     *
     * ⚠️ Android 对比例有**硬性范围限制**：
     * ```
     * 最小 1:2.39   最大 2.39:1
     * ```
     * 超出会抛 IllegalArgumentException。竖屏视频（如 9:16 = 0.5625）
     * 刚好在范围内，但极端比例（如 1:3）会崩 —— 所以必须夹取。
     */
    private fun rationalFrom(ratio: Double): Rational {
        val clamped = ratio.coerceIn(1.0 / 2.39, 2.39)
        // 用 1000 做分母，精度足够且不会溢出
        return Rational((clamped * 1000).toInt(), 1000)
    }

    /**
     * 系统切换 PiP 状态时通知 Flutter
     *
     * ⚠️ 这个回调是**必须**的：用户点小窗的 X 关闭时，
     *    Flutter 侧不知道 —— 不通知的话播放器上的 PiP 按钮
     *    会一直显示"已激活"，再点一下反而进不去。
     */
    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: android.content.res.Configuration
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        flutterEngine?.dartExecutor?.binaryMessenger?.let { messenger ->
            MethodChannel(messenger, "sourin/pip").invokeMethod(
                "onPipChanged",
                mapOf("active" to isInPictureInPictureMode)
            )
        }
    }
}
