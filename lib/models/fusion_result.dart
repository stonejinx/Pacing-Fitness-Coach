enum FusionResult { idle, pushHarder, slowDown, maintainPace }

class SensorState {
  final double? hr;           // bpm
  final double? cadence;      // steps/min
  final double? skinTemp;     // °C
  final double? eda;          // µS (from ESP32)

  const SensorState({this.hr, this.cadence, this.skinTemp, this.eda});

  SensorState copyWith({double? hr, double? cadence, double? skinTemp, double? eda}) {
    return SensorState(
      hr: hr ?? this.hr,
      cadence: cadence ?? this.cadence,
      skinTemp: skinTemp ?? this.skinTemp,
      eda: eda ?? this.eda,
    );
  }

  bool get isReady => hr != null && cadence != null;

  @override
  String toString() =>
      'HR=${hr?.toStringAsFixed(1)} bpm  '
      'Cadence=${cadence?.toStringAsFixed(0)} spm  '
      'Temp=${skinTemp?.toStringAsFixed(1)}°C  '
      'EDA=${eda?.toStringAsFixed(2)}µS';
}
