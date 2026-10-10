// ═══════════════════════════════════════════════════════════════════════
//  Owner 1009 反馈 F1 后半 + B① 的回归门禁（task-33 / T7）
// ═══════════════════════════════════════════════════════════════════════
//
//  # 两条缺口（T5 对抗性复核证伪后留下的精确锚点）
//
//  ```text
//  F1 后半  本地会话（provider='local'）进播放页，顶栏挂出一枚写着字面
//           'local' 的胶囊 —— Owner 原话：
//           「已缓存的也要显示原来的封面,点击进去的播放也要显示出来原来源,
//             而不是local」
//           改前锚点：lib/ui/player_page.dart:2303-2313 _loadProviderName()
//             final id = _provider;
//             final n = await providerDisplayName(id);
//           providerDisplayName 查不到就**原样返回 id**
//           （lib/ui/widgets/provider_name.dart:68-74）⇒ 顶栏显示 'local'。
//
//  B①       播放页「更多」菜单里那枚「换源」没有本地门控 —— Owner 原话：
//           「这个好像是概率性的,缓存到本地就不要显示换源按钮了」
//           改前锚点：lib/ui/player_page.dart:4275-4279
//             MoreMenuEntry(label: '换源', icon: Icons.travel_explore,
//                           onTap: () => unawaited(_openSwitchSource()))
//           （紧邻的 if (!_isLive) 只包「字幕搜索」，包不到它）
//  ```
//
//  # ★★ 为什么本文件**不含渲染腿**（这是有证据的裁决，不是偷懒）
//
//  `_PlayerPageState.initState` 无条件 `_player = Player(...)`
//  （lib/ui/player_page.dart:2098），而 `Player(...)` 的构造函数体里就是
//  `generated.MPV(DynamicLibrary.open(NativeLibrary.path))`
//  （media_kit-1.2.6/lib/src/player/native/player/real.dart:77-78），
//  而 `NativeLibrary.path` 在没初始化时**直接 throw**
//  （同包 native_library.dart:20-27）。
//  ⇒ 在**没有 libmpv-2.dll** 的干净 runner（CI 就是这样）上，那一行抛异常
//    ⇒ 整棵子树建不起来 ⇒ 任何「顶栏里没有 local」/「菜单里没有 换源」的
//    widget 断言都会**假绿**（子树压根没建，find 自然找不到）。
//  这与 dart_test.yaml 里 native-media 标签的存在理由是同一件事。
//  ⇒ 真渲染只作为**证据**留在 .probe/ops/_f1b1_repro_raw.txt；
//    本文件改成两条**在干净 runner 上必然真跑**的腿：
//    腿① 纯函数行为（@visibleForTesting 的顶层纯函数，零 native 依赖）
//    腿② 源码契约（dart:io 读生产源码 + 剥注释，零 widget）
//
//  # 两条腿各自的红度（原始输出见 .probe/ops/F1B1-report.md 的往返证明）
//  腿①：把 providerNameLookupId 的 local 分支改回 return provider
//        ⇒ 立刻红（本地会话又拿 'local' 去查名字）。
//  腿②：把 _loadProviderName 改回 providerDisplayName(_provider)、
//        把 if (!_isLocalSession) 删掉 ⇒ 立刻红。
//
//  ═══════════════════════════════════════════════════════════════════════
//  ★★★ task-39（T13）：再补两条 —— 改 `_provider` 的两段方法体里
//      必须跟着重取站名（这是 T7 如实上报、本轮修掉的两条残留）
//  ═══════════════════════════════════════════════════════════════════════
//
//  ```text
//  残留① lib/ui/player_page.dart::applySession
//          分流前刚 setState({ _provider = req.provider; })，
//          但本地支（if (req.localPath != null)）走 _bootLocalFile
//          —— 那个方法只做 _streams/_prepareResume/_startPlayback/
//             _loadSkipMarker，**从不碰 _providerName**
//          ⇒ 从在线会话切到本地会话后，顶栏仍挂着**上一个站点**的名字。
//  残留② lib/ui/player_page.dart::_adoptLiveChannel
//          setState({ _provider = pick.provider; }) 之后整段没有取名字调用
//          ⇒ 换到**别的 provider** 的直播台后，顶栏仍是旧 provider 的名字。
//  ```
//
//  ★ 新腿为什么分成「源码契约」与「行为腿」两档（**红度不同**）
//  ```text
//  契约档：断言全文里存在 `unawaited(_loadProviderName());`
//          ⇒ 便宜，但**把那一行挪进一个永不执行的分支也照样绿**。
//  行为档：用同一个配平切片把两个方法的**函数体**切出来，再断言
//          「_provider 赋值 < 取名字调用」这个**相对顺序**
//          ⇒ 挪出方法体 / 挪到赋值之前 / 挪进 else 支 / 挪进 catch 都会红。
//  ```
//
//  ⚠️ 两档都**仍然不含渲染腿**，理由与上面那条裁决逐字相同
//     （CI 没有 libmpv ⇒ `Player(...)` 抛 ⇒ widget 断言会假绿）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:sourin_spike/core/progress_origin.dart';
import 'package:sourin_spike/ui/player_page.dart';

