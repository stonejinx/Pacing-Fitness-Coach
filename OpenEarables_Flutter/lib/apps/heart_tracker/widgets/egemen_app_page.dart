import 'dart:async';
import 'dart:math';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_platform_widgets/flutter_platform_widgets.dart';
import 'package:open_earable_flutter/open_earable_flutter.dart';
import 'package:running_coach/view_models/sensor_configuration_provider.dart';
import 'package:running_coach/view_models/wearables_provider.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:running_coach/view_models/sensor_recorder_provider.dart';

class EgemenAppPage extends StatefulWidget {
  final Map<String, Sensor?> sensors;

  const EgemenAppPage({super.key, required this.sensors});

  @override
  State<EgemenAppPage> createState() => _EgemenAppPageState();
}

class _SensorSpec {
  final String key;
  final String label;
  final int channels;
  final double defaultHz;
  final List<double> options;
  final Sensor? sensor;
  SensorConfiguration? configuration;
  List<SensorConfigurationValue> configValues = [];
  double? selectedHz;
  StreamSubscription? subscription;
  int labelRemaining = 0;

  _SensorSpec({
    required this.key,
    required this.label,
    required this.channels,
    required this.defaultHz,
    required this.options,
    required this.sensor,
  });
}

class _EgemenAppPageState extends State<EgemenAppPage> {
  late final List<_SensorSpec> _sensors;
  bool _isRunning = false;
  bool _showSlow = false;
  Timer? _slowResetTimer;
  int _accSampleCount = 0;
  double _accSumX = 0;
  double _accSumY = 0;
  double _accSumZ = 0;
  String? _recordingDir;
  final Map<String, List<String>> _liveBuffers = {};
  String? _liveSensorKey;
  static const int _maxLiveLines = 200;
  String? _stageMessage;
  final Map<String, IOSink> _egemenSinks = {};

  @override
  void initState() {
    super.initState();

    _sensors = [
      _SensorSpec(
        key: 'acc',
        label: 'ACC',
        channels: 3,
        defaultHz: 50,
        options: [25, 50, 100, 200, 400, 800],
        sensor: widget.sensors['acc'],
      ),
      _SensorSpec(
        key: 'gyro',
        label: 'GYRO',
        channels: 3,
        defaultHz: 50,
        options: [25, 50, 100, 200, 400, 800],
        sensor: widget.sensors['gyro'],
      ),
      _SensorSpec(
        key: 'mgnt',
        label: 'MGNT',
        channels: 3,
        defaultHz: 50,
        options: [25, 50, 100, 200, 400, 800],
        sensor: widget.sensors['mgnt'],
      ),
      _SensorSpec(
        key: 'ppg',
        label: 'PPG',
        channels: 4,
        defaultHz: 50,
        options: [8, 16, 25, 32, 50, 64, 84, 100, 128, 200, 256, 400, 512],
        sensor: widget.sensors['ppg'],
      ),
      _SensorSpec(
        key: 'skin_temp',
        label: 'SKIN_TEMP',
        channels: 1,
        defaultHz: 32,
        options: [0.5, 1, 2, 4, 8, 16, 32, 64],
        sensor: widget.sensors['skin_temp'],
      ),
      _SensorSpec(
        key: 'env_temp',
        label: 'ENV_TEMP',
        channels: 1,
        defaultHz: 50,
        options: [50],
        sensor: widget.sensors['env_temp'],
      ),
      _SensorSpec(
        key: 'baro',
        label: 'BARO',
        channels: 1,
        defaultHz: 50,
        options: [0.1, 0.2, 0.39, 0.78, 1.5, 3.10, 6.25, 12.5, 25, 50, 100, 200],
        sensor: widget.sensors['baro'],
      ),
      _SensorSpec(
        key: 'bone_acc',
        label: 'BONE_ACC',
        channels: 3,
        defaultHz: 50,
        options: [12.5, 25, 50, 100, 200, 400, 800],
        sensor: widget.sensors['bone_acc'],
      ),
    ];
    for (final spec in _sensors) {
      _liveBuffers[spec.key] = [];
    }


    WidgetsBinding.instance.addPostFrameCallback((_) {
      final configProvider =
          Provider.of<SensorConfigurationProvider>(context, listen: false);

      for (final spec in _sensors) {
        final sensor = spec.sensor;
        if (sensor == null) continue;

        final configuration = sensor.relatedConfigurations.first;
        spec.configuration = configuration;

        if (configuration is ConfigurableSensorConfiguration &&
            configuration.availableOptions.contains(StreamSensorConfigOption())) {
          configProvider.addSensorConfigurationOption(
            configuration,
            StreamSensorConfigOption(),
          );
        }

        final values = configProvider.getSensorConfigurationValues(
          configuration,
          distinct: true,
        );
        spec.configValues = values;
        spec.selectedHz =
            _pickAvailableFrequency(values, spec.defaultHz, spec.options);
      }

      if (!mounted) return;
      setState(() {});
    });
  }

