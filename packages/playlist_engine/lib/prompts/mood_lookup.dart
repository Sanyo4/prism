/// `MoodLookup` — adjective → 5-mood snap table.
///
/// The classifier emits five mood scalars (`happy`, `sad`,
/// `aggressive`, `relaxed`, `party`). The LLM, however, will reach
/// for any adjective in the user's vibe ("melancholic", "brooding",
/// "euphoric", ...). This table maps ~40 common adjectives to the
/// 5-mood vocabulary so `MoodTarget.fromJson` can snap unknowns
/// before they reach the SQL filter.
///
/// Snap rule: lowercase + trim → exact match in
/// [kAdjectiveToMood]; otherwise return `'relaxed'` as the least
/// likely to feel wrong (a low-energy room is the safest mismatch).
/// `MoodLookup.snap` is non-throwing per slice plan §10 risk 4.
library;

class MoodLookup {
  MoodLookup._();

  /// 40+ adjective → primary classifier mood. Some adjectives map
  /// to two moods (`'euphoric'` → `happy + party`); the table
  /// records the **primary** one. The verification card at §11 item
  /// 10 spot-checks combos like "euphoric summer party" — the
  /// snap returns `happy` here; the engine's user-text scan in
  /// `Intent.fallback` separately picks up `'party'` from the raw
  /// vibe.
  static const Map<String, String> kAdjectiveToMood = {
    // happy
    'happy': 'happy',
    'cheerful': 'happy',
    'joyful': 'happy',
    'joyous': 'happy',
    'sunny': 'happy',
    'uplifting': 'happy',
    'upbeat': 'happy',
    'feelgood': 'happy',
    'euphoric': 'happy',
    'bright': 'happy',
    'playful': 'happy',
    // sad
    'sad': 'sad',
    'melancholic': 'sad',
    'melancholy': 'sad',
    'mournful': 'sad',
    'somber': 'sad',
    'sombre': 'sad',
    'wistful': 'sad',
    'heartbroken': 'sad',
    'brooding': 'sad',
    'nostalgic': 'sad',
    'bittersweet': 'sad',
    'lonely': 'sad',
    'gloomy': 'sad',
    // aggressive
    'aggressive': 'aggressive',
    'angry': 'aggressive',
    'rage': 'aggressive',
    'raging': 'aggressive',
    'furious': 'aggressive',
    'heavy': 'aggressive',
    'metal': 'aggressive',
    'metallic': 'aggressive',
    'intense': 'aggressive',
    'fierce': 'aggressive',
    'hardcore': 'aggressive',
    'harsh': 'aggressive',
    // relaxed
    'relaxed': 'relaxed',
    'chill': 'relaxed',
    'mellow': 'relaxed',
    'calm': 'relaxed',
    'rainy': 'relaxed',
    'cozy': 'relaxed',
    'sleepy': 'relaxed',
    'ambient': 'relaxed',
    'lofi': 'relaxed',
    'drive': 'relaxed',
    'driving': 'relaxed',
    'lounge': 'relaxed',
    'soft': 'relaxed',
    // party
    'party': 'party',
    'dance': 'party',
    'dancy': 'party',
    'energetic': 'party',
    'festive': 'party',
    'pumping': 'party',
    'club': 'party',
    'banger': 'party',
    'hype': 'party',
  };

  /// Snap an arbitrary mood adjective to one of the 5 classifier
  /// moods. Non-throwing: unknowns default to `'relaxed'`.
  ///
  /// Already-canonical inputs (`'happy'`, `'sad'`, ...) are
  /// idempotent (the table contains them).
  static String snap(String unknown) {
    final s = unknown.toLowerCase().trim();
    if (s.isEmpty) return 'relaxed';
    final hit = kAdjectiveToMood[s];
    if (hit != null) return hit;
    return 'relaxed';
  }

  /// The five canonical mood names, in stable order. Used by the
  /// SQL filter to know which mood column to ORDER BY (§5).
  static const List<String> kCanonicalMoods = <String>[
    'happy',
    'sad',
    'aggressive',
    'relaxed',
    'party',
  ];
}
