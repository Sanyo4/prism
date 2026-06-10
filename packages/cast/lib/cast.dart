/// Prism cast — Cast & DLNA transports.
///
/// Slice 9 surface: [CastTransport] abstract class plus the
/// [TransportEvent] sealed family, [LocalTransport] (delegates to
/// slice 1's `AudioPlayerPort`), [DlnaTransport] (UPnP AVTransport v1
/// client + embedded `MediaServer`), and [ChromecastTransport]
/// (Android-only Cast SDK wrapper with FLAC→AAC transcode via
/// `MediaServer`). [DiscoveryService] drives SSDP M-SEARCH +
/// description fetch with a 5-min refresh; [IpSelector] picks the
/// LAN-facing interface for the embedded server.
///
/// This barrel exports only the public surface Track B's
/// `apps/mobile` integration and `packages/playback`'s
/// transport-seam refactor consume. Internal helpers
/// (`_StubAdapter` etc.) stay in `lib/src/`.
library;

export 'src/cast_transport.dart';
export 'src/local_transport.dart';
export 'src/net/ip_selector.dart';
export 'src/net/media_server.dart';
export 'src/net/transcoder.dart';
export 'src/dlna/discovery.dart';
export 'src/dlna/dlna_device.dart';
export 'src/dlna/soap.dart';
export 'src/dlna/didl_lite.dart';
export 'src/dlna/dlna_transport.dart';
export 'src/chromecast/chromecast_device.dart';
export 'src/chromecast/chromecast_transport.dart';
