// ═══════════════════════════════════════════════════════════════════════
//  CR-19 回归门禁：「JS 插件」tab 的排序只作用于非直播源子序列
// ═══════════════════════════════════════════════════════════════════════
//
// # 缺陷（CR-19，本批自己在 task-74 里引入的）
//
// 「JS 插件」二级页现在只渲染 _nonLiveProviders（把直播源分隔到另一个 tab），
// 但 ReorderableCardGrid 的 onReorder / 上下箭头走的是 _onReorderProviders /
// _moveProviderBy，而这两个收/算的是**全局** _providers 的下标：
//
//   itemBuilder: (context, i, …) => … key: ValueKey(list[i].id)   ← list 是子集
//   onReorder: _onReorderProviders,                                ← 收的是子集下标 i
//   onMoveUp:   () => _moveProviderBy(list[i].id, -1),             ← id 对、位置错
//
// ⇒ 拖动/点箭头移走的是**别的源**；本 tab 里两张卡的相对顺序一点没变。
//
// # 本文件锁的是换位纯函数本身（ZZ_CRITICAL：判据不许写死成"某个全局排列"）
//
// 判据按**契约**写：
//   ① 被移动项落到子序列的第 newIndex 位（网格语义：落点格 = 目标位，不 -= 1）
//   ② 子集外的项（直播源）相对顺序一个都不动
//   ③ 结果是 allIds 的一个排列（不多、不少、不重复）
// 之所以不写死整条全局顺序：只要契约成立，落点必然唯一确定，写死反而会把
// 测试焊死在某一种交错写法上（换一种同样正确的交错就假红）。
//
// ★ 附带**反证**：每条用例都对照"旧的全局切表"算一遍，说明两者确实不同 ——
//   否则下面的断言可能只是恒真（假门禁比红更糟）。
//
// # 为什么不能 pump SettingsPage 来验
//
// build() → SourinApi.version → _ensureBound() → DynamicLibrary.open(
// 'sourin_core.dll')；ffi.dart 的 _lib 是 private static 且**没有注入口**
// ⇒ 整棵子树在 flutter_test 里会被换成 ErrorWidget（t76 文件头已记）。
// 好在换位函数是 public static、本 bug 又是**纯逻辑**——与 t76 同一套路：
// 直接调**发布出去的那份**纯函数，测的就是真身。

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/ui/settings_page.dart';

