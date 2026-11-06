import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tachyon_client/controller.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Official core downloads in background and repeats without reinstall',
    (tester) async {
      final api = NativeApi();
      final device = await api.deviceInfo();
      expect((device['packageId'] as String).endsWith('.checks'), true);
      Future<Map<String, dynamic>> update() async {
        await api.startCoreUpdate();
        final deadline = DateTime.now().add(const Duration(minutes: 2));
        while (DateTime.now().isBefore(deadline)) {
          final state = await api.status();
          final progress = Map<String, dynamic>.from(
            state['coreUpdate'] as Map,
          );
          final phase = progress['phase'];
          if (phase == 'ready' || phase == 'current') {
            return state;
          }
          if (phase == 'error') {
            fail('Core update failed: ${progress['message']}');
          }
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
        fail('Core background update did not complete within two minutes.');
      }

      final installed = await update();
      expect((installed['coreManager'] as Map)['source'], 'github');
      expect((installed['coreUpdate'] as Map)['phase'], 'ready');
      final inspection = await api.coreInfo();
      expect(inspection['compatible'], true);
      expect((await update())['coreSelectionId'], installed['coreSelectionId']);
      expect((await api.status())['coreUpdate']['phase'], 'current');
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
