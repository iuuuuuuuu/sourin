// ═══════════════════════════════════════════════════════════════════════
//  t72 —— 组播锁（MulticastLock）契约测试
// ═══════════════════════════════════════════════════════════════════════
//
// # 这组测试要证明什么
//
// ```text
// ① 非 Android 宿主（Windows / flutter test）上**不报错、不阻塞**扫描
// ② Android 分支真的会去调原生通道 sourin/net 的 acquireMulticastLock
// ③ 原生返回 false / 通道缺失时**只返回 false，不抛异常**（真机症状不能变成崩溃）
// ④ scope() 在正常返回**和**抛异常两条路径上都会释放（否则锁泄漏）
// ⑤ acquire 幂等（重复调用不会重复 acquire —— 原生侧 setReferenceCounted(false)）
// ```
//
// # 为什么能测「Android 分支」
//
// `Platform.isAndroid` 在 flutter test 里恒为 false（测试跑在 Windows 上），
// 所以 `MulticastLock.debugAndroidOverride` 提供强制开关 ——
// 不这么做的话，**真机上真正会跑的那条路一行都测不到**。
//
// # 这里**不测**什么（如实标注）
//
// ```text
// · 真机上这把锁到底有没有让组播收得到包 —— 本机没有真机，
//   模拟器是 QEMU 用户态网络（组播路径本身断的），无法证伪也无法证实。
//   证据缺口见 .probe/cast/TASK27-REPORT.md 与 lib/core/net/multicast_lock.dart 文件头。
// ```

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/net/multicast_lock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('sourin/net');

  /// 原生侧被调用的方法名序列（断言"到底发没发出去"）
  late List<String> calls;

  /// 原生返回值：null = 不实现（抛 MissingPluginException）
  bool? nativeAcquireResult;
  bool? nativeReleaseResult;

  void installNativeHandler({bool installed = true}) {
    if (!installed) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      return;
    }
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'acquireMulticastLock':
          return nativeAcquireResult;
        case 'releaseMulticastLock':
          return nativeReleaseResult ?? true;
      }
      throw MissingPluginException('未实现：${call.method}');
    });
  }

  setUp(() {
    calls = <String>[];
    nativeAcquireResult = true;
    nativeReleaseResult = true;
    MulticastLock.debugReset();
    installNativeHandler();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    MulticastLock.debugReset();
  });

  group('① 非 Android 宿主：不需要锁，且不能报错', () {
    test('acquire 返回 true（"已具备条件"），一个原生调用都不发', () async {
      // 前提检查：测试宿主确实不是 Android（否则这组测试没有意义）
      expect(MulticastLock.debugAndroidOverride, isFalse);

      final ok = await MulticastLock.acquire();

      expect(ok, isTrue, reason: '非 Android 上不应把"没有锁"当成失败');
      expect(MulticastLock.held, isFalse,
          reason: 'held 只在真的持有原生锁时才为 true');
      expect(calls, isEmpty, reason: '非 Android 不该碰 sourin/net 通道');
    });

    test('release 在非 Android 上是安全 no-op', () async {
      await MulticastLock.release();
      expect(calls, isEmpty);
    });

    test('scope 在非 Android 上照常执行 body 并返回其结果', () async {
      final v = await MulticastLock.scope(() async => 42);
      expect(v, 42);
      expect(calls, isEmpty);
    });
  });

  group('② Android 分支：真的调原生通道', () {
    setUp(() => MulticastLock.debugAndroidOverride = true);

    test('原生返回 true ⇒ held 变 true，且方法名正确', () async {
      final ok = await MulticastLock.acquire();

      expect(ok, isTrue);
      expect(MulticastLock.held, isTrue);
      expect(calls, ['acquireMulticastLock']);
      expect(MulticastLock.lastFailure, isNull);
    });

    test('release 会调原生 releaseMulticastLock，并把 held 归零', () async {
      await MulticastLock.acquire();
      await MulticastLock.release();

      expect(calls, ['acquireMulticastLock', 'releaseMulticastLock']);
      expect(MulticastLock.held, isFalse);
    });

    test('原生返回 false（无 Wi-Fi 硬件/权限被拒）⇒ false 且带原因，不抛', () async {
      nativeAcquireResult = false;

      final ok = await MulticastLock.acquire();

      expect(ok, isFalse);
      expect(MulticastLock.held, isFalse);
      expect(MulticastLock.lastFailure, contains('原生侧返回 false'));
    });

    test('★ 通道完全没注册（MissingPluginException）⇒ false，不抛异常', () async {
      installNativeHandler(installed: false);

      // 这里如果抛异常，真机上一次权限问题就会变成崩溃
      final ok = await MulticastLock.acquire();

      expect(ok, isFalse);
      expect(MulticastLock.held, isFalse);
      expect(MulticastLock.lastFailure, contains('未注册'));
    });

    test('★ 原生抛 PlatformException ⇒ 也吞掉，只返回 false', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        throw PlatformException(
          code: 'SecurityException',
          message: 'CHANGE_WIFI_MULTICAST_STATE 未声明',
        );
      });

      final ok = await MulticastLock.acquire();

      expect(ok, isFalse);
      expect(MulticastLock.lastFailure, contains('SecurityException'));
    });

    test('★ 幂等：连续 acquire 两次只调原生一次', () async {
      await MulticastLock.acquire();
      await MulticastLock.acquire();

      expect(calls, ['acquireMulticastLock'],
          reason: '原生侧 setReferenceCounted(false)，重复 acquire 会泄漏引用计数');
    });

    test('没持有时 release 不发调用（幂等）', () async {
      await MulticastLock.release();
      expect(calls, isEmpty);
    });
  });

  group('③ scope：异常路径也必须释放（否则锁泄漏）', () {
    setUp(() => MulticastLock.debugAndroidOverride = true);

    test('正常返回：进入时 acquire，退出时 release', () async {
      final v = await MulticastLock.scope(() async {
        // 体内应当处于持有状态
        expect(MulticastLock.held, isTrue);
        return 'done';
      });

      expect(v, 'done');
      expect(calls, ['acquireMulticastLock', 'releaseMulticastLock']);
      expect(MulticastLock.held, isFalse);
    });

    test('★ body 抛异常：异常照常冒泡，但锁**必须**已经释放', () async {
      await expectLater(
        MulticastLock.scope<void>(() async => throw StateError('扫描炸了')),
        throwsA(isA<StateError>()),
      );

      expect(MulticastLock.held, isFalse, reason: 'finally 必须释放');
      expect(calls, ['acquireMulticastLock', 'releaseMulticastLock']);
    });

    test('★ 拿不到锁时 scope 照常执行 body（调用方不必写两套分支）', () async {
      nativeAcquireResult = false;
      var ran = false;

      final v = await MulticastLock.scope(() async {
        ran = true;
        return 7;
      });

      expect(ran, isTrue);
      expect(v, 7);
      // 没持有 ⇒ release 不发调用
      expect(calls, ['acquireMulticastLock']);
    });
  });

  group('④ debugReset 清干净内部状态（测试隔离）', () {
    test('重置后 held / lastFailure / override 都回默认值', () async {
      MulticastLock.debugAndroidOverride = true;
      nativeAcquireResult = false;
      await MulticastLock.acquire();
      expect(MulticastLock.lastFailure, isNotNull);

      MulticastLock.debugReset();

      expect(MulticastLock.held, isFalse);
      expect(MulticastLock.lastFailure, isNull);
      expect(MulticastLock.debugAndroidOverride, isFalse);
    });
  });
}
