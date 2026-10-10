// ═══════════════════════════════════════════════════════════════════════
//  ★★★ CR-02 反向验证：构建后 Release 里的核心必须是**新编那颗**（2026-10-10）
// ═══════════════════════════════════════════════════════════════════════
//
// # 缺陷
//
//  `tools/run_client.ps1` 在 build **之前**把 Release 树里的 `sourin_core.dll`
//  备份到 %TEMP%，build **之后**只要两边大小不同，就把**旧件**盖回 Release 树
//  —— 于是客户端跑的是构建前的旧核心，而屏幕上只多一行黄色警告。
//  脚本注释写的恰好相反（说这是把刚编好的核心还原回去）。
//
// # ★ 那个注释的前提本身是假的（实测，不是推测）
//
//  ```text
//  windows/CMakeLists.txt:122-135
//    install(FILES .../rust/sourin_core/target/release/sourin_core.dll
//            DESTINATION INSTALL_BUNDLE_LIB_DIR COMPONENT Runtime)
//
//  install() 没有「按时间戳决定要不要拷」这种行为；
//  README:208-211 那套说法在本仓的 CMake 里找不到对应实现。
//  ⇒ 还原逻辑不但是多余的，它本身就是把旧件装回去的那个动作。
//  ```
//
// # 本文件怎么测（不跑真构建，也不碰仓库里的产物）
//
//  在临时目录搭一棵假树，跑的是 `run_client.ps1` 的**副本**，
//  再用**假的 flutter** 顶掉真 flutter —— 整条 build→校验逻辑秒级跑完。
//
//  ★ 铁律：`flutter build windows` 是父 agent 独占资源，本文件**绝不**调它。
//  注入方式：副本里写死真 flutter 路径的那一行被换成假 flutter 的路径。
//  真 flutter 路径在本机是存在的，所以不改这一行就一定会打到真 flutter
//  ⇒ 替换点找不到时**直接抛错停下**，绝不放行真构建。
//
//  ★ 只改副本：仓库里那份脚本**只被读**（腿 A 读源码、腿 B 跑副本）。

// # 两条腿
//
//  ① **腿 A（结构）**：源码里不再有「构建前备份 + 构建后还原」。
//     → 修之前真红（RED）。
//  ② **腿 B（行为）**：构建成功时，Release 树里的 DLL 必须是**新件**；
//     构建失败时，Release 树里已有的核心**不许被动**。
//
// ⚠ 腿 B **刻意不测「实现长什么样」**：脚本删掉还原、改成构建后
//   从 target/release 显式拷贝、或用别的等效手段，都应该过。
//   只钉**结果**（Release 里那颗是谁），免得门禁退化成对实现的迷信。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String kScriptPath = 'tools/run_client.ps1';
const String kStubName = 'stub_flutter.ps1';

/// 真 flutter 那一行在脚本里的**形状**（唯一注入点）。
///
/// ★ 跨平台（2026-10-10 预检）：原来是 `kRealFlutter = r'C:\Users\iuuuuuuuu\…'`
///   —— 那是**本机专属**路径：CI（macOS 跑 macOS、Windows 跑 windows-latest）
///   以及任何别人的机器上，`tools/run_client.ps1` 里那一行都**不是**这个值。
///   于是唯一注入点匹配不上 ⇒ 本文件 setUpAll 抛 StateError ⇒ 整文件红。
///   改成从**被读的那份脚本**里提取实际路径：注入点跟着脚本走，任何机器都成立。
final RegExp kFlutterAssignRe = RegExp(r'\$flutter\s*=\s*"([^"]*)"');

/// 从脚本源码里取出「$flutter = "…"」的实际路径；取不到返回 null。
String? realFlutterPathIn(String psCode) {
  return kFlutterAssignRe.firstMatch(psCode)?.group(1);
}

/// PowerShell 可执行文件：**不写死** `C:/Windows/System32/...`。
///
/// 依次试：① PATH 上的 pwsh（macOS 上真有）② PATH 上的 powershell
///         ③ Windows 的绝对路径（旧写法，只在 Windows 上命中）。
/// 三个都没有 ⇒ 返回 null，由调用方 [ensureHostPrerequisites] 打一行原因后
/// markTestSkipped（**不**降低断言：本文件的两条腿本来就只在「有 PowerShell
/// 且脚本里确实有那条写死的 flutter 路径」的机器上可测）。
String? _resolvePowerShell() {
  for (final exe in <String>['pwsh', 'powershell']) {
    try {
      final r = Process.runSync(exe, <String>['-NoProfile', '-Command', r'$PSVersionTable.PSVersion.Major']);
      if (r.exitCode == 0) return exe;
    } on ProcessException {
      // PATH 上没有这个可执行文件 —— 继续试下一个
    }
  }
  const String winAbs =
      'C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe';
  if (File(winAbs).existsSync()) return winAbs;
  return null;
}

