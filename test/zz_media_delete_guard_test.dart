// ═══════════════════════════════════════════════════════════════════════
//  Owner 1009 ⑬：本地缓存删除的**路径穿越防护**（安全硬要求）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么这份必须存在（lead 明令）
// ```text
// 删缓存是真删、不可逆，而"文件名"是完全不受控的输入：
// 扫盘读到的是一个目录里的文件，而那个目录名/文件名可能来自
// 旁文件、用户手拷、乃至构造出来的 `..`。
// ⇒ 判据只有一条：**只允许删 <作品目录>/ 里的文件**。
// ```
//
// # 仪器自检（防假绿）
//   D-0 先证明 `resolveDeletable` 在**正常文件名**上返回非 null ——
//   否则后面那些"全部被拒绝"可能是判据写坏了。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/ui/cache_page.dart';

Directory _sandbox() {
  final p =
      '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}sourin_media_del';
  final d = Directory(p);
  if (!d.isAbsolute) fail('★ 沙盒必须是绝对路径，实际 = $p');
  d.createSync(recursive: true);
  return d;
}

void main() {
  late Directory root;
  late Directory work;

  setUp(() {
    root = _sandbox();
    for (final e in root.listSync()) {
      e.deleteSync(recursive: true);
    }
    work = Directory('${root.path}${Platform.pathSeparator}某剧')
      ..createSync(recursive: true);
  });

  tearDownAll(() {
    final d = Directory(
        '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}sourin_media_del');
    if (!d.isAbsolute) fail('★ 清理路径必须是绝对路径');
    if (d.existsSync()) d.deleteSync(recursive: true);
  });

  test('D-0 自检：正常文件名必须被判为「可删」', () {
    final f = CachedDelete.resolveDeletable(work.path, '第01集.mp4');
    expect(f, isNotNull, reason: '★ 仪器自检：普通文件名必须通过');
    expect(f!.path, endsWith('第01集.mp4'));
  });

  test('D-1 穿越文件名一律被拒（一个都不许漏）', () {
    final evil = <String>[
      r'..\..\..\Windows\System32\drivers\etc\hosts',
      '../../../Windows/win.ini',
      r'..\..\evil.mp4',
      r'sub\第01集.mp4',
      'sub/第01集.mp4',
      '..',
      '.',
      '',
      r'C:\Windows\win.ini',
      'C:evil.mp4',
    ];
    for (final name in evil) {
      expect(CachedDelete.resolveDeletable(work.path, name), isNull,
          reason: '★★★ 越界文件名必须被拒绝：$name');
    }
  });

  test('D-2 真删只发生在作品目录内', () async {
    // 作品目录内的一个真文件 + 目录外的一个"诱饵"
    final inside = File('${work.path}${Platform.pathSeparator}第01集.mp4')
      ..writeAsBytesSync(List<int>.filled(16, 1));
    final outside = File('${root.path}${Platform.pathSeparator}别删我.txt')
      ..writeAsBytesSync(List<int>.filled(16, 2));

    final ok = await CachedDelete.deleteEpisodeFile(work.path, '第01集.mp4');
    expect(ok, isTrue, reason: '★ 目录内的文件必须真能删掉');
    expect(inside.existsSync(), isFalse);
    expect(outside.existsSync(), isTrue, reason: '★★★ 目录外的东西必须纹丝不动');

    // ★ 越界的那个：调用删不掉任何东西，且**不**把外面的文件删掉
    final bad = await CachedDelete.deleteEpisodeFile(
      work.path,
      '..${Platform.pathSeparator}别删我.txt',
    );
    expect(bad, isFalse, reason: '★★★ 越界请求必须删不掉任何东西');
    expect(outside.existsSync(), isTrue,
        reason: '★★★ ★ 越界删除必须被拦住（这是这一整份测试的判据）');
  });

  test('D-3 批量删：返回真实删掉的个数与字节', () async {
    final eps = <CachedEpisode>[];
    for (final n in <String>['第01集.mp4', '第02集.mp4']) {
      File('${work.path}${Platform.pathSeparator}$n')
          .writeAsBytesSync(List<int>.filled(1024, 3));
      eps.add(CachedEpisode(fileName: n, bytes: 1024, isComplete: true));
    }
    final r = await CachedDelete.deleteEpisodes(work.path, eps);
    expect(r.$1, 2, reason: '★ 两个都要删掉');
    expect(r.$2, 2048, reason: '★ 字节数按扫盘读数累计');
  });

  test('D-4 半成品 .part 与同名 .ts 一起清掉（与队列那套后缀一致）', () async {
    for (final suffix in <String>['', '.part', '.ts', '.ts.part']) {
      File('${work.path}${Platform.pathSeparator}第03集.mp4$suffix')
          .writeAsBytesSync(const <int>[1]);
    }
    final ok = await CachedDelete.deleteEpisodeFile(work.path, '第03集.mp4');
    expect(ok, isTrue);
    final left = Directory(work.path)
        .listSync()
        .map((e) => e.path.split(Platform.pathSeparator).last)
        .where((n) => n.startsWith('第03集'))
        .toList();
    expect(left, isEmpty, reason: '★★★ 四个产物必须全部清掉，实际还剩 $left');
  });
}
