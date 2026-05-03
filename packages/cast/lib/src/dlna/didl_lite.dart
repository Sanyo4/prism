import 'package:prism_core/core.dart';
import 'package:xml/xml.dart';

/// DIDL-Lite metadata builder for AVTransport's
/// `CurrentURIMetaData` argument.
///
/// **`DLNA.ORG_PN` decision:** slice 9 §7 default is **MIME-only**
/// `protocolInfo='http-get:*:audio/flac:*'`. Sony STR-DN1080
/// firmware accepts this without a PN tag; community DLNA pushers
/// (BubbleUPnP, Linn Kazoo, mconnect) emit the same shape against
/// Sony AV receivers without issue.
///
/// The strict-PN path ([DidlLite.buildWithPnTag]) is opt-in for
/// the slice-9 §10 risk 12 "Strict DLNA profile" debug toggle.
/// `DLNA.ORG_PN=FLAC` is the spec-documented profile name from
/// DLNA Guidelines v1.5; there is no separate hi-res FLAC PN
/// (PCM `LPCM_low` / `LPCM` carry rate/depth via the protocolInfo
/// additional-info field). We pin `'FLAC'` as the default PN
/// because that's the only registered FLAC content profile;
/// receivers that need a different PN are expected to be rare
/// enough to warrant manual override.
///
/// Two-pass escape note: when DIDL is embedded inside SOAP's
/// `<CurrentURIMetaData>`, the outer envelope's `builder.text(...)`
/// performs the second escape automatically. Tests exercise the
/// double-escape round-trip to confirm.
class DidlLite {
  /// Hidden constructor — `DidlLite` is a static-only utility.
  DidlLite._();

  /// Default DIDL-Lite XML for [track]. MIME-only `protocolInfo`
  /// per slice 9 §4 / §7. [url] is the public URL the receiver
  /// will dial — typically `MediaServer.urlForFlac(track)`.
  ///
  /// [protocolInfoOverride] lets callers pass an exact
  /// `protocolInfo` string when they have device-specific
  /// requirements (e.g. an `LPCM` profile for a strict receiver).
  /// Default is `http-get:*:audio/flac:*`.
  static String build({
    required Track track,
    required Uri url,
    String? protocolInfoOverride,
  }) {
    return _build(
      track: track,
      url: url,
      protocolInfo: protocolInfoOverride ?? 'http-get:*:audio/flac:*',
    );
  }

  /// Strict DIDL-Lite XML emitting `DLNA.ORG_PN=$pn`,
  /// `DLNA.ORG_OP=01` (range-seek supported), and
  /// `DLNA.ORG_FLAGS=01700000000000000000000000000000` (DLNA v1.5
  /// streaming flags — `BACKGROUND_TRANSFER_MODE`,
  /// `INTERACTIVE_TRANSFER_MODE`, `STREAMING_TRANSFER_MODE`,
  /// `DLNA_V15`).
  ///
  /// Default [pn] is `'FLAC'` (DLNA Guidelines v1.5 profile name
  /// for the FLAC content format). Receivers rejecting this fall
  /// back through the default [build].
  static String buildWithPnTag({
    required Track track,
    required Uri url,
    String pn = 'FLAC',
  }) {
    final protocolInfo = 'http-get:*:audio/flac:'
        'DLNA.ORG_PN=$pn;'
        'DLNA.ORG_OP=01;'
        'DLNA.ORG_FLAGS=01700000000000000000000000000000';
    return _build(track: track, url: url, protocolInfo: protocolInfo);
  }

  static String _build({
    required Track track,
    required Uri url,
    required String protocolInfo,
  }) {
    final duration = _formatDuration(track.duration);
    final builder = XmlBuilder();
    builder.element('DIDL-Lite', nest: () {
      builder.attribute(
        'xmlns',
        'urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/',
      );
      builder.attribute(
        'xmlns:dc',
        'http://purl.org/dc/elements/1.1/',
      );
      builder.attribute(
        'xmlns:upnp',
        'urn:schemas-upnp-org:metadata-1-0/upnp/',
      );
      builder.attribute(
        'xmlns:dlna',
        'urn:schemas-dlna-org:metadata-1-0/',
      );
      builder.element('item', nest: () {
        builder.attribute('id', '0');
        builder.attribute('parentID', '-1');
        builder.attribute('restricted', '1');

        builder.element('dc:title', nest: () {
          builder.text(track.title ?? _basenameWithoutExt(track.path));
        });
        if (track.artist != null && track.artist!.isNotEmpty) {
          builder.element('upnp:artist', nest: () {
            builder.text(track.artist!);
          });
          builder.element('dc:creator', nest: () {
            builder.text(track.artist!);
          });
        }
        if (track.album != null && track.album!.isNotEmpty) {
          builder.element('upnp:album', nest: () {
            builder.text(track.album!);
          });
        }
        builder.element('upnp:class', nest: () {
          builder.text('object.item.audioItem.musicTrack');
        });

        builder.element('res', nest: () {
          builder.attribute('protocolInfo', protocolInfo);
          if (duration != null) {
            builder.attribute('duration', duration);
          }
          // `sampleFrequency`, `bitsPerSample`, `nrAudioChannels`
          // are spec-allowed `res@` attributes; slice-1's `Track`
          // doesn't expose them. Slice 4's sidecar carries
          // `sample_rate` + `bit_depth`; future Track A/B refactor
          // can plumb these through. Receivers that need them for
          // hi-res accept absence (rate is auto-detected from the
          // FLAC stream header at playback start). Pinning them
          // here without sidecar data would risk emitting wrong
          // values for receivers that strict-validate.
          builder.text(url.toString());
        });
      });
    });
    return builder.buildDocument().toXmlString();
  }

  /// Formats [d] as `HH:MM:SS.fff` (the AVTransport `REL_TIME`
  /// shape, also accepted in `res@duration`). Returns `null` for a
  /// null input — the caller omits the attribute.
  static String? _formatDuration(Duration? d) {
    if (d == null) return null;
    final totalMs = d.inMilliseconds;
    final hours = (totalMs ~/ 3600000);
    final minutes = (totalMs ~/ 60000) % 60;
    final seconds = (totalMs ~/ 1000) % 60;
    final millis = totalMs % 1000;
    final hh = hours.toString().padLeft(2, '0');
    final mm = minutes.toString().padLeft(2, '0');
    final ss = seconds.toString().padLeft(2, '0');
    final fff = millis.toString().padLeft(3, '0');
    return '$hh:$mm:$ss.$fff';
  }

  /// Public re-export of [_formatDuration] for transports that need
  /// to format `Seek` targets the same way DIDL formats `res@duration`.
  static String formatRelTime(Duration d) {
    return _formatDuration(d) ?? '00:00:00.000';
  }

  static String _basenameWithoutExt(String path) {
    final lastSlash = path.lastIndexOf('/');
    final base = lastSlash < 0 ? path : path.substring(lastSlash + 1);
    final dot = base.lastIndexOf('.');
    return dot < 0 ? base : base.substring(0, dot);
  }
}
