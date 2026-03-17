import 'dart:collection';

/// Smooths skin temperature using exponential moving average.
class TempProcessor {
  final double alpha;        // EMA weight (lower = smoother)
  double? _smoothed;

  TempProcessor({this.alpha = 0.1});

  double update(double rawCelsius) {
    _smoothed = _smoothed == null
        ? rawCelsius
        : alpha * rawCelsius + (1 - alpha) * _smoothed!;
    return _smoothed!;
  }

  double? get current => _smoothed;
  void reset() => _smoothed = null;
}
