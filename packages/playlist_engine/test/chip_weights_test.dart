import 'dart:typed_data';

import 'package:prism_playlist_engine/playlist_engine.dart';
import 'package:test/test.dart';

CandidateMeta _meta({
  int id = 1,
  String artist = 'a',
  double bpm = 110.0,
  int? year,
  double moodHappy = 0.0,
  double moodSad = 0.0,
  double moodRelaxed = 0.0,
  double moodAggressive = 0.0,
  double moodParty = 0.0,
}) {
  return CandidateMeta(
    trackId: id,
    artistKey: artist,
    title: 't$id',
    key: '',
    year: year,
    bpm: bpm,
    moodHappy: moodHappy,
    moodSad: moodSad,
    moodRelaxed: moodRelaxed,
    moodAggressive: moodAggressive,
    moodParty: moodParty,
    danceability: 0.0,
    voiceInstrumental: 0.0,
  );
}

RadioSession _session({
  Map<SteerChip, ChipState> chips = const {},
  String? lastArtist,
  List<int> history = const [],
}) {
  return RadioSession(
    seed: const TrackSeed(trackId: 0, title: 'seed'),
    seedEmbedding: Float32List(1280),
    chips: chips,
    history: history,
    lastPickArtistKey: lastArtist,
  );
}

void main() {
  const w = ChipWeights();

  group('happier vs sadder — monotone in mood polarity', () {
    test('happier monotonically rewards happier candidates', () {
      final session = _session(
        chips: const {SteerChip.happier: ChipState(10)},
      );
      double scoreFor(double happy, double sad) =>
          w.apply(session, _meta(moodHappy: happy, moodSad: sad));
      final samples = [
        scoreFor(0.0, 1.0),
        scoreFor(0.0, 0.5),
        scoreFor(0.0, 0.0),
        scoreFor(0.5, 0.0),
        scoreFor(1.0, 0.0),
      ];
      for (var i = 0; i < samples.length - 1; i++) {
        expect(samples[i], lessThan(samples[i + 1]));
      }
    });

    test('sadder is the mirror of happier', () {
      final s1 = _session(chips: const {SteerChip.happier: ChipState(10)});
      final s2 = _session(chips: const {SteerChip.sadder: ChipState(10)});
      final happy = _meta(moodHappy: 0.9, moodSad: 0.1);
      final sad = _meta(moodHappy: 0.1, moodSad: 0.9);
      expect(w.apply(s1, happy), greaterThan(w.apply(s1, sad)));
      expect(w.apply(s2, sad), greaterThan(w.apply(s2, happy)));
    });
  });

  group('calmer vs moreIntense', () {
    test('calmer rewards relaxed-not-aggressive', () {
      final s = _session(chips: const {SteerChip.calmer: ChipState(10)});
      final calm = _meta(moodRelaxed: 1.0, moodAggressive: 0.0);
      final hot = _meta(moodRelaxed: 0.0, moodAggressive: 1.0);
      expect(w.apply(s, calm), greaterThan(w.apply(s, hot)));
    });

    test('moreIntense rewards aggressive/party blend', () {
      final s = _session(chips: const {SteerChip.moreIntense: ChipState(10)});
      final hot = _meta(moodAggressive: 1.0, moodParty: 1.0);
      final mid = _meta(moodAggressive: 0.0, moodParty: 0.0);
      expect(w.apply(s, hot), greaterThan(w.apply(s, mid)));
    });
  });

  group('slower vs faster — monotone in BPM', () {
    test('faster rewards higher BPM (no seed anchor)', () {
      final s = _session(chips: const {SteerChip.faster: ChipState(10)});
      final samples = [70.0, 90.0, 110.0, 130.0, 150.0]
          .map((b) => w.apply(s, _meta(bpm: b)))
          .toList();
      for (var i = 0; i < samples.length - 1; i++) {
        expect(samples[i], lessThan(samples[i + 1]));
      }
    });

    test('slower rewards lower BPM (no seed anchor)', () {
      final s = _session(chips: const {SteerChip.slower: ChipState(10)});
      final samples = [150.0, 130.0, 110.0, 90.0, 70.0]
          .map((b) => w.apply(s, _meta(bpm: b)))
          .toList();
      for (var i = 0; i < samples.length - 1; i++) {
        expect(samples[i], lessThan(samples[i + 1]));
      }
    });

    test('slower vs faster uses seed BPM as anchor when supplied', () {
      final s = _session(chips: const {SteerChip.faster: ChipState(10)});
      final seedSlow = _meta(id: 0, bpm: 80.0);
      final candFast = _meta(id: 2, bpm: 130.0);
      final candSlow = _meta(id: 3, bpm: 60.0);
      expect(
        w.apply(s, candFast, seedMeta: seedSlow),
        greaterThan(w.apply(s, candSlow, seedMeta: seedSlow)),
      );
    });
  });

  group('newer vs older — sigmoid in year delta', () {
    test('newer rewards later release dates', () {
      final s = _session(chips: const {SteerChip.newer: ChipState(10)});
      final seed = _meta(id: 0, year: 1990);
      double yr(int y) => w.apply(s, _meta(id: y, year: y), seedMeta: seed);
      expect(yr(1980), lessThan(yr(1990)));
      expect(yr(1990), lessThan(yr(2000)));
      expect(yr(2000), lessThan(yr(2020)));
    });

    test('older mirrors newer', () {
      final s = _session(chips: const {SteerChip.older: ChipState(10)});
      final seed = _meta(id: 0, year: 2000);
      expect(
        w.apply(s, _meta(id: 1, year: 1980), seedMeta: seed),
        greaterThan(w.apply(s, _meta(id: 2, year: 2020), seedMeta: seed)),
      );
    });

    test('missing year on either side is neutral', () {
      final s = _session(chips: const {SteerChip.newer: ChipState(10)});
      // No seed year → kernel returns 1.0
      expect(w.apply(s, _meta(year: 2020)), 1.0);
    });
  });

  group('moreLikeThisArtist + differentArtists', () {
    test('moreLikeThisArtist rewards same artist as seed', () {
      final s = _session(
        chips: const {SteerChip.moreLikeThisArtist: ChipState(10)},
      );
      final seed = _meta(artist: 'cure');
      expect(
        w.apply(s, _meta(artist: 'cure'), seedMeta: seed),
        greaterThan(w.apply(s, _meta(artist: 'pulp'), seedMeta: seed)),
      );
    });

    test('differentArtists penalises last-pick artist re-use', () {
      final s = _session(
        chips: const {SteerChip.differentArtists: ChipState(10)},
        lastArtist: 'cure',
      );
      expect(
        w.apply(s, _meta(artist: 'cure')),
        lessThan(w.apply(s, _meta(artist: 'pulp'))),
      );
    });
  });

  test('inactive chip contributes 1.0', () {
    final s = _session(chips: const {SteerChip.faster: ChipState(0)});
    expect(w.apply(s, _meta(bpm: 200.0)), 1.0);
  });

  test('decay halves the kernel effect linearly', () {
    final full = _session(chips: const {SteerChip.faster: ChipState(10)});
    final half = _session(chips: const {SteerChip.faster: ChipState(5)});
    final cand = _meta(bpm: 150.0);
    final fullEffect = w.apply(full, cand) - 1.0;
    final halfEffect = w.apply(half, cand) - 1.0;
    expect(halfEffect, closeTo(fullEffect * 0.5, 1e-6));
  });
}