/// 体积必须能区分开：否则「旧大小 == 新大小 ⇒ 不还原」那条分支
/// 会让测试看起来绿、其实根本没测到还原逻辑。
const int kStaleBytes = 100; // build 之前 Release 树里那颗（旧）
const int kFreshBytes = 733; // cargo 编出来那颗（新）
const int kStaleMark = 83; // 旧件每字节填 S
const int kFreshMark = 70; // 新件每字节填 F

/// 在 bytes 里找 pattern 的**字节**下标；找不到返回 -1。
///
/// （不能用 List.indexOf，那只找整块相等；也不能先 decode 成字符串，
///  那正是上面那条假红的成因。）
int _indexOfBytes(List<int> bytes, List<int> pattern) {
  if (pattern.isEmpty || pattern.length > bytes.length) return -1;
  final int limit = bytes.length - pattern.length;
  outer:
  for (int i = 0; i <= limit; i++) {
    for (int j = 0; j < pattern.length; j++) {
      if (bytes[i + j] != pattern[j]) continue outer;
    }
    return i;
  }
  return -1;
}

/// 文件是否**通体**由同一个字节组成（用来认出是哪一颗 DLL）。
bool _isAllBytes(String path, int mark) {
  final List<int> b = File(path).readAsBytesSync();
  for (final int x in b) {
    if (x != mark) return false;
  }
  return true;
}

/// PowerShell 源码去注释：只丢掉整行都是 `#` 开头/去空白后 `#` 开头的行。
/// （脚本里的 `#` 只出现在行首注释上，所以这样够用，不做字符串感知。）
String _psCode(String src) => src
    .split('\n')
    .where((l) => !l.trimLeft().startsWith('#'))
    .join('\n');

/// 本机是否具备跑这个文件的前提：
///   ① 有一个 PowerShell 可执行文件；
///   ② `tools/run_client.ps1` 里确实有一条 `$flutter = "…"` 赋值。
///
/// ★ 为什么是 markTestSkipped 而不是直接红（2026-10-10 跨平台预检的取舍）：
///   本文件的**被测对象是那份 PowerShell 脚本**（腿 A 读源码、腿 B/C 跑副本），
///   macOS 上 powershell 是否存在、脚本里那条路径写的是什么，都是**环境事实**，
///   不是本分支引入的缺陷。硬红只会把「这台机器没装 PS」报成「CR-02 回归」。
///   但**绝不**因此放宽任何一条断言：真跑起来的那条腿断言强度一字未改。
///   前提缺失时**每一条**用例都会打印同一行原因（不会静默变绿）。
String? _prereqWhy;

bool _prereqOk(String psCode, String? powerShell) {
  if (powerShell == null) {
    _prereqWhy = '本机没有 PowerShell（PATH 上没有 pwsh/powershell，也没有 '
        'C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe）⇒ '
        '跑不了 tools/run_client.ps1。';
    return false;
  }
  if (realFlutterPathIn(psCode) == null) {
    _prereqWhy = 'tools/run_client.ps1 里找不到 flutter 变量赋值那一行 ⇒ '
        '注入点不存在，跑下去会打到真 flutter build。';
    return false;
  }
  _prereqWhy = null;
  return true;
}

/// 每个用例开头调用：前提不成立就 skip 并说明（返回 false 时调用方直接 return）。
bool _requirePrereq(String psCode, String? powerShell) {
  if (_prereqOk(psCode, powerShell)) return true;
  markTestSkipped(_prereqWhy!);
  return false;
}

