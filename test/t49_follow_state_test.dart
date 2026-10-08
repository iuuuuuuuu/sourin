// ═══════════════════════════════════════════════════════════════════════
//  ⑦ 追更状态误判 —— 用「收藏列表」判「追更状态」（用户报的真 bug）
// ═══════════════════════════════════════════════════════════════════════
//
// # 用户原话（逐字）
//
// > 我已追更的作品,我的追更还显示有这个,但是点进去 **追更状态 根本没选中**,
// > 再点击收藏,然后会变成 **收藏中 追更中** 两个状态都生效,这是bug
//
// # 根因（一句话）
//
// ```text
// 详情页只查了 listFavorites()             → SQL: WHERE favorited=1
// ⇒ 「只追更、未收藏」(favorited=0, following=1) 的行**不在结果里**
// ⇒ hit == null ⇒ _following = false ⇒ 显示"未追更"
// ```
// 点收藏后 `favorited` 变 1，该行**才第一次**进入结果集，
// 而它的 `following` **一直是 1** ⇒ "两个都亮"（现象 3 是现象 2 的必然结果）。
//
// # ★★★ 本文件的判据：**两个列表分别喂，且故意让其中一个缺行**
//
// 这是能**干净分开**正确与错误实现的唯一方式：
// ```text
// 只追更未收藏：favorites=[]        following=[该行]  → 期望 (false, true)
// 只收藏未追更：favorites=[该行]     following=[]      → 期望 (true,  false)
// 两个都要：    favorites=[该行]     following=[该行]   → 期望 (true,  true)
// 都没有：      favorites=[]        following=[]      → 期望 (false, false)
// ```
// ★ 旧实现是"在一份列表里找行"，所以**任何** "favorites 为空" 的用例
//   都会让它返回 (false,false) ⇒ 第 1 条必定红。
//
// # 原版对照（★ 原版也有这个 bug）
//
// ```javascript
// // 原版 src/views/DetailView.vue L219-224 —— 与修之前逐字相同
// const favs = await favApi.list(false);
// const hit = favs.find((f) => f.key === key);
// isFav.value = !!hit;
// following.value = !!hit?.following;    // ★ 同一个错
// ```
// 但原版 `src/components/MyShelf.vue:200-209` 的注释**已经承认**了这个坑
// （"list(false) 只返回收藏过的行 ⇒ following 那份拿不到只追更的条目"）。
// ⇒ ★★ **原版在 MyShelf 修了、DetailView 漏了** —— 我们移植了那个漏掉的 bug。
//
// # 为什么"两个都亮"是**对的**，不能加互斥
//
// Owner 两次纠正：「追更并不代表就要收藏，这是独立的状态」
// ⇒ `favorited` 与 `following` 是独立位，**可以同时为真**。
//   本文件的第 3 条用例就是在**钉住这个语义**（防止后人"顺手加互斥"）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/detail_page.dart';

/*
 * ⚠️ task-58：DetailPage 已不再是**独立页面**（Owner 裁决③），
 *    它现在由 MediaPage 嵌在下半屏（embedded: true）。
 *    ⇒ 本文件断言的契约**仍然成立**且仍在产品路径上（不是假绿）。
 *    而它被挂在正确的地方由 	est/t58_media_page_test.dart 的 group ③ 守着。
 */


/// 造一行 favorite
///
/// ★ 参数刻意叫 `favorited`/`following` —— 与 DB 的两个独立列同名，
///   提醒读者它们**不是互斥**的。
Favorite fav(
  String key, {
  bool favorited = false,
  bool following = false,
  String? title,
}) =>
    Favorite(
      key: key,
      provider: key.split(':').first,
      nativeId: key.split(':').skip(1).join(':'),
      title: title ?? key,
      favorited: favorited,
      following: following,
    );

/// 生产数据里真实的 key（来自用户 DB 的复制件）
///
/// `.probe/t43_dump_rows.py` 实测：库里那行是
/// `key=cycani:3862  无职转生 第三季 ～到了异世界就拿出真本事～`
/// 而详情页拼的是 `'${provider}:${id}'` ⇒ **格式一致**（已验证 MATCH）。
const kKey = 'cycani:3862';

