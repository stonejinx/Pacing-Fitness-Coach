// =============================================================
// Fusion Rule Engine — score-based, matches page evaluation logic
// Each sensor returns -1 / 0 / +1.
// Total ≤ -2 → pushHarder, ≥ +2 → slowDown, else maintain.
// HR safety override (90 % maxHR) fires before scoring.
// =============================================================

import 'user_profile.dart';

enum FeedbackType { pushHarder, slowDown, maintain }

class FusionEngine {
  // ── Skin temp zone boundaries ──────────────────────────────
  static const double tempLow  = 36.0;  // °C — below → score -1
  static const double tempHigh = 38.5;  // °C — above → score +1

  // ── Cadence floor ──────────────────────────────────────────
  static const double cadenceFloor = 60.0; // spm — below → no score

  // ── Cooldown between triggers ─────────────────────────────
  static const int _cooldownSec = 15;

  DateTime?   _lastTrigger;
  UserProfile _profile;

  FusionEngine({UserProfile? profile})
      : _profile = profile ??
            UserProfile(ageYears: 25, heightCm: 170, sex: 'male');

  void updateProfile(UserProfile profile) => _profile = profile;

  /// Evaluates all four sensors using the unified scoring system.
  /// [eda] in Hz. [edaHigh] / [edaLow] are dynamic thresholds from EDAProcessor.
  FeedbackType? evaluate({
    required double hr,
    required double cadence,
    required double skinTemp,
    required double eda,
    double edaHigh = 0.37,
    double edaLow  = 0.28,
  }) {
    // Cooldown
    if (_lastTrigger != null &&
        DateTime.now().difference(_lastTrigger!).inSeconds < _cooldownSec) {
      return null;
    }

    // ── HR safety override — checked before scoring ────────
    if (hr > _profile.hrSafetyOverride) {
      _lastTrigger = DateTime.now();
      return FeedbackType.slowDown;
    }

    // ── Not running — silent ───────────────────────────────
    if (cadence < cadenceFloor) return FeedbackType.maintain;

    // ── Score each sensor ──────────────────────────────────
    int score = 0;

    // HR
    if (hr < _profile.zone2Low)       score -= 1;
    else if (hr > _profile.zone3High) score += 1;

    // Cadence (floor already checked above)
    if (cadence < _profile.cadenceOptLow)       score -= 1;
    else if (cadence > _profile.cadenceOptHigh) score += 1;

    // Skin temp
    if (skinTemp < tempLow)       score -= 1;
    else if (skinTemp > tempHigh) score += 1;

    // EDA
    if (eda < edaLow)        score -= 1;
    else if (eda > edaHigh)  score += 1;

    // ── Deadband: at least 2 sensors must agree ────────────
    if (score <= -2) {
      _lastTrigger = DateTime.now();
      return FeedbackType.pushHarder;
    }
    if (score >= 2) {
      _lastTrigger = DateTime.now();
      return FeedbackType.slowDown;
    }

    return FeedbackType.maintain;
  }

  void reset() => _lastTrigger = null;
}
