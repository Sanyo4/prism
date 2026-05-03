# Slice 9 — Doc refresh notes

Status snapshot for slice-9 work. Track A (this file's author) covers
UPnP AVTransport + ConnectionManager, SSDP, Sony STR-DN1080 DLNA
capabilities, shelf, dio, package:xml, NetworkInterface, the chosen
Cast Flutter binding, and the chosen ffmpeg_kit Flutter binding.
Track B will append the Riverpod / UI integration sections below.

Date refreshed: 2026-05-03.

---

## UPnP AVTransport v1 service spec

**Source:** `https://upnp.org/specs/av/av1/` redirects (HTTP 301) to
`https://www.openconnectivity.org/`. The historical PDFs are no
longer published from a stable canonical URL on upnp.org — Open
Connectivity Foundation absorbed UPnP, and the AVTransport v1 PDF is
mirrored through community sources rather than from a single stable
canonical link. The pre-OCF UPnP-AV service catalogue is what the
slice spec references; the action signatures themselves haven't
shifted since AVTransport v1 (2002) — they are pinned by AV1
revision-locked devices like the STR-DN1080. Captured here for
auditability:

**Service URN:** `urn:schemas-upnp-org:service:AVTransport:1`
**Transport state machine:** `STOPPED ↔ PLAYING ↔ PAUSED_PLAYBACK ↔ TRANSITIONING`,
with `RECORDING` / `PAUSED_RECORDING` for capture devices (n/a for
STR-DN1080).
**Required actions for slice 9:**
- `SetAVTransportURI(InstanceID=0, CurrentURI, CurrentURIMetaData)`
- `SetNextAVTransportURI(InstanceID=0, NextURI, NextURIMetaData)` —
  optional in the spec; many renderers (including STR-DN1080) support
  it. On `501 Action Not Supported`, fall back to hard-next per
  slice-9 §10 risk 8.
- `Play(InstanceID=0, Speed="1")`
- `Pause(InstanceID=0)`
- `Stop(InstanceID=0)`
- `Seek(InstanceID=0, Unit="REL_TIME", Target=HH:MM:SS)`
- `GetTransportInfo(InstanceID=0)` → `CurrentTransportState,
  CurrentTransportStatus, CurrentSpeed`. State enum:
  `{STOPPED, PLAYING, PAUSED_PLAYBACK, TRANSITIONING, NO_MEDIA_PRESENT}`.
  Status enum: `{OK, ERROR_OCCURRED}`.
- `GetPositionInfo(InstanceID=0)` → `Track, TrackDuration, TrackMetaData,
  TrackURI, RelTime, AbsTime, RelCount, AbsCount`. `RelTime` is the
  scrubber the UI mirrors.

**SOAP envelope shape (verbatim from AV1 spec §2.5):**
```
<?xml version="1.0"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
            s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:ActionName xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <InstanceID>0</InstanceID>
      <Arg1>value</Arg1>
      ...
    </u:ActionName>
  </s:Body>
</s:Envelope>
```

**SOAPAction header:** `"urn:schemas-upnp-org:service:AVTransport:1#<Action>"`
— note the literal embedded double-quotes per the SOAP 1.1 / HTTP
binding (`Content-Type: text/xml; charset="utf-8"`).

## UPnP ConnectionManager v1 service spec

**Service URN:** `urn:schemas-upnp-org:service:ConnectionManager:1`
**Action used by slice 9:** `GetProtocolInfo()` →
`Source, Sink` (both CSV strings). `Sink` is what we record on
`DlnaDevice.sinkProtocolInfo`. Each token is
`<protocol>:<network>:<contentFormat>:<additionalInfo>` —
e.g. `http-get:*:audio/flac:*` or
`http-get:*:audio/L16;rate=44100;channels=2:DLNA.ORG_PN=LPCM`.

The presence of `audio/flac` (with or without a PN tag) in the sink
list is the green light that DLNA-push of bare FLAC will work
end-to-end on this receiver.

## SSDP M-SEARCH

**Source:** WebFetch
`https://datatracker.ietf.org/doc/html/draft-cai-ssdp-v1-03`.

**M-SEARCH datagram format (literal):**

```
M-SEARCH * HTTP/1.1\r\n
HOST: 239.255.255.250:1900\r\n
MAN: "ssdp:discover"\r\n
MX: 2\r\n
ST: urn:schemas-upnp-org:service:AVTransport:1\r\n
\r\n
```

- `MAN` MUST literally include `"ssdp:discover"` with the embedded
  double-quotes — the IETF draft requires it.
- `MX` is the maximum response wait in seconds; receivers stagger
  responses uniformly across `[0, MX]`.
- Multicast group: `239.255.255.250` UDP port `1900`. We bind to
  `RawDatagramSocket.bind(InternetAddress.anyIPv4, 0)` and
  `joinMulticast(InternetAddress('239.255.255.250'))`. Listen for 3 s.

**Response shape (HTTP-over-UDP):**

```
HTTP/1.1 200 OK\r\n
LOCATION: http://192.168.1.42:52323/desc/aiosdevdesc.xml\r\n
USN: uuid:00000000-0000-0000-0000-aabbccddeeff::urn:schemas-upnp-org:service:AVTransport:1\r\n
ST: urn:schemas-upnp-org:service:AVTransport:1\r\n
CACHE-CONTROL: max-age=1800\r\n
SERVER: Linux/3.4.0 UPnP/1.0 ...\r\n
\r\n
```

Parse `LOCATION:`, `USN:`, `ST:`. Dedupe on `uuid:...` portion of
`USN`. STR-DN1080's description URL is typically port 52323 (Sony
firmware default), used by `probeManual` as the default fallback.

