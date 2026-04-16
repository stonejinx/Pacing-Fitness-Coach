import 'package:flutter/material.dart';
import 'package:open_earable_flutter/open_earable_flutter.dart';
import 'package:provider/provider.dart';
import 'package:running_coach/apps/cadence_tracker/model/cadence_tracker_model.dart';
import 'package:running_coach/apps/cadence_tracker/view_model/cadence_tracker_view_model.dart';
import 'package:running_coach/view_models/sensor_configuration_provider.dart';

class CadenceTrackerView extends StatelessWidget {
  final SensorManager _sensorManager;
  final SensorConfigurationProvider _sensorConfigurationProvider;

  const CadenceTrackerView(
    this._sensorManager,
    this._sensorConfigurationProvider, {
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<CadenceTrackerViewModel>(
      create: (_) => CadenceTrackerViewModel(
        CadenceTrackerModel(_sensorManager, _sensorConfigurationProvider),
      ),
      builder: (context, _) => Consumer<CadenceTrackerViewModel>(
        builder: (context, vm, _) => Scaffold(
          appBar: AppBar(title: const Text('Cadence & Speed')),
          backgroundColor: Theme.of(context).colorScheme.surface,
          body: _CadenceBody(vm: vm),
        ),
      ),
    );
  }
}

class _CadenceBody extends StatelessWidget {
  final CadenceTrackerViewModel vm;
  const _CadenceBody({required this.vm});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: 32),

        // Step count
        Text(
          '${vm.stepCount}',
          style: const TextStyle(fontSize: 84, fontWeight: FontWeight.bold),
        ),
        const Text('steps', style: TextStyle(fontSize: 18, color: Colors.grey)),

        const SizedBox(height: 20),

        // Cadence and speed
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _MetricCard(
              value: vm.cadenceSpm > 0 ? vm.cadenceSpm.toStringAsFixed(1) : '--',
              unit: 'spm',
              label: 'Cadence',
            ),
            _MetricCard(
              value: vm.speedKmh > 0 ? vm.speedKmh.toStringAsFixed(2) : '--',
              unit: 'km/h',
              label: 'Speed',
            ),
          ],
        ),

        const SizedBox(height: 32),

        // Control buttons
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ElevatedButton(
              onPressed: vm.isTracking ? vm.stopTracking : vm.startTracking,
              style: ElevatedButton.styleFrom(
                backgroundColor: vm.isTracking
                    ? const Color(0xfff27777)
                    : const Color(0xff77F2A1),
                foregroundColor: Colors.black,
                minimumSize: const Size(90, 44),
              ),
              child: Text(vm.isTracking ? 'Stop' : 'Start'),
            ),
            const SizedBox(width: 10),
            OutlinedButton(
              onPressed: vm.reset,
              style: OutlinedButton.styleFrom(minimumSize: const Size(76, 44)),
              child: const Text('Reset'),
            ),
            const SizedBox(width: 10),
            ElevatedButton(
              onPressed: vm.toggleRecording,
              style: ElevatedButton.styleFrom(
                backgroundColor:
                    vm.isRecording ? const Color(0xffF2C77A) : null,
                foregroundColor: Colors.black,
                minimumSize: const Size(90, 44),
              ),
              child: Text(vm.isRecording ? 'Stop Rec' : 'Record'),
            ),
          ],
        ),

        const SizedBox(height: 10),

        // Export button — only shown when there are recorded steps
        if (vm.recordedSteps.isNotEmpty)
          TextButton.icon(
            onPressed: () => vm.exportCsv(),
            icon: const Icon(Icons.download),
            label: Text('Export CSV (${vm.recordedSteps.length} rows)'),
          ),

        const SizedBox(height: 8),

        // Recorded steps list
        if (vm.recordedSteps.isNotEmpty) ...[
          const Divider(),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Recorded Steps',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
              ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: vm.recordedSteps.length,
              itemBuilder: (context, i) {
                final r = vm.recordedSteps[i];
                return ListTile(
                  dense: true,
                  leading: CircleAvatar(
                    radius: 16,
                    child: Text('${r.stepNumber}',
                        style: const TextStyle(fontSize: 11)),
                  ),
                  title: Text(
                    _formatTime(r.time),
                    style: const TextStyle(fontSize: 13),
                  ),
                  trailing: Text(
                    '${r.cadenceSpm.toStringAsFixed(1)} spm  •  '
                    '${r.speedKmh.toStringAsFixed(2)} km/h',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                );
              },
            ),
          ),
        ] else
          const Expanded(child: SizedBox()),
      ],
    );
  }

  String _formatTime(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}:'
      '${t.second.toString().padLeft(2, '0')}.'
      '${(t.millisecond ~/ 100)}';
}

class _MetricCard extends StatelessWidget {
  final String value;
  final String unit;
  final String label;

  const _MetricCard(
      {required this.value, required this.unit, required this.label});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(value,
            style:
                const TextStyle(fontSize: 40, fontWeight: FontWeight.w600)),
        Text(unit,
            style: const TextStyle(fontSize: 14, color: Colors.grey)),
        const SizedBox(height: 4),
        Text(label,
            style:
                const TextStyle(fontSize: 13, color: Colors.blueGrey)),
      ],
    );
  }
}
