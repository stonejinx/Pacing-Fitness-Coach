// =============================================================
// EDA Processor
// Boucsein 2012, "Electrodermal Activity" 2nd Ed.
//   → 0.05Hz lowpass for tonic SCL component (Ch. 3)
//   → baseline normalization via z-score (Ch. 4)
// Sensor: ESP32 + GSR module at 10Hz
// =============================================================

import 'dart:math';

class EDAProcessor {
  // ── Boucsein 2012 Chapter 3 ───────────────────────────────
  static const double _sclCutoff   = 0.05; // Hz tonic SCL
  static const double _fs          = 10.0; // Hz ESP32 rate
  static const int    _baselineSec = 60;   // s rest at session start

  final List<double> _baselineBuf = [];
  double _sclState     = 0.0;
  double _lastEDA      = 0.0;
  double _baselineMean = 0.0;
  double _baselineStd  = 1.0;
  bool   _baselineDone = false;

  /// Returns null during baseline collection (first 60 s).
  /// Returns normalized EDA 0.0–1.0 after baseline.
  double? process(double rawADC) {
    // Convert ADC → microsiemens
    final uS = rawADC * (3.3 / 4096.0) / 100000.0 * 1e6;

    // Baseline collection — Boucsein 2012 Ch. 4
    if (!_baselineDone) {
      _baselineBuf.add(uS);
      if (_baselineBuf.length >= (_fs * _baselineSec).round()) {
        _baselineMean = _baselineBuf.reduce((a, b) => a + b) / _baselineBuf.length;
        final variance = _baselineBuf
            .map((v) => pow(v - _baselineMean, 2).toDouble())
            .reduce((a, b) => a + b) /
            _baselineBuf.length;
        _baselineStd  = sqrt(max(variance, 1e-6));
        _baselineDone = true;
      }
      return null;
    }

    // SCL extraction — Boucsein 2012 Ch. 3
    final alpha = (1.0 / _fs) / (1.0 / (2 * pi * _sclCutoff) + 1.0 / _fs);
    _sclState  += alpha * (uS - _sclState);

    // Z-score normalization — Boucsein 2012 Ch. 4
    final normalized = (_sclState - _baselineMean) / _baselineStd;
    _lastEDA = normalized.clamp(0.0, 1.0);
    return _lastEDA;
  }

  void reset() {
    _baselineBuf.clear();
    _sclState = _lastEDA = _baselineMean = 0.0;
    _baselineStd  = 1.0;
    _baselineDone = false;
  }

  bool get isBaselineReady => _baselineDone;
  int  get baselineProgress =>
      ((_baselineBuf.length / (_fs * _baselineSec)) * 100)
          .round()
          .clamp(0, 100);
}
