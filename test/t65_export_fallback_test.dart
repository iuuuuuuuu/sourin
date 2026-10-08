// ═══════════════════════════════════════════════════════════════════════
//  task-24：导出落点「先探再写」的回归守卫
// ═══════════════════════════════════════════════════════════════════════
//
// 这条测试守的是两个**真机缺陷**（task-24 台账 A / B）：
// ```text
// A  设置 → 播放与下载 → 「导出为日志文件」
// B  设置 → 备份与恢复 → 「导出备份」
// ```
// 两者在 Android 上都点了没用：SAF 选目录（file_selector 的
// `getDirectoryPath`）返回的是**真实文件系统路径**（`/storage/emulated/0/Movies`），
// 而本应用没有 MANAGE_EXTERNAL_STORAGE、targetSdk=36 ⇒ dart:io 写它必失败：
// ```text
// A  PathAccessException: Cannot open file, path =
//    '/storage/emulated/0/Movies/sourin-log-20261004-150033.log'
//    (OS Error: Operation not permitted, errno = 1)
// B  SourinCoreException(other): 创建备份文件失败: Operation not permitted (os error 1)
// ```
//
// 修法 = `lib/ui/settings/export_dir.dart`：**真的写一次空文件再删掉**
//（`probeWritableFile`），探不通就换 `writableExportDir()` 给的兜底目录。
//
// 这里三层都测：
// ```text
// ① 探针本身：可写 → true 且不留垃圾；不可写 → false 且**不抛**
// ② 兜底目录：<dataDir>/exports 真被建出来、真能写（用 debugSetDataDir 隔离）
// ③ 源码契约：两个产品文件都**必须**走 probeWritableFile + writableExportDir，
//    且**不得**再出现「SAF 目录直接拼路径返回」那行旧写法
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/clip_download.dart';
import 'package:sourin_spike/ui/settings/export_dir.dart';

/// 拼路径（不依赖 `Platform.pathSeparator` 猜分隔符）
String j(String dir, String name) => '$dir${Platform.pathSeparator}$name';

/// 剥掉注释（`//` 与 `/* */`）—— 本项目踩过"注释让测试假绿"至少四次
String stripComments(String s) {
  final out = StringBuffer();
  var i = 0;
  while (i < s.length) {
    if (s.startsWith('//', i)) {
      while (i < s.length && s[i] != '\n') {
        i++;
      }
    } else if (s.startsWith('/*', i)) {
      i += 2;
      while (i < s.length && !s.startsWith('*/', i)) {
        i++;
      }
      i += 2;
    } else {
      out.write(s[i]);
      i++;
    }
  }
  return out.toString();
}

