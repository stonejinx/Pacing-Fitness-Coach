import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

class Esp32Manager extends ChangeNotifier {
  // ── Match to your ESP32 sketch ────────────────────────────
  static const String _serviceUuid = '12345678-1234-1234-1234-123456789abc';
  static const String _gsrCharUuid = 'abcd1234-5678-1234-5678-12345678';

  BluetoothDevice? _device;
  StreamSubscription? _scanSub;
  StreamSubscription? _connectionSub;
  StreamSubscription? _notifySub;

  final StreamController<double> _gsrController = StreamController.broadcast();
  Stream<double> get gsrStream => _gsrController.stream;

  bool _connected  = false;
  bool _isScanning = false;
  bool get isConnected => _connected;

  String _status = 'Not connected';
  String get status => _status;

  Future<void> startScanAndConnect() async {
    if (_isScanning || _connected) return;

    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
    ].request();
    if (statuses.values.any((s) => !s.isGranted)) {
      _status = 'Bluetooth permission denied';
      notifyListeners();
      return;
    }

    if (await FlutterBluePlus.adapterState.first != BluetoothAdapterState.on) {
      _status = 'Bluetooth is off';
      notifyListeners();
      return;
    }

    _isScanning = true;
    _status = 'Scanning…';
    notifyListeners();

    _scanSub?.cancel();
    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        final name     = r.device.platformName;
        final advSvcs  = r.advertisementData.serviceUuids
            .map((u) => u.toString().toLowerCase())
            .toList();

        // Log every named device found
        if (name.isNotEmpty) {
          debugPrint('[ESP32] Scan found: "$name"  services=$advSvcs');
        }

        // Match by advertised service UUID OR device name
        final serviceMatch = advSvcs.any(
            (s) => s.replaceAll('-', '').contains(
                _serviceUuid.replaceAll('-', '').toLowerCase()));
        final nameMatch = name.toLowerCase().contains('esp32');

        if (serviceMatch || nameMatch) {
          debugPrint('[ESP32] Matched device: "$name"');
          _scanSub?.cancel();
          FlutterBluePlus.stopScan();
          _isScanning = false;
          _connect(r.device);
          break;
        }
      }
    });

    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 15));

    // Timed out
    if (!_connected && _isScanning) {
      _isScanning = false;
      _status = 'Not found — tap to retry';
      notifyListeners();
    }
  }

  Future<void> _connect(BluetoothDevice device) async {
    _device = device;
    _status = 'Connecting…';
    notifyListeners();

    try {
      await device.connect(
          autoConnect: false, timeout: const Duration(seconds: 10));
      _connected = true;
      _status = 'Connected — waiting for data';
      notifyListeners();

      _connectionSub?.cancel();
      _connectionSub = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _connected = false;
          _notifySub?.cancel();
          _status = 'Disconnected — retrying…';
          notifyListeners();
          Future.delayed(const Duration(seconds: 3), startScanAndConnect);
        }
      });

      await _discoverAndSubscribe();
    } catch (e) {
      _connected = false;
      _isScanning = false;
      _status = 'Connect failed — tap to retry';
      notifyListeners();
      debugPrint('[ESP32] Connect error: $e');
    }
  }

  Future<void> _discoverAndSubscribe() async {
    if (_device == null) return;
    try {
      final services = await _device!.discoverServices();

      // Log everything so you can verify UUIDs
      for (final svc in services) {
        debugPrint('[ESP32] Service: ${svc.uuid}');
        for (final char in svc.characteristics) {
          debugPrint('[ESP32]   Char: ${char.uuid}  '
              'notify=${char.properties.notify}');
        }
      }

      for (final svc in services) {
        final svcMatch = svc.uuid.toString().toLowerCase().replaceAll('-', '')
            .contains(_serviceUuid.replaceAll('-', '').toLowerCase());
        if (!svcMatch) continue;

        for (final char in svc.characteristics) {
          final charMatch = char.uuid.toString().toLowerCase().replaceAll('-', '')
              .contains(_gsrCharUuid.replaceAll('-', '').toLowerCase());
          if (!charMatch) continue;

          await char.setNotifyValue(true);
          _notifySub?.cancel();
          _notifySub = char.onValueReceived.listen((bytes) {
            debugPrint('[ESP32] ${bytes.length} bytes: $bytes');
            final v = _parse(bytes);
            if (v != null) {
              debugPrint('[ESP32] Parsed: $v');
              _gsrController.add(v);
            }
          });
          _status = 'Streaming';
          notifyListeners();
          debugPrint('[ESP32] Subscribed — receiving data');
          return;
        }
      }

      _status = 'UUID mismatch — see debug log';
      notifyListeners();
      debugPrint('[ESP32] Target char not found. Check UUIDs printed above.');
    } catch (e) {
      debugPrint('[ESP32] Discover error: $e');
    }
  }

  /// ESP32 sends GSR as an ASCII string e.g. "0.00" or "1.23".
  /// Try string parse first; fall back to uint16 binary for future firmware.
  double? _parse(List<int> bytes) {
    if (bytes.isEmpty) return null;
    try {
      final str = String.fromCharCodes(bytes).trim();
      return double.parse(str);
    } catch (_) {
      // binary uint16 little-endian fallback
      if (bytes.length >= 2) return (bytes[0] | (bytes[1] << 8)).toDouble();
      return bytes[0].toDouble();
    }
  }

  Future<void> disconnect() async {
    _scanSub?.cancel();
    _connectionSub?.cancel();
    _notifySub?.cancel();
    await _device?.disconnect();
    _device     = null;
    _connected  = false;
    _isScanning = false;
    _status     = 'Disconnected';
    notifyListeners();
  }

  @override
  void dispose() {
    disconnect();
    _gsrController.close();
    super.dispose();
  }
}
