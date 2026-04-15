import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:open_earable_flutter/open_earable_flutter.dart';
import '../models/fusion_result.dart';
import '../processors/bcg_hr_processor.dart';
import '../processors/cadence_processor.dart';
import '../processors/hr_processor.dart';
import '../processors/temp_processor.dart';
import '../engine/rule_engine.dart';

/// Wraps the open_earable_flutter WearableManager.
/// Exposes streams for processed sensor values and connection state.
class OpenEarableManager extends ChangeNotifier {
  final WearableManager _wm = WearableManager();
  final RuleEngine ruleEngine;

  final CadenceProcessor _cadence = CadenceProcessor();
  final HrProcessor      _hr      = HrProcessor();   // PPG path (fw ≥ 2.1)
  final BcgHrProcessor   _bcgHr   = BcgHrProcessor(); // bone conduction path (fw 2.0)
  final TempProcessor    _temp    = TempProcessor();

  // ── Public streams ───────────────────────────────────────────────────────
  final StreamController<double>  hrStream      = StreamController.broadcast();
  final StreamController<double>  cadenceStream = StreamController.broadcast();
  final StreamController<double>  tempStream    = StreamController.broadcast();
  final StreamController<FusionResult> feedbackStream = StreamController.broadcast();

  // ── Observable state ─────────────────────────────────────────────────────
  Wearable?  connectedWearable;
  bool       isScanning = false;
  String     status = 'Disconnected';

  // EDA injected externally from Esp32Manager
  double? _latestEda;

  final List<StreamSubscription> _subs = [];

  OpenEarableManager({required this.ruleEngine});

  Stream<DiscoveredDevice> get scanStream => _wm.scanStream;

  Future<void> startScan() async {
    isScanning = true;
    status = 'Scanning…';
    notifyListeners();
    await _wm.startScan();
  }

  Future<void> connect(DiscoveredDevice device) async {
    status = 'Connecting…';
    notifyListeners();

    final wearable = await _wm.connectToDevice(device);
    connectedWearable = wearable;
    isScanning = false;
    status = 'Connected: ${wearable.name}';
    notifyListeners();

    wearable.addDisconnectListener(() {
      connectedWearable = null;
      status = 'Disconnected';
      notifyListeners();
    });

    _configureSensors(wearable);
    _subscribeSensors(wearable);
  }

  void _configureSensors(Wearable wearable) {
    final cfgMgr = wearable.getCapability<SensorConfigurationManager>();
    if (cfgMgr == null) return;

    for (final cfg in cfgMgr.sensorConfigurations) {
      if (cfg is SensorFrequencyConfiguration) {
        final n = cfg.name.toLowerCase();
        int targetHz;
        if (n.contains('imu') || n.contains('bone')) {
          targetHz = 100;
        } else if (n.contains('pulse') || n.contains('oximeter')) {
          targetHz = 50; // PPG needs at least 25 Hz for HR detection
        } else if (n.contains('pressure') || n.contains('baro')) {
          targetHz = 25;
        } else if (n.contains('skin') || n.contains('temp')) {
          targetHz = 10;
        } else {
          targetHz = 25;
        }
        debugPrint('[OE] Configuring "${cfg.name}" at ${targetHz}Hz');
        cfg.setFrequencyBestEffort(targetHz, streamData: true, recordData: false);
      }
    }
  }

  void _subscribeSensors(Wearable wearable) {
    final sm = wearable.getCapability<SensorManager>();
    if (sm == null) return;

    // Debug: log all sensor names so we can verify name matching
    debugPrint('[OE] Available sensors: ${sm.sensors.map((s) => s.sensorName).join(', ')}');

    for (final sensor in sm.sensors) {
      final name = sensor.sensorName.toLowerCase();
      debugPrint('[OE] Subscribing to sensor: "${sensor.sensorName}"');
      final sub = sensor.sensorStream.listen((value) {
        if (value is! SensorDoubleValue) {
          debugPrint('[OE] Unexpected value type for "$name": ${value.runtimeType}');
          return;
        }
        final vals = value.values;
        final ts   = value.timestamp;   // ms (timestampExponent == -3)

        if (name.contains('acc') || name.contains('imu')) {
          if (vals.length >= 3) {
            final magSq = vals[0] * vals[0] + vals[1] * vals[1] + vals[2] * vals[2];
            if (magSq < 250000) {
              // Calibrated IMU (m/s²) → cadence
              final c = _cadence.update([vals[0], vals[1], vals[2]], ts);
              if (c != null) {
                cadenceStream.add(c);
                _maybeEvaluate(cadence: c);
              }
            } else {
              // Bone conduction raw ADC → BCG heart rate
              final h = _bcgHr.update([vals[0], vals[1], vals[2]], ts);
              if (h != null) {
                hrStream.add(h);
                _maybeEvaluate(hr: h);
              }
            }
          }
        }

        // PHOTOPLETHYSMOGRAPHY: [RED, IR, GREEN, AMBIENT]
        // Use GREEN channel (index 2) — highest signal on this sensor
        if (name.contains('photo') || name.contains('ppg') || name.contains('optical')) {
          if (vals.isNotEmpty) {
            final greenIndex = vals.length > 2 ? 2 : 0;
            final h = _hr.update(vals[greenIndex], ts);
            if (h != null) {
              hrStream.add(h);
              _maybeEvaluate(hr: h);
            }
          }
        }

        if (name.contains('temp')) {
          final t = _temp.update(vals[0]);
          tempStream.add(t);
        }
      });
      _subs.add(sub);
    }
  }

  double? _lastHr;
  double? _lastCadence;

  void _maybeEvaluate({double? hr, double? cadence}) {
    if (hr != null) _lastHr = hr;
    if (cadence != null) _lastCadence = cadence;

    final result = ruleEngine.evaluate(
      hr: _lastHr,
      cadence: _lastCadence,
      eda: _latestEda,
      skinTemp: _temp.current,
    );
    if (result != FusionResult.idle) feedbackStream.add(result);
  }

  void updateEda(double eda) {
    _latestEda = eda;
  }

  Future<void> disconnect() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await connectedWearable?.disconnect();
    connectedWearable = null;
    status = 'Disconnected';
    notifyListeners();
  }

  @override
  void dispose() {
    disconnect();
    hrStream.close();
    cadenceStream.close();
    tempStream.close();
    feedbackStream.close();
    super.dispose();
  }
}
