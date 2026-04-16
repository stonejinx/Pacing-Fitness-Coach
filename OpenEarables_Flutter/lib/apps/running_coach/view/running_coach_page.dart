import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_earable_flutter/open_earable_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:running_coach/apps/running_coach/model/running_coach_model.dart';
import 'package:running_coach/apps/running_coach/model/esp32_manager.dart';
import 'package:running_coach/apps/running_coach/model/user_profile.dart';
import 'package:running_coach/apps/running_coach/model/audio_coach.dart';
import 'package:running_coach/apps/heart_tracker/model/ppg_filter.dart';
import 'package:running_coach/view_models/sensor_configuration_provider.dart';
import 'dart:math';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:share_plus/share_plus.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:open_earable_flutter/open_earable_flutter.dart' show BatteryLevelStatus;

enum _AppState  { idle, baseline, workout }
enum _CoachState { safetyAlarm, tooFast, maintain, tooSlow }

// ── Cadence zones (spm) ───────────────────────────────────────────────────────
const double kCadenceStationary  = 20.0;
const double kCadenceWalking     = 120.0;
const double kCadenceTargetLow   = 160.0;
const double kCadenceTarget      = 165.0;
const double kCadenceTargetHigh  = 180.0;

class RunningCoachPage extends StatefulWidget {
  final Wearable wearable;

  const RunningCoachPage({super.key, required this.wearable});

  @override
  State<RunningCoachPage> createState() => _RunningCoachPageState();
}

class _RunningCoachPageState extends State<RunningCoachPage> {
  // ── Model ────────────────────────────────────────────────────────────────
  final RunningCoachModel _model = RunningCoachModel();
  final Esp32Manager _esp32 = Esp32Manager();
  final AudioCoach _audioCoach = AudioCoach();

  // ── Audio coach state ─────────────────────────────────────────────────
  bool        _audioCoachEnabled = true;
  Timer?      _audioTimer;
  AudioCue?   _lastAudioCue; // recorded in CSV

  // ── Display state ────────────────────────────────────────────────────────
  double? _cadence;
  double? _speedKmh;
  int     _stepCount = 0;
  double? _hr;
  double? _skinTemp;           // raw display value (post dropout)
  double? _skinTempSmoothed;   // EMA-smoothed — used for scoring only
  double? _lastValidSkinTemp;  // last accepted (non-dropout) reading
  double? _eda;   // model's processed EDA value (kept for future use)
  String  _coachTip = 'Connect sensors and start running!';

  // ── Skin temp pipeline constants ──────────────────────────────────────────
  static const double _skinTempDropout  = 32.0;
  static const double _skinTempEmaAlpha = 0.1;
  static const double _skinTempHighOn   = 38.5; // score +1 above this
  static const double _skinTempHighOff  = 38.0; // hysteresis — clears below this
  bool _skinTempHighActive = false;             // hysteresis state

  // ── Last total score for CSV ──────────────────────────────────────────────
  int _lastTotalScore = 0;

  // ── Debug / latency columns — cleared after each CSV row ──────────────────
  int  _ppgRawReceivedMs   = 0;   // timestamp of last raw PPG sample
  int? _lastHrProcessingMs;
  int? _lastEdaProcessingMs;
  int? _lastScoreComputeMs;
  int? _lastAudioTriggerMs;

  // ── Battery columns — written once on the relevant transition row ──────────
  int? _pendingPhoneBattBaselineStart;
  int? _pendingPhoneBattWorkoutStart;
  int? _pendingOe2BattWorkoutStart;
  final _battery = Battery();

  // ── App state ─────────────────────────────────────────────────────────────
  _AppState _appState = _AppState.idle;

  // ── User profile & baseline ───────────────────────────────────────────────
  int?          _userAge;
  UserProfile?  _userProfile;
  final List<double> _rhrSamples = [];
  double?       _measuredRHR;
  int     _baselineSecondsRemaining = 0;
  Timer?  _baselineTimer;
  static const int _kBaselineSec       = 60;
  static const int _kStabilizationSec  = 25; // first 25 s: warm-up only
  // RHR collected during last (_kBaselineSec - _kStabilizationSec) = 35 s

  // ── Phone accelerometer step detection — BCG-free ────────────────────────
  static const double _strideLengthFallback = 0.75;
  double _strideLengthM = 0.75; // set from height in _startWorkout()
  static const int    _maxTimestamps = 8;
  static const double _fastAlpha    = 0.3;
  static const double _slowAlpha    = 0.02;
  static const double _minPeakDelta = 0.25;
  static const int    _minStepMs    = 250;
  double _fastEma        = 9.8;
  double _slowEma        = 9.8;
  bool   _aboveThreshold = false;
  int    _lastStepMs     = 0;
  final List<int> _stepTimestampsMs = [];
  StreamSubscription? _stepSub;

  // ── Goal tracking ─────────────────────────────────────────────────────────
  double? _goalKm;
  double? _goalMinutes;
  bool    _goalReached      = false;
  double  _coveredKm        = 0.0;
  int     _elapsedWorkoutSec = 0;
  Timer?  _workoutTimer;
  int     _paceScore         = 0;   // -1 too slow, 0 on track, +1 ahead
  int     _paceCheckCountdown = 30;

  // ── CSV recorder ─────────────────────────────────────────────────────────
  IOSink?  _csvSink;
  bool     _recording = false;
  int      _recordingSeconds = 0;
  Timer?   _recordTimer;
  String?  _csvPath;
  double?  _edaHz; // Hz from ESP32 (spike count / 2)

  // ── Subscriptions ────────────────────────────────────────────────────────
  final List<StreamSubscription> _subs = [];
  StreamSubscription? _hrSub;
  StreamSubscription? _esp32Sub;

