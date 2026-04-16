// =============================================================
// Running Coach Model — wires all verified processors
// Skin temp: factory-calibrated optical sensor (Röddiger et al. 2025)
//   → apply fixed −0.8 °C offset + light EMA (α=0.1) before use
// =============================================================

import 'package:flutter/foundation.dart';
import 'eda_processor.dart';
import 'fusion_engine.dart';
import 'user_profile.dart';

class RunningCoachModel extends ChangeNotifier {
  final _eda    = EDAProcessor();
  final _fusion = FusionEngine();

  double? heartRate;
  double? cadence;
  double? skinTemp;       // corrected + smoothed
  double? eda;            // Hz

  // Skin temp — raw pass-through, no filter

  // ── Sensor feed methods ────────────────────────────────────

  /// Step-based cadence update — called from page after step detection
  void updateCadence(double? spm) {
    cadence = spm;
    _tryFusion();
    notifyListeners();
  }

  void onTempSample(double tempC) {
    skinTemp = tempC;
    _tryFusion();
    notifyListeners();
  }

  /// ESP32 GSR — receives Hz directly from Esp32Manager
  void onEDASample(double hz) {
    eda = _eda.process(hz);
    _tryFusion();
    notifyListeners();
  }

  void _tryFusion() {
    if (heartRate == null || cadence == null ||
        skinTemp == null || eda == null) return;
    _fusion.evaluate(
      hr:       heartRate!,
      cadence:  cadence!,
      skinTemp: skinTemp!,
      eda:      eda!,
      edaHigh:  _eda.thresholdHigh,
      edaLow:   _eda.thresholdModerate,
    );
  }

  void updateUserProfile(UserProfile profile) {
    _fusion.updateProfile(profile);
    notifyListeners();
  }

  bool   get edaReady         => _eda.isBaselineReady;
  int    get edaProgress      => _eda.baselineProgress;
  double get edaThresholdHigh => _eda.thresholdHigh;
  double get edaThresholdLow  => _eda.thresholdModerate;

  void reset() {
    heartRate = cadence = skinTemp = eda = null;
    _eda.reset();
    _fusion.reset();
    notifyListeners();
  }
}
