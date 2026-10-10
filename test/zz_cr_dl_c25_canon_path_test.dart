// ═══════════════════════════════════════════════════════════════════════
//  ★★★ CR-25 回归探针：canonicalLocalPath 的**跨平台**语义
// ═══════════════════════════════════════════════════════════════════════
//
// # 任务书的要求
// ```text
// ★必须证明非 Windows 语义下修复正确：至少一条断言路径规范化的单元测试，
//   覆盖「Windows 大小写混写 + 反斜杠」和「macOS/Linux 正斜杠 + 保留大小写」
//   两种输入，RED / GREEN 都贴出来。
// ```end
//
// # ★ 为什么必须让「平台判断」**参数化**，而不是靠 if (Platform.isWindows) 守卫
// ```text
// 那台跑测试的机器是 Windows（Platform.isWindows 是编译期常量 true）
//   ⇒ 一条被平台守卫包住的 POSIX 断言在这台机器上**永远不执行**，
//     绿灯只证明「Windows 分支没坏」，对 macOS CI 一点保证都没有
//     —— 那正是本仓铁律「假门禁比红更糟」要防的事。
// ⇒ 这里把平台判断从**编译期常量**变成**入参**（canonicalLocalPathAs），
//   于是 POSIX 语义能在 Windows 主机上被**真跑一遍**。
//   canonicalLocalPath 本身退化成一行委托，**语义逐字不变**。
// ```end
//
// # CR-25 对 canonicalLocalPath 的两条说法，实测核对
// ```text
// ① 「反斜杠转正斜杠只对 Windows 生效」
//    ⇒ **不成立**：lib/ui/cache_page.dart:729 的 replaceAll 在**任何平台**都跑。
//      （本文件用例 ② 会在任何平台都通过，包括 Windows —— 这就是证据。）
// ② 「非 Windows 也要折小写」
//    ⇒ **是错的**：POSIX 大小写敏感。折小写会把 /movies/E1.mp4 与
//      /movies/e1.mp4（两个不同文件）算成**同一个**进度键 ⇒ 续播串集。
// ⇒ 本文件不折小写，只把这条语义**变成可测的**，并钉住它。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/ui/cache_page.dart';

