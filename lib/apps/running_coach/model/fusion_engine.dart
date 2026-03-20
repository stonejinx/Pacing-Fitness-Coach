// =============================================================
// Fusion Rule Engine
// HR zones:   ACSM Guidelines for Exercise Testing and
//             Prescription, 10th Ed.
// Cadence:    Heiderscheit et al. 2011, J. Orthopaedic &
//             Sports Physical Therapy — "Effects of step rate
//             manipulation on joint mechanics during running"
//             → optimal cadence 160–180 spm
// EDA:        Boucsein 2012
// Temperature: Exercise physiology consensus
// =============================================================

enum FeedbackType { pushHarder, slowDown, maintain }

class FusionEngine {
  // ── ACSM 10th Ed. absolute HR zones ──────────────────────
  static const double hrZone2Low  = 120.0; // bpm aerobic base
  static const double hrZone4High = 175.0; // bpm threshold ceiling

  // ── Heiderscheit et al. 2011 ─────────────────────────────
  static const double cadenceOptLow  = 160.0; // spm optimal low
  static const double cadenceOptHigh = 180.0; // spm optimal high

  // ── Boucsein 2012 ─────────────────────────────────────────
  static const double edaStress = 0.70; // normalized threshold

  // ── Exercise physiology consensus ─────────────────────────
  static const double tempWarning = 38.5; // °C skin

  // Cooldown between triggers (seconds)
  static const int _cooldownSec = 15;
  DateTime? _lastTrigger;

  FeedbackType? evaluate({
    required double hr,
    required double cadence,
    required double skinTemp,
    required double eda,
  }) {
    // Cooldown check
    if (_lastTrigger != null &&
        DateTime.now().difference(_lastTrigger!).inSeconds < _cooldownSec) {
      return null;
    }

    // Not running — silent
    if (cadence < 120.0) return FeedbackType.maintain;

    // SLOW DOWN — safety first, any one condition is sufficient
    // Sources: ACSM (HR), Boucsein (EDA), physiology consensus (temp)
    if (hr > hrZone4High || eda > edaStress || skinTemp > tempWarning) {
      _lastTrigger = DateTime.now();
      return FeedbackType.slowDown;
    }

    // PUSH HARDER — all three must agree
    // Sources: ACSM (HR below zone 2), Heiderscheit (cadence below optimal),
    //          Boucsein (EDA below 50% stress = not fatigued)
    if (hr < hrZone2Low && cadence < cadenceOptLow && eda < edaStress * 0.5) {
      _lastTrigger = DateTime.now();
      return FeedbackType.pushHarder;
    }

    return FeedbackType.maintain;
  }

  void reset() => _lastTrigger = null;
}
