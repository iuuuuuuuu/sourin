// ZZ-CR-DL · CR-16 · 作品目录名目录穿越回归测试
//
// 缺陷：DownloadDir.forWork(title) 直接把 ClipDownloader.safeName(title) 当目录名，
//       而 safeName 只取路径分隔符那一段（raw.split(RegExp(r'[\\/]')).last），
//       对 '.' 与 '..' **原样返回**。于是 title='..' 时目录变成
//       '<下载根>/..' = **下载根的上级目录**；配合 DownloadQueue.removeWork(
//       force:true) 里的 Directory.delete(recursive:true) ⇒ 可以把下载根连同
//       上级目录整棵删掉。
//
// 判据（在真机上会红，见报告的 RED 输出）：
//   forWork('..') 的结果路径必须落在 root() 之下（root 是它的祖先），
//   且**不等于** root() 本身；forWork('.') 同理；两者还必须互不相同。
//
// 本文件所有路径都用 Platform.pathSeparator 拼 —— CR-25 同款铁律。
//
// 跑法：flutter test test/zz_cr_dl_c16_workdir_test.dart --concurrency=1

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/download_dir.dart';


/// 把路径按 . / .. 段**真解析**成规范形式。
///
/// ★ 为什么必须这么做：字符串前缀比较是假门禁 ——
///   '<root>' + Platform.pathSeparator + '..' 以 '<root>' 开头（startsWith 为真），
///   但它在文件系统里指的是 root 的**上级**。缺陷代码就是这样把断言全骗过去的。
/// 目录穿越必须按解析后的路径判断，字符串比较看不出来。
String _normalize(String p) {
  final norm = p.replaceAll(String.fromCharCode(92), '/');
  final drive = norm.length >= 2 && norm[1] == ':' ? norm.substring(0, 2) : '';
  final body = drive.isEmpty ? norm : norm.substring(2);
  final out = <String>[];
  for (final seg in body.split('/')) {
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') {
      if (out.isNotEmpty) out.removeLast();
      continue;
    }
    out.add(seg);
  }
  return drive + '/' + out.join('/');
}

String _sandboxRoot() => Directory(
        '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}cr_dl_c16')
    .path;

/// 根目录里再垫一个「上级」层，这样 .. 一旦生效就会指向一个真实存在的目录，
/// 我们能在磁盘上**看见**它，而不是只比对字符串。
Future<String> _freshRoot(String tag) async {
  final d = Directory(
      '${_sandboxRoot()}${Platform.pathSeparator}$tag${Platform.pathSeparator}下载根');
  if (await d.exists()) await d.delete(recursive: true);
  await d.create(recursive: true);
  return d.path;
}

void main() {
  late String rootPath;

  setUp(() async {
    rootPath = await _freshRoot('case');
    DownloadDir.setConfiguredDir(rootPath);
    DownloadDir.debugReset();
  });

  tearDown(() {
    DownloadDir.debugReset();
  });

  test('★ forWork(\u0027.\u0027) 不得等于下载根本身', () async {
    final r = await DownloadDir.root();
    final d = await DownloadDir.forWork('.');
    debugPrint('CR-16 根=' + r + ' dot=' + d + ' 规范化后=' + _normalize(d));
    final nd = _normalize(d);
    expect(nd, isNot(equals(_normalize(r))),
        reason: '★★ forWork(\u0027.\u0027) 拿到的是下载根本身 ⇒ removeWork(force) 会把下载根连同里面所有作品一起删掉');
  }, timeout: const Timeout(Duration(minutes: 2)));


  test('★ forWork(\u0027..\u0027) 不得逃出下载根', () async {
    final r = await DownloadDir.root();
    final d = await DownloadDir.forWork('..');
    final nr = _normalize(r);
    final nd = _normalize(d);
    debugPrint('CR-16 根=' + r + ' dotdot=' + d + ' 规范化后=' + nd);
    expect(nd, isNot(equals(nr)), reason: '★★ 规范化后等于下载根本身');
    expect(nd.startsWith(nr + '/'), isTrue,
        reason: '★★ forWork(\u0027..\u0027) 逃出了下载根：根=' + r + ' 目录=' + d +
            ' ⇒ 规范化后指向 root 的上级：' + nd);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('★ forWork 的结果必须真在根下面建出目录（不能在盘上凭空指向别处）', () async {
    final r = await DownloadDir.root();
    for (final t in <String>['.', '..']) {
      final d = await DownloadDir.forWork(t);
      expect(Directory(d).existsSync(), isTrue,
          reason: 'forWork(' + t + ') 应建出目录 ' + d);
      expect(_normalize(d).startsWith(_normalize(r) + '/'), isTrue,
          reason: '★★ forWork(' + t + ') 逃出下载根：' + d +
              ' ⇒ 规范化后=' + _normalize(d));
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('★ 退化标题（空白 / . / ..）一律不得逃出下载根', () async {
    final r = _normalize(await DownloadDir.root());
    for (final t in <String>['', '   ', '.', '..']) {
      final d = await DownloadDir.forWork(t);
      debugPrint('CR-16 标题=[' + t + '] ⇒ ' + d + ' 规范化后=' + _normalize(d));
      expect(_normalize(d).startsWith(r + '/'), isTrue,
          reason: '★★ 标题 [' + t + '] 让作品目录逃出下载根 ⇒ ' + d);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('★★ 真删一次：对 forWork(\u0027..\u0027) 的目录做 recursive 删除时不得动到下载根', () async {
    // 上级目录里放一个哨兵：目录穿越一旦生效，删 .. 会把它连根一起带走。
    final sep = Platform.pathSeparator;
    final parent = Directory(rootPath.substring(0, rootPath.lastIndexOf(sep)));
    final sentinel = File(parent.path + sep + 'CR16 上级哨兵.txt');
    await sentinel.writeAsString('别删我', flush: true);
    final inside = await DownloadDir.forWork('正常剧');
    await File(inside + sep + '第01集.mp4').writeAsBytes(<int>[1, 2, 3]);

    final d = await DownloadDir.forWork('..');
    debugPrint('CR-16 要删的目录=' + d + ' 下载根=' + rootPath);
    await Directory(d).delete(recursive: true);

    expect(Directory(rootPath).existsSync(), isTrue,
        reason: '★★ 删除 forWork(..) 的目录把**下载根本身**删掉了');
    expect(File(inside + sep + '第01集.mp4').existsSync(), isTrue,
        reason: '★★ 删除 forWork(..) 的目录把别的作品也带走了');
    expect(sentinel.existsSync(), isTrue,
        reason: '★★ 删除 forWork(..) 的目录把下载根的**上级目录**删掉了：' +
            sentinel.path);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('★ 正常剧名不受影响（不能为了挡 . / .. 把普通名字也改了）', () async {
    final r = await DownloadDir.root();
    final d = await DownloadDir.forWork('无职转生');
    expect(d, r + Platform.pathSeparator + '无职转生');
    expect(Directory(d).existsSync(), isTrue, reason: '★ 目录必须真被建出来');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
