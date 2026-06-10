import 'package:flutter_test/flutter_test.dart';
import 'package:prism_cast/cast.dart';
import 'package:prism_core/core.dart';
import 'package:xml/xml.dart';

/// Slice-9 §8 step 11 contract: DIDL-Lite parses round-trip,
/// survives the SOAP double-escape pass, and emits the right
/// `protocolInfo` under both default (MIME-only) and PN-tag modes.
void main() {
  Track track({
    String title = 'Track Title with <special> & "chars"',
    String? artist = "O'Connor",
    String? album = 'Album & Stuff',
    Duration duration = const Duration(minutes: 4, seconds: 32, milliseconds: 100),
    String path = '/music/Artist/Album/01 - Track.flac',
  }) {
    return Track(
      path: path,
      mtimeMs: 0,
      title: title,
      artist: artist,
      album: album,
      duration: duration,
    );
  }

  final url = Uri.parse('http://192.168.1.42:54321/abc123.flac');

  group('DidlLite.build (MIME-only default)', () {
    test('round-trips through XmlDocument.parse', () {
      final didl = DidlLite.build(track: track(), url: url);
      // Should parse cleanly.
      final doc = XmlDocument.parse(didl);
      expect(doc.rootElement.name.local, 'DIDL-Lite');
      // `<item>` carries id=0, parentID=-1, restricted=1.
      final item = doc.findAllElements('item').single;
      expect(item.getAttribute('id'), '0');
      expect(item.getAttribute('parentID'), '-1');
      expect(item.getAttribute('restricted'), '1');
    });

    test('protocolInfo is MIME-only under the default builder', () {
      final didl = DidlLite.build(track: track(), url: url);
      final doc = XmlDocument.parse(didl);
      final res = doc.findAllElements('res').single;
      expect(res.getAttribute('protocolInfo'), 'http-get:*:audio/flac:*');
      // No DLNA.ORG_PN tag in the default path.
      expect(res.getAttribute('protocolInfo'), isNot(contains('DLNA.ORG_PN')));
    });

    test('XML special characters are escaped (single-pass)', () {
      final didl = DidlLite.build(track: track(), url: url);
      // After a single XML escape pass package:xml emits the
      // minimum required escapes — `<` (ambiguity with element-
      // delimiter), `&` (ambiguity with entity reference), and `"`
      // when inside an attribute. `>` and `'` are not formally
      // required to be escaped in PCDATA per the XML spec; rely on
      // a parse round-trip rather than character-by-character
      // assertions.
      expect(didl, contains('&lt;special'));
      expect(didl, contains('&amp;'));
      expect(didl, contains('"chars"'));
      // The literal raw `<` from the title body must NOT appear
      // outside element delimiters — confirm the round-trip
      // recovers the original PCDATA.
      final innerText = XmlDocument.parse(didl)
          .findAllElements('title', namespace: '*')
          .single
          .innerText;
      expect(innerText, contains('<special>'));
      expect(innerText, contains('"chars"'));
    });

    test('embeds the URL verbatim in the <res> element body', () {
      final didl = DidlLite.build(track: track(), url: url);
      final doc = XmlDocument.parse(didl);
      final res = doc.findAllElements('res').single;
      expect(res.innerText, url.toString());
    });

    test('encodes duration as HH:MM:SS.fff', () {
      final didl = DidlLite.build(track: track(), url: url);
      final doc = XmlDocument.parse(didl);
      final res = doc.findAllElements('res').single;
      // 4m 32s 100ms → 00:04:32.100.
      expect(res.getAttribute('duration'), '00:04:32.100');
    });

    test('omits duration attribute when track.duration is null', () {
      final didl = DidlLite.build(
        track: track(duration: Duration.zero).copyDuration(null),
        url: url,
      );
      final doc = XmlDocument.parse(didl);
      final res = doc.findAllElements('res').single;
      expect(res.getAttribute('duration'), isNull);
    });

    test('survives SOAP double-escape — DIDL embedded inside an envelope '
        'parses back to the same DIDL', () {
      final original = DidlLite.build(track: track(), url: url);
      // Build a SOAP envelope with DIDL embedded inside CurrentURIMetaData.
      // package:xml's XmlBuilder.text() performs the second escape.
      final soap = Soap();
      final envelope = soap.buildEnvelope(
        action: 'SetAVTransportURI',
        args: {
          'CurrentURI': url.toString(),
          'CurrentURIMetaData': original,
        },
      );
      // Parse the envelope, extract CurrentURIMetaData's text content
      // (which dart-xml unescapes once back to the original DIDL),
      // and re-parse it as XML — confirms the round-trip survives both
      // escape passes.
      final envelopeDoc = XmlDocument.parse(envelope);
      final metaText = envelopeDoc
          .findAllElements('CurrentURIMetaData', namespace: '*')
          .single
          .innerText;
      // Re-parse the unescaped DIDL — must be valid XML again.
      final didlDoc = XmlDocument.parse(metaText);
      expect(didlDoc.rootElement.name.local, 'DIDL-Lite');
      expect(didlDoc.findAllElements('item').single.getAttribute('id'), '0');
    });
  });

  group('DidlLite.buildWithPnTag (strict)', () {
    test('emits DLNA.ORG_PN, DLNA.ORG_OP and DLNA.ORG_FLAGS', () {
      final didl = DidlLite.buildWithPnTag(track: track(), url: url);
      final doc = XmlDocument.parse(didl);
      final res = doc.findAllElements('res').single;
      final protocolInfo = res.getAttribute('protocolInfo')!;
      expect(protocolInfo, startsWith('http-get:*:audio/flac:'));
      expect(protocolInfo, contains('DLNA.ORG_PN=FLAC'));
      expect(protocolInfo, contains('DLNA.ORG_OP=01'));
      expect(protocolInfo, contains('DLNA.ORG_FLAGS=01700000000000000000000000000000'));
    });

    test('honors a custom PN value when provided', () {
      final didl = DidlLite.buildWithPnTag(
        track: track(),
        url: url,
        pn: 'LPCM',
      );
      final res = XmlDocument.parse(didl).findAllElements('res').single;
      expect(res.getAttribute('protocolInfo'), contains('DLNA.ORG_PN=LPCM'));
    });
  });
}

/// Test-only `Track` helper — builds a fresh `Track` with the
/// duration overwritten. Slice-1's [Track] is immutable, so we
/// reconstruct it.
extension on Track {
  Track copyDuration(Duration? d) {
    return Track(
      path: path,
      mtimeMs: mtimeMs,
      title: title,
      artist: artist,
      albumArtist: albumArtist,
      album: album,
      genre: genre,
      trackNo: trackNo,
      discNo: discNo,
      year: year,
      duration: d,
      replayGainTrackDb: replayGainTrackDb,
      replayGainAlbumDb: replayGainAlbumDb,
    );
  }
}
