// ═══════════════════════════════════════════════════════════════════════
//  纯前端偏好存储 —— 对齐原版的 localStorage 用法
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么不用 shared_preferences
//
// 原版注释说明了这类数据的性质：
// > 用 localStorage 而非后台库：这是**纯前端展示偏好**，
// > 丢了最多是回到默认源，不值得为它加表和同步。
//
// Flutter 侧的对应物是 `shared_preferences`，但它是一个**平台插件**
// （Windows 上要带 C++ 实现、Android 上要带 Java 实现）——
// 为了存一个"上次选了哪个播放源"而增加安装包体积不划算
// （硬指标③要求 Windows <50MB）。
//
// 用数据目录下的一个 JSON 文件即可：
// ```text
// ① 零依赖 —— 不增加任何平台代码
// ② 所有平台行为一致 —— 不存在插件实现差异
// ③ 数据在应用数据目录里，跟其它状态放一起，便于用户备份/清理
// ```
//
// # 同步 API
//
// 启动时一次性读进内存，之后读写都是内存操作（写入异步落盘）。
// 调用方（UI）拿到的是同步接口 —— 这正是 localStorage 的用法，
// 原版代码里就是 `localStorage.getItem(...)` 直接用在渲染路径上。
//
// ⚠️ 但**必须**先 `await UiPrefs.load(dir)` 再用，否则读到空值。

import 'dart:convert';
import 'dart:io';

/// 纯前端偏好（键值对）
class UiPrefs {
  UiPrefs._();

  static Map<String, String> _data = {};
  static File? _file;
  static bool _dirty = false;

  /// 是否已加载
  static bool get isLoaded => _file != null;

  /// 测试专用：清空内存里的偏好（不碰磁盘文件）
  ///
  /// 为什么需要：`_data` 是 static，同一个 isolate 里多个测试文件会互相
  /// 看到对方写过的键；单测要的是"从空开始"的确定性。
  static void debugResetForTest([Map<String, String>? data]) {
    _data = <String, String>{...?data};
    _file = null;
    _dirty = false;
  }

  /// 从数据目录加载
  ///
  /// # 失败不抛 —— 偏好丢了不该让应用起不来
  ///
  /// 文件损坏 / 权限不足时降级成"空偏好"：
  /// 表现是"上次选的播放源没记住"，而不是白屏。
  static Future<void> load(String dataDir) async {
    final f = File('$dataDir${Platform.pathSeparator}ui-prefs.json');
    _file = f;
    try {
      if (await f.exists()) {
        final txt = await f.readAsString();
        final m = jsonDecode(txt);
        if (m is Map) {
          _data = m.map((k, v) => MapEntry(k.toString(), v.toString()));
        }
      }
    } catch (e) {
      // 损坏 → 用空偏好继续（不删文件，用户可能想自己看看）
      debugLog('偏好文件读取失败（降级为空）: $e');
      _data = {};
    }
  }

  /// 读一个键（不存在返回 null）
  static String? get(String key) => _data[key];

  /// 写一个键
  ///
  /// 立即改内存（UI 下一次读就能看到），落盘是异步的 ——
  /// 调用方不需要 await（与 localStorage 的同步语义一致）。
  static void set(String key, String value) {
    if (_data[key] == value) return;
    _data[key] = value;
    _dirty = true;
    _flushSoon();
  }

  /// 删一个键
  static void remove(String key) {
    if (!_data.containsKey(key)) return;
    _data.remove(key);
    _dirty = true;
    _flushSoon();
  }

  static Future<void>? _pending;

  /// 合并短时间内的多次写入
  ///
  /// 为什么：用户快速切几个播放源会触发多次写。
  /// 每次都落盘是浪费（且可能写坏 —— 两个异步写重叠）。
  static void _flushSoon() {
    if (_pending != null) return;
    _pending = Future.delayed(const Duration(milliseconds: 300), () async {
      _pending = null;
      await flush();
    });
  }

  /// 立刻落盘（退出前调一次，或测试里用）
  static Future<void> flush() async {
    if (!_dirty || _file == null) return;
    _dirty = false;
    try {
      await _file!.writeAsString(jsonEncode(_data));
    } catch (e) {
      debugLog('偏好落盘失败: $e');
      // 写失败不算致命 —— 内存里还是对的，本次会话不受影响
    }
  }

  // ── 播放源偏好（原版 `dsh.srcpref.<provider>:<id>`）──

  /// 读某作品记住的播放源 code
  static String sourcePref(String provider, String id) =>
      _data['dsh.srcpref.$provider:$id'] ?? '';

  /// 记住某作品的播放源 code
  static void setSourcePref(String provider, String id, String code) =>
      set('dsh.srcpref.$provider:$id', code);

  // ── 首页选中的源（原版 `dsh.homeSource`）──

  /// 存储键 —— **故意与原版同名**
  ///
  /// # 为什么必须是**独立的键**（原版注释专门解释了）
  ///
  /// > 它和播放偏好（`dsh.playprefs`）没关系。混在一起的话，
  /// > 「清空播放偏好」会顺带把首页选中的源也清掉 ——
  /// > 那是两件不相干的事。
  ///
  /// 所以**不要**把它塞进 `dsh.srcpref.*` 那个命名空间
  /// （那是"某作品用哪个播放线路"，与"首页看哪个内容源"完全是两回事）。
  static const homeSourceKey = 'dsh.homeSource';

  /// 首页当前选中的内容源 id（空串 = 没选过 / 已失效）
  static String get homeSource => _data[homeSourceKey] ?? '';

  /// 记住首页选中的内容源
  ///
  /// ⚠️ 传空串 = **清除**（与原版 `removeItem` 等价）。
  ///    不能直接 `set(key, '')` —— `set` 会把空串**存进去**
  ///    （而 `_data[key] ?? ''` 读出来也是空串，看起来一样，
  ///     但文件里会留一个 `"dsh.homeSource": ""` 的垃圾键）。
  static void setHomeSource(String id) {
    if (id.isEmpty) {
      remove(homeSourceKey);
    } else {
      set(homeSourceKey, id);
    }
  }
}

/// 轻量日志（这个文件不依赖 Flutter，所以用 print）
void debugLog(String msg) {
  // ignore: avoid_print
  print('[UI-PREFS] $msg');
}
