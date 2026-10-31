import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tachyon_client/controller.dart';
import 'package:tachyon_client/core_settings_card.dart';

class UpdateApi extends NativeApi {
  int disconnects = 0, requests = 0;
  String selection = 'bundled';
  bool automatic = false, busy = false;
  @override
  Future<Map<String, dynamic>> status() async => {
    'state': 'running',
    'logs': <String>[],
    'coreVersion': 'v0.2.7',
    'coreSelectionId': selection,
    'runningCoreVersion': 'v0.2.6',
    'runningCoreId': 'previous',
    'coreManager': {
      'autoUpdate': automatic,
      'canRollback': true,
      'previousVersion': 'v0.2.6',
    },
    'coreUpdate': {
      'busy': busy,
      'phase': busy ? 'downloading' : 'idle',
      'progress': busy ? 35 : -1,
      'message': busy ? 'Загрузка Android-ядра' : '',
    },
  };
  @override
  Future<Map<String, dynamic>> coreInfo() async => {
    'compatible': true,
    'selectionId': selection,
  };
  @override
  Future<void> startCoreUpdate() async {
    requests++;
    busy = true;
  }

  @override
  Future<void> setCoreAutoUpdate(bool enabled) async {
    automatic = enabled;
  }

  @override
  Future<void> rollbackCore() async {
    selection = 'previous';
  }

  @override
  Future<void> disconnect() async {
    disconnects++;
  }
}

void main() {
  test(
    'Background updates and rollback leave the running VPN untouched',
    () async {
      final api = UpdateApi();
      final client = ClientController(api);
      await client.refreshStatus();
      await client.updateCore();
      await client.updateCore();
      expect(api.requests, 1);
      expect(client.updatingCore, true);
      await client.setCoreAutoUpdate(true);
      expect(client.coreManager['autoUpdate'], true);
      api.busy = false;
      await client.rollbackCore();
      expect(client.coreInfo['selectionId'], 'previous');
      expect(client.state, 'running');
      expect(api.disconnects, 0);
      client.dispose();
    },
  );

  testWidgets('Core progress, pending version and rollback fit large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final api = UpdateApi()..busy = true;
    final client = ClientController(api);
    await client.refreshStatus();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: CoreSettingsCard(client: client, run: (action) => action()),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('при следующем подключении'), findsWidgets);
    expect(find.text('Загрузка Android-ядра · 35%'), findsOneWidget);
    final update = tester.widget<FilledButton>(find.byType(FilledButton).first);
    expect(update.onPressed, isNull);
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      0.35,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    client.dispose();
  });
}
