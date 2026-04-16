import 'package:flutter/material.dart';
import 'package:running_coach/apps/running_coach/model/user_profile.dart';

class UserProfileForm extends StatefulWidget {
  final void Function(UserProfile) onSaved;

  const UserProfileForm({required this.onSaved, super.key});

  @override
  State<UserProfileForm> createState() => _UserProfileFormState();
}

class _UserProfileFormState extends State<UserProfileForm> {
  final _ageController    = TextEditingController(text: '25');
  final _heightController = TextEditingController(text: '170');
  String _sex = 'male';

  @override
  void dispose() {
    _ageController.dispose();
    _heightController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Your Profile',
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            'Used to calculate Karvonen HR zones (70/80/85 % HRR)',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _ageController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Age (years)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _heightController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Height (cm)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 14),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'male',   label: Text('Male')),
              ButtonSegment(value: 'female', label: Text('Female')),
            ],
            selected: {_sex},
            onSelectionChanged: (s) => setState(() => _sex = s.first),
          ),
          const SizedBox(height: 22),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () {
                final age    = int.tryParse(_ageController.text)       ?? 25;
                final height = double.tryParse(_heightController.text) ?? 170;
                widget.onSaved(UserProfile(
                  ageYears:  age,
                  heightCm:  height,
                  sex:       _sex,
                ));
                Navigator.of(context).pop();
              },
              child: const Text('Save'),
            ),
          ),
        ],
      ),
    );
  }
}
