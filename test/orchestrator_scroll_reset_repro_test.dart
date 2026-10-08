// 验证「_loading=true 会销毁 ListView 导致滚动位置归零」
// 这是一个可复现的 widget 测试 —— 不需要真机
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// 复现 settings_page 的结构：
///   if (_loading) return Center(CircularProgressIndicator());
///   return ListView(...);
class Repro extends StatefulWidget {
  const Repro({super.key});
  @override
  State<Repro> createState() => ReproState();
}

class ReproState extends State<Repro> {
  bool loading = false;

  @override
  Widget build(BuildContext context) {
    // ★ 这是 settings_page.dart:1102 的真实结构
    if (loading) {
      return const Center(child: CircularProgressIndicator());
    }
    return ListView(
      children: [
        for (var i = 0; i < 100; i++)
          SizedBox(height: 60, child: Text('item $i')),
      ],
    );
  }
}

void main() {
  testWidgets('★ 假设验证：_loading 切换会销毁 ListView → 滚动位置归零', (tester) async {
    final key = GlobalKey<ReproState>();
    await tester.pumpWidget(MaterialApp(home: Repro(key: key)));
    await tester.pumpAndSettle();

    // 1) 滚到 3000
    final listFinder = find.byType(ListView);
    await tester.drag(listFinder, const Offset(0, -3000));
    await tester.pumpAndSettle();

    final pos1 = tester.state<ScrollableState>(find.byType(Scrollable)).position.pixels;
    // ignore: avoid_print
    print('[REPRO] 滚动后 pixels = $pos1');
    expect(pos1, greaterThan(1000), reason: '先确认真的滚下去了');

    // 2) 触发 _loading = true（模拟 loadAll 的开头）
    key.currentState!.setState(() => key.currentState!.loading = true);
    await tester.pump();
    // ignore: avoid_print
    print('[REPRO] _loading=true 后 ListView 还在吗: ${find.byType(ListView).evaluate().isNotEmpty}');

    // 3) 恢复 _loading = false
    key.currentState!.setState(() => key.currentState!.loading = false);
    await tester.pumpAndSettle();

    final pos2 = tester.state<ScrollableState>(find.byType(Scrollable)).position.pixels;
    // ignore: avoid_print
    print('[REPRO] 恢复后 pixels = $pos2');
    // ignore: avoid_print
    print('[REPRO] ★ 滚动位置丢失: ${pos1 - pos2}');

    // ★ 这就是 bug：位置归零
    expect(pos2, lessThan(pos1),
        reason: '★ 复现成功：_loading 切换把滚动位置清零了');
  });
}
