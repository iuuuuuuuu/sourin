// 最小复现：验证「initState 里调 setState」会不会让 AlertDialog 渲染成空/异常
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class Probe extends StatefulWidget {
  const Probe({super.key});
  @override
  State<Probe> createState() => _ProbeState();
}

class _ProbeState extends State<Probe> {
  bool _loading = false;
  @override
  void initState() {
    super.initState();
    // ★ 复现 plugin_edit_dialog.dart:159 那条路径
    _load();
  }
  Future<void> _load() async {
    setState(() => _loading = true);
  }
  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('TITLE'),
        content: SizedBox(width: 560, child: Text(_loading ? 'LOADING' : 'IDLE')),
      );
}

void main() {
  testWidgets('initState 里 setState 会怎样', (t) async {
    final errs = <String>[];
    final prev = FlutterError.onError;
    FlutterError.onError = (d) => errs.add(d.exceptionAsString());
    addTearDown(() => FlutterError.onError = prev);

    await t.pumpWidget(MaterialApp(home: Scaffold(body: Probe())));
    await t.pump();

    print('PROBE| 捕获到的异常数 = ${errs.length}');
    for (final e in errs) {
      print('PROBE| 异常: ${e.split('\n').take(3).join(' ')}');
    }
    print('PROBE| 树里有 TITLE = ${find.text('TITLE').evaluate().isNotEmpty}');
    print('PROBE| 树里有 LOADING = ${find.text('LOADING').evaluate().isNotEmpty}');
    print('PROBE| 树里有 IDLE = ${find.text('IDLE').evaluate().isNotEmpty}');
  });
}