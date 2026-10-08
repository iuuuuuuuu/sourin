/*
 * t466 —— 时间轴刻度标签**重叠让位**（真机截图发现的丑）
 *
 * ══════════════════════════════════════════════════════════════════════
 * # 缺陷是怎么发现的（不是想出来的，是**看出来的**）
 * ══════════════════════════════════════════════════════════════════════
 *
 * 真机探针 `lib/t465_skip_dialog_probe.dart` 跑完 **pass=30 fail=0**，
 * 所有结构性判据（`rectOf != null`、四行在固定脚上方、宽高比 1.333…）
 * **全绿**。然后我把截图 `.probe/t465-02-布局.png` 里时间轴那一条
 * 裁出来放大 10 倍 —— 看到的是：
 *
 * ```text
 * ▶0(0)0-00        ← 两串字叠在一起
 * ```
 *
 * 位置在 0 时，播放头 x == `kArrowInset`（= 21），而静态起点标签
 * **也**画在 `kArrowInset` ⇒ 完全重合。
 *
 * ★ 教训：**结构性判据全绿 ≠ 画出来好看**。
 *   「有点丑，要美观」这个验收标准，只有**看**才能判。
 *
 * ══════════════════════════════════════════════════════════════════════
 * # 为什么这个测试长这样（判据必须与结论同层）
 * ══════════════════════════════════════════════════════════════════════
 *
 * 缺陷的**决定**只依赖两个矩形（`leftRect` / `rightRect` vs `curRect`）。
 * 如果那个判断留在 `paint()` 里，验证它就只能"渲染出图再数像素"——
 * 贵、脆、还说不清边界在哪。
 *
 * ⇒ 把判断抽成纯函数 `tickLabelsCollide(a, b, {pad})`，
 *   这里直接喂矩形、断言边界值。
 *
 * ⚠️ 但**纯函数测通了 ≠ painter 用对了**：下面第二组专门钉"接线"，
 *    证明 `paint()` 真的调用了它（否则抽出来的函数可以谁都不理）。
 */
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:sourin_spike/ui/widgets/skip_timeline.dart';

/// 造一个 `width x height` 的矩形，左上角在 [left] / [top]
Rect r(double left, double top, double width, double height) =>
    Rect.fromLTWH(left, top, width, height);