const String _pagePath = 'lib/ui/player_page.dart';
const String _detailPath = 'lib/ui/detail_page.dart';

/// 剥掉 `//` 行注释、`///` 文档注释、`/* */` 块注释
///
/// ★ 逐字照抄 `test/t68_android_adapt_test.dart:65-114`（同一个仓库里已有的
///   实现，不另起一套）：只剥注释、**保留字符串字面量**里的内容 ——
///   下面有些断言就是要匹配用户可见的文案（'换源' / '本地'）。
String _stripComments(String src) {
  final out = StringBuffer();
  var i = 0;
  String? quote; // 当前是否在字符串里（' 或 "）

  while (i < src.length) {
    final c = src[i];

    if (quote != null) {
      out.write(c);
      if (c == r'\' && i + 1 < src.length) {
        out.write(src[i + 1]);
        i += 2;
        continue;
      }
      if (c == quote) quote = null;
      i++;
      continue;
    }
    if (c == "'" || c == '"') {
      quote = c;
      out.write(c);
      i++;
      continue;
    }

    if (c == '/' && i + 1 < src.length && src[i + 1] == '/') {
      while (i < src.length && src[i] != '\n') {
        i++;
      }
      continue;
    }

    if (c == '/' && i + 1 < src.length && src[i + 1] == '*') {
      i += 2;
      while (i + 1 < src.length && !(src[i] == '*' && src[i + 1] == '/')) {
        i++;
      }
      i += 2;
      continue;
    }

    out.write(c);
    i++;
  }
  return out.toString();
}

String _readStripped(String path) {
  final f = File(path);
  expect(
    f.existsSync(),
    isTrue,
    reason: '★ 读不到 $path ⇒ 本文件全部无从判起（空断言比没断言更危险）',
  );
  return _stripComments(f.readAsStringSync());
}

/// 取 `start` 之后第一次出现 `open` 到**配平**的 `close` 之间的文本
///
/// ★ 照抄 `test/t68_android_adapt_test.dart:151-168`：只按固定字数切片会在
///   以后有人往里面加注释时**静默切错**（本项目踩过）。
String _sliceBalanced(String src, int start, String open, String close) {
  final begin = src.indexOf(open, start);
  expect(begin, greaterThanOrEqualTo(0), reason: '找不到「$open」');
  var depth = 0;
  for (var i = begin; i < src.length; i++) {
    if (src.startsWith(open, i)) {
      depth++;
      i += open.length - 1;
      continue;
    }
    if (src.startsWith(close, i)) {
      depth--;
      if (depth == 0) return src.substring(begin, i + close.length);
      i += close.length - 1;
    }
  }
  fail('括号没配平：从 $begin 起');
}

/// 从 `marker` 起到其后第一次出现 `end`（含）之间的文本
String _fromMarkerTo(String src, String marker, String end) {
  final i = src.indexOf(marker);
  expect(i, greaterThan(-1), reason: '找不到「$marker」');
  final j = src.indexOf(end, i + marker.length);
  expect(j, greaterThan(i), reason: '找不到「$marker」之后的「$end」');
  return src.substring(i, j + end.length);
}

