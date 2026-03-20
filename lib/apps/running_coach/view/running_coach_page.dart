import 'dart:async';  // StreamSubscription
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:open_earable_flutter/open_earable_flutter.dart';
import 'package:provider/provider.dart';
import 'package:running_coach/apps/running_coach/model/running_coach_model.dart';
import 'package:running_coach/apps/running_coach/model/cadence_processor.dart';
import 'package:running_coach/apps/running_coach/model/esp32_manager.dart';
import 'package:running_coach/apps/heart_tracker/model/ppg_filter.dart';
import 'package:running_coach/view_models/sensor_configuration_provider.dart';

// ── Cadence zones (spm) ───────────────────────────────────────────────────────
const double kCadenceStationary  = 20.0;
const double kCadenceWalking     = 120.0;
const double kCadenceTargetLow   = 155.0;
const double kCadenceTarget      = 165.0;
const double kCadenceTargetHigh  = 180.0;

// Max wave buffer points shown in chart
const int kWavePoints = 60;

class RunningCoachPage extends StatefulWidget {
  final Wearable wearable;

  const RunningCoachPage({super.key, required this.wearable});

  @override
  State<RunningCoachPage> createState() => _RunningCoachPageState();
}

class _RunningCoachPageState extends State<RunningCoachPage> {
  // ── Processors / model ──────────────────────────────────────────────────
  late CadenceProcessor _cadenceProcessor;
  final RunningCoachModel _model = RunningCoachModel();
  final Esp32Manager _esp32 = Esp32Manager();

  // ── Display state ────────────────────────────────────────────────────────
  double? _cadence;
  double? _hr;
  double? _skinTemp;
  double? _eda;
  String  _coachTip = 'Connect sensors and start running!';

  // ── Wave buffers (rolling history for charts) ────────────────────────────
  final List<double> _cadenceWave   = [];
  final List<double> _hrWave        = [];
  final List<double> _skinTempWave  = [];
  final List<double> _edaWave       = [];

  void _pushWave(List<double> buf, double val) {
    buf.add(val);
    if (buf.length > kWavePoints) buf.removeAt(0);
  }

  // ── Cadence consistency filter (rejects BCG spikes) ─────────────────────
  final List<double?> _cadenceHistory = [];
  DateTime? _lastCadenceSample;

  // ── Subscriptions ────────────────────────────────────────────────────────
  final List<StreamSubscription> _subs = [];
  StreamSubscription? _hrSub;
  StreamSubscription? _esp32Sub;

  @override
  void initState() {
    super.initState();
    _cadenceProcessor = CadenceProcessor();
    _subscribeEsp32();
    WidgetsBinding.instance.addPostFrameCallback((_) => _configureSensors());
  }

  void _configureSensors() {
    final sm = widget.wearable.getCapability<SensorManager>();
    if (sm == null) return;

    final configProvider =
        Provider.of<SensorConfigurationProvider>(context, listen: false);

    for (final sensor in sm.sensors) {
      final cfg = sensor.relatedConfigurations.first;

      if (cfg is ConfigurableSensorConfiguration &&
          cfg.availableOptions.contains(StreamSensorConfigOption())) {
        configProvider.addSensorConfigurationOption(cfg, StreamSensorConfigOption());
      }

      final values = configProvider.getSensorConfigurationValues(cfg, distinct: true);
      if (values.isNotEmpty) {
        configProvider.addSensorConfiguration(cfg, values.first);
        final selected = configProvider.getSelectedConfigurationValue(cfg);
        if (selected != null) cfg.setConfiguration(selected);
      }
    }

    _subscribeOpenEarable(sm);
  }