void main() {
  group('task-24 (1) 探针 probeWritableFile', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('t65_export_'));
    tearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('可写的路径 → true，且探针文件**被删掉**（不留垃圾）', () async {
      final p = j(tmp.path, '.probe-test.tmp');
      expect(await probeWritableFile(p), isTrue);
      expect(File(p).existsSync(), isFalse,
          reason: '探针文件必须删掉 —— 否则用户目录里会多出垃圾文件');
      expect(tmp.existsSync(), isTrue, reason: '目录本身不能被动过');
    });

    test('不可写的路径 → false，且**不抛**（异常必须被吃掉）', () async {
      // 父目录不存在 ⇒ 写入必失败
      final p = j(j(tmp.path, 'no-such-dir'), 'x.tmp');
      expect(await probeWritableFile(p), isFalse);
    });
  });

  group('task-24 (2) 兜底目录', () {
    late Directory tmp;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('t65_dir_');
      ClipDownloader.debugSetDataDir(tmp.path);
    });
    tearDown(() {
      ClipDownloader.debugSetDataDir(null);
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('appExportDir() = <dataDir>/exports，真建目录、真能写', () async {
      final d = await appExportDir();
      expect(d, j(tmp.path, 'exports'),
          reason: '必须落在数据目录下的 exports/（测试用 debugSetDataDir 隔离）');
      expect(Directory(d).existsSync(), isTrue, reason: '目录必须真的被建出来');
      final f = File(j(d, 'hello.log'));
      await f.writeAsString('hi', flush: true);
      expect(await f.length(), 2, reason: '★ 返回的目录必须**真的**能写');
    });

    test('writableExportDir() 返回的目录**真的**能写（探过再返回）', () async {
      final d = await writableExportDir();
      expect(d.path.isNotEmpty, isTrue);
      final f = File(j(d.path, 't65-write.log'));
      await f.writeAsString('x', flush: true);
      expect(await f.length(), 1);
      await f.delete();
      // 纯 dart 环境（flutter_test 无插件）下拿不到外部存储 ⇒ 只能是应用目录
      expect(d.userVisible, isFalse,
          reason: '测试环境没有 path_provider 插件 ⇒ 走应用目录分支');
    });
  });

  group('task-24 (2b) Android media 目录拼串（纯函数，钉死回归）', () {
    // ★ 这里守的是一个**真机上静默失效**的 bug：
    //   曾经拼成 <sdcard>/media/<包名>（少了 'Android' 段），
    //   而 /storage/emulated/0/media 在真机上不存在 ⇒ create() 抛 ⇒ 整条分支失效。
    final sep = Platform.pathSeparator;

    test('标准输入 → <sdcard>/Android/media/<包名>', () {
      final ext = '${sep}storage${sep}emulated${sep}0${sep}Android${sep}data'
          '${sep}app.sourin.sourin_spike${sep}files';
      expect(
        androidMediaDirFrom(ext),
        '${sep}storage${sep}emulated${sep}0${sep}Android${sep}media'
        '${sep}app.sourin.sourin_spike',
        reason: '★ 必须含 Android 段 —— 少了它就落到不存在的 /storage/emulated/0/media',
      );
    });

    test('★ 回归：结果里必须出现 Android 段，且不得出现 <sdcard>/media', () {
      final ext = '${sep}storage${sep}emulated${sep}0${sep}Android${sep}data'
          '${sep}com.example.app${sep}files';
      final got = androidMediaDirFrom(ext)!;
      expect(got.contains('$sep' 'Android' '$sep' 'media' '$sep'), isTrue,
          reason: '★ 拼串必须经过 Android/media');
      expect(got.contains('$sep' '0' '$sep' 'media' '$sep'), isFalse,
          reason: '★ 这就是那个 bug 的形状：<sdcard>/media/<pkg>');
    });

    test('形状不对 → null（不猜、不抛）', () {
      expect(androidMediaDirFrom(''), isNull);
      expect(androidMediaDirFrom('${sep}a${sep}b'), isNull);
      // 尾部不是 files 的（有些 ROM 会返回别的名字）⇒ 宁可不认
      expect(androidMediaDirFrom('${sep}sdcard${sep}Android${sep}data${sep}p${sep}other'), isNull);
      // data 段写错
      expect(androidMediaDirFrom('${sep}sdcard${sep}Android${sep}dat${sep}p${sep}files'), isNull);
    });
  });

  group('task-24 (3) 源码契约（两个产品文件都必须先探再写）', () {
    const files = <String>[
      'lib/ui/settings/playback_page.dart',
      'lib/ui/widgets/backup_panel.dart',
    ];

    test('★ 两处降级路径都调 probeWritableFile + writableExportDir', () {
      for (final p in files) {
        final code = stripComments(File(p).readAsStringSync());
        expect(code.contains('probeWritableFile('), isTrue,
            reason: '$p 必须**先探再写** —— 否则安卓上用户选了目录也写不进去');
        expect(code.contains('writableExportDir()'), isTrue,
            reason: '$p 的兜底目录必须来自 writableExportDir()（它保证可写）');
      }
    });

    test('★★ 旧写法必须消失：SAF 目录直接拼路径就 return', () {
      for (final p in files) {
        final code = stripComments(File(p).readAsStringSync());
        expect(
          code.contains('if (dir.isNotEmpty) return _join(dir, suggestedName);'),
          isFalse,
          reason: '★ $p 里那行就是缺陷本体（选了目录就当能写）—— 不许回来',
        );
      }
    });

    test('★ 设置页仍保留系统「保存」对话框优先（不得退回"规定好目录"）', () {
      final code = stripComments(
          File('lib/ui/settings/playback_page.dart').readAsStringSync());
      expect(code.contains('getSaveLocation'), isTrue,
          reason: '桌面端必须仍然弹系统保存框（原版行为）');
      expect(code.contains('getDirectoryPath'), isTrue,
          reason: 'Android 降级仍走系统目录选择器，不是手填路径');
    });
  });
}
