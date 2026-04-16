// =============================================================
// Audio Coach — phone-speaker tone feedback
//
// Three perceptually distinct sounds — differ in rhythm, pulse
// count, and timing character so they are identifiable by feel:
//
//   safety    → RAPID TRIPLET BURST
//               dit-dit-dit ... dit-dit-dit
//               880 Hz × 3, 40 ms gap, 300 ms pause, repeat
//               Universal "emergency cluster" feel.
//
//   tooSlow   → SLOW DOUBLE KNOCK
//               DUM-dum ... DUM-dum
//               330 → 660 Hz pairs, 80 ms gap, 400 ms pause, repeat
//               Opposite of urgent — slow wake-up knock.
//
//   moderate  → SINGLE FALLING WOBBLE
//               woooop
//               528 → 330 Hz smooth linear chirp over 600 ms, once only
//               One continuous glide — no rhythm at all, categorically
//               different from both others.
//
// freq: 0 in a _Tone = silence segment (sin(0) = 0).
// audio_session ducks music/podcasts while each tone plays.
// =============================================================

import 'dart:math';
import 'package:audio_session/audio_session.dart' as as_;
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

enum AudioCue { safety, tooSlow, moderate }

// A single tone segment: frequency in Hz (0 = silence) and duration in ms.
typedef _Tone = ({double freq, int ms});

class AudioCoach {
  as_.AudioSession? _session;
  final AudioPlayer _player = AudioPlayer();

  // ── Tone patterns ─────────────────────────────────────────

  // Safety — rapid triplet burst: dit-dit-dit [pause] dit-dit-dit
  // 40 ms gap between pulses within a triplet; 300 ms silent pause between triplets.
  static const List<_Tone> _patternSafety = [
    (freq: 880, ms: 80), (freq: 880, ms: 80), (freq: 880, ms: 80),
    (freq: 0,   ms: 300), // pause between triplets
    (freq: 880, ms: 80), (freq: 880, ms: 80), (freq: 880, ms: 80),
  ];

  // Too slow — slow double knock: DUM-dum [pause] DUM-dum
  // 80 ms gap within each pair; 400 ms silent pause between pairs.
  static const List<_Tone> _patternTooSlow = [
    (freq: 330, ms: 300), (freq: 660, ms: 300),
    (freq: 0,   ms: 400), // pause between pairs
    (freq: 330, ms: 300), (freq: 660, ms: 300),
  ];

  // Moderate stress — single falling wobble: woooop (528 → 330 Hz, 600 ms)
  // Built separately via _buildSweepWav — no stepped pattern needed.

  /// Call once at app startup (inside initState postFrameCallback).
  Future<void> init() async {
    try {
      _session = await as_.AudioSession.instance;
      await _session!.configure(as_.AudioSessionConfiguration(
        avAudioSessionCategory: as_.AVAudioSessionCategory.playback,
        avAudioSessionCategoryOptions:
            as_.AVAudioSessionCategoryOptions.duckOthers,
        avAudioSessionMode: as_.AVAudioSessionMode.defaultMode,
        avAudioSessionRouteSharingPolicy:
            as_.AVAudioSessionRouteSharingPolicy.defaultPolicy,
        avAudioSessionSetActiveOptions:
            as_.AVAudioSessionSetActiveOptions.none,
        androidAudioAttributes: const as_.AndroidAudioAttributes(
          contentType: as_.AndroidAudioContentType.sonification,
          flags: as_.AndroidAudioFlags.none,
          usage: as_.AndroidAudioUsage.assistanceSonification,
        ),
        androidAudioFocusGainType:
            as_.AndroidAudioFocusGainType.gainTransientMayDuck,
        androidWillPauseWhenDucked: false,
      ));
    } catch (e) {
      debugPrint('[AudioCoach] Session init error: $e');
    }
  }

  /// Play the tone pattern for [cue]. Non-blocking.
  Future<void> play(AudioCue cue) async {
    final Uint8List bytes;
    switch (cue) {
      case AudioCue.safety:
        bytes = _buildWav(_patternSafety, gapMs: 40);
      case AudioCue.tooSlow:
        bytes = _buildWav(_patternTooSlow, gapMs: 80);
      case AudioCue.moderate:
        bytes = _buildSweepWav(startFreq: 528, endFreq: 330, durationMs: 600);
    }

    try {
      await _session?.setActive(true,
          avAudioSessionSetActiveOptions:
              as_.AVAudioSessionSetActiveOptions.none);
      await _player.play(BytesSource(bytes));
      await _player.onPlayerComplete.first;
      await _session?.setActive(false,
          avAudioSessionSetActiveOptions:
              as_.AVAudioSessionSetActiveOptions.none);
    } catch (e) {
      debugPrint('[AudioCoach] Play error: $e');
    }
  }

  /// CSV label for a cue (empty string = no cue fired).
  static String cueLabel(AudioCue? cue) => switch (cue) {
        AudioCue.safety   => 'safety',
        AudioCue.tooSlow  => 'too_slow',
        AudioCue.moderate => 'moderate',
        null              => '',
      };

  void dispose() {
    _player.dispose();
  }

  // ── WAV builders ──────────────────────────────────────────

