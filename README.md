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
