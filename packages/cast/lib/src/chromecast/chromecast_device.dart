/// Chromecast device handle. Wraps the mDNS result the
/// `flutter_chrome_cast` plugin surfaces from
/// `_googlecast._tcp.local.` discovery.
///
/// We keep this a thin data class — the live Cast SDK device
/// reference (`GoogleCastDevice`) is held inside
/// [ChromecastTransport] so the rest of the workspace can refer to
/// devices without dragging in the Cast plugin's types.
class ChromecastDevice {
  const ChromecastDevice({
    required this.id,
    required this.friendlyName,
    this.modelName = '',
  });

  /// Stable Cast device identifier surfaced by the SDK. Used as the
  /// `cast:<id>` key in [CastTransport.id].
  final String id;

  /// Human-readable label — "Living Room speaker", "Kitchen mini",
  /// the user's chosen device name in the Google Home app.
  final String friendlyName;

  /// Optional model name — "Chromecast Audio", "Google Home".
  /// Some Cast SDK builds surface this; others don't. UI should
  /// treat empty-string as "unknown".
  final String modelName;

  @override
  String toString() =>
      'ChromecastDevice(id: $id, friendlyName: $friendlyName)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is ChromecastDevice && other.id == id);

  @override
  int get hashCode => id.hashCode;
}
