# How the Flutter App Works

## What is Flutter and why are we using it?

Flutter is Google's open-source framework for building mobile apps using the Dart programming language. You write one codebase and it runs on Android (and iOS if needed). We chose Flutter because it handles BLE (Bluetooth Low Energy) communication cleanly through packages, it's fast to build and deploy to a phone via USB in one command (`flutter run`), and it has good text-to-speech support for the voice coaching cues. Essentially it lets us focus on the sensor logic instead of low-level Android plumbing.

## Overview
The app runs on an Android phone. The phone connects via BLE to the OpenEarable 2.0 (and an ESP32 GSR sensor), processes the sensor data in real time, and speaks voice coaching cues.


## Sensor to Signal flow

The IMU accelerometer streams XYZ at 100 Hz; the app computes the vector magnitude each sample and counts peaks to get steps per minute (cadence). The pulse oximeter streams its green LED channel at 50 Hz; the app subtracts the rolling mean to isolate the tiny AC pulse waveform, then counts peaks to get heart rate in BPM. Skin temperature arrives as °C and is smoothed with an exponential moving average. The ESP32 GSR sensor (not yet wired) will send raw ADC counts that get converted to microsiemens and baseline-calibrated into a relative stress signal.

## Rule Engine
Every second, HR + cadence + EDA + temp feed into `RuleEngine`:
- **High stress** (EDA or temp spike) → "Slow down"
- **HR low AND cadence low** → "Push harder"
- **HR high OR cadence high** → "Slow down"
- Otherwise → "Maintain pace"

A 30-second cooldown prevents back-to-back cues.

## Files created and what each one does

**`lib/main.dart`**
The entry point of the app. It sets up the dependency tree (creates the RuleEngine, OpenEarableManager, and Esp32Manager) and launches the home screen.

**`lib/ble/openearable_manager.dart`**
The most important file. It connects to the OpenEarable 2.0 over BLE, configures each sensor's sampling rate, subscribes to every sensor stream, and routes raw data to the right processor. It also holds the latest HR, cadence, and temp values and triggers the rule engine whenever new data arrives.

**`lib/ble/esp32_manager.dart`**
Handles the BLE connection to the ESP32 + GSR hardware (not yet wired up). Once connected it will read the GSR ADC values and forward them to the EDA processor. You need to fill in your device's BLE UUIDs here before it will work.

**`lib/processors/cadence_processor.dart`**
Takes the raw XYZ accelerometer values from the IMU and detects footstrike peaks in the magnitude signal to produce steps per minute.

**`lib/processors/hr_processor.dart`**
Takes the green channel of the pulse oximeter at 50 Hz, removes the DC baseline by subtracting the rolling mean, and counts peaks in the AC waveform to output heart rate in BPM.

**`lib/processors/bcg_hr_processor.dart`**
A fallback heart rate path. The bone conduction accelerometer in the OpenEarable also picks up arterial pulse vibrations. This processor detects those peaks and produces a BPM estimate if the PPG signal is unavailable or weak.

**`lib/processors/temp_processor.dart`**
Receives skin temperature in °C and applies an exponential moving average to smooth out noise before passing it to the rule engine.

**`lib/processors/eda_processor.dart`**
Converts raw ADC counts from the ESP32 GSR sensor into microsiemens (µS) and applies a baseline calibration so the rule engine sees a relative stress signal rather than an absolute hardware reading.

**`lib/engine/rule_engine.dart`**
Takes the latest HR, cadence, temperature, and EDA values every second and decides what voice cue to give: slow down, push harder, or maintain pace. A 30-second cooldown stops it from speaking too often.

**`lib/screens/home_screen.dart`**
The visual dashboard. Shows live HR, cadence, and temperature readings. Has a button to scan for and connect to OpenEarable devices. When the rule engine fires a cue, this screen speaks it out loud using text-to-speech.

## Still to do
- Fill in real ESP32 BLE UUIDs in `esp32_manager.dart:11-13`
- Wire up ESP32 + GSR hardware
- Tune thresholds in `rule_engine.dart:12-19` from pilot data