// 假 flutter：扮演**整个 flutter build windows 步骤**。
//
// ⚠⚠ 必须是 .ps1，不能是 .cmd/.bat —— 这是本轮实测踩出来的坑：
//
//  ```text
//  探针（在 PowerShell 5.1 里跑）              $LASTEXITCODE
//  & cmd.exe /c exit 3                (原生 exe)  []   ← 空
//  & t_direct.bat                     (批处理)    []   ← 空！
//  & cmd.exe /c <bat 的路径>                      []   ← 空
//  & t_run.ps1                        (PowerShell) 7    ← 只有 ps1 能传出来
//  ```
//
//  批处理文件在 PS 里跑**根本不设置** $LASTEXITCODE。所以第一版假
//  flutter 做成 .cmd 时，脚本的 `if ($rc -ne 0)` 拿到空值 ⇒
//  "flutter build 失败（exit ）"，测到的是我自己的桩子坏了，不是被测逻辑。
//  这是**假红**，记在这里免得再踩。
//
//  另外 `rem xxx >> file` 里的重定向会被 rem 吃掉（文件不生成），
//  要写日志必须用 `echo`。
//
// ⚠ 无论 STUB_RC 是多少都**照样写新件**：这样才能测出
//   构建失败时脚本有没有把一颗不该出现的核心塞进 Release 树。
//
// STUB_COPY=1 时把新件拷进 Release 树 —— 真构建里 CMake 的
// install(FILES ...) 干的就是这件事。不模拟它的话，修复方式一换
// （改成「显式拷贝」而不是「删掉还原」）测试就会误判。
String _stubFlutterPs1() => [
  r'if ($args[0] -ne "build") { exit 0 }',
  r'Add-Content -LiteralPath $env:STUB_LOG -Value ("build " + $args -join " ")',
  r'$Bytes = [int]$env:STUB_BYTES',
  r'$Mark = [int]$env:STUB_MARK',
  r'$b = New-Object byte[] $Bytes',
  r'for ($i = 0; $i -lt $Bytes; $i++) { $b[$i] = $Mark }',
  r'[IO.File]::WriteAllBytes($env:STUB_TARGET, $b)',
  r'if ($env:STUB_COPY -eq 1) {',
  r'  Copy-Item -LiteralPath $env:STUB_TARGET -Destination $env:STUB_RELEASE -Force',
  r'}',
  r'$global:LASTEXITCODE = [int]$env:STUB_RC',
  r'exit [int]$env:STUB_RC',
].join("\r\n") + "\r\n";

// ── 假树 ──────────────────────────────────────────────────────────
//
// 需要的目录 / 文件：
//   <root>/tools/run_client.ps1           脚本**副本**（$root 由它自己算）
//   <root>/<stub>                         假 flutter
//   <root>/build/windows/x64/runner/Release/sourin_spike.exe
//   <root>/build/windows/x64/runner/Release/data/app.so   （必须 > 5 MB）
//   <root>/build/windows/x64/runner/Release/sourin_core.dll  ← 旧件
//   <root>/rust/sourin_core/target/release/                cargo 输出目录
//   <root>/tmp                             顶替 %TEMP%，脚本的备份落这里
class FakeTree {
  FakeTree(this.root);

  final Directory root;

  static const String kRel = 'build/windows/x64/runner/Release';
  static const String kTargetRel = 'rust/sourin_core/target/release';

  String get releaseDll => '${root.path}/$kRel/sourin_core.dll';
  String get targetDll => '${root.path}/$kTargetRel/sourin_core.dll';
  String get tmp => '${root.path}/tmp';
  String get stubLog => '${root.path}/stub_calls.log';

