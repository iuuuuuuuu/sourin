// 镜像下载回退的往返一致性（lead 复核 update agent 的实现时补的）
//
// # 为什么这条重要
//
// `client.dart` 的下载回退是**反推**出来的：镜像地址拼不上去时，用
// `substring(mirrorPrefix.length)` 把前缀剥掉、还原成 GitHub 直链再试一次。
// 若这个往返不成立，镜像一挂就连直连都试不了 —— 更新功能整体失效，
// 而且症状是「一直失败」，很难一眼看出是这里错了。
import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/app_update/route.dart';

void main() {
  const raw = 'https://github.com/a/b/releases/download/v1/x.zip';

  RouteRewriter rewriterFor(UpdateRouteConfig cfg) => RouteRewriter(cfg);

  test('镜像前缀拼接后，剥掉前缀能还原原始直链', () {
    final cfg = UpdateRouteConfig(
      route: UpdateRoute.mirror,
      customMirror: 'https://ghfast.top/',
    );
    final rw = rewriterFor(cfg);
    final mirrored = rw.rewriteDownloadUrl(raw);
    expect(mirrored, 'https://ghfast.top/$raw');

    final prefix = cfg.mirrorPrefix;
    final restored = mirrored.substring(
      prefix.length.clamp(0, prefix.length),
    );
    expect(restored, raw, reason: '还原不出来 ⇒ 镜像挂掉时连直连都试不了');
  });

  test('预置镜像名同样成立', () {
    final cfg = UpdateRouteConfig(
      route: UpdateRoute.mirror,
      mirrorName: UpdateMirror.list.first.name,
    );
    final prefix = cfg.mirrorPrefix;
    expect(prefix, isNotEmpty);
    final mirrored = rewriterFor(cfg).rewriteDownloadUrl(raw);
    expect(mirrored.startsWith(prefix), isTrue);
    expect(mirrored.substring(prefix.length), raw);
  });

  test('非镜像路由时 URL 原样返回', () {
    final cfg = UpdateRouteConfig(
      route: UpdateRoute.direct,
      customMirror: 'https://ghfast.top/',
    );
    expect(rewriterFor(cfg).rewriteDownloadUrl(raw), raw);
  });

  test('API 地址永远不被镜像改写（镜像只代理文件）', () {
    final cfg = UpdateRouteConfig(
      route: UpdateRoute.mirror,
      customMirror: 'https://ghfast.top/',
    );
    final api = Uri.parse('https://api.github.com/repos/a/b/releases/latest');
    expect(rewriterFor(cfg).resolveApi(api), api.toString());
  });

  test('非 github.com 的地址不被镜像改写', () {
    final cfg = UpdateRouteConfig(
      route: UpdateRoute.mirror,
      customMirror: 'https://ghfast.top/',
    );
    expect(rewriterFor(cfg).rewriteDownloadUrl('https://example.com/x.zip'),
        'https://example.com/x.zip');
  });
}