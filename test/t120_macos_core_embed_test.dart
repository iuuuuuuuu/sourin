// ═══════════════════════════════════════════════════════════════════════
//  ★★★ macOS 产物必须真的带上 Rust 核心（libsourin_core.dylib）
// ═══════════════════════════════════════════════════════════════════════
//
// # 怎么发现的（这是**产品级**缺陷，不是测试问题）
// 2026-10-08 排查 macOS CI 时搜 sourin_core：
//   · macOS 构建日志        → 零命中
//   · macos/ 整棵目录树      → 零命中
// ⇒ 产出的 sourin_spike.app 里**根本没有**这颗 dylib。
//
// 而 lib/core/ffi.dart 的 _openLibrary() 用**裸文件名**打开：
//   macOS / iOS → DynamicLibrary.open('libsourin_core.dylib')
// 裸名走 dyld 搜索路径（@rpath / DYLD_* / 系统目录），**不会**自动去
// .app/Contents/Frameworks/ 翻 —— 那个目录只对「二进制里带 LC_RPATH」
// 的调用方生效，管不到 dart:ffi 运行时用裸名发起的 dlopen。
// ⇒ macOS 版能启动、窗口能出来，但**所有核心功能不可用**，
//   连 providers 列表都拿不到，用户只看到一个错误页。
//
// # 为什么 CI 一直是绿的
// 「核验产物」那一步只查 entitlements（network.client / network.server），
// 查不出「包里少了核心库」。
// ★ 这与 Android 那次的 grep LEANBACK_LAUNCHER 是同一种病：
//   门禁查的是**别的东西**，所以它绿得毫无意义。
//
// # 修法（两处，必须成对）
// ① macos/Runner.xcodeproj/project.pbxproj
//    新增一个 PBXShellScriptBuildPhase「Embed Rust Core」，
//    挂在 Runner target 的 buildPhases 末尾，把
//    rust/sourin_core/target/release/libsourin_core.dylib
//    拷进 BUILT_PRODUCTS_DIR / FRAMEWORKS_FOLDER_PATH 下。
//    （对照物：Windows 侧的 windows/CMakeLists.txt 早就在干这件事。）
// ② lib/core/ffi.dart
//    macOS 分支先按**包内绝对路径**找
//    <exe>/../Frameworks/libsourin_core.dylib，找不到才退回裸名。
//    ★ 只做 ① 不够：裸名 dlopen 不认 Frameworks；
//      只做 ② 也不够：包里压根没有这个文件。
//
// # 本文件怎么测（不依赖 macOS）
// A) 源码守卫 —— 解析 pbxproj，断言那个阶段存在、挂在正确的 target 上、
//    且正文确实是「拷贝」而不是「检查完就退出」。
// B) 行为验证 —— 把 shellScript 从 pbxproj 里**反转义后真跑一遍**：
//    造一棵假的 <tmp>/macos + <tmp>/rust/sourin_core/target/release/，
//    设好 SRCROOT / BUILT_PRODUCTS_DIR / FRAMEWORKS_FOLDER_PATH，
//    断言 dylib **真的落到** out/sourin_spike.app/Contents/Frameworks/。
//    ★ 这才是「脚本写对了」的证据 —— 光看字符串看不出 set -e 里
//      某一步会不会提前退出、路径拼错没拼错。
// C) 路径解析 —— SourinCore.debugBundledDylibPathFor() 在**任意平台**
//    都能对着一棵假的 .app 树给出正确结果
//    （macOS 的逻辑不该只能在 macOS 上测）。
//
// # 反向验证（本文件真能抓到缺陷吗）
// ① 把 pbxproj 里那条 buildPhases 引用删掉 ⇒ 用例①必须转红（已实测）。
// ② 把 shellScript 的 cp -f 换成 echo skip ⇒ 用例④必须转红（已实测）。
// ③ 把 ffi.dart 里 _bundledDylibPath() 的调用删掉 ⇒ 用例⑦必须转红（已实测）。
// ★ 本仓铁律：新测试必须证明它**能失败**，否则只是装饰。
//
// 跑法（纯 Dart/IO，不需要 native-media、不需要 macOS）：
//   flutter test test/t120_macos_core_embed_test.dart --reporter expanded

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:sourin_spike/core/ffi.dart';

