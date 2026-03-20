// =============================================================
// BCG Heart Rate Processor
// Ferlini et al. 2021, IEEE Pervasive Computing
//   "In-ear PPG for vital signs"
//   → adapted for BCG via BMA580 bone conduction accelerometer
//   → same cardiac band (0.8–4Hz), same 10s window, J-wave peaks
// Sensor: sensorId 7 — BMA580 at 100Hz
// =============================================================

import 'dart:math';

class BCGHeartRateProcessor {
  // ── Ferlini et al. 2021 Section IV ────────────────────────
  static const double _lowCutoff       = 0.8;  // Hz cardiac band low
  static const double _highCutoff      = 4.0;  // Hz cardiac band high
  static const double _fs              = 100.0; // Hz BMA580
  static const int    _windowSec       = 10;   // s sliding window
  static const int    _minPeaks        = 5;    // min beats for valid HR
  static const double _minBeatInterval = 0.30; // s (200 BPM max)
  static const double _maxBeatInterval = 1.50; // s (40 BPM min)

  final List<double> _buf = [];
  double _hpPrev  = 0.0;
  double _hpInput = 0.0;
  double _lpState = 0.0;
  double _lastHR  = 0.0;

  double? process({
    required double ax,
    required double ay,
    required double az,
  }) {
    final mag = sqrt(ax * ax + ay * ay + az * az);

    // Bandpass = highpass(0.8Hz) → lowpass(4Hz) — Ferlini et al.
    final hpA   = 1.0 / (2 * pi * _lowCutoff / _fs + 1.0);
    final hp    = hpA * (_hpPrev + mag - _hpInput);
    _hpPrev     = hp;
    _hpInput    = mag;

    final lpA   = (1.0 / _fs) / (1.0 / (2 * pi * _highCutoff) + 1.0 / _fs);
    _lpState   += lpA * (hp - _lpState);

    _buf.add(_lpState);
    final windowSize = (_fs * _windowSec).round();
    if (_buf.length > windowSize) _buf.removeAt(0);
    if (_buf.length < windowSize) return null;

    // DC removal
    final mean  = _buf.reduce((a, b) => a + b) / _buf.length;
    final x     = _buf.map((v) => v - mean).toList();

    // Adaptive threshold at 50%
    final xMax  = x.reduce(max);
    final xMin  = x.reduce(min);
    final thresh = xMin + (xMax - xMin) * 0.5;

    // J-wave peak detection (Ferlini et al. Section IV-B)
    final minDist = (_minBeatInterval * _fs).round();
    final peaks   = <int>[];
    int lastPeak  = -minDist;
    for (int i = 1; i < x.length - 1; i++) {
      if (x[i] > thresh &&
          x[i] > x[i - 1] &&
          x[i] > x[i + 1] &&
          i - lastPeak >= minDist) {
        peaks.add(i);
        lastPeak = i;
      }
    }

    if (peaks.length < _minPeaks) return _lastHR > 0 ? _lastHR : null;

    // Inter-beat intervals → median IBI (Ferlini et al.)
    final ibi = <double>[];
    for (int i = 1; i < peaks.length; i++) {
      final iv = (peaks[i] - peaks[i - 1]) / _fs;
      if (iv >= _minBeatInterval && iv <= _maxBeatInterval) ibi.add(iv);
    }
    if (ibi.isEmpty) return _lastHR > 0 ? _lastHR : null;

    ibi.sort();
    final medIBI = ibi[ibi.length ~/ 2];
    final rawHR  = 60.0 / medIBI;

    _lastHR = _lastHR == 0.0
        ? rawHR
        : 0.75 * _lastHR + 0.25 * rawHR;

    return _lastHR;
  }

  void reset() {
    _buf.clear();
    _hpPrev = _hpInput = _lpState = _lastHR = 0.0;
  }
}
