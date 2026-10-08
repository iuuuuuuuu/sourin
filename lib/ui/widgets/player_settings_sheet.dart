// ═══════════════════════════════════════════════════════════════════════
//  播放设置面板 —— 字幕 / 音轨 / 连播策略
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个面板存在的理由
//
// 用户目标里逐条列了播放器能力，其中**字幕（内嵌 + 外挂 + ASS 样式）**、
// **音轨切换** 这两项在原版 `PlayerView.vue` 里**根本没有 UI 入口** ——
// 原版把这些交给了 ArtPlayer 的 `setting: true` 内置面板：
// ```ts
// // PlayerView.vue:3429-3450
// art = new Artplayer({
//   setting: true,        // ★ 内置设置面板（清晰度/倍速/比例/镜像都在里面）
//   playbackRate: true,
//   aspectRatio: true,
//   ...
// });
// ```
// 而 ArtPlayer 的内置面板**只有播放速度 / 画面比例 / 镜像 / 清晰度**，
// 没有字幕轨、没有音轨、没有字幕样式（翻过 ArtPlayer 的 setting 定义）。
// 也就是说：**原版本身就没有这三项能力**。
//
// 我们是 libmpv 后端，mpv 原生就支持这些（`sid` / `aid` / `sub-add` /
// `sub-*` 样式属性），只是缺一个入口。所以这里补的是
// 「**mpv 有能力、但原版没有**」的部分 —— 这是**能力补齐**，不是照抄。
//
// # ⚠️ 必须如实标注的交互差异
//
// ```text
// ① 面板形态   原版 ArtPlayer 是"齿轮 → 弹出列表"；这里是全屏 scrim + 居中卡片
//              （与播放页已有的「快捷键提示」「线路」面板同一套视觉语言）
// ② 新增入口   底部控制条上的「设置」按钮 —— 原版没有这个按钮
// ③ 新增能力   字幕轨切换 / 外挂字幕 / 字幕样式 / 音轨切换
// ```
// ①② 是**必须的**：没有入口就点不到面板。③ 是本次任务要求补齐的能力。
//
// # 为什么"连播策略"也放进来
//
// 原版把连播策略做成了 ArtPlayer 的自定义 settings 项
// （`PlayerView.vue:3475-3514` 的 `settings: [...]`）：
// ```text
// 播放完            → endAction（自动连播 / 单集循环 / 播完停止）
// 连播前倒计时       → countdownBeforeNext
// 自动跳过片头       → autoSkip
// 连播沿用线路       → keepSourceOnNext
// ```
// 我们**照抄这四项**，只是从"ArtPlayer 的面板"搬到"我们自己的面板"——
// 语义、默认值、可选项一字不改。
//
// # 样式项的默认值：**不写死，从 mpv 读**
//
// 面板不硬编码 mpv 的默认值（`sub-font-size` 的默认值在不同 mpv 版本
// 之间变过，写死就等于**悄悄改了用户的观感**）。
// 宿主机在打开面板前用 `getProperty` 把当前值读出来传进来
// （`mpvStyle`），面板只负责显示与修改。
//
// # ⚠️ 禁止 `package:flutter/material.dart`
//
// Flutter 3.47 把 Material 拆成了独立包 `material_ui`。混用会让
// `Theme.of` 拿到 `ThemeData.fallback()`（亮色），项目踩过 ——
// 见 `test/material_split_test.dart`。统一 `material_ui`。

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/app_log.dart';
import '../../core/clip_download.dart';
import '../tokens.dart';

/// 一条可选轨道（字幕或音轨）
///
/// # 为什么不直接用 media_kit 的 `SubtitleTrack` / `AudioTrack`
///
/// 面板是**纯 UI**：它只需要"一个 id + 一行给人看的文字"。
/// 传 media_kit 的类型进来会：
/// ```text
/// ① 把面板和播放后端绑死（将来换后端要改 UI）
/// ② 让面板**没法单测**（构造 media_kit 的轨对象要拉起原生库）
/// ```
/// 所以宿主做一次转换（`PlayerTrackOption.fromMediaKit` 那种活由宿主干）。
class PlayerTrackOption {
  const PlayerTrackOption({
    required this.id,
    required this.label,
    this.hint,
  });

  /// mpv 的轨 id（`"auto"` / `"no"` / `"1"` / `"2"` …）
  final String id;

  /// 主标签（轨标题，没有就用「轨道 N」）
  final String label;

  /// 副标签（语言 / 编码），可为空
  final String? hint;
}

/// 播放完一集之后干什么
///
/// **照抄原版 `stores/player.ts` 的 `PlayEndAction`**（三个选项、默认自动连播）。
enum PlayEndAction {
  /// 有下一集就接着播（原版默认）
  autoNext('autoNext', '自动连播', '播完自动播放下一集'),

  /// 单集循环
  singleLoop('singleLoop', '单集循环', '播完重播本集'),

  /// 播完停在最后一帧
  stop('stop', '播完停止', '播完停在最后一帧');

  const PlayEndAction(this.wire, this.label, this.hint);

  /// 与原版 localStorage 里的字符串一致（将来若要读写原版数据可直接用）
  final String wire;
  final String label;
  final String hint;
}

/// ★★★ task-22 P2-9：解码模式（用户原话：「解码模式 Auto/HW+/HW/SW」）
///
/// # 四个档位与 mpv 的 `--hwdec` 取值一一对应
///
/// ```text
/// Auto  → auto-safe  硬解优先，失败**安全回落**软解（改前就是这个值）
/// HW+   → auto       系统硬解，**不回写**系统内存（最省带宽，部分设备上不可用）
/// HW    → auto-copy  系统硬解，**回写**系统内存（兼容性最好的一档硬解）
/// SW    → no         纯软解（大量耗 CPU，但能解硬件解码器不支持的编码）
/// ```
///
/// 档位表来自 `.probe/research/yamby-可整合清单.md:115-120`（抄录 yamby wiki
/// 的「mpv 解码模式」一节）+ `:410` 第 9 条（P2-9）。
///
/// # 为什么 `wire` 直接就是 mpv 的取值
///
/// 面板只负责「把用户点的档位翻译成 mpv 的字符串」，落点是宿主的
/// `NativePlayer.setProperty('hwdec', …)`。`wire` 就是那个字符串 ⇒ 面板与
/// 宿主之间不需要第二张映射表（少一张表 = 少一处会漂的地方）。
///
/// ⚠️ **面板不许碰 mpv**（本文件文件头那条禁令）：这里只定义常量与档位，
///    真正的 `setProperty` 在 `player_page.dart`。
enum HwdecMode {
  /// 默认档 —— 与改前的行为**逐字一致**（`auto-safe`）
  auto('auto-safe', 'Auto', '硬解优先，失败自动回落软解'),

  /// 系统硬解（不回写系统内存）
  hwPlus('auto', 'HW+', '系统硬解；部分设备上不可用'),

  /// 系统硬解（回写到系统内存）
  hwCopy('auto-copy', 'HW', '系统硬解，回写到系统内存'),

  /// 纯软解
  sw('no', 'SW', '软解，大量消耗 CPU，兼容性最好');

  const HwdecMode(this.wire, this.label, this.hint);

  /// 直接就是 mpv `--hwdec` 的取值（见类文档）
  final String wire;
  final String label;
  final String hint;

