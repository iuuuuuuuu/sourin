// ═══════════════════════════════════════════════════════════════════════
//  toast 宿主的挂载守卫
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么要有这个文件（settings agent 在合并时提出的一个真问题）
//
// `showAppToast()` 的实现是 `AppToaster.maybeOf(context)?.show(...)` ——
// 找不到宿主就**静默返回**。这本来是好的设计（toast 是锦上添花，
// 绝不该把调用方搞崩），但在"把手写 `_Toast` 迁到 `showAppToast`"的
// 迁移期，它变成了**静默失效**：
//
// ```text
// 没挂 ToastHost + 迁了调用点 = 所有 toast 全部消失，零报错、零测试红
// ```
//
// 这类"不报错的回归"正是本仓反复付过代价的那一类（见 theme_regression_test.dart
// 里两套 Material 串台的那段）。所以这里把"宿主必须在树上"变成断言。
//
// # 判据为什么是「结构断言」而不是「跑一遍看有没有 toast」
//
// 结构断言更快、更直接，且**不需要**把每个页面都 pump 一遍 —
// 它锁的是"宿主这个节点存在"这一件事实本身。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/widgets/app_toast.dart';

void main() {
  group('★ ToastHost 必须挂在应用外壳上', () {
    test('shell.dart 的 MaterialApp.builder 里必须有 ToastHost', () {
      final src = File('lib/shell.dart').readAsStringSync();
      expect(
        src.contains('ToastHost('),
        isTrue,
        reason: '★ `MaterialApp.builder` 里没有 `ToastHost` ⇒ 宿主不存在。\n'
            '此时 `showAppToast()` 会**静默返回**（找不到 `AppToaster` 就 no-op），'
            '所有迁过去的调用点会"看起来正常"但一条 toast 都不弹 —— '
            '**不报错、不变红**，是本仓最贵的那种回归。\n'
            '挂载点应与自绘标题栏同一层（Navigator 之外），'
            '这样 push 出来的详情页/播放页也能收到。',
      );
    });

    test('挂载点必须在 MaterialApp.builder 内（Navigator 之外）', () {
      final src = File('lib/shell.dart').readAsStringSync();
      final b = src.indexOf('builder: (context, child) =>');
      expect(b, greaterThan(0), reason: '找不到 builder —— shell 结构变了');
      final t = src.indexOf('ToastHost(', b);
      expect(t, greaterThan(0),
          reason: 'ToastHost 不在 builder 里 ⇒ 它只挂在某个页面内部，'
              'push 出来的二级页就收不到 toast');
    });

    test('ToastHost 的子树里必须包住 Navigator（child 传下去）', () {
      final src = File('lib/shell.dart').readAsStringSync();
      final i = src.indexOf('ToastHost(');
      expect(i, greaterThan(0));
      // 取 ToastHost 之后的一小段，确认它把 `child` 往里传了
      final seg = src.substring(i, (i + 400).clamp(0, src.length));
      expect(seg.contains('_TitleBarHost(child: child'),
          isTrue,
          reason: 'ToastHost 里面必须原样传递 builder 的 child —— '
              '否则整个应用的内容都不会被渲染（比"toast 不弹"严重得多）');
    });
  });

  group('★ 找不到宿主时的行为是有意的', () {
    testWidgets('没有 ToastHost 时 showAppToast 静默 no-op，不抛异常', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (ctx) {
          // ★ 这正是迁移期最危险的场景：调用点换成了 showAppToast，
          //   但宿主还没挂上。必须**安静地**什么都不做，而不是把调用方搞崩。
          showAppToast(ctx, '这条 toast 会被丢掉');
          return const SizedBox();
        }),
      ));
      await tester.pump();
      expect(tester.takeException(), isNull,
          reason: 'toast 是锦上添花，宿主缺席不该让调用方崩');
      expect(find.text('这条 toast 会被丢掉'), findsNothing);
    });
  });

  group('ToastHost 存在时 toast 真的能弹出来', () {
    testWidgets('挂了就弹得出来（这条能测出反面：去掉 ToastHost 就红）', (tester) async {
      await tester.pumpWidget(MaterialApp(
        builder: (context, child) =>
            ToastHost(child: child ?? const SizedBox()),
        home: Builder(builder: (ctx) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            showAppToast(ctx, '宿主在，toast 就会出现');
          });
          return const SizedBox();
        }),
      ));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('宿主在，toast 就会出现'), findsOneWidget,
          reason: '挂载了宿主却弹不出来 ⇒ 宿主本身坏了');
    });
  });
}
