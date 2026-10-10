// ⚠️ 探针 2：结论**已被探针 3 推翻** —— 见 test/zz_cr_origin_probe3_test.dart。
// 它测出的「listProviders() 的 future 永不完成」只在**假时钟**下成立：
// NativeCallable.listener 的回包走真消息端口，FakeAsync 里不转。
// 真事件循环（tester.runAsync）下 FFI 立刻回 SourinCoreException(unsupported)
// ⇒ providerDisplayName 退化成裸 id，并没有卡住。
// 探针2：providerDisplayName 在 flutter_tester 里到底返回什么 / 会不会卡住
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sourin_spike/ui/widgets/provider_name.dart';

void main() {
  testWidgets('providerDisplayName 的真实行为（cycani）', (t) async {
    var done = false;
    String? got;
    Object? err;
    // ignore: unawaited_futures
    providerDisplayName('cycani').then((v) {
      done = true;
      got = v;
    }).catchError((e) {
      done = true;
      err = e;
    });

    for (var i = 0; i < 10; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
    debugPrint('[PROBE2] done=' + done.toString() + ' got=' + got.toString() + ' err=' + err.toString());
    if (!done) {
      debugPrint('[PROBE2] ★★ 卡住了 —— listProviders() 这个 future 永不完成');
    }
  });
}
