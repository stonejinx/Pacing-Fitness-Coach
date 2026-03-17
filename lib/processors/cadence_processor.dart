import 'dart:collection';
import 'dart:math';

/// Detects running cadence (steps/min) from the IMU accelerometer.
/// Uses vertical-axis peak detection on a rolling window.
class CadenceProcessor {
  final int windowSize;           // samples to keep (~2 sec at 30 Hz = 60)
  final double peakThreshold;     // minimum magnitude to count as a step

  final Queue<double> _magnitudes = ListQueue();
  final List<int> _stepTimestamps = [];

  CadenceProcessor({this.windowSize = 60, this.peakThreshold = 11.5});

  /// Feed one ACC sample [ax, ay, az] in m/s².  Returns cadence in steps/min,
  /// or null if not enough data yet.
  double? update(List<double> acc, int timestampMs) {
    final mag = sqrt(acc[0] * acc[0] + acc[1] * acc[1] + acc[2] * acc[2]);

    _magnitudes.addLast(mag);
    if (_magnitudes.length > windowSize) _magnitudes.removeFirst();
    if (_magnitudes.length < 3) return null;

    // Simple peak detection: current value is a local max above threshold
    final prev = _magnitudes.elementAt(_magnitudes.length - 3);
    final curr = _magnitudes.elementAt(_magnitudes.length - 2);
    final next = mag;
    if (curr > peakThreshold && curr > prev && curr > next) {
      _stepTimestamps.add(timestampMs);
      // Keep only last 10 steps for cadence estimate
      if (_stepTimestamps.length > 10) _stepTimestamps.removeAt(0);
    }

    return _computeCadence(timestampMs);
  }

  double? _computeCadence(int nowMs) {
    if (_stepTimestamps.length < 2) return null;
    // Only count steps within the last 5 seconds
    final recentSteps = _stepTimestamps.where((t) => nowMs - t < 5000).toList();
    if (recentSteps.length < 2) return null;
    final durationSec = (recentSteps.last - recentSteps.first) / 1000.0;
    if (durationSec <= 0) return null;
    return (recentSteps.length - 1) / durationSec * 60.0;
  }

  void reset() {
    _magnitudes.clear();
    _stepTimestamps.clear();
  }
}
