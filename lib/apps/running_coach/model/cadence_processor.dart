// =============================================================
// Cadence Processor
// PRIMARY: Burgos et al. 2020, IEEE Sensors Journal
//   "In-ear accelerometer-based sensor for gait classification"
//   → 3Hz filter, magnitude, median IBI, activity gate
// REAL-TIME WINDOW: Zhao et al. 2010
//   "Full-Featured Pedometer Design Realized with 3-Axis Digital
//    Accelerometer"
//   → progressive window: first reading at 2s not 3s
// =============================================================

import 'dart:math';

class CadenceProcessor {
  // ── Burgos et al. 2020 Section III-B ──────────────────────
  static const double _filterCutoff = 3.0;  // Hz
  static const double _minInterval  = 0.34; // s (176 spm max; blocks 0.32s BCG sub-peaks)
  static const double _maxInterval  = 1.30; // s (46 spm min)
  static const double _activityGate = 0.45; // amplitude/mean ratio (BCG ~0.05–0.25, running ~0.5+)

  // ── Zhao et al. 2010 — progressive window ─────────────────
  static const double _earlyWindowSec = 2.0; // first output at 2s
  static const double _fullWindowSec  = 3.0; // stable output at 3s
  static const int    _earlyMinPeaks  = 3;   // 2 intervals minimum early
  static const int    _fullMinPeaks   = 4;   // 3 intervals stable

  // ── internal state ─────────────────────────────────────────
  final List<double> _magBuf   = [];
  final List<double> _tsBuf    = [];
  final List<double> _recentTs = [];
  double _stage1       = 0.0;
  double _stage2       = 0.0;
  double _fs           = 100.0;
  double _lastCadence  = 0.0;
  bool   _firstReading = false;

  final int timestampExponent;

  CadenceProcessor({this.timestampExponent = -6});

  /// Returns cadence in spm, 0.0 if stationary, null if insufficient data.
  double? process({
    required double ax,
    required double ay,
    required double az,
    required int rawTimestamp,
  }) {
    final tSec = _toSec(rawTimestamp);

    // Live fs from last 10 timestamps (Burgos et al. — BLE jitter robust)
    _recentTs.add(tSec);
    if (_recentTs.length > 10) _recentTs.removeAt(0);
    if (_recentTs.length >= 2) {
      final span = _recentTs.last - _recentTs.first;
      if (span > 0) _fs = (_recentTs.length - 1) / span;
    }

    // Step 1 — vector magnitude (Burgos et al.)
    final mag = sqrt(ax * ax + ay * ay + az * az);

    // Step 2 — two-pass 3 Hz lowpass IIR (Burgos et al. Section III-B)
    final a = (1.0 / _fs) / (1.0 / (2 * pi * _filterCutoff) + 1.0 / _fs);
    _stage1 += a * (mag    - _stage1);
    _stage2 += a * (_stage1 - _stage2);

    _magBuf.add(_stage2);
    _tsBuf.add(tSec);

    // Keep max 3 s
    final maxSamples = (_fs * _fullWindowSec).ceil();
    while (_magBuf.length > maxSamples) {
      _magBuf.removeAt(0);
      _tsBuf.removeAt(0);
    }

    // Zhao et al. — progressive window
    final windowDur = _tsBuf.length >= 2 ? _tsBuf.last - _tsBuf.first : 0.0;
    if (windowDur < _earlyWindowSec) return null;

    final earlyMode      = windowDur < _fullWindowSec;
    final minPeaksNeeded = earlyMode ? _earlyMinPeaks : _fullMinPeaks;

    // Step 3 — DC removal (Burgos et al.)
    final mean = _magBuf.reduce((a, b) => a + b) / _magBuf.length;
    final x    = _magBuf.map((v) => v - mean).toList();

    // Step 4 — activity gate (Burgos et al.)
    final xMax      = x.reduce(max);
    final xMin      = x.reduce(min);
    final amplitude = xMax - xMin;
    if (mean.abs() < 1e-6 || amplitude / mean.abs() < _activityGate) {
      _lastCadence = 0.0;
      return 0.0;
    }

    // Step 5 — adaptive threshold (Burgos et al.)
    final threshold = xMin + amplitude * 0.5;

    // Step 6 — peak detection with min distance (Burgos et al.)
    final minDist = (_minInterval * _fs).round().clamp(1, 9999);
    final peaks   = <int>[];
    int lastPeak  = -minDist;
    for (int i = 1; i < x.length - 1; i++) {
      if (x[i] > threshold &&
          x[i] > x[i - 1] &&
          x[i] > x[i + 1] &&
          i - lastPeak >= minDist) {
        peaks.add(i);
        lastPeak = i;
      }
    }

    if (peaks.length < minPeaksNeeded) return _lastCadence > 0 ? _lastCadence : null;

    // Step 7 — real-timestamp intervals (Burgos et al.)
    final intervals = <double>[];
    for (int i = 1; i < peaks.length; i++) {
      final iv = _tsBuf[peaks[i]] - _tsBuf[peaks[i - 1]];
      if (iv >= _minInterval && iv <= _maxInterval) intervals.add(iv);
    }

    if (intervals.isEmpty) return _lastCadence > 0 ? _lastCadence : null;

    // Step 8a — IBI regularity check
    // Footsteps are metronomic (CV < 0.20); BCG/artifact is irregular (CV > 0.20)
    // Reference: Karantonis et al. 2006, IEEE Trans. Inf. Technol. Biomed.
    if (intervals.length >= 2) {
      final mean = intervals.reduce((a, b) => a + b) / intervals.length;
      final variance = intervals
          .map((v) => pow(v - mean, 2).toDouble())
          .reduce((a, b) => a + b) / intervals.length;
      final cv = sqrt(variance) / mean;
      if (cv > 0.20) return _lastCadence > 0 ? _lastCadence : null;
    }

    // Step 8b — median interval → cadence (Burgos et al.)
    intervals.sort();
    final median     = intervals[intervals.length ~/ 2];
    final rawCadence = 60.0 / median;

    // Step 9 — Plausibility gate: cadence must ramp up from walking before running
    // Can't physically jump from stationary to sprinting in one window
    if (_lastCadence == 0.0 && rawCadence > 150.0) {
      return null; // reject; looks like artifact, not a genuine first stride
    }

    // Step 10 — EMA (Zhao et al.: skip on first reading for instant display)
    if (!_firstReading) {
      _lastCadence  = rawCadence;
      _firstReading = true;
    } else {
      // Adaptive alpha: faster response when running, smoother when walking
      final emaAlpha = rawCadence > 140 ? 0.40 : 0.25;
      _lastCadence   = (1 - emaAlpha) * _lastCadence + emaAlpha * rawCadence;
    }

    return _lastCadence;
  }

  // Legacy update() kept for compatibility with any existing call sites
  double? update(List<double> acc, int rawTimestamp) => process(
        ax: acc[0], ay: acc[1], az: acc[2],
        rawTimestamp: rawTimestamp,
      );

  double _toSec(int ts) {
    // Convert raw timestamp to seconds using timestampExponent
    // e.g. exponent=-6 → microseconds → divide by 1e6
    return ts * pow(10, timestampExponent.toDouble()).toDouble();
  }

  void reset() {
    _magBuf.clear();
    _tsBuf.clear();
    _recentTs.clear();
    _stage1 = _stage2 = 0.0;
    _fs           = 100.0;
    _lastCadence  = 0.0;
    _firstReading = false;
  }
}