  /// 从偏好里存的 `wire` 反解回档位（**白名单校验**）
  ///
  /// 与 `PlayEndAction` 的读法同构：`UiPrefs` 里的值可能被旧版本写坏，
  /// 非法值一律回落到 [auto]（**不抛异常** —— 一个坏偏好不该让播放页起不来）。
  static HwdecMode fromWire(String? wire) => HwdecMode.values.firstWhere(
        (m) => m.wire == wire,
        orElse: () => HwdecMode.auto,
      );
}
/// 面板里的倍速档位
///
/// ★ 与底栏那个 `PopupMenuButton<double>`（`player_page.dart:10142-10148`）的 7 档
///   **逐字一致** —— 两个入口看到的必须是同一组值。
/// ★ 7 档全部落在宿主 `_rateBy` 的 clamp 区间 `0.25–4.0` 内（`player_page.dart:5943`），
///   也全部满足 `_lastRate` 的恢复校验（`player_page.dart:1663`）⇒ 不引入非法值。
/// ★ 7 档全是 0.25 的整数倍 ⇒ 面板选完再按 `,` / `.`（`_rateBy(±0.25)`）不会卡在档位之间。
const _rateOptions = <double>[0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0];

/// 倍速档位的显示文本：`1x` / `0.5x` / `1.25x` …
///
/// 与底栏 `Text('${rate}x')`（`player_page.dart:10155`）同一套写法：
/// 整数档不带小数点，非整数档保留原始小数。
String _rateLabel(double v) => v == v.roundToDouble() ? '${v.toInt()}x' : '${v}x';

/// 字幕样式覆盖模式 —— **直接映射 mpv `--sub-ass-override`**
///
/// # 为什么必须有这一项（否则"调了没反应"）
///
/// mpv 手册（`--sub-font` 那一条）原文：
/// > The `--sub-font` option (and many other style related `--sub-` options)
/// > are ignored when ASS-subtitles are rendered, unless `--sub-ass=no` is
/// > specified.
///
/// 也就是说：**ASS 字幕默认不吃 `sub-font` / `sub-color` 这些样式项**。
/// 用户拖动字号却发现画面没变，不是 bug 而是 mpv 的既定行为。
/// 所以把 `sub-ass-override` 做成一个显式选项，并把三个档位的
/// 后果写在界面上（不给说明的话用户只会以为功能坏了）。
///
/// 档位语义来自 mpv 手册 `--sub-ass-override=<no|yes|scale|force|strip>`：
/// ```text
/// no    Render subtitles as specified by the subtitle scripts, without overrides.
/// yes   Apply all the --sub-ass-* style override options.
/// force Like yes, but also force all --sub-* options. Can break rendering easily.
/// ```
/// `scale` 与 `yes` 同义（额外套用 `sub-scale`）—— 我们不用 `sub-scale`
/// （手册明确警告它会破坏 ASS 渲染），所以不暴露这一档。
/// `strip` 会**剥掉全部 ASS 标签**（等于关掉 ASS），与"ASS 样式"目标相反，不暴露。
enum SubtitleOverride {
  /// `no` —— 完全按字幕脚本渲染（ASS 原样）★ 默认
  assOnly('no', 'ASS 原样', '按字幕自带样式渲染（改下面几项对 ASS 无效）'),

  /// `yes` —— 允许下面的样式项覆盖
  allowStyle('yes', '允许覆盖样式', '下面的字号/字体/颜色会对 ASS 生效'),

  /// `force` —— 连定位一起强行覆盖
  force('force', '强制覆盖', '连 ASS 的定位也覆盖 —— 可能错位');

  const SubtitleOverride(this.wire, this.label, this.hint);

  final String wire;
  final String label;
  final String hint;

  /// 从 mpv 读回来的字符串还原（读到 `scale`/`strip` 时归到最接近的档）
  static SubtitleOverride fromWire(String? s) {
    switch ((s ?? '').trim().toLowerCase()) {
      case 'yes':
      case 'scale':
        return SubtitleOverride.allowStyle;
      case 'force':
        return SubtitleOverride.force;
      default:
        return SubtitleOverride.assOnly;
    }
  }
}

/// 字幕颜色预设
///
/// mpv 的颜色是 `r/g/b`（各分量 0.0–1.0，见手册 `--sub-color`）。
/// 给预设而不是让用户填三个小数：那串东西没法手输。
class SubtitleColorPreset {
  const SubtitleColorPreset(this.label, this.r, this.g, this.b);

  final String label;
  final double r;
  final double g;
  final double b;

  /// mpv 要的 `r/g/b` 形式
  String get wire => '${_f(r)}/${_f(g)}/${_f(b)}';

  /// 面板上的色块
  Color get swatch => Color.fromARGB(
        255,
        (r * 255).round(),
        (g * 255).round(),
        (b * 255).round(),
      );

  static String _f(double v) => v.toStringAsFixed(2);

  /// 与 mpv 读回来的值比较（容差 0.02 —— 避免浮点字符串比对失败）
  bool matches(String? wire) {
    if (wire == null) return false;
    final parts = wire.split('/');
    if (parts.length < 3) return false;
    final vals = parts.take(3).map((s) => double.tryParse(s.trim())).toList();
    if (vals.any((v) => v == null)) return false;
    return (vals[0]! - r).abs() < 0.02 &&
        (vals[1]! - g).abs() < 0.02 &&
        (vals[2]! - b).abs() < 0.02;
  }
}

/// 字幕文字色预设（mpv `--sub-color`）
const kSubtitleTextColors = <SubtitleColorPreset>[
  SubtitleColorPreset('白', 1, 1, 1),
  SubtitleColorPreset('黄', 1, 1, 0),
  SubtitleColorPreset('青', 0, 1, 1),
  SubtitleColorPreset('绿', 0, 1, 0),
  SubtitleColorPreset('浅灰', 0.8, 0.8, 0.8),
];

/// 字幕边框色预设（mpv `--sub-border-color`，别名 `sub-outline-color`）
const kSubtitleBorderColors = <SubtitleColorPreset>[
  SubtitleColorPreset('黑', 0, 0, 0),
  SubtitleColorPreset('深灰', 0.2, 0.2, 0.2),
  SubtitleColorPreset('深蓝', 0, 0, 0.35),
  SubtitleColorPreset('白', 1, 1, 1),
];

/// 常用字体候选
///
/// # 为什么是这几个
///
/// ```text
/// ① 中文字幕必须能落到一个**真实存在**的中文字体上 ——
///    落到西文字体上会显示成方块（fontconfig 找不到字形）
/// ② 这几个是 Windows / Android 两边都**大概率预装**的
///    （Windows: 微软雅黑/黑体/宋体；Android: Noto Sans CJK）
/// ③ 用户仍可自己输入 —— 系统里有的字体都能填
/// ```
/// ⚠️ 不 bundle 字体：最小的中文字体也要 3.4 MB，且 Windows 自带字体
///    是**微软专有**、不能随应用分发（见 `player_page.dart` 的字体注释）。
const kSubtitleFontChoices = <String>[
  'sans-serif',
  'Microsoft YaHei',
  'SimHei',
  'SimSun',
  'Noto Sans CJK SC',
  'Arial',
];

