import 'dart:async';
import 'dart:math';

import 'package:open_earable_flutter/open_earable_flutter.dart';
import 'package:running_coach/view_models/sensor_configuration_provider.dart';

class StepRecord {
  final DateTime time;
  final int stepNumber;
  final double cadenceSpm;
  final double speedKmh;

  StepRecord({
    required this.time,
    required this.stepNumber,
    required this.cadenceSpm,
    required this.speedKmh,
  });

  String toCsvRow() =>
      '${time.toIso8601String()},$stepNumber,'
      '${cadenceSpm.toStringAsFixed(2)},'
      '${speedKmh.toStringAsFixed(3)}';
}

class CadenceTrackerModel {
  final SensorManager _sensorManager;
  final SensorConfigurationProvider _sensorConfigurationProvider;

  StreamSubscription<SensorValue>? _subscription;

  int _stepCount = 0;
  int get stepCount => _stepCount;

  double _cadenceSpm = 0.0;
  double get cadenceSpm => _cadenceSpm;

  double _speedKmh = 0.0;
  double get speedKmh => _speedKmh;

  static const double _strideLengthM = 0.75;

  bool get isTracking => _subscription != null && !_subscription!.isPaused;

  final List<int> _stepTimestampsMs = [];
  static const int _maxTimestamps = 8;

  // Step detection — dynamic threshold via two EMAs
  double _fastEma = 1.0;
  double _slowEma = 1.0;
  static const double _fastAlpha = 0.4;
  static const double _slowAlpha = 0.02;
  static const double _minPeakDelta = 0.25;
  bool _aboveThreshold = false;
  int _lastStepMs = 0;
  static const int _minStepIntervalMs = 350;

  // Recording
  bool _isRecording = false;
  bool get isRecording => _isRecording;
  final List<StepRecord> _recordedSteps = [];
  List<StepRecord> get recordedSteps => List.unmodifiable(_recordedSteps);

  void Function()? onUpdate;

  CadenceTrackerModel(this._sensorManager, this._sensorConfigurationProvider);

  void start() {
    if (_subscription?.isPaused ?? false) {
      _subscription?.resume();
      return;
    }

    final Sensor accelSensor = _sensorManager.sensors.firstWhere(
      (s) => s.sensorName.toLowerCase() == 'accelerometer',
    );

    final Set<SensorConfiguration> configurations = {};
    configurations.addAll(accelSensor.relatedConfigurations);

    for (final SensorConfiguration configuration in configurations) {
      if (configuration is ConfigurableSensorConfiguration &&
          configuration.availableOptions.contains(StreamSensorConfigOption())) {
        _sensorConfigurationProvider.addSensorConfigurationOption(
            configuration, StreamSensorConfigOption());
      }
      final List<SensorConfigurationValue> values =
          _sensorConfigurationProvider.getSensorConfigurationValues(
              configuration, distinct: true);
      _sensorConfigurationProvider.addSensorConfiguration(
          configuration, values.first);
      configuration.setConfiguration(
          _sensorConfigurationProvider
              .getSelectedConfigurationValue(configuration)!);
    }

    _subscription = accelSensor.sensorStream.listen((data) {
      if (data is SensorDoubleValue) {
        _processAccelData(data);
      }
    });
  }

  void _processAccelData(SensorDoubleValue data) {
    final double ax = data.values[0];
    final double ay = data.values[1];
    final double az = data.values[2];

    final double mag = sqrt(ax * ax + ay * ay + az * az);

    _fastEma = _fastAlpha * mag + (1.0 - _fastAlpha) * _fastEma;
    _slowEma = _slowAlpha * mag + (1.0 - _slowAlpha) * _slowEma;

    final bool nowAbove = (_fastEma - _slowEma) > _minPeakDelta;
    if (nowAbove && !_aboveThreshold) {
      final int nowMs = DateTime.now().millisecondsSinceEpoch;
      if ((nowMs - _lastStepMs) >= _minStepIntervalMs) {
        _stepCount++;
        _lastStepMs = nowMs;

        _stepTimestampsMs.add(nowMs);
        if (_stepTimestampsMs.length > _maxTimestamps) {
          _stepTimestampsMs.removeAt(0);
        }
        _updateCadenceAndSpeed();

        if (_isRecording) {
          _recordedSteps.add(StepRecord(
            time: DateTime.now(),
            stepNumber: _stepCount,
            cadenceSpm: _cadenceSpm,
            speedKmh: _speedKmh,
          ));
        }
      }
    }
    _aboveThreshold = nowAbove;

    onUpdate?.call();
  }

  void _updateCadenceAndSpeed() {
    if (_stepTimestampsMs.length < 2) {
      _cadenceSpm = 0.0;
      _speedKmh = 0.0;
      return;
    }
    double totalMs = 0;
    for (int i = 1; i < _stepTimestampsMs.length; i++) {
      totalMs += _stepTimestampsMs[i] - _stepTimestampsMs[i - 1];
    }
    final double avgIntervalMs = totalMs / (_stepTimestampsMs.length - 1);
    _cadenceSpm = 60000.0 / avgIntervalMs;
    final double avgIntervalS = avgIntervalMs / 1000.0;
    _speedKmh = (_strideLengthM / avgIntervalS) * 3.6;
  }

  void stop() {
    _subscription?.pause();
  }

  void reset() {
    _stepCount = 0;
    _cadenceSpm = 0.0;
    _speedKmh = 0.0;
    _stepTimestampsMs.clear();
    _aboveThreshold = false;
    // Keep EMAs running so no artificial spike on next sample.
    // Enforce the minimum interval from now so the first real step
    // after reset isn't counted until at least _minStepIntervalMs has passed.
    _lastStepMs = DateTime.now().millisecondsSinceEpoch;
    onUpdate?.call();
  }

  void startRecording() {
    _recordedSteps.clear();
    _isRecording = true;
  }

  void stopRecording() {
    _isRecording = false;
  }

  void cancel() {
    stop();
    _subscription?.cancel();
    _subscription = null;
  }
}
