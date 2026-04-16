import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:running_coach/apps/cadence_tracker/model/cadence_tracker_model.dart';
import 'package:share_plus/share_plus.dart';

class CadenceTrackerViewModel with ChangeNotifier {
  final CadenceTrackerModel _model;
  bool _isDisposed = false;

  CadenceTrackerViewModel(this._model) {
    _model.onUpdate = () {
      if (!_isDisposed) notifyListeners();
    };
  }

  int get stepCount => _model.stepCount;
  double get cadenceSpm => _model.cadenceSpm;
  double get speedKmh => _model.speedKmh;
  bool get isTracking => _model.isTracking;
  bool get isRecording => _model.isRecording;
  List<StepRecord> get recordedSteps => _model.recordedSteps;

  void startTracking() {
    _model.start();
    if (!_isDisposed) notifyListeners();
  }

  void stopTracking() {
    _model.stop();
    if (!_isDisposed) notifyListeners();
  }

  void reset() {
    _model.reset();
    if (!_isDisposed) notifyListeners();
  }

  void toggleRecording() {
    if (_model.isRecording) {
      _model.stopRecording();
    } else {
      _model.startRecording();
    }
    if (!_isDisposed) notifyListeners();
  }

  Future<void> exportCsv() async {
    if (_model.recordedSteps.isEmpty) return;

    final buffer = StringBuffer();
    buffer.writeln('timestamp,step,cadence_spm,speed_kmh');
    for (final r in _model.recordedSteps) {
      buffer.writeln(r.toCsvRow());
    }

    final dir = await getTemporaryDirectory();
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .substring(0, 19);
    final file = File('${dir.path}/cadence_$stamp.csv');
    await file.writeAsString(buffer.toString());

    await Share.shareXFiles(
      [XFile(file.path, mimeType: 'text/csv')],
      subject: 'Cadence & Speed $stamp',
    );
  }

  @override
  void dispose() {
    _isDisposed = true;
    _model.cancel();
    super.dispose();
  }
}