/// 播放设置面板
///
/// # 自包含的程度
///
/// 面板**不持有任何播放状态** —— 它只：
/// ```text
/// ① 把宿主传进来的当前值画出来
/// ② 用户改动时回调宿主（由宿主落到 mpv / 偏好存储）
/// ```
/// 这样面板可以脱离播放器单测（见 `test/player_capability_test.dart`）。
/// 唯一的例外是「加载外挂字幕…」—— 那里要弹系统文件框，
/// 是纯 UI 动作，所以在面板里做，选完把**路径**回给宿主。
class PlayerSettingsSheet extends StatefulWidget {
  const PlayerSettingsSheet({
    super.key,
    required this.isLive,
    required this.subtitleTracks,
    required this.audioTracks,
    required this.currentSubtitleId,
    required this.currentAudioId,
    required this.externalSubtitleName,
    required this.mpvStyle,
    required this.endAction,
    required this.countdownBeforeNext,
    required this.keepSourceOnNext,
    required this.autoSkip,
    required this.rate,
    required this.onSetRate,
    required this.isPlaying,
    required this.clipDownloading,
    required this.clipDownloaded,
    required this.clipDownloadError,
    required this.onSetConcurrency,
    required this.onDownloadClip,
    required this.onOpenClipDir,
    required this.onPickSubtitle,
    required this.onPickAudio,
    required this.onLoadSubtitleFile,
    required this.onRemoveExternalSubtitle,
    required this.onSetMpvProperty,
    required this.onSetEndAction,
    required this.onSetCountdown,
    required this.onSetKeepSource,
    required this.onSetAutoSkip,
    required this.onClose,
    /*
     * ★★★ task-22：以下四项**全部可选**（带默认值）。
     *
     * 为什么不设成 required：三个测试夹具
     * （`test/player_capability_test.dart:130-178 _sheet({...})`、
     *   `test/t62_player_rate_test.dart:140-221 _sheet({...})`、
     *   `test/t68_android_adapt_test.dart:180-229 makeSheet()`）
     * 都按具名参数逐个传值 —— 设成 required 就要同步改三个测试文件
     * （那是**改测试**，不是加功能）。带默认值之后三处夹具一行都不用动。
     */
    this.hwdecMode = HwdecMode.auto,
    this.onSetHwdecMode,
    this.videoZoom,
    this.onSetVideoZoom,
    /*
     * ★★★ task-31 ⑤：在线字幕搜索入口，**可选**。
     *
     * 传 null ⇒ 按钮不画（面板仍可被别处复用而不带上 assrt）。
     * 与上面四项同理：带默认值 ⇒ 四个测试夹具（player_capability /
     * t62 / t68 / t78）一行都不用改。
     */
    this.onOpenSubtitleSearch,
  });

  /// 直播 —— 隐藏"连播"整段（直播没有"播完"这回事）
  final bool isLive;

  /// 可选字幕轨（宿主已过滤/补全，含 `auto` / `no`）
  final List<PlayerTrackOption> subtitleTracks;

  /// 可选音轨
  final List<PlayerTrackOption> audioTracks;

  /// 当前字幕轨 id（`"auto"` / `"no"` / `"1"` …）
  final String currentSubtitleId;

  /// 当前音轨 id
  final String currentAudioId;

  /// 已加载的外挂字幕文件名（null = 没有）
  final String? externalSubtitleName;

  /// 从 mpv **读回来**的当前样式值（键是 mpv 属性名）
  ///
  /// 认识的键：
  /// ```text
  /// sub-ass-override   no|yes|scale|force|strip
  /// sub-font-size      int（720p 高度下的缩放像素）
  /// sub-font           字体名
  /// sub-color          r/g/b
  /// sub-border-size    double（别名 sub-outline-size）
  /// sub-border-color   r/g/b（别名 sub-outline-color）
  /// sub-back-color     r/g/b/a（别名 sub-shadow-color）
  /// sub-margin-y       int（距底部）
  /// ```
  /// 缺键时那一项显示"读不到"并**禁用**（而不是假装是默认值）。
  final Map<String, String> mpvStyle;

  final PlayEndAction endAction;
  final bool countdownBeforeNext;
  final bool keepSourceOnNext;
  final bool autoSkip;

  /// ★ task-21 P1-8：当前播放倍速
  ///
  /// 真源是宿主的 `_player.stream.rate` 广播（`player_page.dart:2159-2163`）——
  /// 面板**不持有**倍速状态，只把宿主传进来的值画成高亮。
  /// 用户点某一档 → 回调 `onSetRate` → 宿主 `_player.setRate` →
  /// 那条广播回填 `_rate` 并写 `lastSpeed` ⇒ 面板重画。
  final double rate;

  /// 当前是否正在播放 —— 只用来决定「下载本集到缓存」按钮能不能点。
  ///
  /// ★ 下载必须**正在播放**才有意义：media_kit 只在 open() 之后才
  ///   真正拿到 _current 那条流的地址与 headers；没起播时下载按钮
  ///   点了也只能报错。
  final bool isPlaying;

  /// 正在下载（宿主传进来，面板自己不改）
  final bool clipDownloading;

  /// 本次会话里至少成功下载过一次
  final bool clipDownloaded;

  /// 上一次下载失败的原因（null = 没有失败过）
  final String? clipDownloadError;

  /// ★ task-18 ③：改并发上限。
  ///
  /// 面板**不自己存**这个值 —— 真正的状态在 ClipDownloader（进程级单例），
  /// 面板只是把当前值画出来。所以这里传的是「用户选了第几档」，
  /// 由宿主落到 ClipDownloader.setConcurrency。
  final ValueChanged<int> onSetConcurrency;

  /// 下载**本集**（宿主拿当前流的 url + headers 去真下载）——
  /// 注意下的是整集视频，不是某个片段（Owner 第 5 条）。
  final VoidCallback onDownloadClip;

  /// 在系统文件管理器里打开片段缓存目录
  final VoidCallback onOpenClipDir;

  /// 选字幕轨（`"no"` = 关闭字幕）
  final ValueChanged<String> onPickSubtitle;

  /// 选音轨
  final ValueChanged<String> onPickAudio;

  /// 加载外挂字幕文件（面板已经弹完文件框，这里给**路径**）
  final ValueChanged<String> onLoadSubtitleFile;

  /// 移除已加载的外挂字幕
  final VoidCallback onRemoveExternalSubtitle;

  /// 改一个 mpv 属性（字幕样式项都走这里）
  final void Function(String property, String value) onSetMpvProperty;

  final ValueChanged<PlayEndAction> onSetEndAction;

  /// 改播放倍速
  ///
  /// 宿主落到 `_player.setRate`（与底栏 `onRate` 同一个落点）。
  /// 面板**不写** `lastSpeed` 偏好：`player_page.dart:2163` 的 `stream.rate`
  /// 监听已经无条件写了一次，再写就是两个真相。
  final ValueChanged<double> onSetRate;
  final ValueChanged<bool> onSetCountdown;
  final ValueChanged<bool> onSetKeepSource;
  final ValueChanged<bool> onSetAutoSkip;

  final VoidCallback onClose;

  /// ★★★ task-22 P2-9：当前解码模式（宿主从 `dsh.playprefs.hwdecMode` 恢复）
  final HwdecMode hwdecMode;

