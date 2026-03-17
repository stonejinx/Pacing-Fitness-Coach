import 'dart:async';
import 'package:flutter/material.dart';
import 'package:open_earable_flutter/open_earable_flutter.dart';
import 'package:flutter_tts/flutter_tts.dart';
import '../ble/openearable_manager.dart';
import '../ble/esp32_manager.dart';
import '../models/fusion_result.dart';
import '../processors/eda_processor.dart';

class HomeScreen extends StatefulWidget {
  final OpenEarableManager oeManager;
  final Esp32Manager esp32Manager;

  const HomeScreen({
    super.key,
    required this.oeManager,
    required this.esp32Manager,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final FlutterTts _tts = FlutterTts();
  final EdaProcessor _edaProc = EdaProcessor();

  double? _hr;
  double? _cadence;
  double? _temp;
  double? _eda;
  FusionResult _lastFeedback = FusionResult.idle;

  final List<StreamSubscription> _subs = [];

  @override
  void initState() {
    super.initState();
    _initTts();
    _subscribeStreams();
    _subscribeEsp32();
  }

  void _initTts() async {
    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(0.5);
    await _tts.setVolume(1.0);
  }

  void _subscribeStreams() {
    final oe = widget.oeManager;
    _subs.addAll([
      oe.hrStream.stream.listen((v)      => setState(() => _hr = v)),
      oe.cadenceStream.stream.listen((v) => setState(() => _cadence = v)),
      oe.tempStream.stream.listen((v)    => setState(() => _temp = v)),
      oe.feedbackStream.stream.listen(_onFeedback),
    ]);
  }

  void _subscribeEsp32() {
    _subs.add(widget.esp32Manager.gsrStream.listen((raw) {
      final eda = _edaProc.update(raw);
      if (eda != null) {
        setState(() => _eda = eda);
        widget.oeManager.updateEda(_edaProc.relativeEda ?? 0);
      }
    }));
  }

  void _onFeedback(FusionResult result) {
    setState(() => _lastFeedback = result);
    switch (result) {
      case FusionResult.pushHarder:
        _tts.speak("Push harder. Increase your pace.");
        break;
      case FusionResult.slowDown:
        _tts.speak("Slow down. Your body needs recovery.");
        break;
      case FusionResult.maintainPace:
        _tts.speak("Good pace. Keep it up.");
        break;
      default:
        break;
    }
  }

  @override
  void dispose() {
    for (final s in _subs) s.cancel();
    _tts.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('Running Coach', style: TextStyle(color: Colors.white)),
        actions: [
          ListenableBuilder(
            listenable: widget.oeManager,
            builder: (_, __) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Chip(
                backgroundColor: widget.oeManager.connectedWearable != null
                    ? Colors.green.shade700
                    : Colors.red.shade700,
                label: Text(
                  widget.oeManager.status,
                  style: const TextStyle(color: Colors.white, fontSize: 11),
                ),
              ),
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            _FeedbackBanner(result: _lastFeedback),
            const SizedBox(height: 16),
            Row(children: [
              Expanded(child: _MetricCard(label: 'Heart Rate', value: _hr, unit: 'bpm', icon: Icons.favorite, color: Colors.redAccent)),
              const SizedBox(width: 8),
              Expanded(child: _MetricCard(label: 'Cadence', value: _cadence, unit: 'spm', icon: Icons.directions_run, color: Colors.orangeAccent)),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: _MetricCard(label: 'Skin Temp', value: _temp, unit: '°C', icon: Icons.thermostat, color: Colors.blueAccent)),
              const SizedBox(width: 8),
              Expanded(child: _MetricCard(label: 'EDA', value: _eda, unit: 'µS', icon: Icons.bolt, color: Colors.purpleAccent)),
            ]),
            const SizedBox(height: 24),
            _ConnectionPanel(
              oeManager: widget.oeManager,
              esp32Manager: widget.esp32Manager,
            ),
          ],
        ),
      ),
    );
  }
}

class _FeedbackBanner extends StatelessWidget {
  final FusionResult result;
  const _FeedbackBanner({required this.result});