  // Cached so _startTracking() never calls Provider.of during async gaps
  SensorConfigurationProvider? _configProvider;
  SensorManager? _sensorManager;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _configureSensors();
      _audioCoach.init(); // initialize audio session once at startup
    });
  }

  void _configureSensors() {
    final sm = widget.wearable.getCapability<SensorManager>();
    if (sm == null) return;
    _sensorManager = sm;

    // Cache provider once here — never call Provider.of in async code paths
    _configProvider =
        Provider.of<SensorConfigurationProvider>(context, listen: false);

    for (final sensor in sm.sensors) {
      if (sensor.relatedConfigurations.isEmpty) continue;
      final cfg = sensor.relatedConfigurations.first;

      if (cfg is ConfigurableSensorConfiguration &&
          cfg.availableOptions.contains(StreamSensorConfigOption())) {
        _configProvider!.addSensorConfigurationOption(cfg, StreamSensorConfigOption());
      }

      final values = _configProvider!.getSensorConfigurationValues(cfg, distinct: true);
      if (values.isNotEmpty) {
        _configProvider!.addSensorConfiguration(cfg, values.first);
        final selected = _configProvider!.getSelectedConfigurationValue(cfg);
        if (selected != null) cfg.setConfiguration(selected);
      }
    }

    // Subscriptions are started only when the user presses Start
  }

  void _subscribeOpenEarable(SensorManager sm, SensorConfigurationProvider configProvider) {
    // Debug: print all sensor names so we can verify index mapping
    for (int i = 0; i < sm.sensors.length; i++) {
      debugPrint('[RunningCoach] sensor[$i] = "${sm.sensors[i].sensorName}"');
    }

    // OE2 V2 sensor layout (matches EgemenApp index mapping):
    //   index 3 → PPG / Photoplethysmography
    //   index 4 → Skin Temperature
    // Fall back to name matching if indices are out of range.
    Sensor? ppgSensor;
    Sensor? tempSensor;

    // Primary: name-based (works on V1 and if V2 uses same names)
    for (final sensor in sm.sensors) {
      final name = sensor.sensorName.toLowerCase();
      if (name.contains('photoplethysmography') || name == 'ppg') {
        ppgSensor ??= sensor;
      }
      if (name.contains('skin') || name.contains('temperature')) {
        tempSensor ??= sensor;
      }
    }

    // Fallback: index-based (proven on OE2 V2 via EgemenApp)
    if (ppgSensor == null && sm.sensors.length > 3) {
      ppgSensor = sm.sensors[3];
      debugPrint('[RunningCoach] PPG fallback to index 3: "${ppgSensor.sensorName}"');
    }
    if (tempSensor == null && sm.sensors.length > 4) {
      tempSensor = sm.sensors[4];
      debugPrint('[RunningCoach] SkinTemp fallback to index 4: "${tempSensor.sensorName}"');
    }

    // Subscribe PPG → HR
    if (ppgSensor != null) {
      double sampleFreq = 50; // safe default matching original code
      if (ppgSensor.relatedConfigurations.isNotEmpty) {
        final cfg = ppgSensor.relatedConfigurations.first;
        final selected = configProvider.getSelectedConfigurationValue(cfg);
        if (selected is SensorFrequencyConfigurationValue) {
          sampleFreq = selected.frequencyHz;
        }
      }
      final filter = PpgFilter(
        inputStream: ppgSensor.sensorStream.asyncMap((data) {
          _ppgRawReceivedMs = DateTime.now().millisecondsSinceEpoch;
          final d = data as SensorDoubleValue;
          // Use index 2 (IR channel); negate to match PpgFilter polarity.
          // Guard against sensors with <3 or <4 values.
          final double raw;
          if (d.values.length >= 4) {
            raw = -(d.values[2] + d.values[3]);
          } else if (d.values.length >= 3) {
            raw = -d.values[2];
          } else {
            raw = -d.values[0];
          }
          return (d.timestamp, raw);
        }).asBroadcastStream(),
        sampleFreq: sampleFreq,
        timestampExponent: ppgSensor.timestampExponent,
      );
      _hrSub = filter.heartRateStream.listen((hr) {
        _lastHrProcessingMs =
            DateTime.now().millisecondsSinceEpoch - _ppgRawReceivedMs;
        if (mounted) setState(() => _hr = hr);
        _updateCoachTip();
      });
      debugPrint('[RunningCoach] Subscribed PPG: "${ppgSensor.sensorName}"');
    } else {
      debugPrint('[RunningCoach] WARNING: No PPG sensor found');
    }

    // Subscribe skin temperature — dropout rejection then EMA smoothing
    if (tempSensor != null) {
      final sub = tempSensor.sensorStream.listen((value) {
        if (value is SensorDoubleValue && value.values.isNotEmpty) {
          final raw = value.values[0];
          // 1. Dropout rejection: below 32°C → use last valid reading
          final accepted = raw >= _skinTempDropout ? raw : _lastValidSkinTemp;
          if (accepted == null) return; // no valid reading yet
          if (raw >= _skinTempDropout) _lastValidSkinTemp = raw;
          // 2. EMA smoothing (α = 0.1) on accepted value
          final smoothed = _skinTempSmoothed == null
              ? accepted
              : _skinTempEmaAlpha * accepted +
                    (1 - _skinTempEmaAlpha) * _skinTempSmoothed!;
          if (mounted) {
            setState(() {
              _skinTemp         = accepted;   // display post-dropout raw
              _skinTempSmoothed = smoothed;   // scoring uses this
            });
          }
          _model.onTempSample(smoothed);
        }
      });
      _subs.add(sub);
      debugPrint('[RunningCoach] Subscribed SkinTemp: "${tempSensor.sensorName}"');
    } else {
      debugPrint('[RunningCoach] WARNING: No skin temp sensor found');
    }
  }

  // ── Start button handler ──────────────────────────────────────────────────
  Future<void> _onStartPressed() async {
    final controller = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Your Age'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Age (10–100)',
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
    final text = controller.text.trim();
    // Do NOT call controller.dispose() here — the keyboard-hide animation
    // still holds a listener on the controller. It is a local variable and
    // will be garbage collected once the dialog and this method are done.

    if (confirmed != true || !mounted) return;
    final age = int.tryParse(text);
    if (age == null || age < 10 || age > 100) return;
    _beginBaseline(age);
  }

  /// Re-sends the streaming configuration to the OE2 hardware.
  /// Needed after turnOffAllSensors() — the cached config is now "off"
  /// so we must rewrite it back to streaming before subscribing.
  void _reEnableSensors() {
    if (_sensorManager == null || _configProvider == null) return;
    for (final sensor in _sensorManager!.sensors) {
      if (sensor.relatedConfigurations.isEmpty) continue;
      final cfg = sensor.relatedConfigurations.first;

      // Re-add the stream option (was cleared by turnOffAllSensors)
      if (cfg is ConfigurableSensorConfiguration &&
          cfg.availableOptions.contains(StreamSensorConfigOption())) {
        _configProvider!.addSensorConfigurationOption(cfg, StreamSensorConfigOption());
      }

      // Re-select the first (streaming) value and push it to the device
      final values = _configProvider!.getSensorConfigurationValues(cfg, distinct: true);
      if (values.isNotEmpty) {
        _configProvider!.addSensorConfiguration(cfg, values.first);
        final selected = _configProvider!.getSelectedConfigurationValue(cfg);
        if (selected != null) cfg.setConfiguration(selected);
      }
    }
  }

  void _beginBaseline(int age) {
    // Read phone battery for CSV baseline_start column
    _readPhoneBattery().then((v) {
      if (mounted) setState(() => _pendingPhoneBattBaselineStart = v);
    });
    _userAge     = age;
    _rhrSamples.clear();
    _measuredRHR = null;
    _userProfile = UserProfile(ageYears: age, heightCm: 170, sex: 'unknown');
    _model.updateUserProfile(_userProfile!);

    // Re-enable OE2 hardware sensors (reverses turnOffAllSensors from last stop)
    _reEnableSensors();

    // Subscribe OE2 + ESP32 — NO accelerometer yet
    if (_sensorManager != null && _configProvider != null) {
      _hrSub?.cancel();
      for (final s in _subs) { s.cancel(); }
      _subs.clear();
      _subscribeOpenEarable(_sensorManager!, _configProvider!);
    }
    _esp32Sub?.cancel();
    _subscribeEsp32();
    _esp32.startScanAndConnect();

    setState(() {
      _appState                 = _AppState.baseline;
      _baselineSecondsRemaining = _kBaselineSec;
    });

    _baselineTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) { t.cancel(); return; }
      setState(() => _baselineSecondsRemaining--);

      // Collect RHR only during the active measurement window (last 35 s)
      if (_baselineSecondsRemaining > 0 &&
          _baselineSecondsRemaining <= (_kBaselineSec - _kStabilizationSec)) {
        final h = _hr;
        if (h != null && h >= 30 && h <= 120) _rhrSamples.add(h);
      }

      if (_baselineSecondsRemaining <= 0) {
        t.cancel();
        _baselineTimer = null;
        _finaliseRHR();
        _onBaselineComplete();
      }
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Sit still for 60 s — first 25 s warm-up, then resting HR'),
          duration: Duration(seconds: 5),
        ),
      );
    }
  }

  void _finaliseRHR() {
    if (_rhrSamples.isEmpty) return;
    final sorted = List<double>.from(_rhrSamples)..sort();
    final mid    = sorted.length ~/ 2;
    final median = sorted.length.isOdd
        ? sorted[mid]
        : (sorted[mid - 1] + sorted[mid]) / 2.0;
    _measuredRHR         = median;
    _userProfile!.restingHR = median.round();
    _model.updateUserProfile(_userProfile!);
  }

  Future<void> _onBaselineComplete() async {
    if (!mounted) return;

    final distCtrl = TextEditingController();
    final durCtrl  = TextEditingController();

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) {
          String? validationMsg;
          return AlertDialog(
            title: Text(
              _measuredRHR != null
                  ? 'Baseline Ready!  RHR: ${_measuredRHR!.round()} bpm'
                  : 'Baseline Ready!',
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Move to your starting position, then tap Start Workout.'),
                const SizedBox(height: 16),
                const Text('Set a goal (optional):',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: distCtrl,
                        keyboardType:
                            const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(
                          labelText: 'Distance (km)',
                          isDense: true,
                        ),
                        onChanged: (_) => setDlg(() {}),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: durCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Duration (min)',
                          isDense: true,
                        ),
                        onChanged: (_) => setDlg(() {}),
                      ),
                    ),
                  ],
                ),
                if (validationMsg != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    validationMsg!,
                    style: TextStyle(
                      color: Theme.of(ctx).colorScheme.error,
                      fontSize: 12,
                    ),
                  ),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  final hasDist = distCtrl.text.trim().isNotEmpty;
                  final hasDur  = durCtrl.text.trim().isNotEmpty;
                  if (hasDist != hasDur) {
                    setDlg(() => validationMsg =
                        'Enter both distance and duration, or leave both empty.');
                    return;
                  }
                  Navigator.pop(ctx, true);
                },
                child: const Text('Start Workout'),
              ),
            ],
          );
        },
      ),
    );

    // Read values before controllers are GC'd
    final goalKm  = double.tryParse(distCtrl.text.trim());
    final goalMin = double.tryParse(durCtrl.text.trim());

    if (!mounted) return;
    if (result == true) {
      // Distance-only OR duration-only goals are each independently valid
      if (goalKm  != null && goalKm  > 0) _goalKm      = goalKm;
      if (goalMin != null && goalMin > 0) _goalMinutes = goalMin;
      _startWorkout();
    } else {
      _resetEverything();
    }
  }

  // ── Stop button handler ───────────────────────────────────────────────────
  Future<void> _onStopPressed() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Stop Workout?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Continue'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              _resetEverything();
            },
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red,
            ),
            child: const Text('Reset Everything'),
          ),
        ],
      ),
    );
  }

  void _resetEverything() {
    _stopTracking();
    _userAge      = null;
    _userProfile  = null;
    _rhrSamples.clear();
    _measuredRHR  = null;
    setState(() => _coachTip = 'Connect sensors and start running!');
  }

  // ── Start / Stop tracking ─────────────────────────────────────────────────
  void _startWorkout() {
    if (!mounted) return;
    // Read battery levels for CSV workout_start columns
    _readPhoneBattery().then((v) {
      if (mounted) setState(() => _pendingPhoneBattWorkoutStart = v);
    });
    _readOe2Battery().then((v) {
      if (mounted) setState(() => _pendingOe2BattWorkoutStart = v);
    });
    // Derive stride length from height (Heiderscheit et al.) — fallback 0.75 m
    final h = _userProfile?.heightCm ?? 0;
    _strideLengthM = h > 0 ? h * 0.413 / 100.0 : _strideLengthFallback;
    _stepSub?.cancel();
    _stepSub = userAccelerometerEventStream(
      samplingPeriod: SensorInterval.gameInterval,
    ).listen(_onPhoneAccel, onError: (_) {});

    _workoutTimer?.cancel();
    _elapsedWorkoutSec  = 0;
    _paceCheckCountdown = 30;
    _paceScore          = 0;
    _workoutTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _elapsedWorkoutSec++);
      _paceCheckCountdown--;
      if (_paceCheckCountdown <= 0) {
        _paceCheckCountdown = 30;
        _checkPaceScore();
      }
    });

    // 30-second audio coaching timer — same priority as visual tips
    _audioTimer?.cancel();
    _lastAudioCue = null;
    _audioTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!mounted || _appState != _AppState.workout) return;
      if (!_audioCoachEnabled) return;
      _fireAudioCue();
    });

    setState(() {
      _appState   = _AppState.workout;
      _lastStepMs = DateTime.now().millisecondsSinceEpoch;
    });
  }

  // ── Unified state evaluation ──────────────────────────────────────────────
  // Returns one of four states based on sensor scoring.
  // Called by both _updateCoachTip() and _fireAudioCue() so they are always in sync.
  _CoachState _evaluateState() {
    final profile = _userProfile;

    // HR safety override — absolute hard ceiling, no deadband needed
    if (_hr != null && profile != null &&
        _hr! > profile.hrSafetyOverride) {
      _lastTotalScore = 99; // sentinel value in CSV
      return _CoachState.safetyAlarm;
    }

    int score = 0;

    // HR zone score
    if (_hr != null && profile != null) {
      if (_hr! < profile.zone2Low)       score -= 1;
      else if (_hr! > profile.zone3High) score += 1;
    }

    // Cadence score — floor at 60 spm (already applied in detection)
    if (_cadence != null && _cadence! >= 60) {
      if (_cadence! < kCadenceTargetLow)       score -= 1;
      else if (_cadence! > kCadenceTargetHigh) score += 1;
    }

    // Skin temp score — uses EMA-smoothed value with hysteresis on high zone
    final temp = _skinTempSmoothed;
    if (temp != null) {
      if (_skinTempHighActive) {
        if (temp < _skinTempHighOff) _skinTempHighActive = false; // hysteresis clears
      } else {
        if (temp > _skinTempHighOn) _skinTempHighActive = true;
      }
      if (temp < 36.0)           score -= 1;
      else if (_skinTempHighActive) score += 1;
    }

    // EDA score — uses live dynamic thresholds
    if (_edaHz != null) {
      if (_edaHz! < _model.edaThresholdLow)       score -= 1;
      else if (_edaHz! > _model.edaThresholdHigh)  score += 1;
    }

    // Pace score — only when both km + min goals are set
    if (_goalKm != null && _goalMinutes != null) {
      score += _paceScore; // -1 too slow, 0 on track, +1 ahead
    }

    _lastTotalScore = score;

    if (score <= -2) return _CoachState.tooSlow;
    if (score >= 2)  return _CoachState.tooFast;
    return _CoachState.maintain;
  }

  void _fireAudioCue() {
    final state = _evaluateState();
    AudioCue? cue;
    switch (state) {
      case _CoachState.safetyAlarm: cue = AudioCue.safety;
      case _CoachState.tooFast:     cue = AudioCue.moderate;
      case _CoachState.tooSlow:     cue = AudioCue.tooSlow;
      case _CoachState.maintain:    cue = null;
    }
    setState(() => _lastAudioCue = cue);
    if (cue != null) {
      final t0 = DateTime.now().millisecondsSinceEpoch;
      _audioCoach.play(cue);
      _lastAudioTriggerMs = DateTime.now().millisecondsSinceEpoch - t0;
    }
  }

  void _checkPaceScore() {
    if (_goalKm == null || _goalMinutes == null) return;
    final elapsedMin   = _elapsedWorkoutSec / 60.0;
    final remainingKm  = _goalKm! - _coveredKm;
    final remainingMin = _goalMinutes! - elapsedMin;

    if (remainingMin <= 0 || remainingKm <= 0) {
      setState(() => _paceScore = 0);
      return;
    }

    final requiredSpeedKmh = remainingKm / (remainingMin / 60.0);
    final currentSpeed     = _speedKmh ?? 0.0;

    // Don't penalise if user hasn't started moving yet
    if (currentSpeed < 0.5) {
      setState(() => _paceScore = 0);
      return;
    }

    final ratio = currentSpeed / requiredSpeedKmh;
    setState(() {
      if (ratio < 0.80)      _paceScore = -1;   // too slow → push harder
      else if (ratio > 1.20) _paceScore =  1;   // ahead   → slow down
      else                   _paceScore =  0;
    });
    _updateCoachTip();

    // Goal completion — fire once when distance OR time goal is reached
    if (!_goalReached) {
      final distDone = _goalKm != null && _coveredKm >= _goalKm! * 0.99;
      final timeDone = _goalMinutes != null &&
          (_elapsedWorkoutSec / 60.0) >= _goalMinutes! * 0.99;
      if (distDone || timeDone) {
        _goalReached = true;
        _audioTimer?.cancel();
        _audioTimer = null;
        if (mounted) {
          setState(() => _coachTip = 'Goal reached! Great job!');
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Goal reached! Great job!'),
              duration: Duration(seconds: 4),
            ),
          );
        }
      }
    }
  }

  void _stopTracking() {
    _baselineTimer?.cancel();
    _baselineTimer = null;
    _workoutTimer?.cancel();
    _workoutTimer = null;
    _audioTimer?.cancel();
    _audioTimer = null;

    // Turn off OE2 sensors on the hardware (stops the blinking LED)
    _configProvider?.turnOffAllSensors();

    _stepSub?.cancel();
    _stepSub = null;
    _hrSub?.cancel();
    _hrSub = null;
    _esp32Sub?.cancel();
    _esp32Sub = null;
    for (final s in _subs) { s.cancel(); }
    _subs.clear();
    _esp32.disconnect();
    _model.reset();
    setState(() {
      _appState       = _AppState.idle;
      _cadence        = null;
      _speedKmh       = null;
      _stepCount      = 0;
      _hr                = null;
      _skinTemp          = null;
      _skinTempSmoothed  = null;
      _lastValidSkinTemp = null;
      _skinTempHighActive = false;
      _lastTotalScore    = 0;
      _eda            = null;
      _edaHz          = null;
      _fastEma        = 9.8;
      _slowEma        = 9.8;
      _aboveThreshold = false;
      _baselineSecondsRemaining = 0;
      _goalKm            = null;
      _goalMinutes       = null;
      _goalReached       = false;
      _coveredKm         = 0.0;
      _elapsedWorkoutSec = 0;
      _paceScore         = 0;
      _paceCheckCountdown = 30;
      _stepTimestampsMs.clear();
      _edaHz        = null;
      _lastAudioCue = null;
      _coachTip = 'Connect sensors and start running!';
    });
  }

  void _onPhoneAccel(UserAccelerometerEvent e) {
    if (_appState != _AppState.workout) return;
    final mag = sqrt(e.x * e.x + e.y * e.y + e.z * e.z);
    _fastEma = _fastAlpha * mag + (1 - _fastAlpha) * _fastEma;
    _slowEma = _slowAlpha * mag + (1 - _slowAlpha) * _slowEma;

    final nowAbove = (_fastEma - _slowEma) > _minPeakDelta;
    if (nowAbove && !_aboveThreshold) {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if (nowMs - _lastStepMs >= _minStepMs) {
        _lastStepMs = nowMs;
        _stepTimestampsMs.add(nowMs);
        if (_stepTimestampsMs.length > _maxTimestamps) _stepTimestampsMs.removeAt(0);

        double? spm;
        double? speed;
        if (_stepTimestampsMs.length >= 2) {
          double totalMs = 0;
          for (int i = 1; i < _stepTimestampsMs.length; i++) {
            totalMs += _stepTimestampsMs[i] - _stepTimestampsMs[i - 1];
          }
          final avgMs = totalMs / (_stepTimestampsMs.length - 1);
          final rawSpm = 60000.0 / avgMs;
          // Floor rejection: below 60 spm is noise/frozen IMU — treat as no data
          spm   = rawSpm >= 60.0 ? rawSpm : null;
          speed = (_strideLengthM / (avgMs / 1000.0)) * 3.6;
        }

        _model.updateCadence(spm);
        if (mounted) {
          setState(() {
            _stepCount++;
            _coveredKm += _strideLengthM / 1000.0;
            _cadence  = spm;
            _speedKmh = speed;
          });
          _updateCoachTip();
        }
      }
    }
    _aboveThreshold = nowAbove;
  }

  void _subscribeEsp32() {
    _esp32Sub = _esp32.gsrStream.listen((hz) {
      final t0 = DateTime.now().millisecondsSinceEpoch;
      _edaHz = hz;
      _model.onEDASample(hz);
      _lastEdaProcessingMs = DateTime.now().millisecondsSinceEpoch - t0;
      if (mounted) {
        setState(() { _eda = _model.eda; });
        _updateCoachTip();
      }
    });
  }

  // ── Recording ─────────────────────────────────────────────────────────────

  Future<void> _startRecording() async {
    final tag = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    final filename = 'running_coach_$tag.csv';

    String path;
    if (Platform.isAndroid) {
      final dir = await getExternalStorageDirectory();
      path = '${dir!.path}/$filename';
    } else {
      final dir = await getApplicationDocumentsDirectory();
      path = '${dir.path}/$filename';
    }

    final file = File(path);
    _csvSink = file.openWrite();
    _csvSink!.writeln(
      'timestamp_ms,elapsed_workout_sec,step_count,covered_km,'
      'cadence_spm,speed_kmh,hr_bpm,skin_temp_c,'
      'eda_hz,total_score,audio_cue,coach_tip,goal_set,goal_completion,'
      'hr_processing_ms,eda_processing_ms,score_compute_ms,audio_trigger_ms,'
      'phone_battery_baseline_start,phone_battery_workout_start,phone_battery_workout_end,'
      'oe2_battery_workout_start,oe2_battery_workout_end',
    );
    _csvPath = path;
    _recordingSeconds = 0;

    _recordTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _recordingSeconds++;
      _writeCsvRow();
      if (mounted) setState(() {});
    });

    setState(() => _recording = true);
  }

  void _writeCsvRow() {
    final ms      = DateTime.now().millisecondsSinceEpoch;
    final elapsed = _elapsedWorkoutSec.toString();
    final steps   = _stepCount.toString();
    final dist    = _coveredKm.toStringAsFixed(4);
    final c       = _cadence?.toStringAsFixed(1)   ?? '';
    final spd     = _speedKmh?.toStringAsFixed(2)  ?? '';
    final h       = _hr?.toStringAsFixed(1)         ?? '';
    final t       = _skinTemp?.toStringAsFixed(2)   ?? '';
    final hz      = _edaHz?.toStringAsFixed(2)         ?? '';
    final cue     = AudioCoach.cueLabel(_lastAudioCue);
    final score   = _lastTotalScore == 99 ? 'safety' : _lastTotalScore.toString();
    final tip     = _coachTip.replaceAll(',', ';');
    final goalSet = _goalKm != null ? 'distance_and_time' : '';
    // Latency columns — present when measured this tick, else empty
    final hrMs    = _lastHrProcessingMs?.toString()  ?? '';
    final edaMs   = _lastEdaProcessingMs?.toString() ?? '';
    final scoreMs = _lastScoreComputeMs?.toString()  ?? '';
    final audioMs = _lastAudioTriggerMs?.toString()  ?? '';
    // Battery columns — written once on their transition row, else empty
    final phoneBattBaseline = _pendingPhoneBattBaselineStart?.toString() ?? '';
    final phoneBattWorkout  = _pendingPhoneBattWorkoutStart?.toString()  ?? '';
    final oe2BattWorkout    = _pendingOe2BattWorkoutStart?.toString()    ?? '';
    _csvSink?.writeln(
      '$ms,$elapsed,$steps,$dist,$c,$spd,$h,$t,$hz,$score,$cue,$tip,$goalSet,,'
      '$hrMs,$edaMs,$scoreMs,$audioMs,'
      '$phoneBattBaseline,$phoneBattWorkout,,$oe2BattWorkout,',
    );
    // Clear after writing so each value appears on exactly one row
    _lastAudioCue               = null;
    _lastHrProcessingMs         = null;
    _lastEdaProcessingMs        = null;
    _lastScoreComputeMs         = null;
    _lastAudioTriggerMs         = null;
    _pendingPhoneBattBaselineStart = null;
    _pendingPhoneBattWorkoutStart  = null;
    _pendingOe2BattWorkoutStart    = null;
  }

  String _goalCompletionLabel() {
    if (_goalKm == null) return ''; // no goal set
    if (_goalReached) return 'completed';
    final distMet = _coveredKm >= _goalKm! * 0.99;
    final timeMet = (_elapsedWorkoutSec / 60.0) >= _goalMinutes! * 0.99;
    if (distMet && timeMet) return 'completed';
    if (distMet) return 'distance_reached';
    if (timeMet) return 'time_reached';
    return 'goal_not_met';
  }

  Future<void> _stopRecording() async {
    _recordTimer?.cancel();
    _recordTimer = null;
    // Write one final summary row with goal_completion and battery_end values
    if (_csvSink != null) {
      final phoneBattEnd = await _readPhoneBattery();
      final oe2BattEnd   = await _readOe2Battery();
      final ms         = DateTime.now().millisecondsSinceEpoch;
      final elapsed    = _elapsedWorkoutSec.toString();
      final steps      = _stepCount.toString();
      final dist       = _coveredKm.toStringAsFixed(4);
      final goalSet    = _goalKm != null ? 'distance_and_time' : '';
      final completion = _goalCompletionLabel();
      final phoneBattEndStr = phoneBattEnd?.toString() ?? '';
      final oe2BattEndStr   = oe2BattEnd?.toString()   ?? '';
      // columns: ...core..., goal_set, goal_completion,
      //          hr_ms, eda_ms, score_ms, audio_ms,
      //          phone_batt_baseline_start, phone_batt_workout_start, phone_batt_workout_end,
      //          oe2_batt_workout_start, oe2_batt_workout_end
      _csvSink!.writeln(
        '$ms,$elapsed,$steps,$dist,,,,,,,,,,$goalSet,$completion,'
        ',,,,'
        ',,$phoneBattEndStr,,$oe2BattEndStr',
      );
    }
    await _csvSink?.flush();
    await _csvSink?.close();
    _csvSink = null;
    setState(() => _recording = false);

    if (_csvPath != null && mounted) {
      final path = _csvPath!;
      showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Recording saved'),
          content: Text(path.split('/').last),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
            FilledButton.icon(
              icon: const Icon(Icons.share),
              label: const Text('Export CSV'),
              onPressed: () {
                Navigator.pop(context);
                SharePlus.instance.share(
                  ShareParams(files: [XFile(path)]),
                );
              },
            ),
          ],
        ),
      );
    }
  }

  String get _recordingLabel {
    final m = _recordingSeconds ~/ 60;
    final s = _recordingSeconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  // ── Coach tip ─────────────────────────────────────────────────────────────

  void _updateCoachTip() {
    if (_appState != _AppState.workout) return;
    final sw = Stopwatch()..start();
    final state = _evaluateState();
    sw.stop();
    _lastScoreComputeMs = sw.elapsedMilliseconds;
    final tip = switch (state) {
      _CoachState.safetyAlarm => 'Ease off — HR too high!',
      _CoachState.tooFast     => 'Ease off — overexertion detected.',
      _CoachState.tooSlow     => 'Push harder — pick up the pace!',
      _CoachState.maintain    => 'Good effort — keep it up!',
    };
    if (mounted) setState(() => _coachTip = tip);
  }

  // ── Battery helpers ───────────────────────────────────────────────────────

  Future<int?> _readPhoneBattery() async {
    try { return await _battery.batteryLevel; } catch (_) { return null; }
  }

  Future<int?> _readOe2Battery() async {
    try {
      final cap = widget.wearable.getCapability<BatteryLevelStatus>();
      return await cap?.readBatteryPercentage();
    } catch (_) { return null; }
  }

  @override
  void dispose() {
    _stepSub?.cancel();
    _recordTimer?.cancel();
    _csvSink?.close();
    _baselineTimer?.cancel();
    _workoutTimer?.cancel();
    _audioTimer?.cancel();
    for (final s in _subs) { s.cancel(); }
    _hrSub?.cancel();
    _esp32Sub?.cancel();
    _esp32.dispose();
    _audioCoach.dispose();
    _model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Running Coach'),
        actions: [
          // Mute / unmute audio coaching
          IconButton(
            icon: Icon(
              _audioCoachEnabled ? Icons.volume_up : Icons.volume_off,
              color: _audioCoachEnabled ? null : Colors.grey,
            ),
            tooltip: _audioCoachEnabled
                ? 'Mute audio coaching'
                : 'Unmute audio coaching',
            onPressed: () =>
                setState(() => _audioCoachEnabled = !_audioCoachEnabled),
          ),
          if (_recording)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 4),
              child: Row(
                children: [
                  const Icon(Icons.circle, color: Colors.red, size: 10),
                  const SizedBox(width: 4),
                  Text(_recordingLabel,
                      style: const TextStyle(
                          fontFeatures: [FontFeature.tabularFigures()])),
                ],
              ),
            ),
          IconButton(
            icon: Icon(_recording ? Icons.stop_circle : Icons.fiber_manual_record,
                color: _recording ? Colors.red : null),
            tooltip: _recording ? 'Stop recording' : 'Start recording',
            onPressed: _recording ? _stopRecording : _startRecording,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Start / Stop
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (_appState == _AppState.idle)
                  ElevatedButton(
                    onPressed: _onStartPressed,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xff77F2A1),
                      foregroundColor: Colors.black,
                      minimumSize: const Size(100, 44),
                    ),
                    child: const Text('Start'),
                  ),
                if (_appState != _AppState.idle)
                  ElevatedButton(
                    onPressed: _onStopPressed,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xfff27777),
                      foregroundColor: Colors.black,
                      minimumSize: const Size(100, 44),
                    ),
                    child: const Text('Stop'),
                  ),
              ],
            ),
            const SizedBox(height: 12),

            // Coach tip / baseline banner
            Card(
              color: Theme.of(context).colorScheme.primaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: _appState == _AppState.baseline
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.hourglass_top,
                                  color: Colors.amber, size: 32),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  _baselineSecondsRemaining >
                                          (_kBaselineSec - _kStabilizationSec)
                                      ? 'Warming up — sit still... '
                                        '$_baselineSecondsRemaining s'
                                      : 'Measuring resting HR... '
                                        '$_baselineSecondsRemaining s',
                                  style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w500),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          if (_hr != null)
                            Text('HR: ${_hr!.round()} bpm',
                                style: const TextStyle(
                                    fontSize: 13, color: Colors.grey)),
                          Text('ESP32: ${_esp32.status}',
                              style: const TextStyle(
                                  fontSize: 13, color: Colors.grey)),
                          if (_measuredRHR != null)
                            Text(
                                'Resting HR: ${_measuredRHR!.round()} bpm',
                                style: const TextStyle(
                                    fontSize: 13, color: Colors.green)),
                          const SizedBox(height: 10),
                          LinearProgressIndicator(
                            value: 1 -
                                (_baselineSecondsRemaining / _kBaselineSec),
                          ),
                        ],
                      )
                    : Row(
                        children: [
                          const Icon(Icons.directions_run, size: 32),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              _coachTip,
                              style: const TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.w500),
                            ),
                          ),
                        ],
                      ),
              ),
            ),
            const SizedBox(height: 16),

            // HR + Skin temp — visible during baseline and workout
            if (_appState != _AppState.idle) ...[
              Row(
                children: [
                  Expanded(child: _MetricCard(
                    label: 'Heart Rate',
                    value: _hr != null ? '${_hr!.round()}' : '--',
                    unit: 'bpm',
                    icon: Icons.favorite,
                    color: Colors.red,
                  )),
                  const SizedBox(width: 12),
                  Expanded(child: _MetricCard(
                    label: 'Skin Temperature',
                    value: _skinTemp != null
                        ? _skinTemp!.toStringAsFixed(1)
                        : '--',
                    unit: '°C',
                    icon: Icons.thermostat,
                    color: Colors.orange,
                  )),
                ],
              ),
              const SizedBox(height: 12),
            ],

            // Cadence + Steps + Speed — only during workout
            if (_appState == _AppState.workout) ...[
              Row(
                children: [
                  Expanded(child: _MetricCard(
                    label: 'Cadence',
                    value: _cadence != null ? '${_cadence!.round()}' : '--',
                    unit: 'spm',
                    icon: Icons.directions_walk,
                    color: _cadenceColor(_cadence),
                  )),
                  const SizedBox(width: 12),
                  Expanded(child: _MetricCard(
                    label: 'Steps',
                    value: '$_stepCount',
                    unit: 'steps',
                    icon: Icons.directions_walk_outlined,
                    color: Colors.indigo,
                  )),
                ],
              ),
              const SizedBox(height: 12),
              _MetricCard(
                label: 'Speed',
                value: _speedKmh != null
                    ? _speedKmh!.toStringAsFixed(1)
                    : '--',
                unit: 'km/h',
                icon: Icons.speed,
                color: Colors.deepPurple,
              ),
              const SizedBox(height: 12),

              // Goal progress card — shown when any goal is set
              if (_goalKm != null || _goalMinutes != null) ...[
                _GoalCard(
                  goalKm:          _goalKm,
                  goalMinutes:     _goalMinutes,
                  coveredKm:       _coveredKm,
                  elapsedSec:      _elapsedWorkoutSec,
                  currentSpeedKmh: _speedKmh,
                ),
                const SizedBox(height: 12),
              ],
            ],

            // ESP32 GSR + EDA — visible during baseline and workout
            if (_appState != _AppState.idle)
              _GsrCard(
                esp32:            _esp32,
                edaHz:            _edaHz,
                edaReady:         _model.edaReady,
                edaProgress:      _model.edaProgress,
                edaThresholdLow:  _model.edaThresholdLow,
                edaThresholdHigh: _model.edaThresholdHigh,
              ),
          ],
        ),
      ),
    );
  }

  Color _cadenceColor(double? c) {
    if (c == null || c < kCadenceStationary) return Colors.grey;
    if (c < kCadenceWalking)     return Colors.blue;
    if (c < kCadenceTargetLow)   return Colors.orange;
    if (c <= kCadenceTargetHigh) return Colors.green;
    return Colors.purple;
  }
}