/// `_moreMenuGroups` 的整段方法体（与既有门禁同一对锚点）
String _moreMenuSource(String page) {
  final from = page.indexOf('List<MoreMenuGroup> _moreMenuGroups');
  expect(from, greaterThan(-1), reason: 'player_page.dart 里找不到 _moreMenuGroups');
  final to = page.indexOf('String? _trackHint(', from);
  expect(to, greaterThan(from), reason: 'player_page.dart 里找不到 _moreMenuGroups 的结尾锚点');
  return page.substring(from, to);
}

/// ★ task-39：取某个方法（从签名起到其后第一个 `async {`）的**函数体**
///
/// 与 `_moreMenuSource` 的区别：那个按"下一个方法签名"截断，**只够用**于
/// 菜单那种线性方法；这两个方法的体内还有嵌套的 `{`（setState 闭包、
/// try/catch）⇒ 必须按**括号配平**切（[_sliceBalanced]），否则会在
/// 第一个 `});` 处**静默切短**，把后面的取名字调用切掉 ⇒ 假绿。
///
/// ⚠️ 配平失败时 [_sliceBalanced] 直接 `fail`（不是返回空串）——
///    这正是"锚点失效不许变成全绿"的落点。
String _methodBody(String page, String signature) {
  final from = page.indexOf(signature);
  expect(from, greaterThan(-1), reason: '★ 找不到方法签名「$signature」');
  final brace = page.indexOf('async {', from);
  expect(brace, greaterThan(from), reason: '★「$signature」之后找不到 async {');
  return _sliceBalanced(page, brace, '{', '}');
}

/// ★ task-39 的判据本体（抽出来是为了让**元门禁**能把它证伪）
///
/// 语义：`call` 必须**真的**出现在 `assign` 之后 —— 两者缺一都判假。
/// 单独写成函数而不是内联 indexOf，是因为下面那条自检用例要拿
/// **合成的**字符串来证明这个判据**不是恒真**（恒真 = 假门禁）。
bool _callFollowsAssign(String body, String assign, String call) {
  final a = body.indexOf(assign);
  final c = body.indexOf(call);
  return a > -1 && c > a;
}