/// pbxproj 里那个阶段的 UUID（改动前全文件不含这个值）
const _kPhaseUuid = '5A0E1F3C2B7D4E6A9C8F1023';

/// Runner target 的 UUID
const _kRunnerTarget = '33CC10EC2044A3C60003C045';

/// 核心库文件名（macOS 上 Cargo 产出的是 libsourin_core.dylib）
const _kDylib = 'libsourin_core.dylib';

String _readPbxproj() =>
    File('macos/Runner.xcodeproj/project.pbxproj').readAsStringSync();

/// 把 pbxproj 里 "..." 形式的 shellScript 反转义回真正的脚本
///
/// pbxproj 是「OpenStep plist 子集」，字符串里的换行写成**字面两字符**
/// 反斜杠 + n。顺序要紧：先换行、再引号、最后反斜杠，否则会把已经
/// 处理过的内容再拆一次。
String _unescape(String s) {
  final out = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (s[i] != '\\' || i + 1 >= s.length) {
      out.write(s[i]);
      continue;
    }
    final n = s[i + 1];
    if (n == 'n') {
      out.write('\n');
    } else if (n == '"') {
      out.write('"');
    } else if (n == '\\') {
      out.write('\\');
    } else {
      out.write(n);
    }
    i++;
  }
  return out.toString();
}

/// 从 pbxproj 里抠出 Embed Rust Core 阶段的 shellScript 正文
String _extractScript(String pbx) {
  final at = pbx.indexOf('$_kPhaseUuid /* Embed Rust Core */ = {');
  expect(
    at,
    greaterThan(-1),
    reason: '★ pbxproj 里找不到 Embed Rust Core 阶段对象 —— '
        '说明这个阶段被删了，macOS 产物又会缺核心库',
  );
  final tail = pbx.substring(at);
  final m = RegExp(r'shellScript = "([\s\S]*?)";\r?\n').firstMatch(tail);
  expect(m, isNotNull, reason: '★ Embed Rust Core 阶段里没有 shellScript');
  return _unescape(m!.group(1)!);
}

/// Windows 路径 → POSIX 风格（git-bash 会把反斜杠当转义符）
String _posix(String p) => p.replaceAll('\\', '/');

/// 找一个能跑 POSIX shell 的解释器；找不到返回 null
///
/// ★ 为什么要探测而不是写死 /bin/sh：本机（Windows）没有 /bin/sh，
///   只有 git-bash；而 macOS/Linux 上 /bin/sh 一定有。
///   探不到就 skip（下沉到用例内，不用 skip: —— 本仓教训：
///   setUpAll 在整文件 skip 时**仍会执行**，throw 出来就是一条红）。
String? _findShell() {
  if (!Platform.isWindows) {
    return File('/bin/sh').existsSync() ? '/bin/sh' : null;
  }
  const candidates = <String>[
    r'D:\APP\Git\bin\bash.exe',
    r'C:\Program Files\Git\bin\bash.exe',
    r'C:\Program Files (x86)\Git\bin\bash.exe',
  ];
  for (final p in candidates) {
    if (File(p).existsSync()) return p;
  }
  return null;
}

/// 造一棵假的构建树
///
/// 目录形状照抄真实工程：
///   <root>/macos/                     ← Xcode 的 SRCROOT
///   <root>/rust/sourin_core/target/release/libsourin_core.dylib
///   <root>/out/                       ← BUILT_PRODUCTS_DIR
Directory _fakeTree({String? dylibRel}) {
  final root = Directory.systemTemp.createTempSync('t120_');
  addTearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });
  Directory('${root.path}/macos').createSync(recursive: true);
  Directory('${root.path}/out').createSync(recursive: true);
  if (dylibRel != null) {
    final f = File('${root.path}/$dylibRel');
    f.parent.createSync(recursive: true);
    f.writeAsStringSync('FAKE-DYLIB-CONTENT');
  }
  return root;
}

