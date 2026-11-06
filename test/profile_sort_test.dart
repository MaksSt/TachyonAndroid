import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tachyon_client/controller.dart';
import 'package:tachyon_client/main.dart';
import 'package:tachyon_client/profiles.dart';

class SortApi extends NativeApi {
  String? saved;
  bool rejectSave = false;
  @override
  Future<String?> load() async => saved;
  @override
  Future<void> save(String value) async {
    if (rejectSave) throw StateError('storage unavailable');
    saved = value;
  }

  @override
  Future<Map<String, dynamic>> coreInfo() async => {'compatible': true};
  @override
  Future<Map<String, dynamic>> status() async => {
    'state': 'stopped',
    'logs': <String>[],
  };
}

Profile node(String id, {bool pinned = false}) => Profile(
  id: id,
  name: id,
  pinned: pinned,
  outbound: {'type': 'trojan', 'server': 'example.invalid', 'server_port': 443},
);

void main() {
  test(
    'Latency ordering preserves pins, stable ties and original storage',
    () async {
      final api = SortApi();
      final client = ClientController(api);
      addTearDown(client.dispose);
      client.profiles.addAll([
        node('Unknown'),
        node('Slow'),
        node('Fast'),
        node('Equal'),
        node('Pinned', pinned: true),
        node('Failed'),
      ]);
      client.selectedId = 'Slow';
      client.latency.addAll({
        'Slow': 200,
        'Fast': 20,
        'Equal': 20,
        'Failed': 0,
      });
      client.tcpLatency['Unknown'] = 1;
      await client.setProfileSort(ProfileSort.latency);
      expect(client.orderedProfiles.map((p) => p.id), [
        'Pinned',
        'Fast',
        'Equal',
        'Slow',
        'Unknown',
        'Failed',
      ]);
      expect(client.selectedId, 'Slow');
      expect(client.profiles.first.id, 'Unknown');
      client.latency['Slow'] = 10;
      expect(client.orderedProfiles[1].id, 'Slow');
      client.latency.remove('Fast');
      expect(client.orderedProfiles.last.id, 'Failed');
      final reopened = ClientController(SortApi()..saved = api.saved);
      addTearDown(reopened.dispose);
      await reopened.initialize();
      expect(reopened.profileSort, ProfileSort.latency);
      expect(reopened.selectedId, 'Slow');
      expect(reopened.orderedProfiles.map((p) => p.id), [
        'Pinned',
        'Unknown',
        'Slow',
        'Fast',
        'Equal',
        'Failed',
      ]);
      await client.setProfileSort(ProfileSort.original);
      expect(client.orderedProfiles.map((p) => p.id), [
        'Pinned',
        'Unknown',
        'Slow',
        'Fast',
        'Equal',
        'Failed',
      ]);
      api.rejectSave = true;
      await expectLater(
        client.setProfileSort(ProfileSort.latency),
        throwsStateError,
      );
      expect(client.profileSort, ProfileSort.original);
    },
  );

  testWidgets('Latency sorting works on a narrow screen with enlarged text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.8;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final api = SortApi();
    final client = ClientController(api);
    addTearDown(client.dispose);
    client.loading = false;
    client.profiles.addAll([node('Slow'), node('Fast')]);
    client.latency.addAll({'Slow': 200, 'Fast': 20});
    await tester.pumpWidget(MaterialApp(home: ClientScreen(client: client)));
    await tester.tap(find.text('Профили').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byTooltip('Сортировка серверов'));
    await tester.tap(find.byTooltip('Сортировка серверов'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(CheckedPopupMenuItem<ProfileSort>, 'По задержке'),
    );
    await tester.pumpAndSettle();
    expect(client.profileSort, ProfileSort.latency);
    expect(client.orderedProfiles.first.id, 'Fast');
    expect(tester.takeException(), isNull);
  });
}
