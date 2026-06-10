/// Parsed UPnP device description plus the AVTransport / ConnectionManager
/// `controlURL`s slice 9 needs to push audio.
///
/// Discovered via SSDP M-SEARCH (the [Discovery] service walks the
/// description XML at the `LOCATION:` header) or surfaced through
/// manual-IP entry (Track B's settings field). [looksLikeStrDn1080]
/// is a convenience for UI labelling — the receiver's own
/// `friendlyName` may be user-customised, so the `modelName` field
/// is the more reliable identifier.
class DlnaDevice {
  const DlnaDevice({
    required this.uuid,
    required this.friendlyName,
    required this.descriptionUrl,
    required this.controlUrl,
    required this.connectionManagerControlUrl,
    required this.manufacturer,
    required this.modelName,
    this.sinkProtocolInfo = const <String>{},
  });

  /// Stable identifier from the SSDP `USN:` header. The full USN is
  /// `uuid:<UUID>::<service-type>`; we record just the UUID portion
  /// for dedup. Survives reboots; changes if the user resets
  /// network identity.
  final String uuid;

  /// Human-readable label from `<friendlyName>` in the description
  /// XML. Typically defaults to the model name; users may rename.
  final String friendlyName;

  /// URL of the device-description XML. Useful for re-fetch + for
  /// resolving relative `controlURL`s on receivers that don't ship
  /// `<URLBase>` in their description.
  final Uri descriptionUrl;

  /// `controlURL` of the AVTransport service. Receives every SOAP
  /// `SetAVTransportURI / Play / Pause / Seek / GetTransportInfo`
  /// POST.
  final Uri controlUrl;

  /// `controlURL` of the ConnectionManager service. Receives the
  /// initial `GetProtocolInfo` SOAP POST that populates
  /// [sinkProtocolInfo].
  final Uri connectionManagerControlUrl;

  /// Manufacturer string from `<manufacturer>` in the description
  /// XML. "Sony" for the STR-DN1080.
  final String manufacturer;

  /// Model name from `<modelName>` — "STR-DN1080" for the slice's
  /// reference receiver. This is the field [looksLikeStrDn1080]
  /// matches against.
  final String modelName;

  /// CSV sink list parsed from `GetProtocolInfo`'s response. Each
  /// entry is `<protocol>:<network>:<contentFormat>:<additionalInfo>`
  /// — e.g. `http-get:*:audio/flac:*`. The presence of the
  /// `audio/flac` token (with or without a PN tag) is the green
  /// light that bare-FLAC DLNA push will work end-to-end.
  final Set<String> sinkProtocolInfo;

  /// Convenience flag — the slice-9 reference receiver. UI may
  /// surface a "Sony STR-DN1080" badge when this is true.
  bool get looksLikeStrDn1080 => modelName.contains('STR-DN1080');

  /// `true` when the receiver advertises an `audio/flac` sink. UI
  /// uses this to decide whether the DLNA path is safe to enable.
  /// Empty `sinkProtocolInfo` (e.g. when `GetProtocolInfo` failed)
  /// reads as `false` — caller's responsibility to retry.
  bool get supportsFlacSink {
    for (final entry in sinkProtocolInfo) {
      if (entry.contains('audio/flac')) return true;
    }
    return false;
  }

  @override
  String toString() => 'DlnaDevice(modelName: $modelName, '
      'friendlyName: $friendlyName, uuid: $uuid)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is DlnaDevice && other.uuid == uuid);

  @override
  int get hashCode => uuid.hashCode;
}
