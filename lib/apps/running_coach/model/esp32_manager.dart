import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// Manages BLE connection to the ESP32 GSR (EDA) module.
/// Advertises as "ESP32-GSR" and exposes a 16-bit ADC characteristic.
/// Adjust UUIDs to match your ESP32 firmware.
class Esp32Manager extends ChangeNotifier {
  static const String _deviceNamePrefix = 'ESP32-GSR';
  static const String _serviceUuid      = '12345678-1234-1234-1234-123456789abc';
  static const String _gsrCharUuid      = '12345678-1234-1234-1234-123456789abd';

  BluetoothDevice? _device;
  StreamSubscription? _scanSub;
  StreamSubscription? _notifySub;

  final StreamController<int> _gsrController = StreamController.broadcast();

  /// Raw ADC integer stream (0–4095) from ESP32 GSR characteristic
  Stream<int> get gsrStream => _gsrController.stream;

  bool _connected = false;
  bool get isConnected => _connected;

  String _status = 'Not connected';
  String get status => _status;

  Future<void> startScanAndConnect() async {
    _status = 'Scanning for ESP32…';
    notifyListeners();

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
    _status = 'Connecting to ${device.platformName}…';
    notifyListeners();

    await device.connect(autoConnect: false);
    _connected = true;
    _status = 'Connected: ${device.platformName}';
    notifyListeners();

    device.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected) {
        _connected = false;
        _status = 'Disconnected — retrying…';
        notifyListeners();
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
            await char.setNotifyValue(true);
            _notifySub = char.onValueReceived.listen((bytes) {
              if (bytes.length >= 2) {
                final raw = bytes[0] | (bytes[1] << 8);
                _gsrController.add(raw);
              }
            });
            return;
          }
        }
      }
    }
    debugPrint('[ESP32] Service/characteristic not found — check UUIDs in esp32_manager.dart');
  }

  Future<void> disconnect() async {
    await _scanSub?.cancel();
    await _notifySub?.cancel();
    await _device?.disconnect();
    _device = null;
    _connected = false;
    _status = 'Disconnected';
    notifyListeners();
  }

  @override
  void dispose() {
    disconnect();
    _gsrController.close();
    super.dispose();
  }
}
