// =============================================================
// User Profile — Karvonen HR zones
// HRmax = 220 − age  (Fox et al. 1971)
// Karvonen zones via Heart Rate Reserve (HRR):
//   HRR = maxHR − restingHR
//   Zone 2 low  = RHR + HRR × 0.70
//   Zone 2 high = RHR + HRR × 0.80
//   Zone 3 high = RHR + HRR × 0.85  (safety ceiling)
// Cadence: Heiderscheit et al. 2011
// =============================================================

class UserProfile {
  final int    ageYears;
  final double heightCm;
  final String sex;
  int          restingHR; // measured during 35-s RHR window; default 60

  UserProfile({
    required this.ageYears,
    required this.heightCm,
    required this.sex,
    this.restingHR = 60,
  });

  // Fox et al. 1971
  double get maxHR => (220 - ageYears).toDouble();

  // Heart Rate Reserve
  double get hrr => maxHR - restingHR;

  // Karvonen zone boundaries
  double get zone2Low  => restingHR + hrr * 0.70; // 70 % HRR
  double get zone2High => restingHR + hrr * 0.80; // 80 % HRR
  double get zone3High => restingHR + hrr * 0.85; // 85 % HRR — safety ceiling
  double get hrSafetyOverride => maxHR * 0.90;    // 90 % maxHR — absolute hard ceiling

  // Heiderscheit et al. 2011
  double get cadenceOptLow  => 160.0;
  double get cadenceOptHigh => 180.0;
}
