import 'dart:collection';

/// Processes raw GSR/EDA values from the ESP32.
/// Converts raw ADC counts to µS and smooths with EMA.
/// Baseline is calibrated from the first N samples at rest.
class EdaProcessor {
  final int baselineSamples;    // samples to collect for baseline
  final double alpha;           // EMA smoothing weight
  final double adcRef;          // ADC reference voltage (ESP32 = 3.3V)
  final int adcBits;            // ADC resolution (ESP32 = 12-bit = 4096)
  final double fixedResistorOhm;// fixed resistor in voltage divider (e.g. 10kΩ)

  final Queue<double> _baseline = ListQueue();
  double? _baselineMean;
  double? _smoothed;

  EdaProcessor({
    this.baselineSamples = 100,
    this.alpha = 0.05,
    this.adcRef = 3.3,
    this.adcBits = 12,
    this.fixedResistorOhm = 10000,
  });

  /// Feed raw ADC integer value from ESP32.
  /// Returns smoothed EDA in µS (microsiemens), or null during calibration.
  double? update(int rawAdc) {
    // Convert ADC → voltage → skin conductance in µS
    final voltage = rawAdc / (1 << adcBits) * adcRef;
    if (voltage <= 0) return _smoothed;
    final conductanceSiemens = voltage / (fixedResistorOhm * (adcRef - voltage).abs().clamp(0.001, adcRef));
    final microsiemens = conductanceSiemens * 1e6;

    // Baseline calibration phase
    if (_baselineMean == null) {
      _baseline.addLast(microsiemens);
      if (_baseline.length >= baselineSamples) {
        _baselineMean = _baseline.reduce((a, b) => a + b) / _baseline.length;
        _smoothed = _baselineMean;
      }
      return null;
    }

    _smoothed = alpha * microsiemens + (1 - alpha) * _smoothed!;
    return _smoothed;
  }

  /// EDA relative to baseline (positive = arousal/stress response)
  double? get relativeEda =>
      (_smoothed != null && _baselineMean != null && _baselineMean! > 0)
          ? _smoothed! - _baselineMean!
          : null;

  bool get isCalibrated => _baselineMean != null;
  double? get current => _smoothed;

  void reset() {
    _baseline.clear();
    _baselineMean = null;
    _smoothed = null;
  }
}