  void _subscribeOpenEarable(SensorManager sm) {
    for (final sensor in sm.sensors) {
      final name = sensor.sensorName.toLowerCase();

      // Accelerometer → cadence
      if (name == 'accelerometer') {
        _cadenceProcessor = CadenceProcessor(
          timestampExponent: sensor.timestampExponent,
        );
        final sub = sensor.sensorStream.listen((value) {
          if (value is SensorDoubleValue && value.values.length >= 3) {
            final ax = value.values[0];
            final ay = value.values[1];
            final az = value.values[2];
            final ts = value.timestamp;

            final c = _cadenceProcessor.process(
              ax: ax, ay: ay, az: az, rawTimestamp: ts,
            );
            _model.onIMUSample(ax, ay, az, ts);

            // Consistency filter: sample every 500ms, show only if ≥3/4 valid
            final now = DateTime.now();
            if (_lastCadenceSample == null ||
                now.difference(_lastCadenceSample!).inMilliseconds >= 500) {
              _lastCadenceSample = now;
              _cadenceHistory.add(c == null || c == 0.0 ? null : c);
              if (_cadenceHistory.length > 4) _cadenceHistory.removeAt(0);

              final valid = _cadenceHistory.whereType<double>().toList();
              double? display;
              if (valid.length >= 3) {
                valid.sort();
                display = valid[valid.length ~/ 2];
              }
              if (mounted) {
                setState(() {
                  _cadence = display;
                  if (display != null) _pushWave(_cadenceWave, display);
                });
                _updateCoachTip();
              }
            }
          }
        });
        _subs.add(sub);
      }

      // Bone conduction → BCG HR for fusion only
      if (name.contains('bone') || name.contains('bma580')) {
        final sub = sensor.sensorStream.listen((value) {
          if (value is SensorDoubleValue && value.values.length >= 3) {
            _model.onBCGSample(
              value.values[0], value.values[1], value.values[2],
            );
          }
        });
        _subs.add(sub);
      }

      // Photoplethysmography → HR display
      if (name == 'photoplethysmography') {
        final rawStream = sensor.sensorStream
            .where((v) => v is SensorDoubleValue && v.values.isNotEmpty)
            .map<(int, double)>((v) {
          final d = v as SensorDoubleValue;
          final idx = d.values.length > 2 ? 2 : 0;
          return (d.timestamp, d.values[idx]);
        }).asBroadcastStream();

        final filter = PpgFilter(
          inputStream: rawStream,
          sampleFreq: 50,
          timestampExponent: sensor.timestampExponent,
        );

        _hrSub = filter.heartRateStream.listen((hr) {
          if (mounted) {
            setState(() {
              _hr = hr;
              _pushWave(_hrWave, hr);
            });
            _updateCoachTip();
          }
        });
      }

      // Skin temperature → raw pass-through
      if (name.contains('skin') || name.contains('temperature')) {
        final sub = sensor.sensorStream.listen((value) {
          if (value is SensorDoubleValue && value.values.isNotEmpty) {
            final temp = value.values[0];
            if (mounted) {
              setState(() {
                _skinTemp = temp;
                _pushWave(_skinTempWave, temp);
              });
            }
            _model.onTempSample(temp);
          }
        });
        _subs.add(sub);
      }
    }
  }

  void _subscribeEsp32() {
    _esp32Sub = _esp32.gsrStream.listen((rawADC) {
      _model.onEDASample(rawADC.toDouble());
      final eda = _model.eda;
      if (eda != null && mounted) {
        setState(() {
          _eda = eda;
          _pushWave(_edaWave, eda);
        });
      }
    });
  }

  void _updateCoachTip() {
    final c = _cadence;
    final h = _hr;
    String tip = '';

    if (c == null || c < kCadenceStationary) {
      tip = 'Not moving — start running!';
    } else if (c < kCadenceWalking) {
      tip = 'Walking detected (${c.round()} spm).';
    } else if (c < kCadenceTargetLow) {
      tip = 'Running too slow — aim for ${kCadenceTarget.round()} spm.';
    } else if (c <= kCadenceTargetHigh) {
      tip = 'Great cadence! Keep it up.';
    } else {
      tip = 'Very high cadence (${c.round()} spm) — stay controlled.';
    }

    if (h != null) {
      if (h > 185)      tip += ' HR very high — ease off!';
      else if (h > 165) tip += ' Hard effort — stay controlled.';
      else if (h < 120) tip += ' HR low — push harder if you feel good.';
    }

    if (mounted) setState(() => _coachTip = tip);
  }

