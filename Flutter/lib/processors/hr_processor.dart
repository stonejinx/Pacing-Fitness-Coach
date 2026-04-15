import 'dart:collection';

/// Estimates heart rate (bpm) from the PPG sensor stream.
///
/// Uses a detrended (AC) approach: subtracts the rolling mean to isolate
/// the cardiac pulse waveform from the large DC offset. Works with both
/// high-quality signals (thousands of counts) and weak signals (~100 counts).
class HrProcessor {
  final int windowSize;    // samples (~5 sec at 50 Hz = 250)

  final Queue<double> _ppg = ListQueue();
  final List<int> _peakTimestamps = [];
  static const int _minPeakIntervalMs = 300; // ≤ 200 BPM

  HrProcessor({this.windowSize = 250});

  /// Feed one PPG sample [rawValue] and its timestamp in ms.
  /// Returns estimated HR in bpm, or null if not enough data.
  double? update(double rawValue, int timestampMs) {
    _ppg.addLast(rawValue);
    if (_ppg.length > windowSize) _ppg.removeFirst();
    if (_ppg.length < 10) return null;

    final samples = _ppg.toList();
    final n = samples.length;

    // Remove DC baseline: subtract rolling mean → isolate AC component
    final mean = samples.reduce((a, b) => a + b) / n;
    final curr = samples[n - 2] - mean;
    final prev = samples[n - 3] - mean;
    final next = samples[n - 1] - mean;

    // Adaptive threshold: 20% of max positive deviation in the window
    double maxDev = 0;
    for (final s in samples) {
      final d = s - mean;
      if (d > maxDev) maxDev = d;
    }
    final threshold = maxDev * 0.20;

    final sinceLastPeak = _peakTimestamps.isEmpty
        ? _minPeakIntervalMs + 1
        : timestampMs - _peakTimestamps.last;

    if (threshold > 0.5 &&
        curr > threshold &&
        curr > prev &&
        curr > next &&
        sinceLastPeak > _minPeakIntervalMs) {
      _peakTimestamps.add(timestampMs);
      if (_peakTimestamps.length > 15) _peakTimestamps.removeAt(0);
    }

    return _computeHr(timestampMs);
  }

  double? _computeHr(int nowMs) {
    if (_peakTimestamps.length < 2) return null;
    final recent = _peakTimestamps.where((t) => nowMs - t < 10000).toList();
    if (recent.length < 2) return null;
    final durationSec = (recent.last - recent.first) / 1000.0;
    if (durationSec <= 0) return null;
    return (recent.length - 1) / durationSec * 60.0;
  }

  void reset() {
    _ppg.clear();
    _peakTimestamps.clear();
  }
}
