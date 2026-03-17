<<<<<<< HEAD
# Running Coach — Setup Guide

## What you need
- A Mac or Windows PC
- An Android phone with USB debugging enabled
- OpenEarable 2.0 earphone

---

## Mac setup

### 1. Install Flutter & Android Studio
```bash
brew install --cask flutter
brew install --cask android-studio
```
Open Android Studio once → click through the setup wizard → let it download the Android SDK.

Then accept licenses:
```bash
flutter doctor --android-licenses
# press y for each prompt
```

### 2. Clone and run
```bash
git clone <repo-url>
cd running_coach
flutter pub get
flutter run
```

---

## Windows setup

### 1. Install Flutter
1. Go to [flutter.dev/docs/get-started/install/windows](https://flutter.dev/docs/get-started/install/windows)
2. Download the Flutter SDK zip, extract it to `C:\flutter`
3. Add `C:\flutter\bin` to your PATH:
   - Search "environment variables" in Start → Edit the system environment variables → Path → New → `C:\flutter\bin`

### 2. Install Android Studio
1. Download from [developer.android.com/studio](https://developer.android.com/studio) and install
2. Open Android Studio → click through the setup wizard → let it download the Android SDK

Then accept licenses in a terminal (Command Prompt or PowerShell):
```
flutter doctor --android-licenses
# press y for each prompt
```

### 3. Clone and run
```
git clone <repo-url>
cd running_coach
flutter pub get
flutter run
```

---

## Connect your Android phone (Mac & Windows)
- Settings → About Phone → tap **Build Number** 7 times
- Settings → Developer Options → enable **USB Debugging**
- Plug in via USB → tap **Allow** on the popup
- `flutter run` will detect the phone and install the app

## First use
1. Open the app → tap **Connect OpenEarable**
2. Wait for scan list → select your device (highlighted in teal)
3. Push the earbud firmly into your ear canal for good PPG contact
4. HR appears after ~10 seconds once seated properly
=======
# Pacing-Fitness-Coach

Github: https://github.com/stonejinx/Pacing-Fitness-Coach.git

Project Draft

Idea: Create a product, which helps in training for running. The machine senses the heartbeat, temperature and speed / pace of the user. These sensor values are used to determine if the user needs to speed up or slow down to train.

Sensors to be used:
IMU - Accelerometer which senses speed / distance.
Heartbeat Sensing
Electrodermal Activity - to sense temp / sweating
Vibration IC

Algorithm for Decision Making:
It is appropriate to use a rule based algorithm to conduct decisions instead of machine learning. The idea is that the heartbeat and EDA will sense values which need to be held in certain thresholds for the user to train effectively. 

For example, if the machine senses that the BPM and temp are under nominal range, then it encourages the user to push their body and vice versa, if it is near or above the range, it alerts the user to slow down or pace themselves.

Literature Review
What % over Resting Heart Rate is acceptable? Should endurance zones be based on HRmax, resting HR, HRR (heart rate reserve), or personalized calibration?
Does acceptable range differ based on activities?
Accuracy of heartbeat/IMU sensor on wrist during motion
Can fatigue be inferred better using multimodal sensing instead of HR alone? (HRV, IMU cadence variability, Skin temperature, EDA (sweat proxy), Respiratory rate from motion)
How can we predict whether a runner will meet their goal before the run ends?
What is the most effective feedback modality during running?
>>>>>>> 621a8bdb1ed9bf2e22fe084adb2027d6c2e678d7
