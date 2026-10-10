// ═══════════════════════════════════════════════════════════════════════
//  CR-19 回归门禁（B）：「JS 插件」tab 的调用点不能退回全局下标
// ═══════════════════════════════════════════════════════════════════════
//
//  配套 zz_cr_ui_19_subset_reorder_test.dart（A）：那边验"换位纯函数"的行为，
//  这边验"**谁在调用它**"。两边必须分开跑：纯函数是新加的符号，缺陷代码上
//  整个文件编译不过；结构性断言这边今天就能编译，能在**缺陷代码**上跑出
//  真正的断言失败（RED 不是"编译不过"，也不是"跑不起来"）。
//
// # 缺陷
//
// 「JS 插件」二级页只渲染 _nonLiveProviders（子序列），但
//   onReorder: _onReorderProviders,                     ← 收的是 tab 内下标 i
//   onMoveUp:   () => _moveProviderBy(list[i].id, -1),  ← id 对
// 而 _onReorderProviders / _moveProviderBy 内部按**全局** _providers 切表：
//   ids.removeAt(oldIndex); ids.insert(newIndex, moved);
// ⇒ 拖动/点箭头移走的是**别的源**，本 tab 里两张卡的相对顺序一点没变。
//
// 修法：把下标交给子集换位纯函数（reorderSubsetIds / reorderLiveIds 那一族），
//      只改**子集内**的相对顺序。
//
// ⚠️ provider_reorder_cards_test.dart 锁的是另一侧（"回调接上了吗"：
//   onReorder: _onReorderProviders / key: ValueKey(list[i].id) /
//   canMoveUp: i > 0 / canMoveDown: i < list.length - 1），两处合起来才是完整护栏。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final src = File('lib/ui/settings_page.dart').readAsStringSync();

  /// 只认**代码**不认注释：注释里可以自由解释实现。
  String codeOnly(String s) =>
      s.split('\n').where((l) => !l.trimLeft().startsWith('//')).join('\n');

  String block(String start, [int span = 2000]) {
    final at = src.indexOf(start);
    expect(at, greaterThan(-1), reason: '源码里找不到锚点：$start');
    return src.substring(at, at + span);
  }

  test('★ _onReorderProviders 必须把下标交给子集换位函数，不能切全局表', () {
    final body = codeOnly(block('Future<void> _onReorderProviders'));
    expect(
      body.contains('reorderSubsetIds('),
      isTrue,
      reason: '★ 拖动排序必须走子集换位（reorderSubsetIds）',
    );
    expect(
      body.contains('subsetIds: _nonLiveProviders'),
      isTrue,
      reason: '★ 传给换位函数的必须是「JS 插件」tab 真正渲染的那个子集',
    );
    expect(
      body.contains('ids.removeAt(oldIndex)'),
      isFalse,
      reason: '★ 用全局下标切 _providers 就是这个 bug：'
          '会把**别的源**移走，本 tab 里两张卡的顺序一点不变',
    );
    expect(
      body.contains('ids.insert(newIndex, moved)'),
      isFalse,
      reason: '★ 同上：不能用全局下标回插',
    );
  });

  test('★ _moveProviderBy 的 i/j 必须算在子集里', () {
    final body = codeOnly(block('Future<void> _moveProviderBy'));
    expect(
      body.contains('_nonLiveProviders'),
      isTrue,
      reason: '★ 箭头移动的起点位置必须按「JS 插件」tab 的子序列算',
    );
    expect(
      body.contains('ids.removeAt(i);'),
      isFalse,
      reason: '★ 按全局下标 removeAt 就会移错人',
    );
    expect(
      body.contains('ids.insert(j, id);'),
      isFalse,
      reason: '★ 按全局下标 insert 同上',
    );
  });
}
