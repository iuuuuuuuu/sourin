// m13655 (B)：窗口几何持久化 —— 序列化 / 夹取 的纯函数单测
//
// # 为什么这些断言值得写
//
// 这条链路里**唯一会让用户「整个窗口消失」的分支**就是「存下来的坐标在屏幕外」
// （换了显示器 / 改了分辨率 / 笔记本拔掉外接屏）。
// 而那个分支是纯算术，**不需要真窗口**就能打 —— 真窗口的验证放在
// `.probe\win_probe\bounds_persist.py`（真进程 + 真模态缩放/移动）。
//
// ⚠️ 这里**不碰** `windowManager` / `screenRetriever`（测试环境没有平台通道），
//    所以只打 `parse` / `format` / `clampTo` 三个纯函数。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/core/window_bounds.dart';

void main() {
  group('序列化', () {
    test('format 产出 x,y,w,h（整数）', () {
      expect(WindowBoundsStore.format(const Rect.fromLTWH(100, 80, 1100, 700)),
          '100,80,1100,700');
    });

    test('★ format 取整：DPR 1.25 下 getBounds() 会产出 1023.9999999999999', () {
      // window_manager 的 GetBounds 是 int ÷ dpr，125% 缩放必然带小数尾巴。
      // 不取整的话：① 存进 JSON 又长又难读；② 每次读回来的字符串都可能不同，
      // 而 UiPrefs.set 里有「值没变就不写」的短路 ⇒ 会反复触发落盘。
      final r = Rect.fromLTWH(1023.9999999999999, 0.0000000000001, 1280.0000001, 800);
      expect(WindowBoundsStore.format(r), '1024,0,1280,800');
    });

    test('parse 往返一致', () {
      const raw = '100,80,1100,700';
      final r = WindowBoundsStore.parse(raw)!;
      expect(r.left, 100);
      expect(r.top, 80);
      expect(r.width, 1100);
      expect(r.height, 700);
      expect(WindowBoundsStore.format(r), raw);
    });

    test('parse 接受负数坐标（副屏在主屏左边是负的）', () {
      final r = WindowBoundsStore.parse('-1920,0,1280,800')!;
      expect(r.left, -1920);
    });

    test('parse 坏数据一律返回 null（调用方退回默认几何）', () {
      final bads = <String?>[
        null,
        '',
        '100,80,1100',
        '100,80,1100,700,1',
        'a,80,1100,700',
        '100,80,1100,',
        'NaN,80,1100,700',
        'Infinity,80,1100,700',
      ];
      for (final bad in bads) {
        expect(WindowBoundsStore.parse(bad), isNull, reason: 'bad=$bad');
      }
    });

    test('parse 容忍逗号后的空格', () {
      expect(WindowBoundsStore.parse('100, 80, 1100, 700'), isNotNull);
    });
  });

  group('落屏夹取 clampTo', () {
    // 本机工作区：2560x1440 的屏，扣掉 40px 任务栏 ⇒ 2560x1400。
    const work = Rect.fromLTWH(0, 0, 2560, 1400);

    test('工作区内的矩形原样保留', () {
      const r = Rect.fromLTWH(100, 80, 1100, 700);
      expect(WindowBoundsStore.clampTo(r, work), r);
    });

    test('★ 整个跑到右下屏幕外 ⇒ 拉回工作区内（否则用户看到「窗口没了」）', () {
      final got =
          WindowBoundsStore.clampTo(const Rect.fromLTWH(3000, 2000, 1100, 700), work);
      expect(got.right, lessThanOrEqualTo(work.right));
      expect(got.bottom, lessThanOrEqualTo(work.bottom));
      expect(got.left, work.right - 1100);
      expect(got.top, work.bottom - 700);
      expect(got.width, 1100);
      expect(got.height, 700);
    });

    test('负坐标（副屏拔掉后）⇒ 拉回主屏', () {
      final got =
          WindowBoundsStore.clampTo(const Rect.fromLTWH(-3000, -2000, 1100, 700), work);
      expect(got.left, work.left);
      expect(got.top, work.top);
      expect(got.width, 1100);
    });

    test('只露一点点边 ⇒ 也整体拉回来', () {
      final got =
          WindowBoundsStore.clampTo(const Rect.fromLTWH(2500, 1300, 1100, 700), work);
      expect(got.right, lessThanOrEqualTo(work.right));
      expect(got.bottom, lessThanOrEqualTo(work.bottom));
    });

    test('尺寸小于最小 ⇒ 抬到 900x600', () {
      final got =
          WindowBoundsStore.clampTo(const Rect.fromLTWH(50, 50, 400, 300), work);
      expect(got.width, WindowBoundsStore.minWidth);
      expect(got.height, WindowBoundsStore.minHeight);
      expect(got.left, 50);
      expect(got.top, 50);
    });

    test('★ 存下来的尺寸比屏幕还大（换了小屏）⇒ 缩到工作区', () {
      final got =
          WindowBoundsStore.clampTo(const Rect.fromLTWH(0, 0, 4000, 3000), work);
      expect(got.width, work.width);
      expect(got.height, work.height);
    });

    test('★ 工作区比最小尺寸还小时不越界（高 DPI 小屏真会这样）', () {
      // Windows「显示缩放 500%」下，1366x768 的屏工作区只有 273x133 DIP。
      // 此时「抬到 900x600」必然超出工作区 —— 但**必须**保证 left/top 不为负，
      // 否则窗口会被推到屏幕左上角之外（连标题栏都点不到）。
      const tiny = Rect.fromLTWH(0, 0, 273, 133);
      final got =
          WindowBoundsStore.clampTo(const Rect.fromLTWH(100, 100, 1280, 800), tiny);
      expect(got.left, greaterThanOrEqualTo(tiny.left));
      expect(got.top, greaterThanOrEqualTo(tiny.top));
    });

    test('第二显示器（工作区从 x=2560 开始）不会被误夹回主屏', () {
      const second = Rect.fromLTWH(2560, 0, 1920, 1040);
      const r = Rect.fromLTWH(2700, 100, 1200, 800);
      expect(WindowBoundsStore.clampTo(r, second), r);
    });
  });

  group('UiPrefs 往返（只打内存，不落盘）', () {
    setUp(() => UiPrefs.debugResetForTest());

    test('set 之后 read 拿得回来', () {
      WindowBoundsStore.set(const Rect.fromLTWH(120, 60, 1024, 768));
      expect(UiPrefs.get(WindowBoundsStore.key), '120,60,1024,768');
      final back = WindowBoundsStore.read()!;
      expect(back, const Rect.fromLTWH(120, 60, 1024, 768));
    });

    test('没存过 ⇒ read() 是 null', () {
      expect(WindowBoundsStore.read(), isNull);
    });

    test('★ 存的是坏值 ⇒ read() 也是 null（不抛异常）', () {
      UiPrefs.set(WindowBoundsStore.key, 'garbage');
      expect(WindowBoundsStore.read(), isNull);
    });
  });

  group('接线（读源码字符串，与项目里其它窗口测试同一手法）', () {
    test('shell.dart：load → restore → show，顺序不能反', () {
      final src = File('lib/shell.dart').readAsStringSync();
      final iLoad = src.indexOf('await UiPrefs.load(dir);');
      final iRestore = src.indexOf('await WindowBoundsStore.restore();');
      final iShow = src.indexOf('await _showDesktopWindow();');
      expect(iLoad, greaterThan(-1), reason: '找不到 UiPrefs.load');
      expect(iRestore, greaterThan(-1), reason: '找不到 restore');
      expect(iShow, greaterThan(-1), reason: '找不到 _showDesktopWindow');
      expect(iRestore, greaterThan(iLoad), reason: '★ 还原必须在偏好加载之后');
      expect(iShow, greaterThan(iRestore), reason: '★ show 必须在还原之后（否则会跳一下）');
      // ★ 这里不能只写 `expect(src.contains('await windowManager.show();'),
      //   isFalse)` —— `_showDesktopWindow()` 的函数体里本来就有这一行。
      //   正确的断言是「全文件**只有一处**，且那一处在 `_showDesktopWindow`
      //   的定义之后」，即 show() 没有散落在别处提前把窗口显出来。
      final iShowFn = src.indexOf('Future<void> _showDesktopWindow() async {');
      expect(iShowFn, greaterThan(-1), reason: '找不到 _showDesktopWindow 定义');
      final iShowCall = src.indexOf('await windowManager.show();');
      expect(iShowCall, greaterThan(iShowFn),
          reason: '★ show() 的唯一调用点必须落在 _showDesktopWindow 函数体内');
      expect(src.indexOf('await windowManager.show();', iShowCall + 1), -1,
          reason: '★ show() 只能有一处调用 —— 多出来的那处会在还原之前把窗口显出来');
    });

    /*
     * ★★★ 2026-10-04 真机回归（Android 整端不可用，skip-feature 抓到的）
     *
     * # 症状（真机 logcat，不是推断）
     * ```text
     * [SHELL] ★ 显示窗口失败（窗口可能不可见）:
     *         MissingPluginException(No implementation found for method
     *         isMinimized on channel window_manager)
     * [SHELL] ★ 核心启动失败:
     *         MissingPluginException(No implementation found for method
     *         focus on channel window_manager)
     * #2      _showDesktopWindow (package:sourin_spike/shell.dart:719)
     * #3      main (package:sourin_spike/shell.dart:577)
     * ```
     * ⇒ 手机/电视上进「核心未能启动」页，**Rust 核心一次都没启动**。
     *
     * # 根因
     * `show()` 原来在 `waitUntilReadyToShow` 的回调里，而那个回调**只在
     * `if (kIsDesktop) { ... }` 里** —— 搬到 main 的 try 里时把「外层已经判过
     * 平台」这个前提一起丢了。`show()` 自己的异常被吞，但
     * `await windowManager.focus()` 在 try **外面** ⇒ 它一抛就冲出函数，
     * 被 main 的 `catch (e, st) { coreError = ... }` 接住 ⇒
     * 「窗口显示失败」被记成「核心启动失败」，后面 `SourinCore.startAsync(dir)`
     * 那一行永远执行不到。
     *
     * # 为什么这条断言必须存在
     * 上面那条「show() 只有一处」的断言**管不到**这件事：它只看调用点个数，
     * 不看有没有平台闸门。而 `flutter test` 里 `kIsDesktop` 恒为 false（测试跑在
     * 宿主上、且 `window_manager` 插件不存在）⇒ **测试永远走不到这条路径**，
     * 所以这个 bug 只能靠真机发现。读源码字符串断言是唯一能在 CI 里钉住它的办法。
     */
    test('shell.dart：_showDesktopWindow 首行必须有平台闸门（★ Android 回归门）', () {
      final src = File('lib/shell.dart').readAsStringSync();
      final iFn = src.indexOf('Future<void> _showDesktopWindow() async {');
      expect(iFn, greaterThan(-1), reason: '找不到 _showDesktopWindow 定义');

      final iGuard = src.indexOf('if (!kIsDesktop) return;', iFn);
      final iShow = src.indexOf('await windowManager.show();', iFn);
      final iFocus = src.indexOf('await windowManager.focus();', iFn);

      expect(iGuard, greaterThan(-1),
          reason: '★ 非桌面必须**直接返回** —— 否则 window_manager 通道在 Android 上'
              '抛 MissingPluginException，异常冲出函数后被 main 记成「核心启动失败」，'
              'Rust 核心一次都起不来（2026-10-04 真机事故）');
      expect(iShow, greaterThan(-1), reason: '找不到 windowManager.show()');
      expect(iFocus, greaterThan(-1), reason: '找不到 windowManager.focus()');
      expect(iGuard, lessThan(iShow),
          reason: '★ 闸门必须在 show() **之前** —— 晚一行就已经碰过通道了');
      expect(iGuard, lessThan(iFocus),
          reason: '★★ 闸门必须在 focus() 之前 —— 这一条才是真正的原因：'
              'focus() 在 try 外面，不吞异常，一抛就冲出函数');
    });

    test('window_frame.dart：resized 与 moved 都接到记录逻辑上', () {
      final src = File('lib/ui/widgets/window_frame.dart').readAsStringSync();
      expect(src.contains('window_bounds.dart'), isTrue);
      expect(src.contains('WindowBoundsStore.recordCurrent()'), isTrue);
      expect(src.contains('void onWindowMoved()'), isTrue,
          reason: '★ 拖动窗口只发 moved，不接就永远记不住位置');
      expect(src.contains('void onWindowResized()'), isTrue);
    });
  });
}