/// 在假树里跑脚本，返回 (exitCode, stdout+stderr)
Future<(int, String)> _runScript(
  Directory root,
  String shell,
  String script,
) async {
  final sh = File('${root.path}/embed.sh')..writeAsStringSync(script);
  final r = await Process.run(
    shell,
    <String>[_posix(sh.path)],
    environment: <String, String>{
      'SRCROOT': _posix('${root.path}/macos'),
      'BUILT_PRODUCTS_DIR': _posix('${root.path}/out'),
      'FRAMEWORKS_FOLDER_PATH': 'sourin_spike.app/Contents/Frameworks',
    },
  );
  return (r.exitCode, '${r.stdout}${r.stderr}');
}

/// 脚本应该把 dylib 放到这里
File _dest(Directory root) => File(
  '${root.path}/out/sourin_spike.app/Contents/Frameworks/$_kDylib',
);

void main() {
  late String pbx;
  late String script;

  setUpAll(() {
    pbx = _readPbxproj();
    script = _extractScript(pbx);
  });

  group('★ macOS：产物必须带上 Rust 核心', () {
    test('① ★★★ pbxproj 把 Embed Rust Core 挂在了 Runner target 的 buildPhases 上', () {
      final t = pbx.indexOf('$_kRunnerTarget /* Runner */ = {');
      expect(t, greaterThan(-1), reason: '★ Runner target 不见了 —— 锚点失效');
      final tail = pbx.substring(t);

      // buildPhases 数组的结束位置
      final end = tail.indexOf('\n\t\t\t);');
      expect(end, greaterThan(-1), reason: '★ Runner target 的 buildPhases 收尾没找到');
      final phases = tail.substring(0, end);

      final ref = phases.contains('$_kPhaseUuid /* Embed Rust Core */');
      // ignore: avoid_print
      print('T120|① Runner buildPhases 引用 Embed Rust Core = $ref');
      expect(
        ref,
        isTrue,
        reason: '★ Embed Rust Core 阶段**没挂上** Runner target ⇒ '
            '它永远不会执行 ⇒ .app 里没有 libsourin_core.dylib ⇒ '
            'macOS 版所有核心功能不可用（这正是本次修的缺陷）',
      );
    });

    test('② ★★★ 脚本确实在「拷贝」核心库，而不是只检查', () {
      // 判据是「有 cp 到 DEST」，不是「有提到 dylib」——
      // 后者在有 bug 的版本里也成立（它只是找不到就 warning）。
      final hasCp = script.contains('cp -f "\$CORE" "\$DEST"');
      final destUsesFrameworks = script.contains(
        'DEST="\${BUILT_PRODUCTS_DIR}/\${FRAMEWORKS_FOLDER_PATH}/$_kDylib"',
      );
      // ignore: avoid_print
      print('T120|② cp 到 DEST = $hasCp，DEST 指向 Frameworks = $destUsesFrameworks');
      expect(
        hasCp,
        isTrue,
        reason: '★ 脚本里没有把核心库拷进 DEST ⇒ .app 里不会有这颗 dylib',
      );
      expect(
        destUsesFrameworks,
        isTrue,
        reason: '★ DEST 没指向 FRAMEWORKS_FOLDER_PATH ⇒ 就算拷了也不在 dyld 认的位置',
      );
    });

    test('③ ★★ 找不到核心库时是 warning + exit 0（对齐 Windows 的约定）', () {
      /*
       * ★ 这条是**故意**要求「不报错」的：Windows 的 CMakeLists 同样只
       *   message(WARNING ...) 不 fail。本仓约定是「允许没编核心库时构建
       *   仍能跑通」，真正的门禁放在 CI 的「核验产物」那一步。
       *   这里守住它，免得有人把 warning 改成 error 之后本地开发被卡死。
       */
      final warn = script.contains('warning: sourin_core dylib not found');
      // ignore: avoid_print
      print('T120|③ 缺失时打 warning = $warn');
      expect(warn, isTrue, reason: '★ 缺失路径没有可读提示 ⇒ 构建日志里看不出来');

      final missBlock = script.indexOf('warning: sourin_core dylib not found');
      final after = script.substring(missBlock);
      expect(
        after.contains('exit 0'),
        isTrue,
        reason: '★ 找不到核心库时没有 exit 0 ⇒ 本地没编 Rust 就会构建失败，'
            '与 Windows 侧行为不一致',
      );
      expect(
        after.contains('exit 1'),
        isFalse,
        reason: '★ 找不到核心库时 exit 1 ⇒ 与 Windows 侧（只 warning）不一致；'
            '要加硬门禁请加在 CI 的「核验产物」里',
      );
    });

    test('④ ★★★ 真跑脚本：dylib 在 target/release/ 时必须被拷进 .app', () async {
      final shell = _findShell();
      if (shell == null) {
        markTestSkipped('本机没有可用的 POSIX shell（Windows 上需要 git-bash）');
        return;
      }
      final root = _fakeTree(
        dylibRel: 'rust/sourin_core/target/release/$_kDylib',
      );
      final (code, out) = await _runScript(root, shell, script);
      final dest = _dest(root);
      // ignore: avoid_print
      print(
        'T120|④ exit=$code，DEST 存在=${dest.existsSync()}，'
        '内容=${dest.existsSync() ? dest.readAsStringSync() : "(无)"}',
      );
      expect(code, 0, reason: '★ 脚本非零退出：$out');
      expect(
        dest.existsSync(),
        isTrue,
        reason: '★ 核心库**没有**落进 Contents/Frameworks ⇒ '
            'macOS 版会启动但所有核心功能不可用。脚本输出：$out',
      );
      expect(dest.readAsStringSync(), 'FAKE-DYLIB-CONTENT');
    });

    test('⑤ ★★ 真跑脚本：只在 target/<triple>/release/ 时也要能回退找到', () async {
      final shell = _findShell();
      if (shell == null) {
        markTestSkipped('本机没有可用的 POSIX shell（Windows 上需要 git-bash）');
        return;
      }
      // 交叉编译（--target aarch64-apple-darwin）时产物在带 triple 的子目录里
      final root = _fakeTree(
        dylibRel:
            'rust/sourin_core/target/aarch64-apple-darwin/release/$_kDylib',
      );
      final (code, out) = await _runScript(root, shell, script);
      final dest = _dest(root);
      // ignore: avoid_print
      print('T120|⑤ exit=$code，DEST 存在=${dest.existsSync()}');
      expect(code, 0, reason: '★ 脚本非零退出：$out');
      expect(
        dest.existsSync(),
        isTrue,
        reason: '★ 带 triple 的产物路径没被回退分支覆盖 ⇒ '
            '用 --target 交叉编译出来的核心库会被静默丢掉。脚本输出：$out',
      );
    });

    test('⑥ ★★ 真跑脚本：完全没有核心库时不得失败，也不得造出空文件', () async {
      final shell = _findShell();
      if (shell == null) {
        markTestSkipped('本机没有可用的 POSIX shell（Windows 上需要 git-bash）');
        return;
      }
      final root = _fakeTree(); // 不放 dylib
      final (code, out) = await _runScript(root, shell, script);
      final dest = _dest(root);
      // ignore: avoid_print
      print('T120|⑥ exit=$code，DEST 存在=${dest.existsSync()}');
      expect(code, 0, reason: '★ 缺核心库时脚本失败了：$out');
      expect(
        out.contains('warning: sourin_core dylib not found'),
        isTrue,
        reason: '★ 缺核心库时没有可读提示，日志里看不出问题：$out',
      );
      expect(
        dest.existsSync(),
        isFalse,
        reason: '★ 缺核心库却造出了 DEST ⇒ 空文件比没有更糟（dlopen 会报坏文件）',
      );
    });

    test('⑦ ★★★ Dart 侧先按包内绝对路径找（裸名 dlopen 不认 Frameworks）', () {
      final src = File('lib/core/ffi.dart').readAsStringSync();
      final at = src.indexOf('static DynamicLibrary _openLibrary()');
      expect(at, greaterThan(-1), reason: '★ _openLibrary 不见了 —— 锚点失效');
      final body = src.substring(
        at,
        src.indexOf('static String? _bundledDylibPath'),
      );

      final callsBundled = body.contains('_bundledDylibPath()');
      // ignore: avoid_print
      print('T120|⑦ macOS 分支先试包内路径 = $callsBundled');
      expect(
        callsBundled,
        isTrue,
        reason: '★ macOS 分支没有先试包内绝对路径 ⇒ 直接退回裸名 ⇒ '
            'dlopen 走 dyld 搜索路径，不会去 Contents/Frameworks 翻 ⇒ '
            '就算 Xcode 把 dylib 拷进去了也加载不到',
      );
      expect(
        body.contains("DynamicLibrary.open('libsourin_core.dylib')"),
        isTrue,
        reason: '★ 裸名回退被删了 ⇒ 开发机（dylib 装在系统路径）会加载不到',
      );
    });

    test('⑧ ★★★ 包内路径解析：任意平台都能对着假的 .app 树给出正确结果', () {
      final root = Directory.systemTemp.createTempSync('t120_app_');
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      final exe = '${root.path}/sourin_spike.app/Contents/MacOS/sourin_spike';
      File(exe).parent.createSync(recursive: true);

      // 场景 1：dylib 在正确位置 ⇒ 必须解析出来
      final good =
          File(
            '${root.path}/sourin_spike.app/Contents/Frameworks/$_kDylib',
          )..createSync(recursive: true);
      final hit = SourinCore.debugBundledDylibPathFor(exe);
      // ignore: avoid_print
      print('T120|⑧ 命中 = $hit');
      expect(hit, isNotNull, reason: '★ 包里有 dylib 却解析不出来 ⇒ 修法无效');
      expect(File(hit!).existsSync(), isTrue, reason: '★ 返回的路径不存在：$hit');
      expect(
        hit.replaceAll('\\', '/').endsWith('/Contents/Frameworks/$_kDylib'),
        isTrue,
        reason: '★ 解析到的不是 Contents/Frameworks 下的那颗：$hit',
      );

      // 场景 2：删掉 ⇒ 必须返回 null（好退回裸名，保持报错文本不变）
      good.deleteSync();
      final miss = SourinCore.debugBundledDylibPathFor(exe);
      // ignore: avoid_print
      print('T120|⑧ 缺失 = $miss');
      expect(
        miss,
        isNull,
        reason: '★ 包内没有 dylib 时没有返回 null ⇒ '
            '会去 open 一个不存在的路径，报错文本与原来不同，'
            'test/t74_perf_synth_test.dart:484 的「真因是缺核心库」判据会被打破',
      );
    });

    test('⑨ ★★ pbxproj 保持纯 ASCII，且行尾不许混合', () {
      /*
       * ★ 为什么守「纯 ASCII」：pbxproj 是 Xcode 生成/读写的文件，原文件
       *   是纯 ASCII。往里塞中文注释会变成非 ASCII —— 与 Xcode 原形状不一致，
       *   且本仓 .gitattributes 是 `* text=auto`，属性行本身又只有注释，
       *   任何形状变化都可能让 Xcode 的 diff 变成整文件重写。
       *   所以那个阶段的 shellScript 正文刻意写成英文。
       *
       * ★ 为什么只守「不混合」而不是「必须 CRLF」：
       *   `git check-attr` 实测 pbxproj 是 `text: auto` + `eol: unspecified`
       *   ⇒ **仓库里存的是 LF**（HEAD 那个 blob 实测 CRLF=0 / LF=728），
       *   Windows 检出时被 `core.autocrlf` 换成 CRLF（工作区实测 749 CRLF）。
       *   两边都合法 ⇒ 只能断言「要么全 LF 要么全 CRLF」，
       *   混行尾才是真问题（Xcode / git 都会把它当整文件改动）。
       */
      final nonAscii = pbx.codeUnits.where((c) => c > 127).length;
      final lf = '\n'.allMatches(pbx).length;
      final crlf = '\r\n'.allMatches(pbx).length;
      final bareLf = lf - crlf;
      final style = crlf == 0
          ? 'LF'
          : (bareLf == 0 ? 'CRLF' : '混合');
      // ignore: avoid_print
      print(
        'T120|⑨ 非 ASCII=$nonAscii，行尾=$style（LF=$lf，CRLF=$crlf，'
        '裸 LF=$bareLf）',
      );
      expect(
        nonAscii,
        0,
        reason: '★ pbxproj 里出现了非 ASCII 字符 ⇒ 与 Xcode 原文件的形状不一致',
      );
      expect(
        style,
        isNot('混合'),
        reason: '★ pbxproj 行尾混了（$crlf 处 CRLF + $bareLf 处裸 LF）⇒ '
            'Xcode 与 git 都会把它当成整文件改动',
      );
    });
  });
}
