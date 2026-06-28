import 'package:flutter_test/flutter_test.dart';
import 'package:glotalk_v3_cross/main.dart';

void main() {
  testWidgets('GloTalk smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const GloTalkApp());
  });
}