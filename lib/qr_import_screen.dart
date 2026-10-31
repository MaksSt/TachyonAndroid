import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

class QrImportScreen extends StatefulWidget {
  const QrImportScreen({super.key, required this.privateMode});
  final bool privateMode;
  @override
  State<QrImportScreen> createState() => _QrImportScreenState();
}

class _QrImportScreenState extends State<QrImportScreen> {
  bool consumed = false;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Сканировать QR-код')),
    body: Stack(
      fit: StackFit.expand,
      children: [
        MobileScanner(
          onDetect: (capture) {
            if (consumed) return;
            final value = capture.barcodes
                .where((barcode) => barcode.format == BarcodeFormat.qrCode)
                .map((barcode) => barcode.rawValue)
                .whereType<String>()
                .where((value) => value.trim().isNotEmpty)
                .firstOrNull;
            if (value == null) return;
            consumed = true;
            Navigator.pop(context, value);
          },
          errorBuilder: (context, error) => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                error.errorCode == MobileScannerErrorCode.permissionDenied
                    ? 'Нужен доступ к камере. Разрешите его в настройках приложения Android.'
                    : 'Камера недоступна. Можно импортировать данные из буфера обмена.',
                textAlign: TextAlign.center,
              ),
            ),
          ),
          overlayBuilder: widget.privateMode
              ? (_, _) => const ColoredBox(
                  color: Colors.black,
                  child: Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'Изображение камеры скрыто. Сканирование QR-кода продолжается.',
                        style: TextStyle(color: Colors.white),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                )
              : null,
        ),
        if (!widget.privateMode)
          const Positioned(
            left: 24,
            right: 24,
            bottom: 32,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.all(Radius.circular(16)),
              ),
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Наведите камеру на QR-код профиля или подписки',
                  style: TextStyle(color: Colors.white),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ),
      ],
    ),
  );
}
