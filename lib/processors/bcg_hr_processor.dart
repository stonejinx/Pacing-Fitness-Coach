import 'dart:collection';
import 'dart:math';

/// Estimates heart rate from the bone conduction accelerometer (BCG signal).
///
/// The bone conduction sensor captures structural vibrations at the ear,
/// including arterial pulse waveforms. Raw ADC values are in the thousands.
///
/// Algorithm:
///   1. Compute vector magnitude of X/Y/Z
///   2. Remove slow baseline drift with a long running mean (high-pass)
///   3. Detect peaks in the detrended signal with adaptive threshold
///   4. Compute HR from inter-peak intervals (sanity-checked 40–200 BPM)
class BcgHrProcessor {
  // 4 s buffer at 100 Hz
  final Queue<double> _mag = ListQueue();
  final List<int> _peakTimestamps = [];

  static const int _bufferSize = 400;       // 4 s at 100 Hz
  static const int _minPeakIntervalMs = 300; // ≤ 200 BPM
  static const int _hrWindowMs = 8000;       // use last 8 s for HR estimate

  /// Feed one bone conduction sample. [acc] = [X, Y, Z] raw ADC integers.
  /// [timestampMs] is the sensor timestamp in milliseconds.
  /// Returns HR in bpm, or null until enough data is collected.
  double? update(List<double> acc, int timestampMs) {
    final m = sqrt(acc[0] * acc[0] + acc[1] * acc[1] + acc[2] * acc[2]);
    _mag.addLast(m);
    if (_mag.length > _bufferSize) _mag.removeFirst();
    if (_mag.length < 30) return null;

    final samples = _mag.toList();
    final n = samples.length;

    // Baseline: mean of the full buffer (removes slow drift)
    final mean = samples.reduce((a, b) => a + b) / n;

    // Detrended current and neighbours
    final curr = samples[n - 2] - mean;
    final prev = samples[n - 3] - mean;
    final next = samples[n - 1] - mean;

    // Adaptive threshold: 25% of max positive deviation in window
    double maxDev = 0;
    for (final s in samples) {
      final d = s - mean;
      if (d > maxDev) maxDev = d;
    }
    final threshold = maxDev * 0.25;

    // Minimum interval guard (prevents double-counting same beat)
    final sinceLastPeak = _peakTimestamps.isEmpty
        ? _minPeakIntervalMs + 1
        : timestampMs - _peakTimestamps.last;

    if (curr > threshold && curr > prev && curr > next &&
        sinceLastPeak > _minPeakIntervalMs) {
      _peakTimestamps.add(timestampMs);
      if (_peakTimestamps.length > 20) _peakTimestamps.removeAt(0);
    }

    return _computeHr(timestampMs);
  }

  double? _computeHr(int nowMs) {
    if (_peakTimestamps.length < 3) return null;
    final recent =
        _peakTimestamps.where((t) => nowMs - t < _hrWindowMs).toList();
    if (recent.length < 3) return null;
    final durationSec = (recent.last - recent.first) / 1000.0;
    if (durationSec <= 0) return null;
    final hr = (recent.length - 1) / durationSec * 60.0;
    // Reject physiologically impossible values
    if (hr < 40 || hr > 200) return null;
    return hr;
  }

  void reset() {
    _mag.clear();
    _peakTimestamps.clear();
  }
}
