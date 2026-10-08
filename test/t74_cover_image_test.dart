// task-74 ⑤ (3) —— 海报「按布局宽度解码」的测试
//
// 被测对象：`lib/ui/widgets/cover_image.dart`
//
// ★★ 为什么不去断言「源码里有 `cacheWidth` 这五个字」
//    那是 analyze 免费就能告诉我的事 —— 源码里出现某个字符串，与
//    「解码宽度真的变成了 162」是两件不同的事。真正要守的是
//    **返回值本身**：`coverImage()` 交出来的那个 `Image`，它的
//    `image` 是不是一个带 `width` 的 `ResizeImage`。前者改坏了照样绿。
//
// ★★ 每条「不存在 / 零命中」式断言都配了**阳性对照**
//    先证明这台仪器**看得见**目标，再报 0。否则 0 可能只是
//    「我搜错了地方」—— 本仓已经踩过这个坑。

import 'dart:io';

// ★ `ResizeImage` / `ResizeImagePolicy` 不需要单独 import painting：
//   analyze 实测 `unnecessary_import`（`material_ui` 已把它们带进来）。
//   ★ 这里如实记录我先前判断错了一次 —— 我按 `widgets.dart` 的 export 列表
//     推断「painting 不 re-export」，但编译器才是权威。删掉后测试仍全绿。
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/widgets/cover_image.dart';