void main() {
  group('t466 tickLabelsCollide：判据本身的边界', () {
    /*
     * 坐标系约定：三个标签都是 `y = canvasH - 6 - height` 起画，
     * 所以**纵向一定重叠**；决定让位与否的只有**横向**。
     */
    const y = 40.0;
    const h = 12.0;

    test('① 完全重合 ⇒ 判定重叠（这就是位置 0 时的真实情形）', () {
      // 位置 0：xOf(0) == kArrowInset == 21 ⇒ cur 被夹到 21，与 left 同点
      final left = r(21, y, 30, h);
      final cur = r(21, y, 46, h);
      expect(tickLabelsCollide(left, cur), isTrue,
          reason: '★ 位置 0 时 ▶0:00 与静态 0:00 必须判为重叠（否则就是那个丑）');
    });

    test('② 横向完全错开 ⇒ 判定不重叠（正常中间位置，两个都要画）', () {
      final left = r(21, y, 30, h); // 0:00
      final cur = r(400, y, 46, h); // ▶ 05:00 在中间
      expect(tickLabelsCollide(left, cur), isFalse,
          reason: '中间位置两个标签都要看得见 —— 不能让位过头');
    });

    test('③ 恰好挨着（间隙 0）⇒ 判定重叠（4px 间隙是有意的）', () {
      // left 右边 = 21+30 = 51；cur 左边 = 51 ⇒ 紧挨着，不压上
      final left = r(21, y, 30, h);
      final cur = r(51, y, 46, h);
      expect(left.overlaps(cur), isFalse, reason: '（前提：几何上确实没压上）');
      expect(tickLabelsCollide(left, cur), isTrue,
          reason: '★ 判据要的是"挨得太近就让位"，不是"压上了才让位"');
    });

    test('④ 间隙刚好 4px ⇒ 判定不重叠（边界是闭区间，不能吃掉正常情形）', () {
      // left 右边 = 51；cur 左边 = 55 ⇒ 间隙 4
      final left = r(21, y, 30, h);
      final cur = r(55, y, 46, h);
      expect(tickLabelsCollide(left, cur), isFalse,
          reason: '间隙 4px 属于"够开"，此时两个都要画');
    });

    test('⑤ 间隙 3.9px ⇒ 判定重叠（4px 那条线是真的在起作用）', () {
      final left = r(21, y, 30, h);
      final cur = r(54.9, y, 46, h);
      expect(tickLabelsCollide(left, cur), isTrue,
          reason: '★ ④⑤ 一起把边界钉死在 4px —— 少一条就不知道线在哪');
    });

    test('⑥ 对称：参数顺序不影响结论（右侧终点标签同样适用）', () {
      final right = r(700, y, 40, h); // 47:06
      final cur = r(700, y, 46, h);
      expect(tickLabelsCollide(right, cur), isTrue);
      expect(tickLabelsCollide(cur, right), isTrue,
          reason: '右端撞上时同理 —— 判据不能只对一个方向成立');
    });

    test('⑦ pad 可调：pad=0 时"紧挨着"不再算重叠', () {
      final left = r(21, y, 30, h);
      final cur = r(51, y, 46, h);
      expect(tickLabelsCollide(left, cur, pad: 0), isFalse,
          reason: '把阈值暴露出来，将来想调间距不用改判据结构');
    });
  });

  group('t466 接线：paint() 真的用了这个判据', () {
    /*
     * ⚠️ 抽出来的纯函数**可以谁都不理**。
     *    这一组钉住"painter 里确实按它决定画谁"。
     *
     * 手法与 `skip_history_dialog_test.dart` 同类：读**源码**断言结构。
     * ★ 但要断言在**语义层**（"用 tickLabelsCollide 做了条件绘制"），
     *   不是语法层（"文件里有这串字符"）—— 否则一次等价重构就会假红。
     */
    late final String src;

    setUpAll(() {
      src = _readLib('lib/ui/widgets/skip_timeline.dart');
    });

    test('★ paint() 里对 left / right 各做了一次条件绘制', () {
      // 两个静态标签都必须被 `if (!tickLabelsCollide(...))` 包住
      expect(
        RegExp(r'if \(!tickLabelsCollide\(leftRect, curRect\)\)')
            .hasMatch(src),
        isTrue,
        reason: '★ 左侧「0:00」必须让位 —— 少了它，位置 0 时照样叠成一团',
      );
      expect(
        RegExp(r'if \(!tickLabelsCollide\(rightRect, curRect\)\)')
            .hasMatch(src),
        isTrue,
        reason: '★ 右侧「总长」必须让位 —— 播到末尾时同理',
      );
    });

    test('★ 「当前时间」**无条件**画（它才是不能被让掉的那个）', () {
      /*
       * 关键语义：让位的是**静态**标签。
       * 如果哪天有人"对称地"把 cur 也包进条件里，那就等于
       * "两串字打架时两个都不画" ⇒ 用户彻底看不到当前位置。
       * ⇒ 这里钉住 cur 的绘制是**无条件**的。
       */
      final body = _paintBody(src);
      expect(
        RegExp(r'\n\s*cur\.paint\(canvas, curRect\.topLeft\);').hasMatch(body),
        isTrue,
        reason: '★ 当前时间必须无条件画出来',
      );
      // 反向：cur.paint 那一行前面**不能**紧跟一个 if 判据
      expect(
        RegExp(r'if \([^)]*\)\s*\{\s*cur\.paint\(').hasMatch(body),
        isFalse,
        reason: '★ 当前时间一旦也被条件包住，打架时就会"两个都不画"',
      );
    });

    test('★ 三个标签的矩形都先算好再决定画谁（不是边算边画）', () {
      /*
       * 要让位就必须**先知道对方的矩形** ⇒ 三个 Rect 都得在
       * 任何一次 paint 之前算出来。
       * 语义：`curRect` / `leftRect` / `rightRect` 的定义必须先于
       * 第一次 `left.paint` / `right.paint` / `cur.paint`。
       */
      final body = _paintBody(src);
      final defCur = body.indexOf('final curRect = Rect.fromLTWH(');
      final defLeft = body.indexOf('final leftRect = Rect.fromLTWH(');
      final defRight = body.indexOf('final rightRect = Rect.fromLTWH(');
      final firstPaint = [
        body.indexOf('left.paint('),
        body.indexOf('right.paint('),
        body.indexOf('cur.paint('),
      ].where((i) => i >= 0).reduce((a, b) => a < b ? a : b);

      expect(defCur, greaterThan(0), reason: 'curRect 必须有定义');
      expect(defLeft, greaterThan(0), reason: 'leftRect 必须有定义');
      expect(defRight, greaterThan(0), reason: 'rightRect 必须有定义');
      expect(defCur, lessThan(firstPaint),
          reason: '★ 判定要用到 curRect ⇒ 它必须先算出来');
      expect(defLeft, lessThan(firstPaint));
      expect(defRight, lessThan(firstPaint));
    });
  });
}

/// 读 lib 下的源文件（测试与 lib 同仓，路径相对仓库根）
String _readLib(String rel) {
  final f = File(rel);
  if (f.existsSync()) return f.readAsStringSync();
  // `flutter test` 的 cwd 有时在仓库根，有时不是 —— 兜一层
  final alt = File('../$rel');
  if (alt.existsSync()) return alt.readAsStringSync();
  throw StateError('读不到 $rel（cwd=${Directory.current.path}）');
}

/// 取 `void paint(Canvas canvas, Size size) {` 的函数体（花括号配平）
///
/// ⚠️ 不能简单 `indexOf('{')` —— 参数表里可能有 `{`（本文件没有，
///    但 `t66` 就踩过这个坑：`bodyOf` 切到了参数表里）。
String _paintBody(String src) {
  final sig = src.indexOf('void paint(Canvas canvas, Size size)');
  expect(sig, greaterThan(0), reason: '找不到 paint 签名');
  // 跳过参数表（配平括号），再找函数体的 `{`
  var i = src.indexOf('(', sig);
  var depth = 0;
  for (; i < src.length; i++) {
    if (src[i] == '(') depth++;
    if (src[i] == ')') {
      depth--;
      if (depth == 0) break;
    }
  }
  final open = src.indexOf('{', i);
  expect(open, greaterThan(0), reason: '找不到 paint 函数体');
  var d = 0;
  for (var j = open; j < src.length; j++) {
    if (src[j] == '{') d++;
    if (src[j] == '}') {
      d--;
      if (d == 0) return src.substring(open, j + 1);
    }
  }
  throw StateError('paint 函数体花括号不配平');
}