void main() {
  // ═══════════════════════════════════════════════════════════════════
  //  ⓪ 仪器自检：证明这两个 bool 真的能独立变化
  // ═══════════════════════════════════════════════════════════════════

  group('⓪ 仪器自检（阳性对照：bool 不是恒真/恒假）', () {
    test('★ Favorite 的两个状态位可以**独立**设置', () {
      final a = fav('x:1', favorited: true, following: false);
      final b = fav('x:1', favorited: false, following: true);
      final c = fav('x:1', favorited: true, following: true);

      expect((a.favorited, a.following), (true, false));
      expect((b.favorited, b.following), (false, true));
      expect((c.favorited, c.following), (true, true),
          reason: '★★ 两个都为真是**合法状态**（Owner 明确要求独立）—— '
              '如果这条不成立，说明模型层把两个状态耦合了');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ① 四种组合 —— 这就是用户报的那个 bug
  // ═══════════════════════════════════════════════════════════════════

  group('① resolveFavFollowState：四种组合都必须对', () {
    test('★★★ 只追更未收藏 → (false, true)  ← **用户报的现象 2**', () {
      /*
       * ★ 这是修复的**核心判据**。
       *
       * 用户：「我已追更的作品…点进去 追更状态 根本没选中」
       *
       * 旧实现必然返回 (false, false)：
       * ```dart
       * final hit = [].where((f) => f.key == key).firstOrNull;  // favorites 为空
       * _following = hit?.following ?? false;                   // ⇒ false ★
       * ```
       * 而 `following` 列表里**明明有这一行**。
       */
      final got = resolveFavFollowState(
        favorites: const [], // ← 收藏列表里没有它（这正是 bug 的触发条件）
        following: [fav(kKey, following: true, title: '无职转生 第三季')],
        key: kKey,
      );

      expect(got.favorited, isFalse, reason: '没收藏 ⇒ favorited=false');
      expect(got.following, isTrue,
          reason: '★★★ 追更列表里有它 ⇒ following **必须**是 true。'
              '旧实现这里恒为 false —— 这就是用户看到的"追更状态没选中"');
    });

    test('★★ 只收藏未追更 → (true, false)', () {
      final got = resolveFavFollowState(
        favorites: [fav(kKey, favorited: true)],
        following: const [],
        key: kKey,
      );
      expect(got.favorited, isTrue);
      expect(got.following, isFalse,
          reason: '★ 反向也必须对 —— 不能"只要命中任一列表就两个都 true"');
    });

    test('★★★ 两个都要 → (true, true)  ← **这是合法状态，不是 bug**', () {
      /*
       * ★ 用户把这描述成 bug（"两个状态都生效,这是bug"），
       *   但 Owner 明确纠正过：**追更与收藏是独立状态，可以并存**。
       *
       * ⇒ 这条测试是在**钉住产品语义**：
       *   如果后人"顺手加互斥"（认为两个同时为真是错的），
       *   这条会红，并告诉他为什么不能那样改。
       *
       * 用户真正的痛点不是"两个都亮"，而是**第①条**：
       * 他被迫点收藏，只为了看到追更状态。修掉①，③自然不再是问题。
       */
      final got = resolveFavFollowState(
        favorites: [fav(kKey, favorited: true, following: true)],
        following: [fav(kKey, favorited: true, following: true)],
        key: kKey,
      );
      expect(got.favorited, isTrue);
      expect(got.following, isTrue,
          reason: '★★★ 两个都为真是**合法**的（Owner：「追更并不代表就要收藏，'
              '这是独立的状态」）—— 不许改成互斥');
    });

    test('★ 都没有 → (false, false)  ← 阳性对照', () {
      final got = resolveFavFollowState(
        favorites: const [],
        following: const [],
        key: kKey,
      );
      expect(got.favorited, isFalse);
      expect(got.following, isFalse,
          reason: '★ 都没碰过 ⇒ 两个都未选中（否则"按钮全亮"同样是 bug）');
    });

    test('★★ key 不匹配 → 两个都 false（别误命中别人的行）', () {
      final got = resolveFavFollowState(
        favorites: [fav('tyyszy:70260', favorited: true, following: true)],
        following: [fav('tyyszy:70260', favorited: true, following: true)],
        key: kKey,
      );
      expect(got.favorited, isFalse);
      expect(got.following, isFalse,
          reason: '★ 别的作品的追更/收藏状态不能泄漏到这一部');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② 静态审计：调用点必须是**两个**查询
  // ═══════════════════════════════════════════════════════════════════

  group('② 静态审计（防止有人把双查询改回单查询）', () {
    String read(String p) => File(p).readAsStringSync();

    /// 剥掉注释（状态机）—— **必须**，否则会命中我自己写的证据链注释
    ///
    /// ★ 本项目已踩 7 次"grep 命中注释导致假通过/假失败"。
    ///   本文件里尤其危险：我在 `resolveFavFollowState` 的文档里
    ///   **刻意引用了旧写法**（`_following = hit?.following`）来解释根因
    ///   —— 不剥注释的话，"旧写法不许回来"这条会**永远失败**
    ///   （我第一次跑就撞上了这个，实测确认）。
    String stripComments(String src) {
      final out = StringBuffer();
      var i = 0;
      String? quote;
      while (i < src.length) {
        final c = src[i];
        final n = i + 1 < src.length ? src[i + 1] : '';
        if (quote != null) {
          if (c == r'\') {
            out.write(c);
            if (n.isNotEmpty) {
              out.write(n);
              i += 2;
              continue;
            }
          }
          if (c == quote) quote = null;
          out.write(c);
          i++;
          continue;
        }
        if (c == "'" || c == '"') {
          quote = c;
          out.write(c);
          i++;
          continue;
        }
        if (c == '/' && n == '/') {
          while (i < src.length && src[i] != '\n') {
            i++;
          }
          continue;
        }
        if (c == '/' && n == '*') {
          i += 2;
          while (i < src.length &&
              !(src[i] == '*' && i + 1 < src.length && src[i + 1] == '/')) {
            if (src[i] == '\n') out.write('\n');
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

    test('★★★ _init 里必须同时查收藏与追更两个列表', () {
      final src = stripComments(read('lib/ui/detail_page.dart'));

      expect(src.contains('SourinApi.listFavorites()'), isTrue,
          reason: '收藏列表（followingOnly: false）');
      expect(src.contains('SourinApi.listFavorites(followingOnly: true)'), isTrue,
          reason: '★★★ 追更列表必须**单独**查 —— '
              '只查收藏列表正是这个 bug 的根因');
      expect(src.contains('resolveFavFollowState('), isTrue,
          reason: '★ 取值必须走那个纯函数（它可被单测覆盖）');
    });

    test('★★ 不许再用"在一份列表里找行然后读 two bools"的旧写法', () {
      // ★ 剥注释后才判 —— 见上面 stripComments 的说明
      final src = stripComments(read('lib/ui/detail_page.dart'));

      // 旧写法的特征：从同一个 hit 里读两个字段
      expect(src.contains('_isFav = hit?.favorited'), isFalse,
          reason: '★★★ 旧写法（hit 为 null ⇒ following 也被误判 false）不许回来');
      expect(src.contains('_following = hit?.following'), isFalse,
          reason: '★★★ 同上 —— 这是用户报的那个 bug 的核心一行');
    });

    test('★ 仪器自检：stripComments 真的剥掉了注释里的旧写法', () {
      final raw = read('lib/ui/detail_page.dart');
      final code = stripComments(raw);

      // 原始文本里**有**（我的文档注释引用了它）……
      expect(raw.contains('_following = hit?.following'), isTrue,
          reason: '★ 文档注释里刻意保留了旧写法作为"历史证据"');
      // ……但剥掉注释后**没有**（那才是真代码）
      expect(code.contains('_following = hit?.following'), isFalse,
          reason: '★★ 剥注释后不许有 —— 这条同时证明了 stripComments 有效');
    });
  });
}
