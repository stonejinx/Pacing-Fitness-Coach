import 'dart:async';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// Manages BLE connection to the ESP32 GSR module.
/// The ESP32 firmware must advertise a device named "ESP32-GSR"
/// and expose the service/characteristic UUIDs below.
/// Adjust UUIDs to match your ESP32 firmware.
class Esp32Manager {
  // ── Change these to match your ESP32 firmware ──────────────────────────
  static const String _deviceNamePrefix = 'ESP32-GSR';
  static const String _serviceUuid      = '12345678-1234-1234-1234-123456789abc';
  static const String _gsrCharUuid      = '12345678-1234-1234-1234-123456789abd';
  // ────────────────────────────────────────────────────────────────────────

  BluetoothDevice? _device;
  BluetoothCharacteristic? _gsrChar;
  StreamSubscription? _scanSub;
  StreamSubscription? _notifySub;

  final StreamController<int> _gsrController = StreamController.broadcast();

  /// Raw ADC integer stream from the ESP32 GSR characteristic
  Stream<int> get gsrStream => _gsrController.stream;

  bool get isConnected => _device?.isConnected ?? false;

  Future<void> startScanAndConnect() async {
    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 15));
    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        if (r.device.platformName.contains(_deviceNamePrefix)) {
          FlutterBluePlus.stopScan();
          _connect(r.device);
          break;
        }
      }
    });
  }

  Future<void> _connect(BluetoothDevice device) async {
    _device = device;
    await device.connect(autoConnect: false);
    device.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected) {
        _gsrChar = null;
        // Auto-reconnect after 3 s
        Future.delayed(const Duration(seconds: 3), startScanAndConnect);
      }
    });
    await _discoverAndSubscribe();
  }

  Future<void> _discoverAndSubscribe() async {
    if (_device == null) return;
    final services = await _device!.discoverServices();
    for (final svc in services) {
      if (svc.uuid.toString().toLowerCase() == _serviceUuid.toLowerCase()) {
        for (final char in svc.characteristics) {
          if (char.uuid.toString().toLowerCase() == _gsrCharUuid.toLowerCase()) {
            _gsrChar = char;
            await char.setNotifyValue(true);
            _notifySub = char.onValueReceived.listen((bytes) {
              if (bytes.length >= 2) {
                // ESP32 sends 16-bit ADC value little-endian
                final raw = bytes[0] | (bytes[1] << 8);
                _gsrController.add(raw);
              }
            });
            return;
          }
        }
      }
    }
  }

  Future<void> disconnect() async {
    await _scanSub?.cancel();
    await _notifySub?.cancel();
    await _device?.disconnect();
    _device = null;
    _gsrChar = null;
  }

  void dispose() {
    disconnect();
    _gsrController.close();
  }
}
