// =============================================================
// Running Coach Model — wires all verified processors
// Skin temp: raw pass-through
//   Röddiger et al. 2025, ACM IMWUT
//   "OpenEarable 2.0: Open-Source Earphone Platform"
//   → factory-calibrated optical sensor, no processing needed
// =============================================================

import 'package:flutter/foundation.dart';
import 'bcg_hr_processor.dart';
import 'cadence_processor.dart';
import 'eda_processor.dart';
import 'fusion_engine.dart';

class RunningCoachModel extends ChangeNotifier {
  final _bcgHr   = BCGHeartRateProcessor();
  final _cadence = CadenceProcessor();
  final _eda     = EDAProcessor();
  final _fusion  = FusionEngine();

  double? heartRate;
  double? cadence;
  double? skinTemp;       // raw — Röddiger et al. 2025
  double? eda;
  FeedbackType? lastFeedback;

  // ── Sensor feed methods ────────────────────────────────────

  /// sensorId 7 — BMA580 100 Hz — BCG heart rate
  void onBCGSample(double ax, double ay, double az) {
    final v = _bcgHr.process(ax: ax, ay: ay, az: az);
    if (v != null && v > 0) {
      heartRate = v;
      _tryFusion();
      notifyListeners();
    }
  }

  /// sensorId 0 — IMU 100 Hz — cadence
  void onIMUSample(double ax, double ay, double az, int rawTimestamp) {
    final v = _cadence.process(
      ax: ax, ay: ay, az: az, rawTimestamp: rawTimestamp,
    );
    if (v != null) {
      cadence = v == 0.0 ? null : v;
      _tryFusion();
      notifyListeners();
    }
  }

  /// Skin temperature sensor — raw pass-through (Röddiger et al. 2025)
  void onTempSample(double tempC) {
    skinTemp = tempC;
    _tryFusion();
    notifyListeners();
  }

  /// ESP32 GSR — EDA
  void onEDASample(double rawADC) {
    final v = _eda.process(rawADC);
    if (v != null) {
      eda = v;
      _tryFusion();
      notifyListeners();
    }
  }

  void _tryFusion() {
    if (heartRate == null || cadence == null ||
        skinTemp == null || eda == null) return;
    final f = _fusion.evaluate(
      hr:       heartRate!,
      cadence:  cadence!,
      skinTemp: skinTemp!,
      eda:      eda!,
    );
    if (f == null || f == FeedbackType.maintain) return;
    lastFeedback = f;
    notifyListeners();
  }

  bool get edaReady    => _eda.isBaselineReady;
  int  get edaProgress => _eda.baselineProgress;

  void reset() {
    heartRate = cadence = skinTemp = eda = null;
    lastFeedback = null;
    _cadence.reset();
    _bcgHr.reset();
    _eda.reset();
    _fusion.reset();
    notifyListeners();
  }
}
