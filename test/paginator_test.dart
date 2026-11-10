import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jmoe/core/reader_paginator.dart';

void main() {
  const paginator = TextPaginator();
  const style = TextStyle(fontSize: 16, height: 1.8);

  List<PageSlice> paginate(String text, {double w = 340, double h = 600}) {
    return paginator.paginate(
      text: text,
      style: style,
      maxWidth: w,
      maxHeight: h,
      align: TextAlign.justify,
    );
  }

  group('TextPaginator 边界', () {
    test('空文本返回空页列表', () {
      expect(paginate(''), isEmpty);
    });

    test('零宽度不崩溃且返回空', () {
      expect(paginate('一些文字', w: 0), isEmpty);
    });

    test('零高度不崩溃且返回空', () {
      expect(paginate('一些文字', h: 0), isEmpty);
    });

    test('短文本只有一页', () {
      final pages = paginate('很短的一句话。');
      expect(pages.length, 1);
      expect(pages.first.start, 0);
    });

    test('页面区间首尾相接且覆盖全文', () {
      final text = List.generate(60, (i) => '第$i段文字内容，用来测试分页边界。').join('\n');
      final pages = paginate(text);
      expect(pages, isNotEmpty);
      expect(pages.first.start, 0);
      for (var i = 1; i < pages.length; i++) {
        expect(pages[i].start, pages[i - 1].end);
      }
      expect(pages.last.end, text.length);
    });

    test('索引连续从 0 递增', () {
      final text = List.generate(20, (i) => '段落$i：内容内容内容内容内容。').join('\n');
      final pages = paginate(text);
      for (var i = 0; i < pages.length; i++) {
        expect(pages[i].index, i);
      }
    });

    test('超长单段（无换行）也能分页', () {
      final text = 'あ' * 3000;
      final pages = paginate(text);
      expect(pages.length, greaterThan(1));
      expect(pages.last.end, text.length);
    });

    test('纯空白文本不产生非法页', () {
      final pages = paginate('   \n\n   ');
      for (final p in pages) {
        expect(p.end, greaterThanOrEqualTo(p.start));
      }
    });

    test('emoji/代理对不会被切断', () {
      final text = '😀' * 2000;
      final pages = paginate(text);
      expect(pages, isNotEmpty);
      for (final p in pages) {
        if (p.end > 0 && p.end < text.length) {
          final c = text.codeUnitAt(p.end);
          expect(c >= 0xDC00 && c <= 0xDFFF, isFalse,
              reason: '切点 ${p.end} 落在代理对中间');
        }
      }
    });

    test('首行缩进时仍覆盖全文长度（缩进会改变文本）', () {
      const text = '第一段。\n第二段。';
      final pages = paginator.paginate(
        text: text,
        style: style,
        maxWidth: 340,
        maxHeight: 600,
        align: TextAlign.justify,
        indentEm: 2,
      );
      expect(pages, isNotEmpty);
    });
  });
}