  @override
  void dispose() {
    for (final s in _subs) { s.cancel(); }
    _hrSub?.cancel();
    _esp32Sub?.cancel();
    _esp32.dispose();
    _model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Running Coach')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Coach tip banner
            Card(
              color: Theme.of(context).colorScheme.primaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    const Icon(Icons.directions_run, size: 32),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _coachTip,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Cadence + HR
            Row(
              children: [
                Expanded(child: _MetricCard(
                  label: 'Cadence',
                  value: _cadence != null ? '${_cadence!.round()}' : '--',
                  unit: 'spm',
                  icon: Icons.directions_walk,
                  color: _cadenceColor(_cadence),
                  wave: _cadenceWave,
                )),
                const SizedBox(width: 12),
                Expanded(child: _MetricCard(
                  label: 'Heart Rate',
                  value: _hr != null ? '${_hr!.round()}' : '--',
                  unit: 'bpm',
                  icon: Icons.favorite,
                  color: Colors.red,
                  wave: _hrWave,
                )),
              ],
            ),
            const SizedBox(height: 12),

            // Skin temp
            _MetricCard(
              label: 'Skin Temperature',
              value: _skinTemp != null ? _skinTemp!.toStringAsFixed(1) : '--',
              unit: '°C',
              icon: Icons.thermostat,
              color: Colors.orange,
              wave: _skinTempWave,
            ),
            const SizedBox(height: 12),

            // ESP32 GSR + EDA
            _GsrCard(
              esp32: _esp32,
              edaValue: _eda,
              edaReady: _model.edaReady,
              edaProgress: _model.edaProgress,
              edaWave: _edaWave,
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

// ── Wave chart ────────────────────────────────────────────────────────────────

class _WaveChart extends StatelessWidget {
  final List<double> data;
  final Color color;
  final double height;

  const _WaveChart({required this.data, required this.color, this.height = 50});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: CustomPaint(
        painter: _WaveChartPainter(data: List.of(data), color: color),
        size: Size.infinite,
      ),
    );
  }
}

class _WaveChartPainter extends CustomPainter {
  final List<double> data;
  final Color color;

  _WaveChartPainter({required this.data, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    if (data.length < 2) return;

    final minVal = data.reduce(min);
    final maxVal = data.reduce(max);
    final range  = maxVal - minVal;

    final paint = Paint()
      ..color       = color.withOpacity(0.85)
      ..strokeWidth = 1.8
      ..style       = PaintingStyle.stroke
      ..strokeCap   = StrokeCap.round
      ..strokeJoin  = StrokeJoin.round;

    // Filled area under the line
    final fillPaint = Paint()
      ..color = color.withOpacity(0.12)
      ..style = PaintingStyle.fill;

    double xStep(int i) => size.width * i / (data.length - 1);
    double yAt(double v) => range < 1e-6
        ? size.height * 0.5
        : size.height * (1 - (v - minVal) / range);

    final linePath = Path();
    final fillPath = Path()..moveTo(xStep(0), size.height);

    for (int i = 0; i < data.length; i++) {
      final x = xStep(i);
      final y = yAt(data[i]);
      if (i == 0) {
        linePath.moveTo(x, y);
        fillPath.lineTo(x, y);
      } else {
        linePath.lineTo(x, y);
        fillPath.lineTo(x, y);
      }
    }

    fillPath.lineTo(xStep(data.length - 1), size.height);
    fillPath.close();

    canvas.drawPath(fillPath, fillPaint);
    canvas.drawPath(linePath, paint);
  }

  @override
  bool shouldRepaint(_WaveChartPainter old) =>
      old.data.length != data.length ||
      (data.isNotEmpty && old.data.isNotEmpty && old.data.last != data.last);
}

// ── Metric card ───────────────────────────────────────────────────────────────

class _MetricCard extends StatelessWidget {
  final String label;
  final String value;
  final String unit;
  final IconData icon;
  final Color color;
  final List<double> wave;

  const _MetricCard({
    required this.label,
    required this.value,
    required this.unit,
    required this.icon,
    required this.color,
    required this.wave,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Column(
          children: [
            Icon(icon, color: color, size: 24),
            const SizedBox(height: 4),
            Text(value,
                style: TextStyle(fontSize: 34, fontWeight: FontWeight.bold, color: color)),
            Text(unit, style: const TextStyle(fontSize: 13, color: Colors.grey)),
            const SizedBox(height: 2),
            Text(label, style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 8),
            _WaveChart(data: wave, color: color),
          ],
        ),
      ),
    );
  }
}

// ── ESP32 GSR card ────────────────────────────────────────────────────────────

class _GsrCard extends StatefulWidget {
  final Esp32Manager esp32;
  final double? edaValue;
  final bool edaReady;
  final int edaProgress;
  final List<double> edaWave;

  const _GsrCard({
    required this.esp32,
    required this.edaValue,
    required this.edaReady,
    required this.edaProgress,
    required this.edaWave,
  });

  @override
  State<_GsrCard> createState() => _GsrCardState();
}

class _GsrCardState extends State<_GsrCard> {
  int? _latest;
  StreamSubscription? _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.esp32.gsrStream.listen((v) {
      if (mounted) setState(() => _latest = v);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final edaText = widget.edaReady
        ? (widget.edaValue != null ? widget.edaValue!.toStringAsFixed(2) : '--')
        : 'Baseline ${widget.edaProgress}%';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.sensors, color: Colors.green, size: 24),
                const SizedBox(width: 8),
                const Text('ESP32 GSR (EDA)',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                const Spacer(),
                Icon(
                  widget.esp32.isConnected
                      ? Icons.bluetooth_connected
                      : Icons.bluetooth_disabled,
                  color: widget.esp32.isConnected ? Colors.green : Colors.grey,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(widget.esp32.status,
                style: const TextStyle(color: Colors.grey, fontSize: 13)),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Raw ADC',
                          style: TextStyle(fontSize: 12, color: Colors.grey)),
                      Text(
                        _latest != null ? '$_latest' : 'No data',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          color: widget.esp32.isConnected
                              ? Colors.green
                              : Colors.grey,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('EDA (norm.)',
                          style: TextStyle(fontSize: 12, color: Colors.grey)),
                      Text(
                        edaText,
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          color: widget.edaReady ? Colors.teal : Colors.grey,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (widget.edaWave.isNotEmpty) ...[
              const SizedBox(height: 8),
              _WaveChart(data: widget.edaWave, color: Colors.teal),
            ],
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: widget.esp32.isConnected
                  ? widget.esp32.disconnect
                  : widget.esp32.startScanAndConnect,
              icon: Icon(widget.esp32.isConnected
                  ? Icons.bluetooth_disabled
                  : Icons.bluetooth_searching),
              label: Text(widget.esp32.isConnected
                  ? 'Disconnect ESP32'
                  : 'Connect ESP32'),
            ),
          ],
        ),
      ),
    );
  }
}
