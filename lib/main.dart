import 'package:flutter/material.dart';
import 'ble/openearable_manager.dart';
import 'ble/esp32_manager.dart';
import 'engine/rule_engine.dart';
import 'screens/home_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const RunningCoachApp());
}

class RunningCoachApp extends StatefulWidget {
  const RunningCoachApp({super.key});

  @override
  State<RunningCoachApp> createState() => _RunningCoachAppState();
}

class _RunningCoachAppState extends State<RunningCoachApp> {
  late final OpenEarableManager _oeManager;
  late final Esp32Manager       _esp32Manager;

  @override
  void initState() {
    super.initState();
    final ruleEngine = RuleEngine(
      profile: const RunnerProfile(
        hrTarget: 155,
        hrTolerance: 10,
        cadenceTarget: 170,
        cadenceTolerance: 10,
        edaHighThreshold: 2.0,
        tempHighThreshold: 37.0,
      ),
    );
    _oeManager    = OpenEarableManager(ruleEngine: ruleEngine);
    _esp32Manager = Esp32Manager();
  }

  @override
  void dispose() {
    _oeManager.dispose();
    _esp32Manager.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Running Coach',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: HomeScreen(
        oeManager: _oeManager,
        esp32Manager: _esp32Manager,
      ),
    );
  }
}
