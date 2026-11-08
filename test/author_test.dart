import 'package:flutter_test/flutter_test.dart';
import 'package:jmoe/core/models.dart';

/// 作者名清洗回归测试。
///
/// 用户反馈「有些作者名称会额外被 [] 包裹」——早期只剥最外层一次，
/// `[[作者]]` 剥完还剩 `[作者]`。这里锁死各种形态。
void main() {
  test('单层方括号被去掉', () {
    expect(cleanAuthor('[作者]'), '作者');
    expect(cleanAuthor('[N/A]'), 'N/A');
  });

  test('多层方括号全部去掉', () {
    expect(cleanAuthor('[[作者]]'), '作者');
    expect(cleanAuthor('[[[作者]]]'), '作者');
  });

  test('两侧空白被去掉', () {
    expect(cleanAuthor('  [作者]  '), '作者');
    expect(cleanAuthor('作者 '), '作者');
  });

  test('多段方括号：不整体剥离，保留原样', () {
    // `[作者] [汉化组]` 的首尾虽然也是 [ ]，但不是一对方括号
    expect(cleanAuthor('[作者] [汉化组]'), '[作者] [汉化组]');
  });

  test('没有方括号时原样返回', () {
    expect(cleanAuthor('作者'), '作者');
    expect(cleanAuthor(''), '');
  });

  test('只有一侧方括号时不动', () {
    expect(cleanAuthor('[作者'), '[作者');
    expect(cleanAuthor('作者]'), '作者]');
  });

  test('括号内嵌方括号的完整包裹仍可剥', () {
    expect(cleanAuthor('[[a] b]'), '[a] b');
  });
}
