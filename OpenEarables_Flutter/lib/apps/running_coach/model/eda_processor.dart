// =============================================================
// EDA Processor (Hz-based, per-person dynamic thresholds)
//
// Collects the first _windowSize samples into a rolling buffer.
// Once full, derives personal thresholds from the distribution:
//   moderate threshold = personal mean + 1 × std  (or static floor)
//   high threshold     = personal mean + 2 × std  (or static floor)
//
// Static floors ensure the thresholds never go below physiologically
// meaningful values even for very calm baselines.
//
// reset() wipes the buffer completely — call this between people
// so each new person gets their own calibration from scratch.
// =============================================================

import 'dart:math';

class EDAProcessor {
  // ── Static floors (fallback before window is full) ─────────
  static const double _staticModerate = 0.28; // Hz
  static const double _staticHigh     = 0.37; // Hz

  // ── Rolling window ─────────────────────────────────────────
  static const int _windowSize = 60; // ~60 samples ≈ 2 min at 0.5 Hz
  final List<double> _window = [];

  // ── Dynamic thresholds (updated as window fills) ───────────
  double _dynModerate = _staticModerate;
  double _dynHigh     = _staticHigh;

  /// Feed a Hz value. Updates dynamic thresholds when window is full.
  /// Returns the raw Hz value unchanged (callers use it directly).
  double process(double hz) {
    _window.add(hz);
    if (_window.length > _windowSize) _window.removeAt(0);

    if (_window.length >= _windowSize) {
      final mean = _window.reduce((a, b) => a + b) / _window.length;
      final variance = _window
              .map((v) => (v - mean) * (v - mean))
              .reduce((a, b) => a + b) /
          _window.length;
      final std = sqrt(variance);

      // Dynamic thresholds — never go below static floors
      _dynModerate = max(_staticModerate, mean + std);
      _dynHigh     = max(_staticHigh,     mean + 2 * std);
    }

    return hz;
  }

  double get thresholdModerate => _dynModerate;
  double get thresholdHigh     => _dynHigh;

  /// Human-readable zone using current (dynamic or static) thresholds.
  String classify(double hz) {
    if (hz > _dynHigh)     return 'high';
    if (hz > _dynModerate) return 'moderate';
    return 'low';
  }

  /// Wipe all accumulated data — call between sessions / people.
  void reset() {
    _window.clear();
    _dynModerate = _staticModerate;
    _dynHigh     = _staticHigh;
  }

  /// True once the window has enough samples for a personal calibration.
  bool get isBaselineReady  => _window.length >= _windowSize;

  /// 0–100 progress toward a full calibration window.
  int  get baselineProgress =>
      ((_window.length / _windowSize) * 100).clamp(0, 100).toInt();
}
