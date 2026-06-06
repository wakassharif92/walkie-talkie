import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie_desktop/main.dart';

void main() {
  testWidgets('shows the push-to-talk surface', (tester) async {
    final controller = WalkieTalkieController()
      ..connected = true
      ..state = TalkState.idle
      ..notice = 'Ready';

    await tester.pumpWidget(
      MaterialApp(home: WalkieTalkieHome(controller: controller)),
    );

    expect(find.text('PUSH TO TALK'), findsOneWidget);
    expect(find.text('Ready'), findsOneWidget);

    await controller.dispose();
  });
}