void main() {
  // ═════════════════════════════════════════════════════════════════════
  //  ① Windows 语义：大小写混写 + 反斜杠 + 长路径前缀 ⇒ 折成**一个**键
  // ═════════════════════════════════════════════════════════════════════
  group('CR-25 ① Windows：大小写不敏感 ⇒ 大小写混写必须折成同一个键', () {
    test('大小写混写 + 反斜杠的 6 种写法收敛成同一个进度键', () {
      const mixed = r'C:\Users\BoB\Videos\MyShow\E1.mp4';
      final keys = <String>{
        canonicalLocalPathAs(mixed, windows: true),
        canonicalLocalPathAs(mixed.toUpperCase(), windows: true),
        canonicalLocalPathAs(mixed.toLowerCase(), windows: true),
        canonicalLocalPathAs(r'C:\Users\BoB\Videos\MyShow\.\E1.mp4', windows: true),
        canonicalLocalPathAs(r'C:\Users\BoB\Videos\MyShow\sub\..\E1.mp4', windows: true),
        canonicalLocalPathAs(r'C:\Users\BoB\Videos\MyShow\\\E1.mp4', windows: true),
      };
      for (final k in keys) {
        debugPrint('CR-25 Win 变体 ⇒ $k');
      }
      expect(keys.length, 1,
          reason: '★★★ NTFS 大小写不敏感 ⇒ 同一文件的 6 种写法必须同一个键');
      expect(keys.first, 'c:/users/bob/videos/myshow/e1.mp4');
    });

    test('长路径前缀（\\?\）不改变文件身份', () {
      const mixed = r'C:\Users\BoB\Videos\MyShow\E1.mp4';
      debugPrint('CR-25 长路径前缀 ⇒ ' +
          canonicalLocalPathAs(r'\\?\' + mixed, windows: true));
      expect(
        canonicalLocalPathAs(r'\\?\' + mixed, windows: true),
        canonicalLocalPathAs(mixed, windows: true),
        reason: '★★ 长路径前缀只是绕 MAX_PATH，不改变文件身份',
      );
    });

    test('UNC 前缀（\\?\UNC\server\share）折成 //server/share', () {
      debugPrint('CR-25 UNC ⇒ ' +
          canonicalLocalPathAs(r'\\?\UNC\nas\share\E1.mp4', windows: true));
      expect(
        canonicalLocalPathAs(r'\\?\UNC\nas\share\E1.mp4', windows: true),
        '//nas/share/e1.mp4',
        reason: '★★ UNC 靠开头那对斜杠，折叠时必须保留它',
      );
    });
  });

  // ═════════════════════════════════════════════════════════════════════
  //  ② 反斜杠折叠：CR 说「只对 Windows 生效」—— 实测**任何平台都生效**
  // ═════════════════════════════════════════════════════════════════════
  group('CR-25 ② 反斜杠折叠是**全平台**行为', () {
    test('windows:false 分支同样把反斜杠折成正斜杠（CR 该处说法不成立）', () {
      final got = canonicalLocalPathAs(
        r'/Users/Bob\Movies\MyShow/E1.mp4',
        windows: false,
      );
      debugPrint('CR-25 非 Windows 也折反斜杠 ⇒ $got');
      expect(got, '/Users/Bob/Movies/MyShow/E1.mp4',
          reason: '★★ CR 说的「反斜杠折叠只对 Windows 生效」与实现不符');
    });

    test('真机上的 canonicalLocalPath 与按本平台参数化调用**完全一致**', () {
      for (final p in <String>[
        r'C:\Users\BoB\Videos\MyShow\E1.mp4',
        '/Users/Bob/Movies/MyShow/E1.mp4',
      ]) {
        final real = canonicalLocalPath(p);
        final byPlatform = canonicalLocalPathAs(p, windows: Platform.isWindows);
        debugPrint('CR-25 一致性 $p ⇒ $real / $byPlatform');
        expect(real, byPlatform,
            reason: '★ canonicalLocalPath 必须等价于按本平台参数化调用');
      }
    });
  });

  // ═════════════════════════════════════════════════════════════════════
  //  ③ macOS/Linux 语义：正斜杠 + **保留大小写**（关键：这里在 Windows 上真跑）
  // ═════════════════════════════════════════════════════════════════════
  group('CR-25 ③ 非 Windows：大小写敏感 ⇒ 必须保留大小写', () {
    test('大小写**原样保留**（不能折小写）', () {
      const p1 = '/Users/Bob/Movies/MyShow/E1.mp4';
      const p2 = '/Users/Bob/Movies/MyShow/e1.mp4';
      debugPrint('CR-25 POSIX 保留：' +
          canonicalLocalPathAs(p1, windows: false) + ' / ' +
          canonicalLocalPathAs(p2, windows: false));
      expect(canonicalLocalPathAs(p1, windows: false), p1);
      expect(canonicalLocalPathAs(p2, windows: false), p2);
    });

    test('★★★ 大小写不同的两个文件必须是**两个不同的进度键**', () {
      const p1 = '/Users/Bob/Movies/MyShow/E1.mp4';
      const p2 = '/Users/Bob/Movies/MyShow/e1.mp4';
      expect(
        canonicalLocalPathAs(p1, windows: false),
        isNot(canonicalLocalPathAs(p2, windows: false)),
        reason: '★★★ POSIX 大小写敏感 ⇒ 折小写会把两个不同文件混成一个键'
            '（CR-25 建议的「非 Windows 也折小写」会造成串集）',
      );
      // ★ 对照：Windows 上这两个**必须**相同（那才是折小写的理由）
      expect(
        canonicalLocalPathAs(p1, windows: true),
        canonicalLocalPathAs(p2, windows: true),
        reason: '★ Windows 上 NTFS 大小写不敏感 ⇒ 同一文件 ⇒ 必须同一个键',
      );
    });

    test('同一文件的多种写法仍收敛成一个键（反斜杠 / 重复斜杠 / 点段）', () {
      final keys = <String>{
        canonicalLocalPathAs('/Users/Bob/Movies/MyShow/E1.mp4', windows: false),
        canonicalLocalPathAs('/Users/Bob//Movies/./MyShow/E1.mp4', windows: false),
        canonicalLocalPathAs('/Users/Bob/Movies/other/../MyShow/E1.mp4', windows: false),
        canonicalLocalPathAs(r'/Users\Bob\Movies\MyShow\E1.mp4', windows: false),
      };
      for (final k in keys) {
        debugPrint('CR-25 POSIX 变体 ⇒ $k');
      }
      expect(keys.length, 1,
          reason: '★ 同一文件的各种写法必须算出同一个进度键');
    });

    test('UNC 样式的开头双斜杠在非 Windows 上也保留', () {
      debugPrint('CR-25 POSIX UNC ⇒ ' +
          canonicalLocalPathAs('//nas/share//E1.mp4', windows: false));
      expect(
        canonicalLocalPathAs('//nas/share//E1.mp4', windows: false),
        '//nas/share/E1.mp4',
        reason: '★ 开头那对斜杠是 UNC 的身份，不能被折叠掉',
      );
    });
  });
}
