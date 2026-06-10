import 'dart:math' as math;

/// Parses a ReplayGain dB string as written to audio tags — commonly
/// `REPLAYGAIN_TRACK_GAIN` (Vorbis comments, MP3 TXXX, MP4 iTunes
/// freeform, etc.) — into a signed `double`.
///
/// Accepts the range of forms real-world taggers emit:
///
/// - `"+3.12 dB"` → `3.12`
/// - `"-3.1"`     → `-3.1`
/// - `"3.1dB"`    → `3.1`
/// - `"3.1"`      → `3.1`
/// - `"  -6.0 dB  "` → `-6.0` (whitespace tolerant)
///
/// Returns `null` if the string can't be parsed — e.g. empty string,
/// non-numeric payload, or an unrelated tag value accidentally routed
/// here. Callers treat `null` as "no gain information", which at the
/// playback layer becomes 0 dB (no attenuation).
///
/// Deliberately lives in `packages/core` (not `packages/playback`) so
/// `Track.fromMetadata` can populate [Track.replayGainTrackDb] without
/// pulling Flutter, `just_audio`, or `audio_service` into the pure-Dart
/// data layer.
double? parseReplayGainDb(String raw) {
  final stripped = raw
      .replaceAll(RegExp(r'\s*dB\s*$', caseSensitive: false), '')
      .trim();
  if (stripped.isEmpty) return null;
  return double.tryParse(stripped);
}

/// Converts a gain expressed in decibels into a linear amplitude
/// multiplier, matching the convention `just_audio`'s `setVolume`
/// consumes: `10 ^ (dB / 20)`.
///
/// - `dbToLinear(0)`  → `1.0` (identity — no attenuation / boost)
/// - `dbToLinear(-6)` ≈ `0.5012` (−6 dB ≈ half-amplitude)
/// - `dbToLinear(6)`  ≈ `1.9953`
///
/// `just_audio.setVolume` clamps its argument to `[0, 1]`, so callers
/// that apply a positive ReplayGain (loud track that still wants
/// headroom applied elsewhere) must clamp themselves. Slice 1's
/// `PlaybackService` clamps to `[0, 1]` — the upper cap never bites
/// because tag-embedded RG is almost always ≤ 0 dB.
double dbToLinear(double db) => math.pow(10, db / 20).toDouble();