  /// 换解码模式
  ///
  /// 宿主落到 `_applyHwdecToMpv()`（`player_page.dart`）—— 面板**不碰**
  /// `NativePlayer`，也不写偏好（与 [onSetRate] 同款单向数据流）。
  final ValueChanged<HwdecMode>? onSetHwdecMode;

  /// ★★★ task-22 P1-11：当前画面缩放（**百分比**，100 = 原始比例）
  ///
  /// ⚠️ 可空、且**没有默认值** —— 与 ASS 字号滑块同一条规矩：
  ///    mpv 的 `video-zoom` 读不到时显示「读不到」并**禁用**，
  ///    而不是假装有个 100%（假装 = 一打开面板就改了用户观感）。
  final double? videoZoom;

  /// 改画面缩放（百分比）。宿主把它换算成 mpv 的 `video-zoom`（log2）
  final ValueChanged<double>? onSetVideoZoom;

  /// ★★★ task-31 ⑤：打开「在线搜索字幕」（assrt.net）面板
  ///
  /// 传 null ⇒ 按钮**不画**。面板本身不知道有 assrt 这回事，
  /// 也不知道搜索面板会怎么挂载 —— 单向数据流同上。
  final VoidCallback? onOpenSubtitleSearch;

  @override
  State<PlayerSettingsSheet> createState() => _PlayerSettingsSheetState();
}

class _PlayerSettingsSheetState extends State<PlayerSettingsSheet> {
  /// 外挂字幕的加载状态（'' = 空闲）
  String _subLoading = '';

  /// 外挂字幕加载失败的原因（非空时显示）
  String? _subError;

  /// 日志导出/复制的结果提示（task-18 ⑤；空串 = 无）
  String _logTip = '';

  /// 日志导出进行中（防重复点）
  bool _logBusy = false;

  /// 读一个 mpv 样式值（读不到返回 null）
  String? _style(String key) {
    final v = widget.mpvStyle[key];
    if (v == null || v.trim().isEmpty) return null;
    return v.trim();
  }

  int? _styleInt(String key) => int.tryParse(_style(key) ?? '');

  double? _styleDouble(String key) => double.tryParse(_style(key) ?? '');