void main() {
  // ═══════════════════════════════════════════════════════════════════
  //  ① 纯函数行为：顶栏该拿**哪个 id** 去查名字（F1 的判据）
  // ═══════════════════════════════════════════════════════════════════
  //
  //  ★ 这一腿在干净 runner 上**必然真跑**（零 widget、零 FFI）。
  //  ★ 红度：把 local 分支改回 return provider ⇒ 第 3 条立刻红。
  group('① providerNameLookupId：本地会话认回真来源、认不回来给 null', () {
    test('★ 在线会话：一个字不动（原行为不许被这次改动碰）', () {
      expect(
        providerNameLookupId(provider: 'cycani', originProvider: null),
        'cycani',
        reason: '★ 在线会话没有"原来源"这回事，必须原样用 provider 去查',
      );
      expect(
        providerNameLookupId(provider: 'cycani', originProvider: 'tyyszy'),
        'cycani',
        reason: '★ 非本地会话**不许**被 originProvider 顶掉 —— '
            'originProvider 只是"这部作品当初从哪下的"，'
            '不等于"现在这个会话是谁在放"',
      );
    });

    test('★ 本地会话 + 有来源 ⇒ 用真站点（Owner 要的「原来源」）', () {
      expect(
        providerNameLookupId(
          provider: kProgressLocalProvider,
          originProvider: 'cycani',
        ),
        'cycani',
      );
      expect(
        providerNameLookupId(
          provider: kProgressLocalProvider,
          originProvider: '  tyyszy  ',
        ),
        'tyyszy',
        reason: '★ 旁文件里带出来的 id 允许有空白，判据要先 trim',
      );
    });

    test('★★ 本地会话 + 认不回来 ⇒ null（绝不许把 local 当站点名）', () {
      expect(
        providerNameLookupId(
          provider: kProgressLocalProvider,
          originProvider: null,
        ),
        isNull,
        reason: '★★ 这就是 Owner 看到的那个缺陷：改前 providerDisplayName'
            "('local') 把 id 原样吐回来 ⇒ 顶栏挂着字面 'local'",
      );
      expect(
        providerNameLookupId(
          provider: kProgressLocalProvider,
          originProvider: '   ',
        ),
        isNull,
        reason: '★ 纯空白等于没写（trim 后为空）',
      );
      expect(
        providerNameLookupId(
          provider: kProgressLocalProvider,
          originProvider: kProgressLocalProvider,
        ),
        isNull,
        reason: '★ 旁文件里写的就是 local（续播命名空间）⇒ 等于没有站点，'
            '不许把它当名字显示出来',
      );
    });

    test('★ 大小写敏感：只有恰好等于 kProgressLocalProvider 才算本地', () {
      expect(kProgressLocalProvider, 'local');
      expect(isLocalSessionProvider(kProgressLocalProvider), isTrue);
      expect(isLocalSessionProvider('cycani'), isFalse,
          reason: '★ 在线会话 ⇒ 谓词必须 false（否则换源会被误藏）');
      expect(isLocalSessionProvider(''), isFalse, reason: '★ 空串不是本地');
      expect(isLocalSessionProvider('LOCAL'), isFalse,
          reason: '★ provider id 是注册表里的原样字符串，不做大小写归一');
      expect(isLocalSessionProvider('localhost'), isFalse,
          reason: '★ 前缀相同不算 —— 判据必须是**相等**，不是 startsWith');
      expect(isLocalSessionProvider(' local'), isFalse, reason: '★ 带空白不算');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② 源码契约：两处缺口不许回退（在干净 runner 上也必然真跑）
  // ═══════════════════════════════════════════════════════════════════
  group('② 源码契约（lib/ui/player_page.dart）', () {
    late String page;
    late String detail;

    setUpAll(() {
      page = _readStripped(_pagePath);
      detail = _readStripped(_detailPath);
    });

    test('B①：更多菜单的「换源」必须被 if (!_isLocalSession) 门控', () {
      final body = _moreMenuSource(page);

      // ① 功能不许删（既有门禁 t68 的 E③ 也钉着这一条，这里再钉一次是为了
      //    让"入口可以门控、功能不许删"这句话在本文件里也是可执行的）。
      expect(
        body.contains("label: '换源'"),
        isTrue,
        reason: '★★「换源」是底栏改成「更多」浮层之前的可见入口，'
            '本轮**只允许门控、不许删功能**',
      );

      // ② 必须仍然在「播放」那个分组里（顺序：播放设置 → 字幕搜索 → 换源）。
      final groupStart = body.indexOf("MoreMenuGroup('播放', [");
      expect(groupStart, greaterThan(-1), reason: '★「播放」分组不见了');
      final groupEnd = body.indexOf("MoreMenuGroup('弹幕'", groupStart);
      expect(groupEnd, greaterThan(groupStart), reason: '★「播放」分组的结尾锚点不见了');
      final playGroup = body.substring(groupStart, groupEnd);
      expect(
        playGroup.contains("label: '换源'"),
        isTrue,
        reason: '★「换源」必须留在「播放」分组**内部** —— '
            't68 的 E③ 与 zz_cr_next_dup_more_menu_test 的解析器都按这个位置认它',
      );

      // ③ ★★ 门控本身：紧邻的那一行必须是 if (!_isLocalSession)
      final entry = playGroup.indexOf("label: '换源'");
      final lead = playGroup.substring(0, entry);
      expect(
        lead.contains('if (!_isLocalSession)'),
        isTrue,
        reason: '★★ Owner 原话「缓存到本地就不要显示换源按钮了」——'
            '本地文件会话里这一项**不许出现**（它就在磁盘上，换源无处可落）',
      );
      // 反向：门控必须**紧贴**这一项（中间不许再夹别的项，否则会误包到别人）
      final tail = lead.substring(lead.lastIndexOf('if (!_isLocalSession)'));
      expect(
        tail.replaceAll(RegExp(r'\s+'), '').startsWith('if(!_isLocalSession)MoreMenuEntry('),
        isTrue,
        reason: '★ 门控与它要包的那一项之间不许再夹别的语句/项 —— '
            '紧贴的下一句必须是 MoreMenuEntry(，否则门控包到了别人身上',
      );
    });

    test('B①：_isLocalSession 必须跟着 _provider 走（不许退回静态判据）', () {
      final decl = _fromMarkerTo(page, 'bool get _isLocalSession', ';')
          .replaceAll(RegExp(r'\s+'), '');
      expect(
        decl,
        'boolget_isLocalSession=>isLocalSessionProvider(_provider);',
        reason: '★★ 判据必须是**动态**的 _provider：applySession（原地换集/换源）'
            '会把 _provider 换成在线站点，用 widget.localPath 这种页面级'
            '不可变量会把换源**永久藏起来**（本地页里切到在线源之后换不回去）',
      );
      expect(
        decl.contains('widget.localPath'),
        isFalse,
        reason: '★ 明确禁止退回 widget.localPath 判据',
      );
    });

    test('F1：_loadProviderName 不许再用 providerDisplayName(_provider) 一把梭', () {
      final body = _fromMarkerTo(
        page,
        'Future<void> _loadProviderName() async {',
        '\n  }',
      );
      expect(
        body.contains('providerDisplayName(_provider)'),
        isFalse,
        reason: '★★ 这就是改前的缺陷写法：本地会话 provider == local ⇒ '
            "providerDisplayName 把 id 原样返回 ⇒ 顶栏显示字面 'local'",
      );
      expect(
        body.contains('providerNameLookupId('),
        isTrue,
        reason: '★ 查名字的 id 必须由 providerNameLookupId 现算',
      );
      expect(
        body.contains('kLocalSessionSourceLabel'),
        isTrue,
        reason: '★ 认不回来时要有兜底名字（「本地」），不能空着',
      );
      expect(
        body.contains('providerDisplayName('),
        isTrue,
        reason: '★ 查名字仍然必须走 providerDisplayName（task-32 的契约：'
            '顶栏站名与详情页同源）',
      );
    });

    test('F1：顶栏那一枚名字不许把 local 当站点渲染', () {
      // ① 顶层判据自己先钉住"本地会话不返回 local"
      // ★ 结尾锚点用 '\n}\n'：参数表那行也是 '}) {' 开头，只找 '\n}' 会切在参数表上
      final fn = _fromMarkerTo(page, 'String? providerNameLookupId({', '\n}\n');
      expect(
        fn.contains('if (provider != kProgressLocalProvider) return provider;'),
        isTrue,
        reason: '★ 非本地会话原样返回',
      );
      expect(
        fn.contains(
            "if (o.isEmpty || o == kProgressLocalProvider) return null;"),
        isTrue,
        reason: '★★ 本地会话且来源空白/就是 local ⇒ **null**，'
            '这正是"绝不显示 local"的落点',
      );

      // ② 顶栏名的接线（task-32 的契约）不许断
      expect(
        page.contains('setState(() => _providerName = n);'),
        isTrue,
        reason: '★ 顶栏名的写入点不见了（任务 32 的接线）',
      );
      expect(page.contains('providerName: _providerName,'), isTrue,
          reason: '★ _TopBar 的 providerName 接线不许断（task-32 的契约）');

      // ③ 兜底名字必须**不是** local
      expect(
        kLocalSessionSourceLabel,
        isNot(kProgressLocalProvider),
        reason: '★★ 兜底名字不许就是那个续播命名空间的 id —— '
            'Owner 要的正是"而不是local"',
      );
      expect(
        kLocalSessionSourceLabel.trim(),
        isNotEmpty,
        reason: '★ 兜底名字不许是空白（那等于没显示）',
      );
    });

    test('F1：兜底「本地」在详情页与播放页必须逐字相等', () {
      // ★ 为什么读源码而不是 import：player_page.dart **不 import** detail_page.dart
      //   （两页之间没有依赖），而这一条要钉的正是"两处说法不许漂"。
      expect(
        detail.contains("const String kLocalSourceLabel = '本地';"),
        isTrue,
        reason: '★ 详情页那半的常量不见了或改了值（Owner 1009 已闭环的那半）',
      );
      expect(
        page.contains("const String kLocalSessionSourceLabel = '本地';"),
        isTrue,
        reason: '★ 播放页这半的常量不见了或改了值',
      );
      expect(
        kLocalSessionSourceLabel,
        '本地',
        reason: '★★ 同一件事在详情页与播放页是两个说法，就是在制造新的不一致',
      );
    });

    test('T13①：applySession 改完 _provider 必须重新取站名（含本地支）', () {
      final body = _methodBody(page, 'Future<void> applySession(PlayRequestData req)');

      // ① 行为腿：取名字的调用必须**真的**排在 _provider 赋值之后。
      expect(
        _callFollowsAssign(
          body,
          '_provider = req.provider;',
          'unawaited(_loadProviderName());',
        ),
        isTrue,
        reason: '★★ 残留①：applySession 分流前那个 setState 已经把 _provider '
            '换成新会话的源，而本地支走 _bootLocalFile —— 那个方法只做 '
            '_streams/_prepareResume/_startPlayback/_loadSkipMarker，'
            '**从不碰 _providerName** ⇒ 不在这里补一次取名字，'
            '从在线会话切到本地会话后顶栏会一直挂着**上一个站点**的名字',
      );

      // ② 反向：不许只给"在线那一支"补 —— 本地支会再次漏掉。
      //    分流点是 req.localPath（task-12 ④ 的判据），
      //    取名字必须排在它**之前**，才能被两条支路共同经过。
      final branch = body.indexOf('if (req.localPath != null)');
      expect(
        branch,
        greaterThan(-1),
        reason: '★ 找不到本地/在线分流点 ⇒ 本用例"两条支路"的前提没了（锚点失效）',
      );
      expect(
        body.indexOf('_loadProviderName()'),
        lessThan(branch),
        reason: '★★ 取名字必须排在**分流之前** —— 塞进任何一支都会漏掉另一支'
            '（这正是残留①的形态：只有 _resolveAndPlay 那一支会刷新）',
      );
    });

    test('T13②：_adoptLiveChannel 改完 _provider 必须重新取站名', () {
      final body = _methodBody(page, 'Future<void> _adoptLiveChannel(');

      expect(
        _callFollowsAssign(
          body,
          '_provider = pick.provider;',
          'unawaited(_loadProviderName());',
        ),
        isTrue,
        reason: '★★ 残留②：换直播台会把 _provider 换成新台所属的源 —— '
            '不重取站名的话，换到**别的 provider** 的台之后顶栏仍是旧 provider',
      );

      // ★ 反向：取名字不许被塞进"只有解析成功才走到"的分支里。
      //   _provider 在 setState 那一刻就已经变了 ⇒ 站名要跟着立刻变，
      //   不能等 getLiveStream 回来（中途会显示错的名字）。
      final tryIdx = body.indexOf('try {');
      expect(tryIdx, greaterThan(-1), reason: '★ 找不到 try { ⇒ 方法结构变了');
      expect(
        body.indexOf('_loadProviderName()'),
        lessThan(tryIdx),
        reason: '★ 取名字必须排在 try 之前 —— _provider 在 setState 里就已经换了',
      );
    });

    test('T13①②：两处补的取名字调用必须真的挂在改 _provider 的方法体里', () {
      // ★ 这一条钉的是**位置**：全文里存在 unawaited(_loadProviderName());
      //   并不能证明它挂在"改 _provider"的那两个方法里 ——
      //   挪进任何一个永不执行的分支都照样绿。
      expect(
        page.contains('unawaited(_loadProviderName());'),
        isTrue,
        reason: '★ 取名字的调用整条不见了',
      );
      for (final sig in <String>[
        'Future<void> applySession(PlayRequestData req)',
        'Future<void> _adoptLiveChannel(',
      ]) {
        final body = _methodBody(page, sig);
        expect(
          body.contains('_provider = '),
          isTrue,
          reason: '★「$sig」里没有 _provider 赋值 ⇒ 锚点切错了方法（自检）',
        );
        expect(
          body.contains('_loadProviderName()'),
          isTrue,
          reason: '★★「$sig」改了 _provider 却不在自己的方法体里取站名 —— '
              '挪到别处（哪怕全文里还在）都算漏',
        );
      }
    });

    test('自检：本文件的解析器不许空跑（防"扫不到 ⇒ 全绿"）', () {
      // ★ 这一条是本文件的**元门禁**：如果锚点/剥离器哪天失效了，
      //   上面的契约断言会变成"什么都没扫到 ⇒ 假绿"。
      expect(_stripComments('a // b\nc'), isNot(contains('b')),
          reason: '★ 行注释必须被剥掉');
      expect(_stripComments('a /* b */ c'), 'a  c', reason: '★ 块注释必须被剥掉');
      expect(_stripComments("x '// not a comment' y"),
          contains('// not a comment'),
          reason: '★ 字符串字面量里的 // 不许被当注释剥掉');
      final body = _moreMenuSource(page);
      expect(body.length, greaterThan(800),
          reason: '★ _moreMenuGroups 的方法体不可能这么短 ⇒ 锚点错了');
      expect(body.contains('MoreMenuGroup('), isTrue);
      // ★ 顺手自检 _sliceBalanced（本文件其它断言若哪天改用它，不许是坏的）
      expect(_sliceBalanced('a{b{c}d}e', 0, '{', '}'), '{b{c}d}');
      expect(
        _sliceBalanced(body, body.indexOf("MoreMenuGroup('播放', ["), '[', ']'),
        isNot(contains("MoreMenuGroup('弹幕'")),
        reason: '★ 配平切片不许越过「播放」这一组的右括号',
      );
      // ★ task-39 元自检：上面那条判据本体不许恒真/恒假
      expect(
        _callFollowsAssign(
          'a _provider = x; b _loadProviderName(); c',
          '_provider = x;',
          '_loadProviderName();',
        ),
        isTrue,
        reason: '★ 调用确实排在赋值之后时必须为真（否则新腿是假红）',
      );
      expect(
        _callFollowsAssign(
          'a _loadProviderName(); b _provider = x; c',
          '_provider = x;',
          '_loadProviderName();',
        ),
        isFalse,
        reason: '★★ 调用排在赋值**之前**时必须为假 —— 恒真 = 假门禁'
            '（把修复挪到赋值之前就抓不到了）',
      );
      expect(
        _callFollowsAssign(
          'a _provider = x; c',
          '_provider = x;',
          '_loadProviderName();',
        ),
        isFalse,
        reason: '★★ 根本没有调用时必须为假 —— 这一条正是残留①的原始形态',
      );
      // ★ 新助手 _methodBody 必须真的切到**函数体**（不是签名、不是空串）
      final t13 = _methodBody(
        page,
        'Future<void> applySession(PlayRequestData req)',
      );
      expect(t13.length, greaterThan(800),
          reason: '★ 函数体不可能这么短 ⇒ 锚点切错了');
      expect(t13.startsWith('{'), isTrue, reason: '★ 必须从 { 起切');
      expect(t13.endsWith('}'), isTrue, reason: '★ 必须切到配平的 } 为止');
      // ★ 合成反例：残留①的**原始形态**（只有在线支会取名字）必须被判为假
      const onlyOnline =
          '{ setState(() { _provider = req.provider; }); '
          'if (req.localPath != null) { await _bootLocalFile(path: req.localPath); } '
          'else { await _resolveAndPlay(req.provider, req.id, null, null); } }';
      expect(
        _callFollowsAssign(
          onlyOnline,
          '_provider = req.provider;',
          'unawaited(_loadProviderName());',
        ),
        isFalse,
        reason: '★★ 残留①的原始形态（本地支不刷新）必须判为假 —— '
            '这是新腿红度的合成证明',
      );

      final groups = RegExp(r"MoreMenuGroup\('([^']*)'")
          .allMatches(body)
          .map((m) => m.group(1))
          .toList();
      expect(groups, contains('播放'), reason: '★ 解析不到「播放」分组');
      expect(groups.length, greaterThanOrEqualTo(4),
          reason: '★ 分组数不可能少于 4（画面/播放/弹幕/剧集）');
    });
  });
}