  @override
  void dispose() {
    for (final spec in _sensors) {
      spec.subscription?.cancel();
    }
    _slowResetTimer?.cancel();
    _closeEgemenSinks();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isRunning) {
      return PlatformScaffold(
        body: _showSlow
            ? Center(
                child: Text(
                  'YAVAŞŞŞ',
                  style: Theme.of(context).textTheme.displayMedium,
                ),
              )
            : SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      if (_stageMessage != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: PlatformText(
                            _stageMessage!,
                            style: Theme.of(context).textTheme.bodyLarge,
                          ),
                        ),
                      Expanded(
                        child: _buildLiveList(),
                      ),
                      const SizedBox(height: 12),
                      _buildLiveSensorDropdown(),
                      const SizedBox(height: 24),
                      SizedBox(
                        width: 220,
                        height: 64,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green,
                            foregroundColor: Colors.white,
                            textStyle: Theme.of(context).textTheme.titleLarge,
                          ),
                          onPressed: _markLabel,
                          child: const Text('Label'),
                        ),
                      ),
                      const SizedBox(height: 16),
                      SizedBox(
                        width: 220,
                        height: 64,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red,
                            foregroundColor: Colors.white,
                            textStyle: Theme.of(context).textTheme.titleLarge,
                          ),
                          onPressed: _stopStreaming,
                          child: const Text('Stop'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
      );
    }

    return PlatformScaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Expanded(
                child: ListView(
                  children: [
                    ..._sensors.map(_buildSensorRow),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              PlatformElevatedButton(
                onPressed: _startStreaming,
                child: const Text('Set'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLiveSensorDropdown() {
    final items = _sensors
        .where((spec) => spec.sensor != null)
        .map(
          (spec) => DropdownMenuItem<String>(
            value: spec.key,
            child: Text(spec.label),
          ),
        )
        .toList();

    return Row(
      children: [
        SizedBox(
          width: 110,
          child: PlatformText(
            'SENSOR:',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: DropdownButton<String>(
            value: _liveSensorKey,
            isExpanded: true,
            hint: const Text('Select'),
            items: items,
            onChanged: (value) {
              setState(() {
                _liveSensorKey = value;
              });
            },
          ),
        ),
      ],
    );
  }

  Widget _buildLiveList() {
    final key = _liveSensorKey;
    final lines = key == null ? const <String>[] : _liveBuffers[key] ?? [];
    if (lines.isEmpty) {
      return Center(
        child: PlatformText(
          key == null ? 'Select a sensor' : 'No data yet',
          style: Theme.of(context).textTheme.bodyLarge,
        ),
      );
    }

    return ListView.builder(
      reverse: true,
      itemCount: lines.length,
      itemBuilder: (context, index) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: PlatformText(
            lines[index],
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        );
      },
    );
  }

  Widget _buildSensorRow(_SensorSpec spec) {
    final bool enabled = spec.sensor != null;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          SizedBox(
            width: 110,
            child: PlatformText(
              '${spec.label}:',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: DropdownButton<double>(
              value: enabled ? spec.selectedHz : null,
              isExpanded: true,
              hint: const Text('N/A'),
              items: spec.options
                  .map(
                    (freq) => DropdownMenuItem<double>(
                      value: freq,
                      child: Text(_formatHz(freq)),
                    ),
                  )
                  .toList(),
              onChanged: enabled
                  ? (value) {
                      setState(() {
                        spec.selectedHz = value;
                      });
                    }
                  : null,
            ),
          ),
        ],
      ),
    );
  }

  void _applySelectedFrequencies() {
    final configProvider =
        Provider.of<SensorConfigurationProvider>(context, listen: false);

    for (final spec in _sensors) {
      final sensor = spec.sensor;
      final configuration = spec.configuration;
      final selectedHz = spec.selectedHz;
      if (sensor == null || configuration == null || selectedHz == null) {
        continue;
      }

      final selectedValue =
          _findFrequencyValue(spec.configValues, selectedHz);
      if (selectedValue == null) continue;

      configProvider.addSensorConfiguration(configuration, selectedValue);
      configuration.setConfiguration(selectedValue);

      if (spec.subscription == null) {
        spec.subscription = sensor.sensorStream.listen((data) {
          final sensorData = data as SensorDoubleValue;
          final line = _formatLine(
            sensorData.timestamp,
            sensorData.values,
            spec.channels,
            spec,
          );
          _updateServerLine(spec.key, line);
          if (spec.key == 'acc') {
            _handleAccSample(sensorData.values);
          }
        });
      }
    }
  }

  void _startStreaming() {
    setState(() {
      _stageMessage = 'Applying sensor configuration...';
    });
    _applySelectedFrequencies();
    setState(() {
      _stageMessage = 'Starting recording...';
    });
    _startRecording();
    setState(() {
      _stageMessage = 'Running';
      _isRunning = true;
    });
  }

  Future<void> _stopStreaming() async {
    for (final spec in _sensors) {
      spec.subscription?.cancel();
      spec.subscription = null;
      spec.labelRemaining = 0;
    }
    for (final buffer in _liveBuffers.values) {
      buffer.clear();
    }
    _slowResetTimer?.cancel();
    _showSlow = false;
    _accSampleCount = 0;
    _accSumX = 0;
    _accSumY = 0;
    _accSumZ = 0;

    final recorder = context.read<SensorRecorderProvider>();
    recorder.stopRecording();
    final wearablesProvider = context.read<WearablesProvider>();
    final futures = wearablesProvider.sensorConfigurationProviders.values
        .map((provider) => provider.turnOffAllSensors());
    await Future.wait(futures);
    _recordingDir = null;
    setState(() {
      _isRunning = false;
    });
  }

  void _markLabel() {
    setState(() {
      for (final spec in _sensors) {
        spec.labelRemaining = 40;
      }
    });
  }

  Future<void> _startRecording() async {
    final dirPath = await _createRecordingDir();
    if (dirPath == null) return;
    _recordingDir = dirPath;
    _openEgemenSinks(dirPath);
    final recorder = context.read<SensorRecorderProvider>();
    recorder.startRecording(dirPath);
  }

  Future<String?> _createRecordingDir() async {
    final recordingName =
        'OpenWearable_Recording_${DateTime.now().toIso8601String()}';
    if (Platform.isAndroid) {
      final dir = await getExternalStorageDirectory();
      if (dir == null) return null;
      final path = '${dir.path}/$recordingName';
      final directory = Directory(path);
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }
      return path;
    }

    if (Platform.isIOS) {
      final appDocDir = await getApplicationDocumentsDirectory();
      final recordingsPath = '${appDocDir.path}/Recordings';
      final recordingsDir = Directory(recordingsPath);
      if (!await recordingsDir.exists()) {
        await recordingsDir.create(recursive: true);
      }
      final path = '$recordingsPath/$recordingName';
      final directory = Directory(path);
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }
      return path;
    }

    return null;
  }


  double? _pickAvailableFrequency(
    List<SensorConfigurationValue> values,
    double preferredHz,
    List<double> options,
  ) {
    if (_findFrequencyValue(values, preferredHz) != null) {
      return preferredHz;
    }
    for (final freq in options.reversed) {
      if (_findFrequencyValue(values, freq) != null) {
        return freq;
      }
    }
    return null;
  }

  SensorConfigurationValue? _findFrequencyValue(
    List<SensorConfigurationValue> values,
    double frequencyHz,
  ) {
    for (final value in values) {
      if (value is SensorFrequencyConfigurationValue &&
          value.frequencyHz == frequencyHz) {
        return value;
      }
    }
    return null;
  }

  String _formatHz(double value) {
    if (value == value.roundToDouble()) {
      return '${value.toInt()} Hz';
    }
    return '${value.toStringAsFixed(2)} Hz';
  }

  String _formatLine(
    int timestamp,
    List<double> values,
    int count,
    _SensorSpec spec,
  ) {
    final int maxCount = values.length < count ? values.length : count;
    final int labelValue = spec.labelRemaining > 0 ? 1 : 0;
    if (spec.labelRemaining > 0) {
      spec.labelRemaining--;
    }
    return [
      timestamp.toString(),
      values.take(maxCount).map((v) => v.toStringAsFixed(3)).join(', '),
      labelValue.toString(),
    ].join(', ');
  }

  void _updateServerLine(String key, String line) {
    // Keep only in-app live view buffers; no server or file writes.
    final buffer = _liveBuffers[key];
    if (buffer != null) {
      buffer.insert(0, line);
      if (buffer.length > _maxLiveLines) {
        buffer.removeLast();
      }
      if (_isRunning && _liveSensorKey == key && mounted) {
        setState(() {});
      }
    }
    final sink = _egemenSinks[key];
    if (sink != null) {
      sink.writeln(line);
    }
  }

  void _openEgemenSinks(String dirPath) {
    _closeEgemenSinks();
    for (final spec in _sensors) {
      if (spec.sensor == null) continue;
      final filename = '$dirPath/egemen_${spec.key}.csv';
      final file = File(filename);
      _egemenSinks[spec.key] =
          file.openWrite(mode: FileMode.writeOnlyAppend);
    }
  }

  void _closeEgemenSinks() {
    for (final sink in _egemenSinks.values) {
      sink.close();
    }
    _egemenSinks.clear();
  }

  void _handleAccSample(List<double> values) {
    if (values.length < 3) return;

    _accSampleCount++;
    _accSumX += values[0];
    _accSumY += values[1];
    _accSumZ += values[2];

    if (_accSampleCount < 10) return;

    final avgX = _accSumX / _accSampleCount;
    final avgY = _accSumY / _accSampleCount;
    final avgZ = _accSumZ / _accSampleCount;
    final magnitude = sqrt(avgX * avgX + avgY * avgY + avgZ * avgZ);

    _accSampleCount = 0;
    _accSumX = 0;
    _accSumY = 0;
    _accSumZ = 0;

    if (magnitude > 15) {
      _slowResetTimer?.cancel();
      if (!_showSlow && mounted) {
        setState(() {
          _showSlow = true;
        });
      }
      return;
    }

    if (_showSlow && (_slowResetTimer == null || !_slowResetTimer!.isActive)) {
      _slowResetTimer = Timer(const Duration(seconds: 1), () {
        if (!mounted) return;
        setState(() {
          _showSlow = false;
        });
      });
    }
  }
}