  /// 弹系统文件框选字幕
  ///
  /// # 为什么在面板里做（而不是回宿主做）
  ///
  /// 这是**纯 UI 动作**（弹框 → 拿路径），不涉及播放状态。
  /// 放在这里，宿主只需要一个 `onLoadSubtitleFile(path)`。
  ///
  /// ⚠️ 用 `file_selector`（**已经在 pubspec 里**，不是本次新加的依赖）。
  ///    原版用的是 Tauri 的 `plugin-dialog`；我们在 Flutter 侧的对应物
  ///    就是 `file_selector`（它带 Windows / Android 的原生实现）。
  Future<void> _pickSubtitleFile() async {
    setState(() {
      _subLoading = '选择文件…';
      _subError = null;
    });
    try {
      /*
       * 类型过滤：字幕常见后缀。
       *
       * ⚠️ 必须给 extensions —— 不给的话 Windows 上会列出所有文件，
       *    用户很容易点到一个视频文件，然后 mpv 静默加载失败。
       *
       * ⚠️ 也提供"全部文件"那一档：有些字幕后缀很冷门
       *    （`.ssa` / `.txt` / `.smi`），硬过滤会让用户**选不到自己的文件**。
       *    这是"宁可让用户选错"的选择 —— 选错有错误提示，选不到无解。
       */
      const groups = <XTypeGroup>[
        XTypeGroup(
          label: '字幕',
          extensions: <String>[
            'ass', 'ssa', 'srt', 'vtt', 'sub', 'smi', 'txt', 'idx',
          ],
        ),
        XTypeGroup(label: '全部文件'),
      ];
      final f = await openFile(acceptedTypeGroups: groups);
      if (!mounted) return;
      if (f == null) {
        setState(() => _subLoading = '');
        return;
      }
      setState(() => _subLoading = '加载中…');
      widget.onLoadSubtitleFile(f.path);
      if (!mounted) return;
      setState(() => _subLoading = '');
    } catch (e) {
      if (!mounted) return;
      // 如实报错 —— 静默失败会让用户以为"点了没反应"
      setState(() {
        _subLoading = '';
        _subError = '选择文件失败：$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: GestureDetector(
        // 点背景关闭（与播放页其它面板一致）
        onTap: widget.onClose,
        child: ColoredBox(
          color: Colors.black.withValues(alpha: 0.72),
          child: Center(
            /*
             * ★★★ task-25 D：面板自己让开安全区（状态栏 / 手势条）
             *
             * # 症状（真机 1080x2400 @480dpi = 360x800dp）
             * 改前 `Positioned.fill` 的父盒是**视频盒**（360x202.67dp），
             * 卡片被夹在里面：标题压在状态栏下、正文只剩几十 dp，
             * 「片段下载」那一段**滚都滚不到**（`.probe/t24/pan3.txt`）。
             * 宿主（`player_page.dart`）已把这一层提升到
             * `OverlayPortal(rootOverlay)` ⇒ 这里拿到的约束是**整窗**，
             * 卡片这才真的居中在整页上。
             *
             * # 为什么安全区在**这里**让，而不是在宿主外面包一层 Padding
             * `Positioned.fill` 只被**最近的 Stack** 认；在它外面再套一层
             * `Positioned`/`Padding`，两个 ParentDataWidget 会争同一个
             * `StackParentData` —— 内层后应用，外层设的 top/bottom 会被
             * 覆盖成 0（`t57_sheet_scrim_geometry_test.dart:63` 记的是同一个坑）。
             *
             * ⚠️ 让位的是**卡片**，不是那层黑底：scrim 仍然铺满整窗，
             *    用户在状态栏那一条上点一下同样能关掉面板。
             * ⚠️ 桌面 / TV 上 `padding` 恒为 0 ⇒ **严格 no-op**，逐像素不变。
             */
            child: Padding(
              padding: EdgeInsets.only(
                top: MediaQuery.paddingOf(context).top,
                bottom: MediaQuery.paddingOf(context).bottom,
              ),
              child: GestureDetector(
                // 卡片内部的点击不能穿透到背景（否则点滑块也会关掉面板）
                onTap: () {},
                child: Container(
                  width: 560,
                  constraints: const BoxConstraints(maxHeight: 620),
                  decoration: BoxDecoration(
                    color: const Color(0xFF14161C).withValues(alpha: 0.98),
                    borderRadius: Radii.rLg,
                    border: Border.all(color: Colors.white24),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _header(),
                      Flexible(
                        child: SingleChildScrollView(
                          clipBehavior: Clip.antiAlias,
                          padding: const EdgeInsets.fromLTRB(
                            Sp.x6,
                            0,
                            Sp.x6,
                            Sp.x4,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _subtitleSection(),
                              _divider(),
                              _audioSection(),
                              _divider(),
                              /*
                               * ★★★ task-21 P1-8 播放速度
                               *
                               * 位置 = **音轨之后、连播之前**。两个理由：
                               *   ① 它不属于「连播」，不该被 `isLive` 一起藏掉 ——
                               *      底栏的倍速菜单也没有 `isLive` 门控；
                               *   ② `test/player_capability_test.dart:1089` 会**不滚动**直接点
                               *      「关闭」那条字幕轨 —— 新段落必须排在 `_audioSection()`
                               *      之后，否则会把那一行挤出折叠线。
                               */
                              _rateSection(),
                              if (!widget.isLive) ...[
                                _divider(),
                                _playbackSection(),
                                _divider(),
                                _clipSection(),
                              ],
                              /*
                               * ★★★ task-22：画面（缩放 + 解码模式）。
                               *
                               * 位置 = **整段末尾**（连播/下载之后）。理由：
                               *   ① 与 `isLive` **无关**（直播也有画面），所以放在
                               *      那个 `if (!widget.isLive) ...[` 块的**外面**；
                               *   ② `test/t62_player_rate_test.dart:422-424` 钉的是
                               *      「音轨 < 倍速 < 连播」的相对顺序 ⇒ 插在连播块之后
                               *      不动那三条；
                               *   ③ `test/player_capability_test.dart:1089` 会**不滚动**
                               *      直接点「关闭」那条字幕轨 —— 新段落放末尾才不会
                               *      把它挤出折叠线。
                               */
                              _divider(),
                              _videoSection(),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Sp.x6, Sp.x4, Sp.x3, Sp.x2),
      child: Row(
        children: [
          const Text(
            '播放设置',
            style: TextStyle(
              color: Colors.white,
              fontSize: FontSizes.lg,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          IconButton(
            onPressed: widget.onClose,
            icon: const Icon(Icons.close, color: Colors.white),
            tooltip: '关闭',
          ),
        ],
      ),
    );
  }

  Widget _divider() => const Padding(
        padding: EdgeInsets.symmetric(vertical: Sp.x4),
        child: Divider(height: 1, color: Colors.white24),
      );

  /// 段落标题
  Widget _sectionTitle(String text, {String? note}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Sp.x3),
      child: Row(
        children: [
          Text(
            text,
            style: const TextStyle(
              color: Colors.white,
              fontSize: FontSizes.base,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (note != null) ...[
            const SizedBox(width: Sp.x2),
            Flexible(
              child: Text(
                note,
                style: const TextStyle(
                  color: Colors.white38,
                  fontSize: FontSizes.cap,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 一行「标签 + 右侧控件」
  Widget _row(String label, Widget child, {String? hint}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Sp.x3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 92,
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: FontSizes.sm,
              ),
            ),
          ),
          Expanded(child: child),
          if (hint != null)
            Padding(
              padding: const EdgeInsets.only(left: Sp.x2),
              child: Text(
                hint,
                style: const TextStyle(
                  color: Colors.white38,
                  fontSize: FontSizes.cap,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 一条轨道一个按钮（选中的高亮）
  Widget _trackChips({
    required List<PlayerTrackOption> tracks,
    required String current,
    required ValueChanged<String> onPick,
  }) {
    return Wrap(
      spacing: Sp.x2,
      runSpacing: Sp.x2,
      children: [
        for (final t in tracks)
          _chip(
            label: t.hint == null ? t.label : '${t.label} · ${t.hint}',
            active: t.id == current,
            onTap: () => onPick(t.id),
          ),
      ],
    );
  }

  /// 一枚档位胶囊。
  ///
  /// ★ `onTap` 可为 null = **这一档当前不可设**（例：mpv 的 `video-zoom`
  ///   读不到时）。此时把 `InkWell.onTap` 一起置空，让这一档**在结构上就点不动**，
  ///   而不是塞一个空实现（`() {}`）把用户的点击**静默吞掉** —— 吞掉的表现是
  ///   「点了没反应」，用户会当成卡顿/丢帧，而不是「当前不可用」。
  ///   置空后 `InkWell` 连水波都不起（`material_ui` 里 onTap == null ⇒ enabled == false），
  ///   语义与视觉都与「不可用」一致。
  ///   （照 `_row` 的 `hint: current == null ? '读不到' : null` 同一套范式：
  ///    读不到就**明说 + 不可操作**，绝不假装选中。）
  Widget _chip({
    required String label,
    required bool active,
    required VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: Radii.rFull,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: Sp.x3,
          vertical: Sp.x2,
        ),
        decoration: BoxDecoration(
          color: active ? Colors.lightBlueAccent.withValues(alpha: 0.22)
                        : Colors.white10,
          borderRadius: Radii.rFull,
          border: Border.all(
            color: active ? Colors.lightBlueAccent : Colors.white24,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: active ? Colors.lightBlueAccent : Colors.white,
            fontSize: FontSizes.sm,
          ),
        ),
      ),
    );
  }

  /// 颜色预设行
  Widget _colorRow({
    required String label,
    required List<SubtitleColorPreset> presets,
    required String property,
    required String? current,
  }) {
    return _row(
      label,
      Wrap(
        spacing: Sp.x2,
        runSpacing: Sp.x2,
        children: [
          for (final p in presets)
            Tooltip(
              message: p.wire,
              child: InkWell(
                onTap: () => widget.onSetMpvProperty(property, p.wire),
                borderRadius: Radii.rFull,
                child: Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: p.swatch,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: p.matches(current)
                          ? Colors.lightBlueAccent
                          : Colors.white38,
                      width: p.matches(current) ? 3 : 1,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
      // 读不到当前值时不假装"选中了某个" —— 直接说明
      hint: current == null ? '读不到' : null,
    );
  }

  // ═══════════════════════════════════════════════════════════════════
  //  字幕
  // ═══════════════════════════════════════════════════════════════════

  Widget _subtitleSection() {
    final override = SubtitleOverride.fromWire(_style('sub-ass-override'));
    final fontSize = _styleInt('sub-font-size');
    final borderSize = _styleDouble('sub-border-size');
    final marginY = _styleInt('sub-margin-y');
    final font = _style('sub-font');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('字幕'),

        _row(
          '字幕轨',
          widget.subtitleTracks.isEmpty
              ? const Text(
                  '这条流没有字幕轨',
                  style: TextStyle(color: Colors.white38, fontSize: FontSizes.sm),
                )
              : _trackChips(
                  tracks: widget.subtitleTracks,
                  current: widget.currentSubtitleId,
                  onPick: widget.onPickSubtitle,
                ),
        ),

        // ── 外挂字幕 ──
        _row(
          '外挂字幕',
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: _subLoading.isEmpty ? _pickSubtitleFile : null,
                icon: const Icon(Icons.subtitles_outlined, size: 18),
                label: Text(
                  _subLoading.isEmpty
                      ? '加载字幕文件…'
                      : _subLoading,
                ),
              ),
              if (widget.externalSubtitleName != null) ...[
                const SizedBox(width: Sp.x2),
                Flexible(
                  child: Text(
                    widget.externalSubtitleName!,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: FontSizes.cap,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: widget.onRemoveExternalSubtitle,
                  icon: const Icon(Icons.delete_outline, size: 18),
                  tooltip: '移除这条外挂字幕',
                ),
              ],
            ],
          ),
        ),

        if (_subError != null)
          Padding(
            padding: const EdgeInsets.only(bottom: Sp.x3),
            child: Text(
              _subError!,
              style: const TextStyle(color: Colors.redAccent, fontSize: FontSizes.cap),
            ),
          ),

        /*
         * ★★★ task-31 ⑤：在线搜索字幕（assrt.net）。
         *
         * 为什么**单独一行**而不是跟上面那枚并排：
         *   两枚带图标的按钮加起来约 356dp，而这一格在 360dp 屏上只有
         *   ~220dp（面板宽 560 被视口夹到 360，再减两侧 Sp.x6 与 92dp 标签列）
         *   ⇒ 并排必然 RenderFlex overflow。
         *
         * `onOpenSubtitleSearch` 为 null ⇒ **整行不画**（面板可以被别的
         *   宿主复用而不带上 assrt 搜索）。
         */
        if (widget.onOpenSubtitleSearch != null)
          _row(
            '在线字幕',
            /*
             * `_row` 会把 child 包进 `Expanded` ⇒ 按钮会拉满整行。
             * 用 `Align` 把它按自然宽度靠左摆 —— 与上面那枚「加载字幕文件…」
             * 的观感一致（那枚在 `Row` 里也是自然宽度）。
             */
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: widget.onOpenSubtitleSearch,
                icon: const Icon(Icons.travel_explore, size: 18),
                label: const Text('在线搜索字幕…'),
              ),
            ),
            hint: 'assrt.net',
          ),

        /*
         * ── ASS 样式 ──
         *
         * ⚠️ 这一整段只在「允许覆盖样式 / 强制覆盖」时才有意义 ——
         *    ASS 原样模式下 mpv 会忽略下面这些项。
         *    不禁用它们（用户可以先调好再切模式），但**必须写清楚**，
         *    否则用户拖了滑块画面没变，只会以为功能坏了。
         */
        _row(
          'ASS 样式',
          Wrap(
            spacing: Sp.x2,
            runSpacing: Sp.x2,
            children: [
              for (final m in SubtitleOverride.values)
                _chip(
                  label: m.label,
                  active: m == override,
                  onTap: () => widget.onSetMpvProperty(
                    'sub-ass-override',
                    m.wire,
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 92, bottom: Sp.x3),
          child: Text(
            override.hint,
            style: const TextStyle(color: Colors.white38, fontSize: FontSizes.cap),
          ),
        ),

        // 字号
        _row(
          '字号',
          Row(
            children: [
              Expanded(
                child: Slider(
                  value: (fontSize ?? 55).toDouble().clamp(20, 120),
                  min: 20,
                  max: 120,
                  divisions: 100,
                  onChanged: fontSize == null
                      ? null
                      : (v) => widget.onSetMpvProperty(
                            'sub-font-size',
                            v.round().toString(),
                          ),
                ),
              ),
              SizedBox(
                width: 36,
                child: Text(
                  fontSize?.toString() ?? '—',
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: FontSizes.cap,
                  ),
                ),
              ),
            ],
          ),
          hint: '720p 高度下的像素',
        ),

        // 字体
        _row(
          '字体',
          DropdownButton<String>(
            value: kSubtitleFontChoices.contains(font) ? font : null,
            hint: Text(
              font ?? '读不到',
              style: const TextStyle(color: Colors.white70, fontSize: FontSizes.sm),
            ),
            dropdownColor: const Color(0xFF14161C),
            isExpanded: true,
            onChanged: (v) {
              if (v != null) widget.onSetMpvProperty('sub-font', v);
            },
            items: [
              for (final f in kSubtitleFontChoices)
                DropdownMenuItem(
                  value: f,
                  child: Text(
                    f,
                    style: const TextStyle(color: Colors.white, fontSize: FontSizes.sm),
                  ),
                ),
            ],
          ),
        ),

        _colorRow(
          label: '文字色',
          presets: kSubtitleTextColors,
          property: 'sub-color',
          current: _style('sub-color'),
        ),
        _colorRow(
          label: '边框色',
          presets: kSubtitleBorderColors,
          property: 'sub-border-color',
          current: _style('sub-border-color'),
        ),

        // 边框粗细
        _row(
          '边框粗细',
          Row(
            children: [
              Expanded(
                child: Slider(
                  value: (borderSize ?? 1.65).clamp(0, 8),
                  min: 0,
                  max: 8,
                  divisions: 16,
                  onChanged: borderSize == null
                      ? null
                      : (v) => widget.onSetMpvProperty(
                            'sub-border-size',
                            v.toStringAsFixed(2),
                          ),
                ),
              ),
              SizedBox(
                width: 36,
                child: Text(
                  borderSize?.toStringAsFixed(1) ?? '—',
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: FontSizes.cap,
                  ),
                ),
              ),
            ],
          ),
        ),

        // 底部距离
        _row(
          '底部距离',
          Row(
            children: [
              Expanded(
                child: Slider(
                  value: (marginY ?? 0).toDouble().clamp(0, 200),
                  min: 0,
                  max: 200,
                  divisions: 40,
                  onChanged: marginY == null
                      ? null
                      : (v) => widget.onSetMpvProperty(
                            'sub-margin-y',
                            v.round().toString(),
                          ),
                ),
              ),
              SizedBox(
                width: 36,
                child: Text(
                  marginY?.toString() ?? '—',
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: FontSizes.cap,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════════════
  //  音轨
  // ═══════════════════════════════════════════════════════════════════

  Widget _audioSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('音轨'),
        _row(
          '音轨',
          widget.audioTracks.isEmpty
              ? const Text(
                  '这条流没有音轨',
                  style: TextStyle(color: Colors.white38, fontSize: FontSizes.sm),
                )
              : _trackChips(
                  tracks: widget.audioTracks,
                  current: widget.currentAudioId,
                  onPick: widget.onPickAudio,
                ),
        ),
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════════════
  //  播放速度（task-21 P1-8）
  // ═══════════════════════════════════════════════════════════════════

  /// 倍速一行 —— **复用 `_chip`，不是 Slider**
  ///
  /// # 为什么不是 Slider（两条硬理由，别改回去）
  ///
  /// ① `test/player_capability_test.dart:1252` 拿的是 `find.byType(Slider).first`
  ///    并拖它，断言改到的是 `sub-font-size`。这里插一根滑杆就会**抢走 `.first`**。
  /// ② 同文件 `:1260-1306` 要求「`min=0 / max=8 / divisions=8` 的滑杆有且只有一根
  ///    （并发那根），其余所有 Slider 的 `onChanged` 必须是 null」。
  ///
  /// # 数据流是**单向**的
  ///
  /// ```text
  /// 点 chip → widget.onSetRate(v)
  ///         → 宿主 _player.setRate(v)
  ///         → media_kit 广播 stream.rate
  ///         → 宿主 :2159-2163 setState(_rate = v) + 写 lastSpeed
  ///         → 面板重画，读到新的 widget.rate ⇒ 高亮跟着走
  /// ```
  ///
  /// 面板**不写**偏好（宿主那条广播已经无条件写了），也**不碰** `_lastRateRequest`
  /// （那是 PC 长按快进的探针，`test/pc_arrow_keys_test.dart` 有 15 处断言它）。
  Widget _rateSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('播放速度', note: '原版 ArtPlayer 面板的第一项'),
        _row(
          '倍速',
          Wrap(
            spacing: Sp.x2,
            runSpacing: Sp.x2,
            children: [
              for (final v in _rateOptions)
                _chip(
                  label: _rateLabel(v),
                  /*
                   * ★ 带容差比较：`_rate` 由 mpv 的 `speed` 属性回显，浮点回显未必
                   *   逐位相等；用 `==` 会出现「明明选了 1.5x 却没高亮」的观感 bug。
                   */
                  active: (widget.rate - v).abs() < 0.001,
                  onTap: () => widget.onSetRate(v),
                ),
            ],
          ),
        ),
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════════════
  //  画面（task-22：解码模式 + 缩放）
  // ═══════════════════════════════════════════════════════════════════

  /// 画面缩放档位（**百分比**，100 = 原始比例）
  ///
  /// ⚠️ 档位是「预设」，不是滑块 —— 两条硬理由（与 `_rateSection` 同一组）：
  ///   ① `test/player_capability_test.dart:1257` 拿的是 `find.byType(Slider).first`
  ///      并拖它，断言改到的是 `sub-font-size` ⇒ 这里插滑杆会**抢走 `.first`**；
  ///   ② `test/t62_player_rate_test.dart:439-452` 要求「mpvStyle 全缺时全面板只有
  ///      一根可动滑杆（并发那根）」⇒ 这里的控件在值读不到时必须**不可动**。
  ///
  /// 任意比例由**底栏长按**那条滑动条提供（P1-5），两处共用一个落点
  /// （`player_page.dart` 的 `_applyVideoZoom()`）⇒ 不会出现两个真相。
  static const List<double> _zoomOptions = <double>[75, 100, 125, 150, 200];

  /// 画面段：解码模式（四档）+ 画面缩放（五个预设）
  ///
  /// 数据流与 `_rateSection()` 同构，**单向**：
  /// ```text
  /// 点 chip → widget.onSetHwdecMode / onSetVideoZoom
  ///         → 宿主下发 mpv 属性 + 写偏好 + setState
  ///         → 面板重画，读到新的 widget.hwdecMode / widget.videoZoom
  /// ```
  ///
  /// ⚠️ 面板**不写偏好**（`test/t62_player_rate_test.dart:389-394` 明文禁止
  ///    面板出现 `UiPrefs` / `_savePlayPref`），也**不碰** `NativePlayer`。
  Widget _videoSection() {
    final zoom = widget.videoZoom;
    final onZoom = widget.onSetVideoZoom;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('画面', note: '原版 yamby 的「解码模式」与「自定义视频缩放」'),
        _row(
          '解码模式',
          Wrap(
            spacing: Sp.x2,
            runSpacing: Sp.x2,
            children: [
              for (final m in HwdecMode.values)
                _chip(
                  label: m.label,
                  active: widget.hwdecMode == m,
                  onTap: () => widget.onSetHwdecMode?.call(m),
                ),
            ],
          ),
          // 每一档「到底解成了什么」由 `_reportHwdecAfterReady` 打日志取证
          // （面板不读 mpv ⇒ 这里不显示「当前用的是哪个解码器」）
          hint: widget.hwdecMode.hint,
        ),
        _row(
          '画面缩放',
          Wrap(
            spacing: Sp.x2,
            runSpacing: Sp.x2,
            children: [
              for (final p in _zoomOptions)
                _chip(
                  label: '${p.toInt()}%',
                  // 带容差：`video-zoom` 回读后要经过 log2 / 2^ 两次换算，
                  // 浮点回显未必逐位相等（与 `_rateSection` 同款理由）。
                  active: zoom != null && (zoom - p).abs() < 0.5,
                  // ★ 读不到时传 **null**（不是空回调）：这一档在结构上就点不动
                  onTap: onZoom == null ? null : () => onZoom(p),
                ),
            ],
          ),
          // 读不到当前缩放时不假装「选中了 100%」—— 直接说明（照 `_colorRow` 范式）
          hint: zoom == null ? '读不到' : null,
        ),
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════════════
  //  连播策略（照抄原版 ArtPlayer settings 的四项）
  // ═══════════════════════════════════════════════════════════════════

  Widget _playbackSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('连播'),

        // 播放完（原版：`html: "播放完"` 的 selector）
        _row(
          '播放完',
          Wrap(
            spacing: Sp.x2,
            runSpacing: Sp.x2,
            children: [
              for (final a in PlayEndAction.values)
                _chip(
                  label: a.label,
                  active: a == widget.endAction,
                  onTap: () => widget.onSetEndAction(a),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 92, bottom: Sp.x3),
          child: Text(
            widget.endAction.hint,
            style: const TextStyle(color: Colors.white38, fontSize: FontSizes.cap),
          ),
        ),

        _switchRow(
          '连播倒计时',
          widget.countdownBeforeNext,
          widget.onSetCountdown,
          hint: '关掉则播完直接下一集',
        ),
        _switchRow(
          '自动跳过片头',
          widget.autoSkip,
          widget.onSetAutoSkip,
          hint: '片尾仍会先倒计时',
        ),
        /*
         * ⚠️ 「连播沿用线路」在**原版里也是死开关** —— 如实照抄，不自己发明行为。
         *
         * 全仓库 grep `keepSourceOnNext` 只有三处：
         * ```text
         * stores/player.ts      声明 + 持久化 + 导出
         * PlayerView.vue:3508   面板里的那个开关
         * ```
         * **没有任何播放逻辑读它**（`gotoEpisode` 走的是 session 里已有的
         * `sourceCode`，跟这个开关无关）。
         *
         * 所以这里照抄：开关能存、能读、显示当前值，
         * 但**不假装它改变了什么** —— 界面上也不写"会沿用线路"这种承诺。
         */
        _switchRow(
          '连播沿用线路',
          widget.keepSourceOnNext,
          widget.onSetKeepSource,
          hint: '原版同样未接入播放逻辑',
        ),
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════════════
  //  片段下载 / 日志（task-18 ③④⑤ 在播放器里的入口）
  // ═══════════════════════════════════════════════════════════════════
  //
  // 为什么入口放在这里：
  //   ③ 的并发上限作用在**下载**上，而下载必须知道「当前这一集的流地址 +
  //   headers」—— 这个信息只有播放页有。放到设置页会变成一个点不到东西的
  //   滑杆（用户没法验证它生效了）。
  //
  // ④ 缓存上限与 ⑤ 日志的完整面板在「设置 → 播放与下载」二级页里
  //   （lib/ui/settings/playback_page.dart）；这里放最常用的两个动作，
  //   用户不用离开播放器。
  Widget _clipSection() {
    final concurrency = ClipDownloader.concurrency;
    final err = widget.clipDownloadError;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        /*
         * ★ 标题是「下载」而不是「片段下载」（Owner 2026-10-07 第 5 条）：
         *   这一区下的**从来不是片段**，是**整集视频** ——
         *   player_page._downloadClip() 用的 st.url 就是整集流地址。
         *   旧标题「片段下载」+ 行标签「当前片段」让用户以为能按片段下，
         *   点下去却下了一整集（几十分钟的 mp4），这是纯误导。
         *   现在标题、行标签、按钮、成功行**四处**都写明「本集」。
         */
        _sectionTitle(
          '下载',
          note: '并发 ${ClipDownloader.concurrencyLabel(concurrency)}',
        ),

        // ── ③ 并发上限（0-8）─────────────────────────────────────────
        _row(
          '并发',
          Row(
            children: [
              Expanded(
                child: Slider(
                  value: concurrency.toDouble().clamp(0, 8),
                  min: 0,
                  max: 8,
                  divisions: 8,
                  label: ClipDownloader.concurrencyLabel(concurrency),
                  onChanged: (v) => widget.onSetConcurrency(v.round()),
                ),
              ),
              const SizedBox(width: Sp.x2),
              Text(
                ClipDownloader.concurrencyLabel(concurrency),
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: FontSizes.cap,
                ),
              ),
            ],
          ),
        ),
        /*
         * ★ 「0」在别处也必须是同一个意思 —— 文案由
         *   ClipDownloader.concurrencyLabel 统一给出，不在这里另写一份。
         */
        const Padding(
          padding: EdgeInsets.only(left: 92, bottom: Sp.x3),
          child: Text(
            '0 = 不限制。上限对所有下载同时生效：改小之后排队中的任务会立刻按新上限收敛，不用重开面板。',
            style: TextStyle(color: Colors.white38, fontSize: FontSizes.cap),
          ),
        ),

        // ── 下载按钮 ────────────────────────────────────────────────
        // 行标签：说清下的是**本集**（不是某个片段）
        _row(
          '本集视频',
          Wrap(
            spacing: Sp.x2,
            runSpacing: Sp.x2,
            children: [
              _chip(
                label: widget.clipDownloading ? '下载中…' : '下载本集到缓存',
                active: widget.clipDownloading,
                /*
                 * ★ 这里**不能**在下载中禁用按钮（Lead 审计 team-message-914508ce
                 *   【中】第 2 条）：一旦禁用，用户就没有任何办法从 UI 起第二个
                 *   下载，并发上限滑杆在真实 UI 路径上就永远不可观测
                 *   （maxObservedActive 恒 ≤ 1）。
                 *
                 * 去重交给 player_page._downloadClip() 按**文件名**做：
                 * 同一集重复点 → 提示「这一集已经在下载了」；
                 * 换一集再点 → 真的并发，两个 download() 同时在池子里。
                 */
                onTap: widget.onDownloadClip,
              ),
              _chip(
                label: '打开缓存目录',
                active: false,
                onTap: widget.onOpenClipDir,
              ),
            ],
          ),
        ),

        /*
         * 下载状态三选一（不是三行都显示）：
         *   正在下载 → 说明下载中，并明说没有进度条的原因
         *   失败过   → 把**原始错误**显示出来（不吞）
         *   成功过   → 只说存到了缓存目录，路径由「打开缓存目录」给
         */
        if (widget.clipDownloading)
          const Padding(
            padding: EdgeInsets.only(left: 92, bottom: Sp.x3),
            child: Text(
              '下载中…（没有进度条：下载走独立连接，不占用播放器的缓冲）',
              style: TextStyle(color: Colors.white38, fontSize: FontSizes.cap),
            ),
          )
        else if (err != null)
          Padding(
            padding: const EdgeInsets.only(left: 92, bottom: Sp.x3),
            child: Text(
              '上次下载失败：$err',
              style: const TextStyle(
                color: Colors.orangeAccent,
                fontSize: FontSizes.cap,
              ),
            ),
          )
        else if (widget.clipDownloaded)
          const Padding(
            padding: EdgeInsets.only(left: 92, bottom: Sp.x3),
            child: Text(
              '已下载本集到缓存目录（受缓存上限约束，超了自动删最旧的）',
              style: TextStyle(color: Colors.white38, fontSize: FontSizes.cap),
            ),
          ),

        // ── ⑤ 日志（分享）───────────────────────────────────────────
        /*
         * 「分享日志」在这里落成「导出成文件 / 复制到剪贴板」——
         * pubspec 里没有分享插件（share_plus 在 pubspec.lock 里 ABSENT），
         * 所以不假装能拉起系统分享面板。详见 lib/core/app_log.dart 文件头。
         */
        _row(
          '日志',
          Wrap(
            spacing: Sp.x2,
            runSpacing: Sp.x2,
            children: [
              _chip(
                label: _logBusy ? '导出中…' : '导出为文件',
                active: _logBusy,
                onTap: _logBusy ? () {} : _exportLog,
              ),
              _chip(
                label: '复制到剪贴板',
                active: false,
                onTap: _logBusy ? () {} : _copyLog,
              ),
            ],
          ),
        ),
        if (_logTip.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 92, bottom: Sp.x3),
            child: Text(
              _logTip,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: FontSizes.cap,
              ),
            ),
          ),
      ],
    );
  }

  /// ⑤ 导出日志到文件。
  ///
  /// 用 file_selector 的「另存为」（与 lib/ui/widgets/backup_panel.dart:239-288
  /// 同一套：先 getSaveLocation，平台没这个能力就退到应用自己的日志目录，
  /// 并且**必须把完整路径显示给用户** —— 静默存到他找不到的地方，
  /// 他会以为导出没成功）。
  Future<void> _exportLog() async {
    if (_logBusy) return;
    setState(() {
      _logBusy = true;
      _logTip = '';
    });
    try {
      final stamp = DateTime.now();
      String p2(int n) => n.toString().padLeft(2, '0');
      final suggested = 'sourin-log-${stamp.year}${p2(stamp.month)}${p2(stamp.day)}'
          '-${p2(stamp.hour)}${p2(stamp.minute)}${p2(stamp.second)}.log';
      String? path;
      try {
        final loc = await getSaveLocation(
          acceptedTypeGroups: const <XTypeGroup>[
            XTypeGroup(label: '日志文件', extensions: <String>['log', 'txt']),
            XTypeGroup(label: '全部文件'),
          ],
          suggestedName: suggested,
        );
        path = loc?.path;
      } on UnimplementedError {
        // Android：file_selector_android 没实现 getSaveLocation
        path = null;
      } catch (_) {
        path = null;
      }

      if (path == null) {
        final dir = await AppLog.logDir();
        path = '$dir${Platform.pathSeparator}$suggested';
      } else if (!path.toLowerCase().endsWith('.log')) {
        // Windows 的系统保存框**不会**自动补后缀（backup_panel.dart:225 同款处理）
        path = '$path.log';
      }

      final f = await AppLog.exportToFile(intoPath: path);
      final len = await f.length();
      if (!mounted) return;
      setState(() => _logTip = '已导出 $len 字节 → ${f.path}');
    } catch (e) {
      if (!mounted) return;
      setState(() => _logTip = '导出失败：$e');
    } finally {
      if (mounted) setState(() => _logBusy = false);
    }
  }

  /// ⑤ 复制日志到剪贴板（先例：lib/shell.dart:5278 / lib/ui/settings_page.dart:1533）
  Future<void> _copyLog() async {
    try {
      await Clipboard.setData(ClipboardData(text: AppLog.exportText()));
      if (!mounted) return;
      setState(() => _logTip = '已复制 ${AppLog.lineCount} 行到剪贴板');
    } catch (e) {
      if (!mounted) return;
      setState(() => _logTip = '复制失败：$e');
    }
  }
  Widget _switchRow(
    String label,
    bool value,
    ValueChanged<bool> onChanged, {
    String? hint,
  }) {
    return _row(
      label,
      Align(
        alignment: Alignment.centerLeft,
        child: Switch(value: value, onChanged: onChanged),
      ),
      hint: hint,
    );
  }
}
