import '../models/fusion_result.dart';

/// Thresholds — adjust based on participant baseline / pilot data
class RunnerProfile {
  final double hrTarget;          // target heart rate bpm (e.g. 155)
  final double hrTolerance;       // ±bpm band around target (e.g. 10)
  final double cadenceTarget;     // target steps/min (e.g. 170)
  final double cadenceTolerance;  // ±spm tolerance (e.g. 10)
  final double edaHighThreshold;  // µS above baseline considered high stress (e.g. 2.0)
  final double tempHighThreshold; // skin temp °C for thermal load (e.g. 37.0)

  const RunnerProfile({
    this.hrTarget = 155,
    this.hrTolerance = 10,
    this.cadenceTarget = 170,
    this.cadenceTolerance = 10,
    this.edaHighThreshold = 2.0,
    this.tempHighThreshold = 37.0,
  });
}

class RuleEngine {
  final RunnerProfile profile;
  int _cooldownCountdown = 0;       // prevent feedback spam
  static const int cooldownCycles = 30;  // ~30 s at 1 Hz evaluation

  RuleEngine({this.profile = const RunnerProfile()});

  FusionResult evaluate({
    required double? hr,
    required double? cadence,
    double? eda,           // relative µS above baseline
    double? skinTemp,
  }) {
    if (hr == null || cadence == null) return FusionResult.idle;

    if (_cooldownCountdown > 0) {
      _cooldownCountdown--;
      return FusionResult.idle;
    }

    final hrLow  = hr < profile.hrTarget - profile.hrTolerance;
    final hrHigh = hr > profile.hrTarget + profile.hrTolerance;
    final cadLow  = cadence < profile.cadenceTarget - profile.cadenceTolerance;
    final cadHigh = cadence > profile.cadenceTarget + profile.cadenceTolerance;

    final highStress = (eda != null && eda > profile.edaHighThreshold) ||
                       (skinTemp != null && skinTemp > profile.tempHighThreshold);

    FusionResult result;

    if (highStress) {
      // Physiological overload — prioritise slowing down regardless of HR/cadence
      result = FusionResult.slowDown;
    } else if (hrLow && cadLow) {
      result = FusionResult.pushHarder;
    } else if (hrHigh || cadHigh) {
      result = FusionResult.slowDown;
    } else {
      result = FusionResult.maintainPace;
    }

    if (result != FusionResult.idle && result != FusionResult.maintainPace) {
      _cooldownCountdown = cooldownCycles;
    }

    return result;
  }

  void resetCooldown() => _cooldownCountdown = 0;
}