void main() {
  /// 全局顺序 = 非直播源 a、直播源 L1、非直播源 b、直播源 L2、非直播源 c
  /// （交错夹具：直播源把子集下标与全局下标错开，"移错人"才会暴露）
  const all = <String>['a', 'L1', 'b', 'L2', 'c'];
  const nonLive = <String>['a', 'b', 'c'];
  const live = <String>['L1', 'L2'];

  /// ★ 生产代码（发布出去的那份）
  List<String>? move(
    List<String> allIds,
    List<String> subsetIds,
    int oldIndex,
    int newIndex,
  ) =>
      SettingsPageState.reorderSubsetIds(
        allIds: allIds,
        subsetIds: subsetIds,
        oldIndex: oldIndex,
        newIndex: newIndex,
      );

  /// 旧的实现（CR-19 缺陷代码）在**全局表**上切一刀，算出来长这样。
  /// 只用于对照，证明"子集语义 ≠ 全局语义"。
  List<String> legacyGlobalCut(List<String> allIds, int oldIndex, int newIndex) {
    final ids = List<String>.of(allIds);
    final moved = ids.removeAt(oldIndex);
    ids.insert(newIndex, moved);
    return ids;
  }

  List<String> project(List<String> ids, List<String> others) =>
      ids.where((id) => !others.contains(id)).toList();

  /// 按契约验一次换位；返回结果好让用例继续做反证。
  List<String> expectSubsetMove({
    required int oldIndex,
    required int newIndex,
    String label = '',
  }) {
    final r = move(all, nonLive, oldIndex, newIndex);
    expect(r, isNotNull, reason: '$label 合法换位不该返回 null');
    expect(r!.toSet(), all.toSet(), reason: '$label 结果必须是 allIds 的一个排列');
    expect(r.length, all.length, reason: '$label 不得增删条目');
    expect(
      project(r, nonLive),
      orderedEquals(live),
      reason: '$label ★ 直播源的相对顺序必须一个都不动（那是另一个 tab 的事）',
    );
    final movedId = nonLive[oldIndex];
    // project(r, live) = 把直播源摘掉 ⇒ 剩下的就是本 tab 看到的那一串
    final subsetAfter = project(r, live);
    expect(
      subsetAfter[newIndex],
      movedId,
      reason: '$label ★ 被拖的那张卡必须真的落到落点格（子序列第 $newIndex 位）',
    );
    return r;
  }

  group('★ 通用子序列换位纯函数（真跑生产代码）', () {
    test('子集内下移一位：被拖的卡要真的换位，直播源一个都不动', () {
      final r = expectSubsetMove(oldIndex: 0, newIndex: 1, label: '下移一位：');
      expect(
        project(r, live),
        orderedEquals(<String>['b', 'a', 'c']),
        reason: '★ 本 tab 里 a 换到了 b 之后 —— 缺陷版本这里是 [a, b, c]'
            '（一点没动，看着像按钮坏了，这才是用户报的 bug）',
      );
      // ★ 反证：旧的全局切表给的是另一个结果 ⇒ 本断言确实在区分两者
      expect(legacyGlobalCut(all, 0, 1), isNot(orderedEquals(r)),
          reason: '子集语义必须与旧的全局语义不同，否则测不出 CR-19');
    });

    test('子集内上移一位：方向与下移对称', () {
      final r = expectSubsetMove(oldIndex: 2, newIndex: 1, label: '上移一位：');
      expect(
        project(r, live),
        orderedEquals(<String>['a', 'c', 'b']),
        reason: '★ c 从末位挪到 a 与 b 之间',
      );
      expect(legacyGlobalCut(all, 2, 1), isNot(orderedEquals(r)),
          reason: '同上：必须与全局语义不同');
    });

    test('拖到子集两端：只换位，不越界、不丢项', () {
      final first = expectSubsetMove(oldIndex: 0, newIndex: 2, label: '拖到子集末位：');
      expect(project(first, live), orderedEquals(<String>['b', 'c', 'a']));
      final last = expectSubsetMove(oldIndex: 2, newIndex: 0, label: '拖到子集首位：');
      expect(project(last, live), orderedEquals(<String>['c', 'a', 'b']));
    });

    test('★ 越界/原地不动一律返回 null（调用方就不写库）', () {
      expect(move(all, nonLive, -1, 0), isNull, reason: 'oldIndex 越下界');
      expect(move(all, nonLive, 3, 0), isNull, reason: 'oldIndex 越上界');
      expect(move(all, nonLive, 1, 1), isNull, reason: '原地放下不该白写一次盘');
      expect(
        move(<String>['a', 'b'], <String>['a', 'zz'], 0, 1),
        isNull,
        reason: '锚点不在全局表里 ⇒ 拒绝（否则会静默丢一个源）',
      );
    });

    test('newIndex 越界时钳到子集末位（而不是当成非法输入丢掉这次拖动）', () {
      final r = move(all, nonLive, 0, 99);
      expect(r, isNotNull, reason: '钳位后仍是一次合法换位，不该丢');
      expect(project(r!, live), orderedEquals(<String>['b', 'c', 'a']),
          reason: 'a 落到子集末位');
      expect(project(r, nonLive), orderedEquals(live),
          reason: '★ 钳位是子集内部的事，直播源依旧不动');
    });

    test('reorderLiveIds 必须仍然等价（t76 在用，不得破坏）', () {
      final ids = <String>['a', 'L1', 'b', 'L2'];
      final a = SettingsPageState.reorderLiveIds(
        allIds: ids,
        liveIds: <String>['L1', 'L2'],
        oldIndex: 0,
        newIndex: 1,
      );
      final b = move(ids, <String>['L1', 'L2'], 0, 1);
      expect(a, equals(b), reason: '★ 旧的 reorderLiveIds 必须等价于新的通用函数');
      expect(a, orderedEquals(<String>['a', 'b', 'L2', 'L1']),
          reason: '直播子序列里 L1 换到 L2 之后（L1 下移到第 1 位）');
    });
  });
}