  static FakeTree build() {
    final root = Directory.systemTemp.createTempSync('cr02_');

    for (final String d in <String>[
      'tools',
      '$kRel/data',
      kTargetRel,
      'tmp',
    ]) {
      Directory('${root.path}/$d').createSync(recursive: true);
    }

    // 脚本副本：跑的是它，不是仓库里那份。
    final String copy = '${root.path}/tools/run_client.ps1';

    // ⚠⚠ 全程按**字节**处理，绝不让 Dart 按字符读进再写回。
    //
    //    这不是洁癖，是本轮实测出来的**假红**（差点当成产品缺陷报上去）：
    //    run_client.ps1 是 UTF-8 **with BOM**，而 File.copySync 以及
    //    readAsStringSync+writeAsStringSync 都会做字符集转换，
    //    拷出来的是 Latin-1 —— 中文全成乱码，PowerShell 直接 ParserError
    //    「函数参数列表中缺少")"」，脚本连第一步都跑不到。
    //    症状极具误导性：Release 里那颗当然是 100 B 旧件，
    //    看着像 CR-02 还活着；但换成字节方式写同一个文件、
    //    跑同一条命令，拿到的是 733 B。
    //
    //    假红比红更糟 ⇒ 记在这里。
    final List<int> bytes = File(kScriptPath).readAsBytesSync();

    // 注入：把写死的那一行换成假 flutter。
    //
    // ⚠ 必须找到才继续 —— 真 flutter 在本机存在，脚本的
    //   `if (Test-Path $flutter)` 会直接用它 ⇒ 就会真构建。
    //   锚点消失就**抛错停下**，绝不放行。
    //   锚点与替换串都是纯 ASCII，用 latin1 编解码不影响其余字节。
    // ★ 跨平台（2026-10-10 预检）：锚点**从被读的这份字节里提取**，
    //   不再用写死的本机路径 —— 原写法（kRealFlutter = r'C:\Users\iuuuuuuuu\…'）
    //   在 CI 与别人的机器上必然匹配不上。
    //   「提取不到就抛错」这条铁律一字未改（_prereqOk 也会先挡一道）。
    final String? realFlutter = realFlutterPathIn(latin1.decode(bytes));
    if (realFlutter == null) {
      throw StateError(
        '注入点没找到：脚本里没有 flutter 变量赋值那一行 —— 锚点消失前这个测试'
        '**不能**继续跑（它会打到真 flutter build）。',
      );
    }
    final List<int> anchor = latin1.encode("\$flutter = \"$realFlutter\"");
    // 提取到了，但**必须**在字节流里真的找到这一段才能继续：
    // 否则说明「脚本的字符编码」与 latin1 往返不一致（BOM/CRLF 之外的意外）。
    final List<int> stubLine =
        latin1.encode("\$flutter = \"${root.path}/$kStubName\"");
    final int at = _indexOfBytes(bytes, anchor);
    if (at < 0) {
      throw StateError(
        '注入点没找到：脚本里那一行已经变了（现在不是 `\$flutter = "…"` 的写法）。\n'
        '锚点消失前这个测试**不能**继续跑 —— 它会打到真 flutter build。\n'
        '锚点 = ' + anchor.toString(),
      );
    }
    File(copy).writeAsBytesSync(<int>[
      ...bytes.sublist(0, at),
      ...stubLine,
      ...bytes.sublist(at + anchor.length),
    ]);

    // 假 flutter。
    File('${root.path}/$kStubName').writeAsStringSync(_stubFlutterPs1());

    // 产物：exe + 6 MB 的 app.so（step 4 的硬闸要 > 5 MB）。
    File('${root.path}/$kRel/sourin_spike.exe').writeAsStringSync('MZ');
    File('${root.path}/$kRel/data/app.so')
        .writeAsBytesSync(List<int>.filled(6 * 1024 * 1024, 65));

    // build 之前 Release 树里的**旧**核心。
    final FakeTree tree = FakeTree(root);
    File(tree.releaseDll)
        .writeAsBytesSync(List<int>.filled(kStaleBytes, kStaleMark));
    return tree;
  }

  void dispose() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  }

  /// 跑一次脚本副本。
  ///
  /// [rc] 决定假 flutter 的退出码；[copyIntoRelease] = false 时
  /// 假 flutter 只写 target/release、不拷进 Release 树 ——
  /// 用来模拟「构建失败 / 核心没被装进 bundle」。
  ProcessResult run(String powerShell, {int rc = 0, bool copyIntoRelease = true}) {
    return Process.runSync(
      powerShell,
      <String>[
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        '${root.path}/tools/run_client.ps1',
        '-BuildOnly',
      ],
      workingDirectory: root.path,
      environment: <String, String>{
        // 顶替 %TEMP%：脚本的备份文件落在这里，不污染真临时目录。
        'TEMP': tmp,
        'TMP': tmp,
        'STUB_LOG': stubLog,
        'STUB_TARGET': targetDll,
        'STUB_RELEASE': releaseDll,
        'STUB_BYTES': '$kFreshBytes',
        'STUB_MARK': '$kFreshMark',
        'STUB_COPY': copyIntoRelease ? '1' : '0',
        'STUB_RC': '$rc',
      },
    );
  }

  /// 假 flutter 确实被调用过（证明注入成功，而不是脚本压根没编）。
  bool stubWasCalled() =>
      File(stubLog).existsSync() && File(stubLog).readAsStringSync().isNotEmpty;
}

