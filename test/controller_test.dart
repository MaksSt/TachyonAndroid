import 'package:flutter_test/flutter_test.dart';
import 'package:tachyon_client/controller.dart';

class MemoryApi extends NativeApi {
  String? data;
  bool rejectSave = false;
  String connection = 'stopped';
  int disconnects = 0;
  @override
  Future<String?> load() async => data;
  @override
  Future<Map<String, dynamic>> coreInfo() async => {'compatible': true};
  @override
  Future<void> save(String value) async {
    if (rejectSave) throw StateError('storage unavailable');
    data = value;
  }

  @override
  Future<Map<String, dynamic>> status() async => {
    'state': connection,
    'logs': <String>[],
  };
  @override
  Future<void> disconnect() async {
    disconnects++;
    connection = 'stopped';
  }
}

void main() {
  test('Failed storage does not silently change the profile list', () async {
    final api = MemoryApi();
    final client = ClientController(api);
    addTearDown(client.dispose);
    await client.initialize();
    await client.importText('trojan://sample@example.com:443#First');
    final selected = client.selectedId;
    api.rejectSave = true;
    await expectLater(
      client.importText('trojan://sample@example.net:443#Second'),
      throwsStateError,
    );
    expect(client.profiles.length, 1);
    expect(client.selectedId, selected);
    api.rejectSave = false;
    await client.importText('trojan://sample@example.net:443#Second');
    expect(client.profiles.length, 2);
  });
  test(
    'Selecting another profile stops the old tunnel before changing its label',
    () async {
      final api = MemoryApi();
      final client = ClientController(api);
      addTearDown(client.dispose);
      await client.initialize();
      await client.importText(
        'trojan://sample@example.com:443#First\ntrojan://sample@example.net:443#Second',
      );
      api.connection = 'running';
      await client.refreshStatus();
      await client.select(client.profiles.last);
      expect(api.disconnects, 1);
      expect(client.state, 'stopped');
      expect(client.selected?.name, 'Second');
    },
  );
}
