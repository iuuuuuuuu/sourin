// ══════════════════════════════════════════════════════════════════════
//  task-21 P1-30：截图**落盘规则**（纯 Dart，进**默认**套件）
// ══════════════════════════════════════════════════════════════════════
//
// # 为什么是纯 Dart（不挂 widget、不打 native-media 标签）
//
// 本文件守的是**落盘契约**：截图存哪个目录、叫什么名字、绝不覆盖旧图、
// 清缓存时不许被连坐。这四件事全在 `ClipDownloader` 的**纯静态函数**里，
// 不需要渲染、不需要 media_kit、不需要 libmpv
// ⇒ 放进默认套件（`flutter test test/`）天天跑。
//
// ★ 反面参照：`test/t63_shot_ui_test.dart` 那种**真渲染**断言必须标
//   `native-media`（挂真 PlayerPage ⇒ `Player(...)` ⇒ 加载 libmpv-2.dll
//   ⇒ flutter_tester 偶发 native 崩溃 c0000005 / 退出码 79，见
//   `.probe/native-media-tests.md`），而落盘规则与渲染无关
//   ⇒ 不该被那个标签连坐（连坐的后果：默认套件里截图契约**零覆盖**）。
//
// # 判据（与 `.probe/yamby/PLAN.md:263-267` 逐条对应）
//
// ```text
// ⑧ shotsDir() 在 debugSetDataDir(tmp) 后 = <tmp>/shots，且**目录被创建**
// ⑨ shotsDir() ≠ cacheDir() ≠ mpvCacheDir()（三个目录各司其职）
// ⑩ 文件名 shot-<yyyyMMdd>-<HHmmss>-<SSS>.jpg（毫秒精度）
// ⑪ 真写盘：3 字节 JPEG magic 0xFF 0xD8 0xFF 写进 shotsDir()，读回一致
// ```
//
// ★★ ⑨ 与「清空缓存不许动截图」是**同一条**判据的两半：
//   目录名不同只是「看起来分开了」，真正的证明是「删了缓存之后图还在」。
//   所以本文件两条都写：光看名字分不出来，要**真的删一次**。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:sourin_spike/core/clip_download.dart';