void main() {
  // 脚本源码（去掉整行注释）与 PowerShell 可执行文件：**只解析一次**。
  late String psCode;
  late String? ps;

  setUpAll(() {
    psCode = _psCode(File(kScriptPath).readAsStringSync());
    ps = _resolvePowerShell();
  });

  group('① 腿 A：源码里不能再有「构建前备份 + 构建后还原」（修之前 RED）', () {
    // ★ 腿 A 是**纯源码扫描**：任何平台、任何机器都必须跑（它是本文件的
    //   跨平台主力）。它不读 PowerShell，也不要求锚点存在。
    test('★★ 不存在备份文件变量 \$bak', () {
      expect(psCode, isNot(contains(r'$bak')),
          reason: '构建前把 Release 里那颗备份到 %TEMP%，正是缺陷的成因：\n'
              '构建后只要大小不同，这段逻辑就把**旧件**装回 Release 树。\n'
              '缺陷源：tools/run_client.ps1:92-102');
    });

    test('★★ 不存在「已把 sourin_core.dll 还原成…」这条提示', () {
      expect(psCode, isNot(contains('还原成')),
          reason: '这条提示是缺陷的**自述**：它在宣告「我把旧核心装回去了」，\n'
              '而注释把它写成「把刚编好的核心还原回去」—— 事实与注释相反');
    });
  });

  group('② 腿 B：构建成功后，Release 里的核心必须是新编那颗', () {
    FakeTree? tree;
    ProcessResult? r;

    setUpAll(() {
      // 前提不成立时**不建树**（build() 找不到锚点会抛 StateError，
      // 那会让整组红成「CR-02 回归」，而真实原因是这台机器跑不了 PS）。
      if (!_prereqOk(psCode, ps)) return;
      tree = FakeTree.build();
      r = tree!.run(ps!);
    });

    tearDownAll(() => tree?.dispose());

    test('★ 前提：注入成功，假 flutter 被调到了', () {
      if (!_requirePrereq(psCode, ps)) return;
      expect(tree!.stubWasCalled(), isTrue,
          reason: '没调假 flutter 就说明脚本没走到构建那一步，\n'
              '下面的断言就没有意义（**假门禁**，比红更糟）');
    });

    test('★★ Release 树里的 DLL 是**新件**（kFreshBytes / F 填充）', () {
      if (!_requirePrereq(psCode, ps)) return;
      expect(File(tree!.releaseDll).existsSync(), isTrue);
      expect(File(tree!.releaseDll).lengthSync(), kFreshBytes,
          reason: '构建成功了却还是 $kStaleBytes B 的旧核心 ⇒ 就是 CR-02 那个 bug：\n'
              '脚本把构建前的备份盖回 Release，客户端跑的是旧核心');
      expect(_isAllBytes(tree!.releaseDll, kFreshMark), isTrue,
          reason: '大小对了但内容是旧件（只改大小不改内容的假修复骗不过这条）');
    });

    test('★★ 脚本没有宣告「已还原」', () {
      if (!_requirePrereq(psCode, ps)) return;
      final String out = (r!.stdout as String) + (r!.stderr as String);
      expect(out.contains('还原成'), isFalse,
          reason: '真输出里出现了「已把 sourin_core.dll 还原成…」\n$out');
    });

    test('★ 目标那颗（cargo 输出）也没被脚本动过', () {
      if (!_requirePrereq(psCode, ps)) return;
      expect(File(tree!.targetDll).lengthSync(), kFreshBytes,
          reason: '脚本应该只往 Release 树装，不该改 cargo 的输出目录');
    });
  });

  group('③ 腿 B：构建失败时，Release 里已有的核心不许被动', () {
    FakeTree? tree;
    ProcessResult? r;

    setUpAll(() {
      if (!_prereqOk(psCode, ps)) return;
      tree = FakeTree.build();
      // 假 flutter 写完 target/release 但**不**装进 Release 树，然后失败。
      r = tree!.run(ps!, rc: 1, copyIntoRelease: false);
    });

    tearDownAll(() => tree?.dispose());

    test('★ 前提：构建确实失败了', () {
      if (!_requirePrereq(psCode, ps)) return;
      expect(r!.exitCode, isNot(0),
          reason: 'rc=1 的假 flutter 却让脚本成功退出 ⇒ 这条腿测不到东西');
    });

    test('★★ 失败后 Release 里那颗还是原样（旧件）', () {
      if (!_requirePrereq(psCode, ps)) return;
      expect(File(tree!.releaseDll).lengthSync(), kStaleBytes,
          reason: '构建失败却把一颗新核心塞进了 Release 树：\n'
              '那份构建根本没过，往 bundle 里装核心只会得到一个跑不起来的客户端');
      expect(_isAllBytes(tree!.releaseDll, kStaleMark), isTrue);
    });
  });
}