  @override
  Widget build(BuildContext context) {
    final Map<FusionResult, ({Color color, String text, IconData icon})> styles = {
      FusionResult.idle:         (color: Colors.grey.shade800, text: 'Waiting for data…', icon: Icons.hourglass_empty),
      FusionResult.pushHarder:   (color: const Color(0xFF00C853), text: 'PUSH HARDER', icon: Icons.arrow_upward),
      FusionResult.slowDown:     (color: const Color(0xFFD50000), text: 'SLOW DOWN', icon: Icons.arrow_downward),
      FusionResult.maintainPace: (color: const Color(0xFF0091EA), text: 'MAINTAIN PACE', icon: Icons.check_circle),
    };

    final s = styles[result]!;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
      decoration: BoxDecoration(
        color: s.color,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(s.icon, color: Colors.white, size: 28),
          const SizedBox(width: 10),
          Text(s.text,
              style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  final String label;
  final double? value;
  final String unit;
  final IconData icon;
  final Color color;

  const _MetricCard({required this.label, required this.value, required this.unit,
      required this.icon, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(icon, color: color, size: 16),
            const SizedBox(width: 4),
            Text(label, style: TextStyle(color: color, fontSize: 12)),
          ]),
          const SizedBox(height: 8),
          Text(
            value != null ? value!.toStringAsFixed(1) : '--',
            style: const TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.bold),
          ),
          Text(unit, style: const TextStyle(color: Colors.white54, fontSize: 12)),
        ],
      ),
    );
  }
}

class _ConnectionPanel extends StatelessWidget {
  final OpenEarableManager oeManager;
  final Esp32Manager esp32Manager;

  const _ConnectionPanel({required this.oeManager, required this.esp32Manager});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ListenableBuilder(
          listenable: oeManager,
          builder: (_, __) {
            if (oeManager.connectedWearable != null) {
              return FilledButton.icon(
                onPressed: oeManager.disconnect,
                icon: const Icon(Icons.bluetooth_disabled),
                label: const Text('Disconnect OpenEarable'),
                style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
              );
            }
            return FilledButton.icon(
              onPressed: () => _showScanSheet(context),
              icon: const Icon(Icons.bluetooth_searching),
              label: const Text('Connect OpenEarable'),
            );
          },
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: esp32Manager.startScanAndConnect,
          icon: const Icon(Icons.cable),
          label: const Text('Connect ESP32 GSR'),
          style: OutlinedButton.styleFrom(foregroundColor: Colors.purpleAccent),
        ),
      ],
    );
  }

  void _showScanSheet(BuildContext context) {
    oeManager.startScan();
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      builder: (_) => _ScanSheet(oeManager: oeManager),
    );
  }
}

class _ScanSheet extends StatefulWidget {
  final OpenEarableManager oeManager;
  const _ScanSheet({required this.oeManager});

  @override
  State<_ScanSheet> createState() => _ScanSheetState();
}

class _ScanSheetState extends State<_ScanSheet> {
  final Map<String, DiscoveredDevice> _devices = {};
  StreamSubscription? _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.oeManager.scanStream.listen((device) {
      setState(() => _devices[device.id] = device);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final devices = _devices.values.toList();
    return Column(
      children: [
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text('Select OpenEarable', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
        ),
        if (devices.isEmpty)
          const Expanded(child: Center(child: CircularProgressIndicator()))
        else
          Expanded(
            child: ListView.builder(
              itemCount: devices.length,
              itemBuilder: (context, i) {
                final device = devices[i];
                final isOE = device.name.toLowerCase().contains('openearable') ||
                             device.name.toLowerCase().contains('oe');
                return ListTile(
                  leading: Icon(Icons.hearing, color: isOE ? Colors.teal : Colors.white38),
                  title: Text(
                    device.name.isEmpty ? '(unnamed)' : device.name,
                    style: TextStyle(color: isOE ? Colors.teal : Colors.white),
                  ),
                  subtitle: Text(device.id, style: const TextStyle(color: Colors.white38, fontSize: 11)),
                  onTap: () {
                    Navigator.pop(context);
                    widget.oeManager.connect(device);
                  },
                );
              },
            ),
          ),
      ],
    );
  }
}
