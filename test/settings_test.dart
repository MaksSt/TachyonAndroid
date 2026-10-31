import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tachyon_client/app_tone.dart';
import 'package:tachyon_client/controller.dart';
import 'package:tachyon_client/main.dart';

import 'settings_flow.dart';

void main() {
  test(
    'All color tones retain accessible text contrast in both brightness modes',
    () {
      for (final tone in AppTone.values) {
        for (final brightness in Brightness.values) {
          final scheme = ColorScheme.fromSeed(
            seedColor: Color(
              brightness == Brightness.light ? tone.lightSeed : tone.darkSeed,
            ),
            brightness: brightness,
          );
          for (final pair in [
            (scheme.primary, scheme.onPrimary),
            (scheme.secondaryContainer, scheme.onSecondaryContainer),
            (scheme.surface, scheme.onSurface),
            (scheme.surfaceContainer, scheme.onSurfaceVariant),
          ]) {
            final first = pair.$1.computeLuminance(),
                second = pair.$2.computeLuminance();
            final ratio = first > second
                ? (first + .05) / (second + .05)
                : (second + .05) / (first + .05);
            expect(
              ratio,
              greaterThanOrEqualTo(4.5),
              reason: '${tone.name} $brightness',
            );
          }
        }
      }
    },
  );
  testWidgets(
    'Settings sections navigate and remain reactive on a narrow screen with large text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await checkSettingsNavigation(tester);
    },
  );

  testWidgets('Color tone changes the live theme and survives reopening', (
    tester,
  ) async {
    final api = SettingsApi();
    await tester.pumpWidget(TachyonApp(api: api));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Настройки').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Оформление'));
    await tester.pumpAndSettle();
    for (final tone in AppTone.values) {
      await tester.tap(find.byType(DropdownButtonFormField<AppTone>));
      await tester.pumpAndSettle();
      await tester.tap(find.text(tone.label).last);
      await tester.pumpAndSettle();
      final scheme = Theme.of(tester.element(find.byType(Scaffold).last))
          .colorScheme;
      expect(
        scheme.primary,
        ColorScheme.fromSeed(seedColor: Color(tone.lightSeed)).primary,
      );
      expect((jsonDecode(api.saved!) as Map)['tone'], tone.name);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(TachyonApp(api: api));
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.byType(Scaffold))).colorScheme.primary,
      ColorScheme.fromSeed(seedColor: Color(AppTone.green.lightSeed)).primary,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('Older preferences default to red and a failed save restores the previous tone', () async {
    final api = SettingsApi()
      ..saved = jsonEncode({
        'theme': 'dark',
        'tone': 'unknown',
        'profiles': [],
        'subscriptions': [],
      });
    final client = ClientController(api);
    await client.initialize();
    expect(client.tone, AppTone.red);
    await client.setTone(AppTone.green);
    api.failSave = true;
    await expectLater(client.setTone(AppTone.blue), throwsStateError);
    expect(client.tone, AppTone.green);
    expect(client.themeChoice, 'dark');
    expect((jsonDecode(api.saved!) as Map)['tone'], 'green');
    client.dispose();
  });
}
