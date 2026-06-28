import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glotalk_v3/main.dart';

void main() {
  testWidgets('GloTalk V3 smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const GloTalkApp());

    // 验证 AppBar 标题存在
    expect(find.text('GloTalk V3'), findsOneWidget);

    // 验证首页正文存在
    expect(find.text('GloTalk V3 — 本地离线实时翻译'), findsOneWidget);
  });
}