void main() {
  group('P1-30 截图落盘契约', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('t63_shot_');
      ClipDownloader.debugSetDataDir(tmp.path);
    });

    tearDown(() {
      ClipDownloader.debugSetDataDir(null);
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('⑧ shotsDir() = <dataDir>/shots，且**顺手建目录**', () async {
      expect(await ClipDownloader.dataDir(), tmp.path,
          reason: '★ 前置条件：debugSetDataDir 必须真的生效 —— 否则下面量的是 %APPDATA%');

      final dir = await ClipDownloader.shotsDir();
      expect(dir, '${tmp.path}${Platform.pathSeparator}shots',
          reason: '★★ 目录名是交付契约（PLAN.md:263 判据⑧）—— 用户要在这里找到自己的图，换名字等于换契约');
      expect(Directory(dir).existsSync(), isTrue,
          reason: '★★ 关键的另一半：shotsDir() 必须**建目录** —— 否则第一张截图会因为父目录不存在直接抛异常');
      expect(tmp.listSync().map((e) => e.path), contains(dir),
          reason: '★ 反向对照：目录必须真的落在 dataDir **里面**');
    });

    test('⑨ 三个目录互不相同：shots / clip-cache / mpv-cache', () async {
      final sep = Platform.pathSeparator;
      final shots = await ClipDownloader.shotsDir();
      final cache = await ClipDownloader.cacheDir();
      final mpv = await ClipDownloader.mpvCacheDir();

      expect(shots, '${tmp.path}${sep}shots');
      expect(cache, '${tmp.path}${sep}clip-cache');
      expect(mpv, '${tmp.path}${sep}mpv-cache');
      expect(shots, isNot(cache),
          reason: '★★★ 截图**绝不能**进 clip-cache —— clearCache() 会把它删空（PLAN.md:240-241 / clip_download.dart:481-490）');
      expect(shots, isNot(mpv),
          reason: '★ mpv 自己会滚动 mpv-cache ⇒ 放进去的图迟早被 mpv 收走');
      expect(cache, isNot(mpv),
          reason: '★ 后两个也不能混（缓存统计按目录算）');
    });

    test('⑩ 文件名：shot-<yyyyMMdd>-<HHmmss>-<SSS>.jpg（毫秒精度）', () {
      final n = DateTime(2026, 10, 4, 12, 15, 30, 842);
      final name = ClipDownloader.shotFileName(n);

      expect(name, matches(RegExp(r'^shot-\d{8}-\d{6}-\d{3}\.jpg$')),
          reason: '★★ 格式契约（PLAN.md:267 判据⑩逐字给的这条正则）');
      expect(name, 'shot-20261004-121530-842.jpg',
          reason: '★ 逐字比对：2026-10-04 12:15:30.842 ⇒ 上面这个名字');
      expect(name, startsWith('shot-'), reason: '★ 前缀是给用户看的分类');
      expect(name, endsWith('.jpg'),
          reason: '★ 后缀必须 .jpg —— 与 screenshot(format: image/jpeg) 同源');

      final later = ClipDownloader.shotFileName(
        DateTime(2026, 10, 4, 12, 15, 30, 843),
      );
      expect(later, isNot(name),
          reason: '★★ 只差 **1 毫秒**也必须不同名 —— 秒级时间戳在「连点两下」时会撞名，第二张**覆盖**第一张（clip_download.dart:436-440）');

      expect(ClipDownloader.shotFileName(n), name,
          reason: '★ 同一时刻两次调用必须同名（纯函数，无隐藏状态）');
      expect(ClipDownloader.shotFileName(n, suffix: 2),
          'shot-20261004-121530-842-2.jpg',
          reason: '★ 撞名兜底的后缀形态（调用方 uniqueShotFile 用它）');
      expect(ClipDownloader.shotFileName(n, suffix: 0), name,
          reason: '★ suffix 0 = 无后缀（不是 -0）');
    });

    test('⑪ 真写盘：3 字节 JPEG magic 写进 shotsDir()，读回字节一致', () async {
      final dir = await ClipDownloader.shotsDir();
      final f = await ClipDownloader.uniqueShotFile(
        Directory(dir),
        now: DateTime(2026, 10, 4, 12, 15, 30, 842),
      );
      const magic = <int>[0xFF, 0xD8, 0xFF];
      await f.writeAsBytes(magic, flush: true);

      expect(f.path, startsWith(dir),
          reason: '★ 落点必须在 shots 目录里（PLAN.md:267 判据⑪）');
      expect(f.path, endsWith('shot-20261004-121530-842.jpg'));
      final back = await File(f.path).readAsBytes();
      expect(back, magic,
          reason: '★★ 字节级相等 —— 这是「图真的写下去了」的最小证明');
      expect(await f.length(), greaterThan(0),
          reason: '★ 大小 > 0（PLAN.md:267 判据⑪原文）');
      expect(File(f.path).existsSync(), isTrue);
    });

    test('⑪b 撞名兜底：已占用则 -1、再占用则 -2；且**不建文件**', () async {
      final dir = Directory(await ClipDownloader.shotsDir());
      final n = DateTime(2026, 10, 4, 12, 15, 30, 842);
      final sep = Platform.pathSeparator;

      final first = await ClipDownloader.uniqueShotFile(dir, now: n);
      expect(first.path, '${dir.path}${sep}shot-20261004-121530-842.jpg');
      expect(await first.exists(), isFalse,
          reason: '★★ uniqueShotFile **只挑名字、不建文件**（clip_download.dart:455 逐字：返回尚未创建的 File）—— 若它顺手建了空文件，下面的写盘就变成「覆盖自己」');

      await first.writeAsBytes(const <int>[1], flush: true);
      final second = await ClipDownloader.uniqueShotFile(dir, now: n);
      expect(second.path, endsWith('-1.jpg'),
          reason: '★ 同一毫秒第二次调用必须退到 -1');

      await second.writeAsBytes(const <int>[2], flush: true);
      final third = await ClipDownloader.uniqueShotFile(dir, now: n);
      expect(third.path, endsWith('-2.jpg'), reason: '★ 第三次退到 -2');

      expect(File(first.path).existsSync(), isTrue,
          reason: '★★★ 第一张必须**还在**且内容未变 —— 撞名兜底的全部意义就是「绝不覆盖用户已有的图」');
      expect(await File(first.path).readAsBytes(), const <int>[1]);
      expect(await File(second.path).readAsBytes(), const <int>[2]);
    });

    test('★★ 清空缓存**不许**动截图（第三个目录存在的全部理由）', () async {
      final shots = Directory(await ClipDownloader.shotsDir());
      final cache = Directory(await ClipDownloader.cacheDir());
      final sep = Platform.pathSeparator;

      final shot = File('${shots.path}${sep}shot-20261004-121530-842.jpg');
      await shot.writeAsBytes(const <int>[0xFF, 0xD8, 0xFF], flush: true);
      final junk = File('${cache.path}${sep}old-clip.mp4');
      await junk.writeAsBytes(const <int>[0, 0, 0, 0], flush: true);

      final deleted = await ClipDownloader.clearCache();
      expect(deleted, greaterThanOrEqualTo(1),
          reason: '★ 阳性对照：clearCache() 必须**真的删了东西** —— 否则下面「截图还在」可能只是它什么都没干（假绿）');
      expect(junk.existsSync(), isFalse,
          reason: '★ clip-cache 里的文件确实被删了（证明清的是那个目录）');
      expect(shot.existsSync(), isTrue,
          reason: '★★★ 截图必须还在（PLAN.md:240-241 判据）—— 用户主动截的图不是缓存，点一次「清空缓存」就没了是**数据丢失**');
      expect(await shot.readAsBytes(), const <int>[0xFF, 0xD8, 0xFF],
          reason: '★ 不只是还在，内容也必须一字不差');
    });
  });
}