  /// Builds a WAV from a list of tone segments.
  /// freq: 0 produces silence. [gapMs] adds silence between consecutive tones.
  static Uint8List _buildWav(List<_Tone> tones, {int gapMs = 60}) {
    const sampleRate    = 44100;
    const numChannels   = 1;
    const bitsPerSample = 16;
    const bytesPerSample = bitsPerSample ~/ 8;
    const maxAmplitude  = 0.70;

    final samples = <int>[];

    for (int t = 0; t < tones.length; t++) {
      final tone       = tones[t];
      final numSamples = (sampleRate * tone.ms / 1000.0).round();

      for (int i = 0; i < numSamples; i++) {
        final double pcmDouble;
        if (tone.freq == 0) {
          pcmDouble = 0;
        } else {
          final fadeIn  = i < sampleRate * 0.01
              ? i / (sampleRate * 0.01) : 1.0;
          final fadeOut = i > numSamples - sampleRate * 0.01
              ? (numSamples - i) / (sampleRate * 0.01) : 1.0;
          pcmDouble = sin(2 * pi * tone.freq * i / sampleRate)
              * fadeIn * fadeOut * maxAmplitude * 32767;
        }
        final pcm = pcmDouble.round().clamp(-32768, 32767);
        samples.add(pcm & 0xFF);
        samples.add((pcm >> 8) & 0xFF);
      }

      // Gap between tones (skip if next tone is already a silence segment)
      if (t < tones.length - 1 && tones[t + 1].freq != 0 && tone.freq != 0) {
        final gapSamples = (sampleRate * gapMs / 1000.0).round();
        samples.addAll(List.filled(gapSamples * bytesPerSample, 0));
      }
    }

    return _wrapWav(samples);
  }

  /// Builds a single linear frequency sweep (chirp) WAV — the "woooop" sound.
  /// Frequency glides smoothly from [startFreq] to [endFreq] over [durationMs].
  static Uint8List _buildSweepWav({
    required double startFreq,
    required double endFreq,
    required int    durationMs,
  }) {
    const sampleRate    = 44100;
    const bitsPerSample = 16;
    const maxAmplitude  = 0.70;

    final numSamples = (sampleRate * durationMs / 1000.0).round();
    final samples    = <int>[];

    // Linear chirp: phase = 2π * integral of instantaneous frequency
    // f(t) = startFreq + (endFreq - startFreq) * t / T
    // phase(i) = 2π * (startFreq * i + (endFreq - startFreq) * i² / (2 * N)) / sampleRate
    final freqSlope = (endFreq - startFreq) / numSamples;

    for (int i = 0; i < numSamples; i++) {
      final fadeIn  = i < sampleRate * 0.01
          ? i / (sampleRate * 0.01) : 1.0;
      final fadeOut = i > numSamples - sampleRate * 0.01
          ? (numSamples - i) / (sampleRate * 0.01) : 1.0;

      final phase = 2 * pi * (startFreq * i + freqSlope * i * i / 2) / sampleRate;
      final pcmDouble = sin(phase) * fadeIn * fadeOut * maxAmplitude * 32767;
      final pcm = pcmDouble.round().clamp(-32768, 32767);
      samples.add(pcm & 0xFF);
      samples.add((pcm >> 8) & 0xFF);
    }

    return _wrapWav(samples);
  }

  /// Wraps raw 16-bit PCM samples in a standard WAV header.
  static Uint8List _wrapWav(List<int> samples) {
    const sampleRate    = 44100;
    const numChannels   = 1;
    const bitsPerSample = 16;
    const bytesPerSample = bitsPerSample ~/ 8;

    final dataSize   = samples.length;
    final fileSize   = 36 + dataSize;
    final byteRate   = sampleRate * numChannels * bytesPerSample;
    final blockAlign = numChannels * bytesPerSample;

    final header = ByteData(44);
    header.setUint8(0,  0x52); // R
    header.setUint8(1,  0x49); // I
    header.setUint8(2,  0x46); // F
    header.setUint8(3,  0x46); // F
    header.setUint32(4,  fileSize,    Endian.little);
    header.setUint8(8,  0x57); // W
    header.setUint8(9,  0x41); // A
    header.setUint8(10, 0x56); // V
    header.setUint8(11, 0x45); // E
    header.setUint8(12, 0x66); // f
    header.setUint8(13, 0x6D); // m
    header.setUint8(14, 0x74); // t
    header.setUint8(15, 0x20); // (space)
    header.setUint32(16, 16,           Endian.little);
    header.setUint16(20, 1,            Endian.little); // PCM
    header.setUint16(22, numChannels,  Endian.little);
    header.setUint32(24, sampleRate,   Endian.little);
    header.setUint32(28, byteRate,     Endian.little);
    header.setUint16(32, blockAlign,   Endian.little);
    header.setUint16(34, bitsPerSample, Endian.little);
    header.setUint8(36, 0x64); // d
    header.setUint8(37, 0x61); // a
    header.setUint8(38, 0x74); // t
    header.setUint8(39, 0x61); // a
    header.setUint32(40, dataSize, Endian.little);

    final result = Uint8List(44 + dataSize);
    result.setRange(0, 44, header.buffer.asUint8List());
    result.setRange(44, 44 + dataSize, samples);
    return result;
  }
}