// ── Metric card ───────────────────────────────────────────────────────────────

class _MetricCard extends StatelessWidget {
  final String   label;
  final String   value;
  final String   unit;
  final IconData icon;
  final Color    color;

  const _MetricCard({
    required this.label,
    required this.value,
    required this.unit,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 12),
        child: Column(
          children: [
            Icon(icon, color: color, size: 24),
            const SizedBox(height: 4),
            Text(value,
                style: TextStyle(
                    fontSize: 34, fontWeight: FontWeight.bold, color: color)),
            Text(unit,
                style: const TextStyle(fontSize: 13, color: Colors.grey)),
            const SizedBox(height: 2),
            Text(label, style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

// ── ESP32 GSR card ────────────────────────────────────────────────────────────

class _GsrCard extends StatelessWidget {
  final Esp32Manager esp32;
  final double? edaHz;
  final bool    edaReady;
  final int     edaProgress;
  final double  edaThresholdLow;
  final double  edaThresholdHigh;

  const _GsrCard({
    required this.esp32,
    required this.edaHz,
    required this.edaReady,
    required this.edaProgress,
    this.edaThresholdLow  = 0.28,
    this.edaThresholdHigh = 0.37,
  });

  Color _hzColor(double hz) {
    if (hz < edaThresholdLow)  return Colors.blue;
    if (hz < edaThresholdHigh) return Colors.orange;
    return Colors.red;
  }

  String _hzLabel(double hz) {
    if (hz < edaThresholdLow)  return 'Low stress';
    if (hz < edaThresholdHigh) return 'Moderate stress';
    return 'High stress';
  }

  @override
  Widget build(BuildContext context) {
    final connected = esp32.isConnected;
    final hz        = edaHz;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                Icon(Icons.sensors,
                    color: connected ? Colors.green : Colors.grey, size: 22),
                const SizedBox(width: 8),
                const Text('GSR / EDA',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                const Spacer(),
                Text(connected ? 'Connected' : 'Disconnected',
                    style: TextStyle(
                        fontSize: 12,
                        color: connected ? Colors.green : Colors.grey)),
              ],
            ),
            const SizedBox(height: 4),
            Text(esp32.status,
                style: const TextStyle(color: Colors.grey, fontSize: 12)),
            const SizedBox(height: 12),

            // Main Hz value
            Center(
              child: Column(
                children: [
                  if (hz == null) ...[
                    const Text('--',
                        style: TextStyle(
                            fontSize: 48,
                            fontWeight: FontWeight.bold,
                            color: Colors.grey)),
                    const Text('Hz',
                        style: TextStyle(fontSize: 13, color: Colors.grey)),
                  ] else ...[
                    Text(hz.toStringAsFixed(2),
                        style: TextStyle(
                            fontSize: 48,
                            fontWeight: FontWeight.bold,
                            color: _hzColor(hz))),
                    Text('Hz  •  ${_hzLabel(hz)}',
                        style: TextStyle(
                            fontSize: 13, color: _hzColor(hz))),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 14),

            // Connect / Disconnect button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: connected
                    ? esp32.disconnect
                    : esp32.startScanAndConnect,
                style: ElevatedButton.styleFrom(
                  backgroundColor: connected
                      ? Colors.red.shade100
                      : Colors.green.shade100,
                  foregroundColor: connected ? Colors.red : Colors.green,
                ),
                child: Text(connected ? 'Disconnect' : 'Connect ESP32'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Goal progress card ────────────────────────────────────────────────────────

class _GoalCard extends StatelessWidget {
  final double?  goalKm;       // nullable — distance goal is optional
  final double?  goalMinutes;  // nullable — duration goal is optional
  final double   coveredKm;
  final int      elapsedSec;
  final double?  currentSpeedKmh;

  const _GoalCard({
    required this.goalKm,
    required this.goalMinutes,
    required this.coveredKm,
    required this.elapsedSec,
    required this.currentSpeedKmh,
  });

  static String _fmtTime(int totalSec) {
    final m = totalSec ~/ 60;
    final s = totalSec  % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  static String _fmtPace(double kmh) {
    if (kmh < 0.1) return '--:-- /km';
    final secPerKm = 3600.0 / kmh;
    final m = secPerKm ~/ 60;
    final s = (secPerKm % 60).round();
    return '${m.toString()}:${s.toString().padLeft(2, '0')} /km';
  }

  @override
  Widget build(BuildContext context) {
    final elapsedMin = elapsedSec / 60.0;

    final hasDist = goalKm != null;
    final hasTime = goalMinutes != null;

    final distProgress  = hasDist
        ? (coveredKm / goalKm!).clamp(0.0, 1.0) : null;
    final remainingKm   = hasDist
        ? (goalKm! - coveredKm).clamp(0.0, goalKm!) : null;
    final remainingMin  = hasTime
        ? (goalMinutes! - elapsedMin).clamp(0.0, goalMinutes!) : null;
    final remainingSec  = remainingMin != null
        ? (remainingMin * 60).round() : null;

    double? requiredKmh;
    if (remainingMin != null && remainingKm != null &&
        remainingMin > 0 && remainingKm > 0) {
      requiredKmh = remainingKm / (remainingMin / 60.0);
    }

    final distDone = hasDist && coveredKm >= goalKm!;
    final timeDone = hasTime && remainingMin != null && remainingMin <= 0;
    final done     = distDone || timeDone;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.flag,
                    color: done ? Colors.green : Colors.blue, size: 22),
                const SizedBox(width: 8),
                const Text('Goal',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                const Spacer(),
                if (remainingSec != null)
                  Text(
                    done ? 'Done!' : '${_fmtTime(remainingSec)} left',
                    style: TextStyle(
                        fontSize: 13,
                        color: done ? Colors.green : Colors.grey),
                  )
                else if (done)
                  const Text('Done!',
                      style: TextStyle(fontSize: 13, color: Colors.green)),
              ],
            ),
            if (distProgress != null) ...[
              const SizedBox(height: 10),
              LinearProgressIndicator(
                value: distProgress,
                backgroundColor: Colors.grey.shade200,
                color: distDone ? Colors.green : Colors.blue,
                minHeight: 8,
                borderRadius: BorderRadius.circular(4),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '${coveredKm.toStringAsFixed(2)} / ${goalKm!.toStringAsFixed(1)} km',
                    style: const TextStyle(fontSize: 13),
                  ),
                  if (!done && requiredKmh != null)
                    Text(
                      'Need ${_fmtPace(requiredKmh)}',
                      style: const TextStyle(fontSize: 13, color: Colors.grey),
                    ),
                ],
              ),
            ],
            if (!done && currentSpeedKmh != null) ...[
              const SizedBox(height: 4),
              Text(
                'Current: ${_fmtPace(currentSpeedKmh!)}',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
