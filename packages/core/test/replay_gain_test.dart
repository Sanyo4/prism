import 'dart:io';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:prism_core/core.dart';
import 'package:test/test.dart';

/// Helper: wrap a fake-file path in an [AudioMetadata] with just a
/// title, enough to satisfy `Track.fromMetadata`'s required [meta]
/// argument. Nothing here touches the filesystem.
AudioMetadata _meta({String? title, String? artist}) => AudioMetadata(
      file: File('/fixture/unused.ext'),
      title: title,
      artist: artist,
    );

void main() {
  group('parseReplayGainDb', () {
    test('parses the exact value from "+3.12 dB"', () {
      expect(parseReplayGainDb('+3.12 dB'), equals(3.12));
    });

    test('handles bare signed values without unit suffix', () {
      expect(parseReplayGainDb('-3.1'), equals(-3.1));
    });

    test('handles no-space unit suffix ("3.1dB")', () {
      expect(parseReplayGainDb('3.1dB'), equals(3.1));
    });

    test('handles case-insensitive unit suffix ("3.1 DB")', () {
      expect(parseReplayGainDb('3.1 DB'), equals(3.1));
    });

    test('handles unsigned decimal without unit ("3.1")', () {
      expect(parseReplayGainDb('3.1'), equals(3.1));
    });

    test('tolerates surrounding whitespace', () {
      expect(parseReplayGainDb('   -6.00 dB   '), equals(-6.0));
    });

    test('returns null for non-numeric / empty input', () {
      expect(parseReplayGainDb(''), isNull);
      expect(parseReplayGainDb('nonsense'), isNull);
      expect(parseReplayGainDb('dB'), isNull);
    });
  });

  group('dbToLinear', () {
    test('-6 dB is within 1e-3 of 0.501', () {
      expect((dbToLinear(-6) - 0.501).abs(), lessThan(1e-3));
    });

    test('0 dB is exactly 1.0 (identity)', () {
      expect(dbToLinear(0), equals(1.0));
    });

    test('+6 dB ≈ 1.9953', () {
      expect((dbToLinear(6) - 1.9953).abs(), lessThan(1e-3));
    });

    test('is the inverse of -dB through parseReplayGainDb', () {
      final parsed = parseReplayGainDb('-6.0 dB');
      expect(parsed, isNotNull);
      expect((dbToLinear(parsed!) - 0.501).abs(), lessThan(1e-3));
    });
  });

  group('Track.fromMetadata — ReplayGain resolution', () {
    test('VorbisMetadata populates replayGainTrackDb from '
        'replayGainTrackGain.first', () {
      final raw = VorbisMetadata()
        ..replayGainTrackGain = <String>['-5.44 dB']
        ..replayGainAlbumGain = <String>['-4.10 dB'];
      final t = Track.fromMetadata(
        path: '/music/a.flac',
        mtimeMs: 1,
        meta: _meta(title: 'FLAC track'),
        raw: raw,
      );
      expect(t.replayGainTrackDb, closeTo(-5.44, 1e-6));
      expect(t.replayGainAlbumDb, closeTo(-4.10, 1e-6));
    });

    test('Mp3Metadata populates replayGainTrackDb from customMetadata TXXX',
        () {
      final raw = Mp3Metadata()
        ..customMetadata = <String, String>{
          'REPLAYGAIN_TRACK_GAIN': '-7.23 dB',
          'REPLAYGAIN_ALBUM_GAIN': '-6.80 dB',
        };
      final t = Track.fromMetadata(
        path: '/music/a.mp3',
        mtimeMs: 1,
        meta: _meta(title: 'MP3 track'),
        raw: raw,
      );
      expect(t.replayGainTrackDb, closeTo(-7.23, 1e-6));
      expect(t.replayGainAlbumDb, closeTo(-6.80, 1e-6));
    });

    test('Mp3Metadata TXXX lookup is case-insensitive', () {
      final raw = Mp3Metadata()
        ..customMetadata = <String, String>{
          'replaygain_track_gain': '+1.23 dB',
        };
      final t = Track.fromMetadata(
        path: '/music/b.mp3',
        mtimeMs: 1,
        meta: _meta(),
        raw: raw,
      );
      expect(t.replayGainTrackDb, closeTo(1.23, 1e-6));
    });

    test('absent RG tag on a VorbisMetadata leaves replayGainTrackDb null',
        () {
      final raw = VorbisMetadata();
      final t = Track.fromMetadata(
        path: '/music/c.flac',
        mtimeMs: 1,
        meta: _meta(),
        raw: raw,
      );
      expect(t.replayGainTrackDb, isNull);
      expect(t.replayGainAlbumDb, isNull);
    });

    test('missing raw parser tag leaves RG fields null', () {
      final t = Track.fromMetadata(
        path: '/music/d.wav',
        mtimeMs: 1,
        meta: _meta(),
      );
      expect(t.replayGainTrackDb, isNull);
      expect(t.replayGainAlbumDb, isNull);
    });

    test('Mp3Metadata populates albumArtist from bandOrOrchestra (TPE2)', () {
      final raw = Mp3Metadata()..bandOrOrchestra = 'Various Artists';
      final t = Track.fromMetadata(
        path: '/music/e.mp3',
        mtimeMs: 1,
        meta: _meta(artist: 'Lead Performer'),
        raw: raw,
      );
      expect(t.albumArtist, equals('Various Artists'));
    });

    test('VorbisMetadata populates albumArtist from unknowns[ALBUMARTIST]',
        () {
      final raw = VorbisMetadata()
        ..unknowns['ALBUMARTIST'] = 'Compilation Folks';
      final t = Track.fromMetadata(
        path: '/music/f.flac',
        mtimeMs: 1,
        meta: _meta(),
        raw: raw,
      );
      expect(t.albumArtist, equals('Compilation Folks'));
    });
  });
}
