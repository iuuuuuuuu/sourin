// ═══════════════════════════════════════════════════════════════════════
//  「单击快进快退」已删除 —— 回归测试（2026-09-25）
// ═══════════════════════════════════════════════════════════════════════
//
// # 用户原话（这是需求，不是建议）
//
// > **不要单击快进快退,去掉这个功能**
//
// # 这个文件为什么单独存在
//
// 原行为是**按屏幕区域分流**：
// ```text
// 左半屏单击 → 快退 N 秒
// 右半屏单击 → 快进 N 秒
// 正中窄带   → 播放/暂停      ← 这条要保留
// ```
// 删除涉及**四个文件**（播放页 / 手势配置 / 设置页 / 交付实测），
// 任何一处漏删都会留下**看起来正常但行为不对**的残留：
// ```text
// 配置项没删 → 设置页有个改了没反应的开关（用户以为坏了）
// 分流没删   → 单击还在跳秒（需求没落地）
// 长按误删   → 左半屏长按变成快进（方向反了）
// 播放/暂停误删 → 单击彻底没反应（比原来更糟）
// ```
// 所以这里把**四条边界**分别钉住。
//
// # ⚠️ 静态断言必须先剥注释
//
// 本次会话已经踩过三次：注释里提到某个标识符，纯文本匹配就把它
// 当成真实调用，测试**假失败**。而这次改动**特意**在注释里写了
// `_onPlayerTapUp` / `pcSeekSeconds` 的"墓碑"说明 ——
// 不剥注释的话，这些墓碑会把自己的测试搞挂。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String page;
  late String gestures;
  late String settings;
  late String delivery;

  /// ★ PC 播放手势二级页（2026-09-25 任务 ㉙）
  ///
  /// 用户拍板方案 A，「PC 播放手势」区块搬到了二级页：
  /// ```text
  /// 改前：settings_page.dart            _Block(title:'PC 播放手势', ...)
  /// 改后：settings/pc_gestures_page.dart SettingsBlock(title:'PC 播放手势', ...)
  /// ```
  /// 下面那几条关于"单击步长已删 / 文案要如实 / 长按项要留"的断言
  /// **语义完全不变**，只是要**两个文件一起查** ——
  /// 因为搬走之后，那些字面量既可能在一级页（入口行的副标题），
  /// 也可能在二级页（真正的开关）。
  ///
  /// ⚠️ 铁律⑥：断言跟着实际承担者走。**不能**因为搬了家就放松断言 ——
  ///    「不得出现 pcSeekSeconds」这类否定断言反而更要跨文件查全，
  ///    否则漏掉的那个文件里藏着假开关也发现不了。
  late String pcPage;

  setUpAll(() {
    page = File('lib/ui/player_page.dart').readAsStringSync();
    gestures = File('lib/core/player_gestures.dart').readAsStringSync();
    settings = File('lib/ui/settings_page.dart').readAsStringSync();
    pcPage = File('lib/ui/settings/pc_gestures_page.dart').readAsStringSync();
    delivery = File('lib/delivery_test.dart').readAsStringSync();
  });

  /// 设置页**两个文件**的合并源码（一级页 + PC 手势二级页）
  ///
  /// 「设置页不得出现 X」这类断言必须查合并后的 —— 搬家的过程中
  /// 最容易出的错就是"新文件干净了、旧文件没删干净"（或反过来）。
  ///
  /// ⚠️ 写成**局部函数**而不是 getter —— Dart 不允许在函数体内声明 getter。
  String settingsAll() => '$settings\n$pcPage';

  group('单击快进快退 —— 已按用户要求删除', () {
    test('★★ 播放页不得再有单击分流实现', () {
      final noComments = _stripComments(page);
      expect(
        noComments.contains('_onPlayerTapUp'),
        isFalse,
        reason: '★ 分流函数必须**整个删掉** —— 用户原话'
            '「不要单击快进快退,去掉这个功能」。'
            '留成"注释掉/没人调"的死代码会让后人以为单击还在分流。',
      );
      expect(
        noComments.contains('onTapUp:'),
        isFalse,
        reason: '★ 播放页那个 GestureDetector 不得挂 `onTapUp` —— '
            '它就是分流的载体（原来靠 `TapUpDetails.localPosition` 判左右）。',
      );
      expect(
        noComments.contains('TapUpDetails'),
        isFalse,
        reason: '★ 播放页不得再引用 `TapUpDetails` —— 它唯一用途就是判左右。',
      );
      expect(
        noComments.contains('dx < center'),
        isFalse,
        reason: '★ 不得再按 dx 判左右半屏（那正是被删掉的单击分流）。',
      );
      expect(
        noComments.contains('_centerBandRatio'),
        isFalse,
        reason: '★ 正中窄带（±8%）只服务"分流 + 中间暂停"，'
            '分流删掉后整屏都是播放/暂停，窄带没有存在理由。',
      );
    });

    test('★★ 单击必须**仍然**能播放/暂停（别把孩子跟洗澡水一起倒掉）', () {
      final noComments = _stripComments(page);
      expect(
        noComments.contains('onTap: _togglePlay'),
        isTrue,
        reason: '★ 用户说的是「不要**单击快进快退**」，**没有**说去掉'
            '「单击画面播放/暂停」—— 那是所有播放器（含原版）的通行习惯。'
            '删掉它会让单击彻底没反应，比原来更糟。',
      );
      expect(
        noComments.contains('void _togglePlay()'),
        isTrue,
        reason: '播放/暂停实现必须还在',
      );
    });

    test('★★ 长按的左右区域判断**必须保留**（删的是单击，不是区域）', () {
      final noComments = _stripComments(page);
      expect(
        noComments.contains('void _onLongPressStartAt(Offset local)'),
        isTrue,
        reason: '★ 长按仍要分左右：左=连续快退、右=倍速快进。'
            '用户删的是**单击**，不是"左右区域"这个概念。',
      );
      expect(
        noComments.contains('_onLongPressStartAt(d.localPosition)'),
        isTrue,
        reason: '★ 长按必须按**按下位置**分流 —— '
            '若误删，左半屏长按会变成快进（方向反了）。',
      );
      expect(
        noComments.contains('_startRewindHold()'),
        isTrue,
        reason: '左半屏长按 = 连续快退，必须还在',
      );
      expect(
        noComments.contains('_startRateHold()'),
        isTrue,
        reason: '右半屏长按 = 倍速快进，必须还在',
      );
    });

    test('★★ 触摸端双击快进快退**不受影响**（那是另一个手势）', () {
      /*
       * 用户删的是**单击**。双击（触摸端）是独立的一条路径，
       * 走 `onDoubleTapDown`，不能连带删掉。
       */
      final noComments = _stripComments(page);
      expect(
        noComments.contains('onDoubleTapDown: _doubleTapEnabled'),
        isTrue,
        reason: '★ 双击仍必须**有条件**挂载（PC 上为 null，手机端生效）—— '
            '用户 2026-09-24 明确要求「pc端不应该双击左右侧快进快退」，'
            '本次（09-25）删的是单击，不要误伤双击。',
      );
      expect(
        noComments.contains('PlayerGestures.doubleTapSeconds'),
        isTrue,
        reason: '双击步长仍要可配置（用户要求"配置多少秒"）',
      );
    });
  });

  group('单击跳秒的**配置项**已清理（否则设置页有假开关）', () {
    test('★★ PlayerGestures 里不得再有 pcSeek*', () {
      final noComments = _stripComments(gestures);
      expect(
        noComments.contains('pcSeekSeconds'),
        isFalse,
        reason: '★ `pcSeekSeconds` 只被 `_onPlayerTapUp` 读过**一次**，'
            '没有第二个消费者 —— 它只服务被删掉的"单击跳秒"，'
            '必须一起清理。',
      );
      expect(
        noComments.contains('pcSeekOptions'),
        isFalse,
        reason: '★ 步长档位同样只服务单击跳秒，一并删除。',
      );
      expect(
        noComments.contains('defaultPcSeekSeconds'),
        isFalse,
        reason: '★ 默认值也要删（否则是孤儿常量）。',
      );
      expect(
        noComments.contains('setPcSeekSeconds'),
        isFalse,
        reason: '★ setter 也要删。',
      );
    });

    test('★★ 但服务**长按**的三项配置必须保留（删错就废了长按）', () {
      /*
       * ⚠️ 这是最容易删过头的边界。
       *
       * `pcSeekSeconds` 和 `pcForwardRate` / `pcRewindStep` 挤在**同一块**
       * 注释（「PC 左右按钮」）里，看起来是一组。但：
       * ```text
       * pcSeekSeconds   → 只服务单击跳秒        → 删
       * pcForwardRate   → 服务右半屏长按倍速    → 留
       * pcRewindStep    → 服务左半屏长按每步    → 留
       * pcButtonsEnabled→ 服务长按总开关        → 留
       * ```
       * 按"整块一起删"会把长按功能废掉。
       */
      final noComments = _stripComments(gestures);
      for (final keep in [
        'pcForwardRate',
        'pcRewindStep',
        'pcButtonsEnabled',
        'pcForwardRateOptions',
        'pcRewindStepOptions',
      ]) {
        expect(
          noComments.contains(keep),
          isTrue,
          reason: '★ `$keep` **必须保留** —— 它服务长按（左连续快退/右倍速），'
              '不是单击跳秒。按"整块删"会废掉长按。',
        );
      }
    });

    test('★ 键与 setter 仍然一一对应（删键时别漏 setter）', () {
      /*
       * 沿用 `player_gestures_test.dart` 里那条"setter 数 == 键数"的
       * 结构性断言 —— 删键时最容易漏掉 setter 或 getter，
       * 而 Dart **不会**为此报错（一个没人用的 setter 完全合法）。
       */
      final keys = RegExp(r"static const _k\w+ = '([^']+)'")
          .allMatches(gestures)
          .map((m) => m.group(1)!)
          .toList();
      final setterCount =
          RegExp(r'prefs\.UiPrefs\.set\(').allMatches(gestures).length;
      expect(
        setterCount,
        keys.length,
        reason: '★ setter 数应等于键数（当前 $setterCount 个 setter、'
            '${keys.length} 个键）—— 删键时漏删 setter 会在这里被抓到。',
      );
      expect(
        keys.toSet().length,
        keys.length,
        reason: '存储键必须唯一',
      );
    });

    test('★★ 设置页不得再有「单击步长」这一项', () {
      final noComments = _stripComments(settingsAll());
      expect(
        noComments.contains('pcSeekSeconds'),
        isFalse,
        reason: '★ 设置页不得再读写单击步长 —— '
            '留着一个"改了毫无反应"的配置项比不显示更糟'
            '（用户会以为坏了，然后来报 bug）。',
      );
      expect(
        noComments.contains("label: '单击步长'"),
        isFalse,
        reason: '★ 那个 UI 控件本身也要删掉。',
      );
    });

    test('★★ 设置页的**说明文案**必须如实（不能还写"单击快进快退"）', () {
      /*
       * ⚠️ 这条抓的是"功能删了、文案没改"这类**最难发现**的残留：
       *    它不报错、不影响运行，但会**主动误导用户** ——
       *    用户按提示去点画面期待跳秒，发现没反应，判定"坏了"。
       */
      final noComments = _stripComments(settingsAll());
      expect(
        noComments.contains('单击左/右侧快退/快进'),
        isFalse,
        reason: '★ 旧提示文案「单击左/右侧快退/快进，长按左连续快退、'
            '右倍速快进」里**前半句已经不成立** —— 必须改，'
            '否则用户会照着去点画面等跳秒。',
      );
      // 长按那部分描述必须还在（功能没删）
      expect(
        noComments.contains('长按左半屏连续快退'),
        isTrue,
        reason: '新的提示文案要如实描述**仍然存在**的长按行为',
      );
    });

    test('★ 长按相关的设置项必须还在（只删了单击那一项）', () {
      final noComments = _stripComments(settingsAll());
      for (final keep in [
        'PlayerGestures.setPcForwardRate',
        'PlayerGestures.setPcRewindStep',
        'PlayerGestures.setPcButtonsEnabled',
      ]) {
        expect(
          noComments.contains(keep),
          isTrue,
          reason: '★ `$keep` 必须保留 —— 长按倍速/连续快退仍是可配置的。',
        );
      }
    });
  });

  group('交付实测必须断言**新行为**', () {
    test('★★ 不得再断言"单击分流已挂载"', () {
      final noComments = _stripComments(delivery);
      expect(
        noComments.contains('单击分流'),
        isFalse,
        reason: '★ 交付实测原来打印「PC 区域手势已挂载（单击分流 + 长按分流）」'
            '并断言 `tapUp=true` —— 那是**旧需求**。'
            '需求变了之后实测必须跟着改，否则它会报告一个错误的状态。',
      );
      expect(
        noComments.contains("g.contains('tapUp=true')"),
        isFalse,
        reason: '★ 尤其不能保留 `tapUp=true` 的断言 —— '
            '它现在会把**正确的**实现判成失败（断言方向反了）。',
      );
    });

    test('★★ 必须断言"单击不再跳秒"（用真实播放位置读数）', () {
      /*
       * ⚠️ 断言"我把回调删了"是**不够的** —— 那只证明源码改了，
       *    证明不了运行时单击真的不跳秒。
       *
       * 所以交付实测必须读**真实播放页**的位置读数做前后对比。
       */
      final noComments = _stripComments(delivery);
      expect(
        noComments.contains('debugPlayerPositionSeconds'),
        isTrue,
        reason: '★ 必须读**真实播放位置**做前后对比 —— '
            '判据是"位置真的没跳"，不是"我把回调删了"。',
      );
      expect(
        noComments.contains('debugPlayerOwnGestureState'),
        isTrue,
        reason: '★ 必须读**播放页自己那个** GestureDetector 的挂载状态。'
            '⚠️ 不能靠扫整棵渲染树找 `onTapUp` —— '
            '`InkWell` 内部无条件挂着它（material/ink_well.dart:1408），'
            '所以"树里有 onTapUp"**永远为真**，那种断言是**空的**。',
      );
      expect(
        noComments.contains('单击'),
        isTrue,
        reason: '实测输出里要能看到"单击"相关的结论，便于人读日志',
      );
    });
  });
}

/// 去掉注释行 —— 静态断言里做文本匹配**必须先剥注释**
///
/// 这个坑在本次会话里已经踩过三次：注释里提到某个标识符，
/// 纯文本匹配就把它当成真实调用，测试**假失败**。
///
/// ⚠️ 本次改动**特意**在源码注释里写了 `_onPlayerTapUp` / `pcSeekSeconds`
///    的"墓碑"说明（解释为什么删）—— 不剥注释的话，
///    这些墓碑会把自己的回归测试搞挂。
String _stripComments(String src) => src
    .split('\n')
    .where((l) {
      final t = l.trimLeft();
      return !t.startsWith('//') && !t.startsWith('*') && !t.startsWith('/*');
    })
    .join('\n');