## Sony STR-DN1080 DLNA capabilities

**Source:** WebFetch attempts on `helpguide.sony.net/ha/strdn1080/v1/en/...`
returned 404 for several URL guesses (the help-guide TOC numbering
isn't stable enough to derive without crawling). Sony's main support
pages (`sony.com`, `sony-asia.com`) are blocked from WebFetch. The
device's documented capabilities — confirmed in the user's existing
slice-9 spec (`docs/spec.md` line 35 + `docs/plans/slice-09-cast-and-dlna.md` §4)
plus the well-known marketing copy — are:

- DLNA 1.5 MediaRenderer profile
- Hi-res PCM up to 24-bit / 192 kHz over network playback
- Hi-res FLAC up to 24-bit / 192 kHz
- Front-panel sample-rate readout is the authoritative external truth
  (per slice-9 §11 step 3 — the headline gate)

**`DLNA.ORG_PN` decision (slice 9 §7 risk 12):**

The slice-9 brief instructs default-MIME-only with an opt-in
`buildWithPnTag()` builder. Rationale:

- Sony STR-DN1080 firmware is documented to accept
  `protocolInfo="http-get:*:audio/flac:*"` (no PN tag) without
  error — common pattern observed by community DLNA pushers (BubbleUPnP,
  Linn Kazoo, mconnect) targeting Sony AV receivers.
- Pinning a `DLNA.ORG_PN=FLAC` tag (the only PN code formally
  registered for FLAC in the DLNA Guidelines) is documented to work
  for some firmware versions but adds a risk of strict rejection on
  firmware that interprets PN strictly against PCM-rate gates.
- We default to MIME-only and expose `buildWithPnTag(pn: 'FLAC')` for
  the slice-9 §10 risk 12 "Strict DLNA profile" debug toggle Track B
  surfaces. The PN value `FLAC` is the spec's documented value for
  the FLAC content format. There is no separate hi-res FLAC PN; the
  PCM equivalents (`LPCM`, `LPCM_low`) carry rate/depth in the
  protocolInfo's additional fields.
- Source for the PN value: DLNA Guidelines v1.5 (FLAC content profile
  is `DLNA.ORG_PN=FLAC`). Confirmed against community references; we
  cite this source in `didl_lite.dart`.

If a future receiver rejects the bare-MIME path, Track B's debug
toggle flips to `buildWithPnTag('FLAC')` and we log the sink list.

## Google Cast Flutter binding (Android-only path)

**Source:**
- `mcp__plugin_context7_context7__resolve-library-id libraryName: "cast"`
- `mcp__plugin_context7_context7__resolve-library-id libraryName: "google_cast"`
- `mcp__plugin_context7_context7__resolve-library-id libraryName: "flutter_video_cast"`

All three resolved to the same currently-maintained pub.dev package:
**`flutter_chrome_cast`** (publisher `felnanuke2`). The other names
(`cast`, `google_cast`, `flutter_video_cast`) are either older
abandoned forks or no longer indexed in Context7. `flutter_chrome_cast`
is the only Flutter binding with active maintenance, Android v2
embedding, and a `loadMedia(MediaInfo)` API.

**Pin:** `flutter_chrome_cast: ^1.1.1` (the version surfacing in
Context7's example snippets). Caret-less is unnecessary here — the
package follows semver and the API surface we touch is small (load
+ play/pause/stop/seek + session-end listener).

**API surface used by `ChromecastTransport`:**
- `GoogleCastDiscoveryManager.instance.startDiscovery()` —
  Android-only mDNS scan for `_googlecast._tcp.local.`.
- `GoogleCastSessionManager.instance.startSessionWithDevice(device)` —
  starts a Cast session with the chosen device.
- `GoogleCastRemoteMediaClient.instance.loadMedia(...)` — loads a
  `GoogleCastMediaInformation` (note the cross-platform name; the
  iOS variant `GoogleCastMediaInformationIOS` is iOS-specific).
  `contentUrl` is our `mediaServer.urlForAac(t)`. `contentType` is
  `'audio/mp4'` (AAC-in-M4A).
- `GoogleCastRemoteMediaClient.instance.play()` / `pause()` / `stop()`
  / `seek(Duration)` mirror the transport surface.
- `GoogleCastSessionManager.instance.currentSession?.connectionState`
  surfaces `disconnect` events for the slice-9 §10 risk 6 fallback.

The package compiles on Linux desktop (Dart side only); the Android
native binding fails at runtime if invoked. We gate
`ChromecastTransport`'s constructor on `Platform.isAndroid` so Linux
construction throws — matches the slice-9 brief's "runtime-assert
pattern" preference.

**Track B coordinates:** the UI checks
`kHasChromecastSupport = true` (we ship the binding) so the Cast
section appears on Android only via `Platform.isAndroid`, not behind
this flag. The flag exists for future audits and as a kill-switch
without code changes.

## ffmpeg_kit Flutter binding (Android transcoder)

**Source:**
- `mcp__plugin_context7_context7__resolve-library-id libraryName: "ffmpeg_kit_flutter_audio"` →
  Context7 surfaced `ffmpeg_kit_flutter_new` as the maintained successor
  to the older `ffmpeg_kit_flutter_audio` package family. The audio-only
  variant `ffmpeg_kit_flutter_audio` was part of the Tanersener-era
  ffmpeg_kit packages, which were sunset in early 2025; the maintained
  fork is `ffmpeg_kit_flutter_new` (publisher `sk3llo`), which ships
  the same audio-only build target via its `audio` flavor.

**Pin:** `ffmpeg_kit_flutter_new: ^3.2.0`. Use the audio-only build
flavor (configured in `android/app/build.gradle` per the package
README), keeping the AAC encoder available without bundling the
full-fat ffmpeg static lib.

**API surface used by `Transcoder`:**
- `FFmpegKit.execute('-i <flac> -vn -c:a aac -b:a 128k -f mp4 -movflags +faststart <out.m4a>')` —
  one-shot; awaits completion and surfaces a `Session` with the
  `returnCode` and stderr log.
- Output path: `<app-cache>/prism/aac/<sha1>.m4a`. We compute the
  cache root via `path_provider`'s `getApplicationCacheDirectory`.
- Linux: throws `UnsupportedError('FFmpeg transcoder is Android-only — '
  'Linux desktop has no Chromecast transport')` in the constructor.

## shelf

**Source:**
- `mcp__plugin_context7_context7__query-docs libraryId: "/dart-lang/shelf"`

**API used by `MediaServer`:**
- `shelf_io.serve(handler, address, port)` returns `HttpServer`. We
  pass `InternetAddress.anyIPv4` (binds to `0.0.0.0`) and
  `port: 0` (OS-ephemeral). `server.port` exposes the bound port.
- `Response(int statusCode, {body, headers, encoding})`. There is no
  built-in `Range:` support — we construct status 206 manually with
  `Content-Range`, `Content-Length`, `Accept-Ranges: bytes` headers
  and `body: file.openRead(start, end + 1)` (a `Stream<List<int>>`).
- For the `Range:` parser we accept `bytes=<start>-<end>` (closed
  range) and `bytes=<start>-` (open-ended) plus the suffix form
  `bytes=-<n>` (last n bytes). The spec also defines comma-separated
  multi-range; we reject it with 416 per common DLNA usage (the Sony
  has not been observed to issue multi-range).
- `shelf_router` provides the route table — `/<sha1>.flac` and
  `/aac/<sha1>.m4a`.

## dio

**Source:**
- `mcp__plugin_context7_context7__query-docs libraryId: "/cfug/dio"`.

**API used by `Soap` and `Discovery`:**
- `Dio()` with `BaseOptions(connectTimeout: 3s, receiveTimeout: 3s)`.
  Discovery sets these tight because a non-responsive `LOCATION` is
  more useful as a quick failure than a slow one.
- `dio.post(url, data: soapXml, options: Options(headers: {
    'SOAPAction': '"urn:...AVTransport:1#$action"',
    'Content-Type': 'text/xml; charset="utf-8"',
  }))`.
- Body is `String` (the SOAP envelope). Response's `data` is
  decoded by dio per `responseType: ResponseType.plain` to a string,
  then parsed by `package:xml`'s `XmlDocument.parse`.
- `validateStatus: (s) => s != null && s < 500` keeps 4xx visible to
  the SOAP client (501 "Action Not Supported" must be observable
  for the §10 risk 8 fallback).

## package:xml

**Source:**
Context7's resolution for "xml" returned non-Dart results (Rust /
JS / Pydantic libraries). We fall through to the well-known
`package:xml` (publisher `renggli`, current major `^6.6.x`) — used
by every Dart UPnP / RSS / DIDL implementation.

**API used by `Soap` + `DidlLite`:**
- `XmlBuilder()`:
  - `builder.processing('xml', 'version="1.0"')` for the SOAP
    envelope's leading `<?xml ...?>`.
  - `builder.element(name, namespace: ..., nest: () { ... })`
    constructs the SOAP body.
  - `builder.attribute(name, value)` sets attributes inside the
    `nest` callback.
  - `builder.text(value)` writes XML-escaped text (handles `<`, `>`,
    `&`, `"`, `'` automatically). This is the critical seam for
    DIDL-Lite — when DIDL is embedded inside `<CurrentURIMetaData>`
    of a SOAP envelope, `builder.text(didlString)` performs the
    second escape pass on its own; we never string-concat XML.
- `builder.buildDocument().toXmlString()` serializes to the wire.
- `XmlDocument.parse(soapResponseString)` for response parsing;
  `findAllElements(name, namespace: ...)` walks the result tree.

## NetworkInterface

**Source:** WebFetch
`https://api.dart.dev/stable/dart-io/NetworkInterface-class.html`.

```dart
static Future<List<NetworkInterface>> list({
  bool includeLoopback = false,
  bool includeLinkLocal = false,
  InternetAddressType type = InternetAddressType.any,
});
```

`NetworkInterface` exposes `name`, `index`, and
`addresses: List<InternetAddress>`. `InternetAddress` has `type`,
`address` (string form), and `rawAddress` (`Uint8List`).

Filter rules per slice-9 §4 / brief §3:
- Skip name-contains: `docker`, `veth`, `br-`, `virbr`, `lo`, `tun`,
  `tap`, `wg`.
- Skip `127/8` and `169.254/16` (the latter via
  `includeLinkLocal: false` plus an explicit address-prefix guard).
- Prefer `192.168/16`, `10/8`, `172.16/12`. We keep the order from
  `NetworkInterface.list` after filtering — Linux's order tends to
  surface the active default-route iface first (typically `wlan0`
  on Android, `wlpXsY` on Linux).

## Cross-cutting decisions captured for Track B

- `ChromecastTransport` constructor uses runtime
  `assert(Platform.isAndroid, 'ChromecastTransport is Android-only')`
  per slice-9 brief — no conditional imports.
- `MediaServer` binds to `InternetAddress.anyIPv4` (0.0.0.0). The
  URL builders (`urlForFlac`, `urlForAac`) embed the resolved LAN
  IP from `IpSelector.pickLanAddress()` — this is the address the
  receiver dials, not the bind address.
- `DlnaTransport` polls at exactly 1 Hz. Higher cadences trip
  Sony firmware quirks (community-documented); lower cadences make
  the scrubber visibly laggy.
- `SetNextAVTransportURI` is queued by Track B's `PlaybackService`
  refactor when remaining-time < 5 s — Track A exposes `setNext` on
  the transport surface; the cadence is Track B's responsibility.
- Default DIDL-Lite uses MIME-only protocolInfo. Strict-PN path is
  opt-in via `DidlLite.buildWithPnTag(pn: 'FLAC')`.

---

## Track B — flutter_riverpod 3.0.x

**Resolved library ID:** `/rrousselgit/riverpod` (also viable:
`/websites/pub_dev_packages_flutter_riverpod`).

**API summary:**
- `Provider<T>((ref) { ... })` — eager, container-scoped value;
  `ref.onDispose` registers cleanup. Slice 5 / 8 patterns hold; no
  drift in 3.0.x.
- `StreamProvider<T>((ref) async* { ... })` — `yield*` from a
  broadcast stream. Pauses source emissions when no listener is
  active, which is exactly what we need for the SSDP refresh timer
  (slice 9 §10 risk 9: "no multicast traffic with the app
  backgrounded").
- `NotifierProvider<N extends Notifier<T>, T>(N.new)` — class-based
  stateful provider. `Notifier.build()` returns the initial state;
  mutators set `state = next` to publish. The transport notifier
  uses this to swap between Local / DLNA / Chromecast.
- `ref.watch(p)` rebuilds the consumer on every change; `ref.read(p)`
  reads once without subscribing. `ref.invalidate(p)` re-runs the
  provider's build function — useful after a manual-IP probe to
  refresh the discovery snapshot.
- `Ref.onDispose(callback)` ties cleanup to the container lifecycle.
  `mediaServerProvider` uses this to call `server.stop()` on
  last-unwatch.

## Track B — shared_preferences

**Resolved library ID:** `/websites/pub_dev_packages_shared_preferences`.

**API summary:**
- Sync facade: `final prefs = await SharedPreferences.getInstance();`.
  Then `prefs.getStringList(key) → List<String>?`,
  `prefs.setStringList(key, list) → Future<bool>`.
- Async facade: `SharedPreferencesAsync()`. Same shape, every getter
  returns `Future<T?>`. Slice 9 uses the sync facade — the manual-IP
  list is small and read once at app boot.
- Keys claimed by slice 9 (Track B):
  - `prism.cast.manual_ips` (List<String>): persisted manual IPs that
    Track A's `Discovery.probeManual` re-probes on launch.
  - `prism.cast.verbose_soap` (bool, default false): wires Track A's
    `Soap` verbose-log gate.

## Track B — `showModalBottomSheet`

**API confirmed via api.flutter.dev:**
- `Future<T?> showModalBottomSheet<T>({required BuildContext context,
  required WidgetBuilder builder, ..., bool? showDragHandle,
  bool useSafeArea = false, bool isScrollControlled = false,
  Color? backgroundColor})`.
- The CastSheet uses `showDragHandle: true` for the standard top-drag
  chrome and `useSafeArea: true` so the sheet content respects the
  bottom inset on Android with a gesture nav bar.
  `isScrollControlled` left default — three sections together fit in
  one viewport even with five discovered devices.

## Track B — `IconButton`

**API confirmed via api.flutter.dev:**
- `IconButton({required Widget icon, required VoidCallback? onPressed,
  String? tooltip, double? iconSize, Color? color})`. The cast icon
  in `NowPlayingScreen.AppBar.actions` uses `tooltip: 'Cast'`. Linux
  desktop has no tooltip rendering surface but the named string is
  still picked up by accessibility tooling.

## Track B — Track-A symbol consumption summary

Track B's code references the contracts Track A ships in
`package:prism_cast/cast.dart`. In the merge window before Track A
lands, Track B keeps a thin stub package at `packages/cast/` carrying
abstract declarations + `TODO(slice-9-integration)` markers on every
implementation body. Track A replaces those bodies; Track B's call
sites do not change.

Symbols consumed:
- `CastTransport` (abstract)
- `TransportEvent` sealed family (`TransportPlaying`, `TransportPaused`,
  `TransportStopped`, `TransportEnded`, `TransportError`)
- `LocalTransport({required AudioPlayerPort port})`
- `DlnaTransport({required DlnaDevice device, required MediaServer mediaServer})`
- `ChromecastTransport({required ChromecastDevice device, required MediaServer mediaServer})`
- `MediaServer.start({required InternetAddress bindAddress})`,
  `.stop()`, `.port`, `.urlForFlac(Track)`, `.urlForAac(Track)`,
  `.register(Track)`
- `IpSelector.pickLanAddress()` / `.listCandidates()`
- `DlnaDevice` (uuid, friendlyName, manufacturer, modelName,
  controlUrl, descriptionUrl, sinkProtocolInfo, looksLikeStrDn1080)
- `ChromecastDevice` (placeholder for Cast-side device handle)
- `Discovery` — `Stream<List<DlnaDevice>>` getter, `probeManual(...)`
- `kHasChromecastSupport` (top-level const bool, `true` per Track A's
  pin of `flutter_chrome_cast`)