/// 取一个带指定 DPR 的 `BuildContext`。
///
/// ★ 必须自己塞 `MediaQuery`：`testWidgets` 里 `tester.view.devicePixelRatio`
///   默认是 **3.0**，不塞就测不到我要的那个读数。
Future<BuildContext> _ctxWithDpr(WidgetTester tester, double dpr) async {
  late BuildContext captured;
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(devicePixelRatio: dpr),
      child: Builder(
        builder: (BuildContext c) {
          captured = c;
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  return captured;
}

/// 读生产源码（`flutter test` 的 cwd = 包根，与既有测试同款）。
String _src(String rel) => File(rel).readAsStringSync();

/// 剥掉注释（本仓惯例：每个测试文件各自实现一份，无共享 helper）。
///
/// ★ 为什么 D4 必须剥：注释里**提到** `LayoutBuilder(` 也会被
///   `String.contains` 数进去。第一版就是被自己写的注释坑了 ——
///   数出 2 个，实际代码里只有 1 个。断言的对象必须是**代码**。
String _stripComments(String src) {
  final out = StringBuffer();
  var i = 0;
  while (i < src.length) {
    final c = src[i];
    // 行注释
    if (c == '/' && i + 1 < src.length && src[i + 1] == '/') {
      while (i < src.length && src[i] != '\n') {
        i++;
      }
      continue;
    }
    // 块注释
    if (c == '/' && i + 1 < src.length && src[i + 1] == '*') {
      i += 2;
      while (i + 1 < src.length && !(src[i] == '*' && src[i + 1] == '/')) {
        i++;
      }
      i += 2;
      continue;
    }
    // 字符串：原样保留内容（`'http://x'` 里的 `//` 不是注释）
    if (c == "'" || c == '"') {
      final quote = c;
      final triple = i + 2 < src.length &&
          src[i + 1] == quote &&
          src[i + 2] == quote;
      final delim = triple ? quote * 3 : quote;
      out.write(delim);
      i += delim.length;
      while (i < src.length) {
        if (src[i] == r'\' && i + 1 < src.length) {
          out.write(src.substring(i, i + 2));
          i += 2;
          continue;
        }
        if (src.startsWith(delim, i)) {
          out.write(delim);
          i += delim.length;
          break;
        }
        out.write(src[i]);
        i++;
      }
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

void main() {
  // ═══════════════════════════════════════════════════════════════════
  // A. coverDecodeWidth —— 纯函数的边界
  // ═══════════════════════════════════════════════════════════════════
  group('A. coverDecodeWidth', () {
    testWidgets('A1 常规：布局宽 × DPR，四舍五入', (WidgetTester t) async {
      final ctx = await _ctxWithDpr(t, 1.0);
      expect(coverDecodeWidth(ctx, 148.0), 148); // poster_card 的 w
      expect(coverDecodeWidth(ctx, 162.3), 162); // 追更页实测 cell 宽
      expect(coverDecodeWidth(ctx, 34.0), 34); // 直播页台标 34x34
      expect(coverDecodeWidth(ctx, 212.0), 212); // detail_page 大封面
      expect(coverDecodeWidth(ctx, 112.0), 112); // detail_page 紧凑封面

      final ctx2 = await _ctxWithDpr(t, 2.0);
      expect(coverDecodeWidth(ctx2, 162.3), 325); // 324.6 → 325
      expect(coverDecodeWidth(ctx2, 148.0), 296);
    });

    testWidgets('A2 ★ 下界 1：算得 0 时必须给 1', (WidgetTester t) async {
      // 理由：`Image.network` 里有 `assert(cacheWidth == null || cacheWidth > 0)`
      // （flutter/lib/src/widgets/image.dart:481）⇒ 去掉 clamp 就是 debug 崩。
      final ctx = await _ctxWithDpr(t, 1.0);
      expect(coverDecodeWidth(ctx, 0.0), 1);
      expect(coverDecodeWidth(ctx, 0.2), 1);
      expect(coverDecodeWidth(ctx, -5.0), 1);

      final ctx0 = await _ctxWithDpr(t, 0.0); // 退化 DPR
      expect(coverDecodeWidth(ctx0, 162.3), 1);
    });

    testWidgets('A3 ★ 非有限值退到上界（不是把异常留给 round()）',
        (WidgetTester t) async {
      // `(double.infinity).round()` 会抛 UnsupportedError: Infinity or NaN toInt
      // ⇒ 那是整页崩，不是「图小一点」。
      final ctx = await _ctxWithDpr(t, 1.0);
      expect(coverDecodeWidth(ctx, double.infinity), kCoverDecodeMaxPx);
      expect(coverDecodeWidth(ctx, double.negativeInfinity), kCoverDecodeMaxPx);
      expect(coverDecodeWidth(ctx, double.nan), kCoverDecodeMaxPx);
    });

    testWidgets('A4 ★ 上界 4096：再大也不超（缓存 key 一致性）',
        (WidgetTester t) async {
      final ctx = await _ctxWithDpr(t, 1.0);
      expect(coverDecodeWidth(ctx, 4096.0), 4096); // 边界值本身不削
      expect(coverDecodeWidth(ctx, 4097.0), 4096);
      expect(coverDecodeWidth(ctx, 1e9), 4096);

      final ctx2 = await _ctxWithDpr(t, 2.0);
      expect(coverDecodeWidth(ctx2, 3000.0), 4096); // 6000 → 夹回
    });

    testWidgets('A5 任何输入下返回值都落在 (0, kCoverDecodeMaxPx] 内',
        (WidgetTester t) async {
      final ctx = await _ctxWithDpr(t, 1.0);
      for (final w in <double>[
        0.0,
        0.2,
        34,
        112,
        148,
        162.3,
        212,
        4096,
        1e9,
        double.infinity,
        double.negativeInfinity,
        double.nan,
        -5,
      ]) {
        final v = coverDecodeWidth(ctx, w);
        expect(v, greaterThan(0), reason: 'layoutWidth=$w');
        expect(v, lessThanOrEqualTo(kCoverDecodeMaxPx), reason: 'layoutWidth=$w');
      }
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // B. coverImage 的返回值 —— 被测对象本身
  // ═══════════════════════════════════════════════════════════════════
  group('B. coverImage 的返回值', () {
    testWidgets('B1 返回的就是 Image 本身，没有新包一层 widget class',
        (WidgetTester t) async {
      final ctx = await _ctxWithDpr(t, 1.0);
      final img = coverImage(
        ctx,
        url: 'https://example.invalid/a.jpg',
        layoutWidth: 162.3,
      );
      expect(img, isA<Image>());
      // ★ 用 runtimeType 而不是 isA：子类也能过 isA，但元素树里的类型就变了，
      //   `find.byType(Image)` 的语义会**静默**改变。
      expect(img.runtimeType, Image);
    });

    testWidgets('B2 ★ image 是 ResizeImage：width = 布局宽×DPR，height 为 null',
        (WidgetTester t) async {
      final ctx = await _ctxWithDpr(t, 1.0);
      final img = coverImage(
        ctx,
        url: 'https://example.invalid/a.jpg',
        layoutWidth: 162.3,
      );
      final p = img.image;
      expect(p, isA<ResizeImage>());
      final r = p as ResizeImage;
      expect(r.width, 162);
      // ★ 只给宽：源图未必是 2:3（实测 1920x1080 / 1077x608 都是 16:9），
      //   同时给宽高会把源图**拉伸**（ResizeImage 不保比例）。
      expect(r.height, isNull);
      expect(r.policy, ResizeImagePolicy.exact);
      expect(r.allowUpscaling, isFalse); // 值超过原图也不会放大
    });

    testWidgets('B3 ★ 阳性对照：不传 cacheWidth 时 image 退化成裸 NetworkImage',
        (WidgetTester t) async {
      // 这条证明 B2 的 `isA<ResizeImage>` 不是恒真：少了 cacheWidth，
      // 同一个构造路径就会给出 NetworkImage。仪器看得见目标。
      final plain = Image.network('https://example.invalid/a.jpg');
      expect(plain.image, isA<NetworkImage>());
      expect(plain.image, isNot(isA<ResizeImage>()));
    });

    testWidgets('B4 ★ 四个 builder 与 fit 逐字透传（identity，不是 ==）',
        (WidgetTester t) async {
      final ctx = await _ctxWithDpr(t, 1.0);
      Widget fb(BuildContext c, Widget child, int? frame, bool wasSync) => child;
      Widget lb(BuildContext c, Widget child, ImageChunkEvent? progress) => child;
      Widget eb(BuildContext c, Object error, StackTrace? stack) =>
          const SizedBox.shrink();

      final img = coverImage(
        ctx,
        url: 'https://example.invalid/a.jpg',
        layoutWidth: 100,
        fit: BoxFit.contain,
        frameBuilder: fb,
        loadingBuilder: lb,
        errorBuilder: eb,
      );
      expect(img.fit, BoxFit.contain);
      // ★ 用 identical 而不是 ==：闭包没有值相等语义，`==` 会退化成
      //   「两个都是函数对象」的恒真式。
      expect(identical(img.frameBuilder, fb), isTrue);
      expect(identical(img.loadingBuilder, lb), isTrue);
      expect(identical(img.errorBuilder, eb), isTrue);
    });

    testWidgets('B5 不传就是 null —— 本函数只决定解码尺寸', (WidgetTester t) async {
      final ctx = await _ctxWithDpr(t, 1.0);
      final img = coverImage(
        ctx,
        url: 'https://example.invalid/a.jpg',
        layoutWidth: 100,
      );
      expect(img.fit, isNull);
      expect(img.frameBuilder, isNull);
      expect(img.loadingBuilder, isNull);
      expect(img.errorBuilder, isNull);

      // 对照：`Image.network` 不传这些参数时默认值也是全 null（逐字相同）
      // ⇒ 本函数确实没有偷偷改变占位 / 加载中 / 失败时的表现。
      final plain = Image.network('https://example.invalid/a.jpg');
      expect(plain.fit, isNull);
      expect(plain.frameBuilder, isNull);
      expect(plain.loadingBuilder, isNull);
      expect(plain.errorBuilder, isNull);
    });

    testWidgets('B6 ★ 真能挂进树：MediaQuery 查得到、布局得出来、不抛异常',
        (WidgetTester t) async {
      await t.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(devicePixelRatio: 1.0),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Builder(
              builder: (BuildContext c) => Center(
                child: SizedBox(
                  width: 162,
                  height: 243,
                  child: coverImage(
                    c,
                    url: 'https://example.invalid/a.jpg',
                    layoutWidth: 162,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await t.pump();
      expect(find.byType(Image), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // C. 缓存 key —— 主判据（imageCache 驻留）背后的机制
  // ═══════════════════════════════════════════════════════════════════
  group('C. 缓存 key', () {
    testWidgets('C1 同 url 同宽度 ⇒ 同一个 key（不会解码两份）',
        (WidgetTester t) async {
      final ctx = await _ctxWithDpr(t, 1.0);
      final a = coverImage(
        ctx,
        url: 'https://example.invalid/a.jpg',
        layoutWidth: 162.3,
      );
      final b = coverImage(
        ctx,
        url: 'https://example.invalid/a.jpg',
        layoutWidth: 162.3,
      );
      final ka = await (a.image as ResizeImage).obtainKey(ImageConfiguration.empty);
      final kb = await (b.image as ResizeImage).obtainKey(ImageConfiguration.empty);
      expect(ka, equals(kb));
    });

    testWidgets('C2 ★ 宽度不同 ⇒ key 不同（文档里那条「值不同就解码两份」是真的）',
        (WidgetTester t) async {
      final ctx = await _ctxWithDpr(t, 1.0);
      final a = coverImage(
        ctx,
        url: 'https://example.invalid/a.jpg',
        layoutWidth: 162.3,
      );
      final b = coverImage(
        ctx,
        url: 'https://example.invalid/a.jpg',
        layoutWidth: 200.0,
      );
      final ka = await (a.image as ResizeImage).obtainKey(ImageConfiguration.empty);
      final kb = await (b.image as ResizeImage).obtainKey(ImageConfiguration.empty);
      expect(ka == kb, isFalse);

      // 同一张图在 DPR=2 的屏上也是另一个 key ⇒ 换显示器会重新解码一次
      // （这是 `cacheWidth` 进 key 的必然代价，与 C1 一起构成受控对照：
      //  同宽 ⇒ 相等，异宽 ⇒ 不等，差异只能来自宽度这一维）。
      final ctx2 = await _ctxWithDpr(t, 2.0);
      final c = coverImage(
        ctx2,
        url: 'https://example.invalid/a.jpg',
        layoutWidth: 162.3,
      );
      final kc = await (c.image as ResizeImage).obtainKey(ImageConfiguration.empty);
      expect(ka == kc, isFalse);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // D. 生产调用点（源码扫描 + 阳性对照）
  // ═══════════════════════════════════════════════════════════════════
  group('D. 生产调用点', () {
    const sites = <String>[
      'lib/ui/widgets/poster_card.dart',
      'lib/ui/follow_page.dart',
      'lib/ui/detail_page.dart',
      'lib/ui/live_page.dart',
    ];

    test('D1 四个调用点都走 coverImage，且都不再直接 Image.network', () {
      for (final p in sites) {
        final s = _src(p);
        expect(s.contains('coverImage('), isTrue, reason: '$p 没有用 coverImage');
        expect(s.contains('Image.network('), isFalse,
            reason: '$p 还在直接 Image.network ⇒ cacheWidth 又丢了');
      }
    });

    test('D2 ★ 阳性对照：扫描器看得见 Image.network', () {
      // helper 自己就是靠 `Image.network` 实现的。它都搜不到 ⇒ D1 的
      // 「不存在」只是瞎报 0。
      final helper = _src('lib/ui/widgets/cover_image.dart');
      expect(helper.contains('Image.network('), isTrue,
          reason: 'helper 里都搜不到 Image.network ⇒ 扫描器坏了，D1 的 0 命中无意义');
    });

    test('D3 全 lib\\ 只有 helper 一处 Image.network', () {
      final hits = <String>[];
      for (final e in Directory('lib').listSync(recursive: true)) {
        if (e is! File || !e.path.endsWith('.dart')) continue;
        if (e.readAsStringSync().contains('Image.network(')) {
          hits.add(e.uri.pathSegments.last);
        }
      }
      expect(hits, <String>['lib/ui/widgets/cover_image.dart'.split('/').last]);
    });

    test('D4 follow_page 的 cell 宽是从 LayoutBuilder 传下去的，不是卡片自己量的', () {
      // ★ 必须剥注释：切片里我写了 8 行注释**提到** `LayoutBuilder(`，
      //   不剥就会数成 2 个（第一版实测就是这个假红）。
      final code = _stripComments(_src('lib/ui/follow_page.dart'));
      final start = code.indexOf('class _ContinueList');
      final end = code.indexOf('class _FavGrid', start);
      expect(start, greaterThan(0));
      expect(end, greaterThan(start));
      final body = code.substring(start, end);

      expect(body.contains('required this.coverWidth'), isTrue);
      expect(body.contains('coverWidth:'), isTrue);
      /*
       * ★★ 2026-10 二次修正：这里原来钉的是 followGridColumns(c.maxWidth)，
       *   但那是**错的** —— Padding 在 LayoutBuilder 外面 ⇒ c.maxWidth
       *   已经减过一次内边距，而 Layout.columnsForBand 的入参是
       *   **没减过**的内容带宽度，内部还会再减一次（1400px 附近少一列）。
       * ⇒ 现在钉的是包装层 _followBandFor：它负责把那 48 加回去。
       *   （判据仍是「不许卡片自己量宽度」—— 宽度依旧从 LayoutBuilder 传下去。）
       */
      expect(body.contains('_followBandFor(context, c.maxWidth)'), isTrue,
          reason: '★ 列数/间距必须经 _followBandFor 换算成内容带宽度');
      expect(body.contains('followGridColumns(c.maxWidth)'), isFalse,
          reason: '★★ 不许再直接把 c.maxWidth 交给 followGridColumns —— '
              '那是「减两次内边距」的坑（1400px 窗口会少算一列）');
      // ★ 本切片里只能有 1 个 LayoutBuilder —— 就是 `_ContinueList.build`
      //   里那个现成的。卡片必须靠构造参数拿到宽度，不许自己再量一次
      //   （`provider_grid_responsive_test.dart:604-616` 钉的是同类约束）。
      expect('LayoutBuilder('.allMatches(body).length, 1);

      // ★ 卡片里必须真的**用**了那个参数：定义了却不用 == 没传
      //   （本仓 t61/t65 都踩过「定义了但没被调用」的假通过）。
      final cardStart = code.indexOf('class _ContinueCard', start);
      expect(cardStart, greaterThan(0));
      final card = code.substring(cardStart);
      expect(card.contains('layoutWidth: coverWidth'), isTrue,
          reason: 'coverWidth 传进来了却没交给 coverImage');
    });

    test('D5 ★ 剥注释器自检（否则 D4 的计数可能是瞎数）', () {
      expect(_stripComments('a; // toggleFavorite\nb;').contains('toggleFavorite'),
          isFalse);
      expect(_stripComments('a; // toggleFavorite\nb;').contains('a;'), isTrue);
      expect(_stripComments('a; // toggleFavorite\nb;').contains('b;'), isTrue);
      // 字符串里的 `//` 不是注释
      expect(_stripComments("final u = 'http://x';").contains('http://x'), isTrue);
      // 块注释（含多行）
      expect(_stripComments('a; /* LayoutBuilder( */ b;').contains('LayoutBuilder('),
          isFalse);
      expect(
          _stripComments('a;\n/*\n * LayoutBuilder(\n */\nb;')
              .contains('LayoutBuilder('),
          isFalse);
      // ★ 阳性对照：剥完还剩的 `LayoutBuilder(` 必须被数出来
      expect(
          _stripComments('// LayoutBuilder(\nreal LayoutBuilder( here;')
              .contains('LayoutBuilder('),
          isTrue);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // E. 行尾与体量
  // ═══════════════════════════════════════════════════════════════════
  group('E. 行尾与体量', () {
    test('E1 live_page.dart 保持 CRLF，另四个保持 LF（不许整文件被重写）', () {
      final live = _src('lib/ui/live_page.dart');
      expect(live.contains('\r\n'), isTrue, reason: 'live_page.dart 被改成 LF 了');
      expect(live.replaceAll('\r\n', '').contains('\n'), isFalse,
          reason: 'live_page.dart 里混进了裸 LF');

      for (final p in <String>[
        'lib/ui/widgets/cover_image.dart',
        'lib/ui/widgets/poster_card.dart',
        'lib/ui/follow_page.dart',
        'lib/ui/detail_page.dart',
      ]) {
        expect(_src(p).contains('\r'), isFalse, reason: '$p 里混进了 CR');
      }
    });

    test('E2 live_page.dart 仍 > 50000 字符', () {
      // merge_live_into_plugins_test.dart:415-467 钉着 greaterThan(50000)
      expect(_src('lib/ui/live_page.dart').length, greaterThan(50000));
    });
  });
}
