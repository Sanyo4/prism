# Slice 9 — Cast & DLNA (STR-DN1080 lossless + Android Chromecast fallback)

## 1. Context

Slice 9 gives Prism a network output surface. Today the app owns a
local `AudioPlayer` that writes to the OS audio stack; slice 9 makes
that one of three interchangeable output transports so the same UI
can route a track to (a) the local speaker, (b) a DLNA receiver on
the LAN, or (c) a Chromecast device when running on Android.

The primary target is the user's **Sony STR-DN1080** AV receiver,
reachable over DLNA/UPnP on both Linux laptop and Android phone. The
STR-DN1080 is the reason this slice exists: its Chromecast input
silently downsamples 24/96 FLAC, so the existing "cast from
Symphonium" workflow loses the hi-res content the rest of the app is
built to preserve. DLNA push bypasses that — the receiver pulls the
file from an embedded HTTP server on the device and renders at
source rate. The front panel then reports `96 kHz / 24 bit`, which
is the external signal that the slice worked.

Chromecast remains a convenience target on Android only, for pushing
to a kitchen speaker or TV. It cannot carry 24/96 FLAC reliably, so
the Chromecast transport transcodes to 128 kbps AAC and is labeled
**lossy** in every UI surface.

Everything lives behind a single `abstract class CastTransport`.
`PlaybackService` (slice 1) keeps one `currentTransport` reference;
all `play / pause / seek / setTrack` calls go through it. Swapping
transports is a `setTransport(...)` call, nothing more.

## 2. Goals / Non-goals

**Goals**

- `packages/cast` — pure Dart + Flutter (Android plugin channel).
  Exports `CastTransport`, `LocalTransport`, `DlnaTransport`,
  `ChromecastTransport`, plus discovery + session types.
- Lossless push to the STR-DN1080: a 24/96 FLAC plays from the app
  and the receiver's front panel reports `96 kHz / 24 bit`. This is
  the external truth condition for "slice 9 works."
- SSDP discovery on startup and refreshed every 5 minutes while the
  app is foregrounded.
- Embedded `MediaServer` (`shelf`) serves the selected track at
  `http://<lan-ip>:<port>/<audio-sha1>.flac`, honoring HTTP `Range:`
  requests so receivers can scrub, buffer, and probe.
- SOAP AVTransport v1 client: `SetAVTransportURI`, `Play`, `Pause`,
  `Seek`, `Stop`, `SetNextAVTransportURI`, `GetTransportInfo`,
  `GetPositionInfo`. Polled at 1 Hz while a DLNA session is active.
- Gapless on DLNA via `SetNextAVTransportURI` queued ~5 s before the
  current track ends.
- DIDL-Lite metadata on `SetAVTransportURI` carrying the correct
  `res@protocolInfo` MIME + `DLNA.ORG_PN` tag for hi-res FLAC so the
  STR-DN1080 accepts the stream at source rate (exact PN value
  confirmed during the §4 refresh and pinned inline in
  `didl_lite.dart`).
- `ChromecastTransport` on Android only (`Platform.isAndroid`). Uses
  the native Google Cast SDK via a Flutter plugin (chosen during §4
  refresh). Transcodes to 128 kbps AAC through a parallel
  `MediaServer` route.
- IP selection picks the LAN-facing interface automatically, skipping
  loopback, docker bridges, and virtual adapters. Ambiguous cases
  surface a picker. Manual IP entry lives in Settings as a fallback.
- UI cast icon in `NowPlayingScreen`. Tap opens a bottom sheet with
  three sections — *Local*, *Speakers (DLNA)*, *Cast devices
  (Android only)*.
- Settings gains a "Cast & DLNA" section: discovered devices,
  manual-IP field, and an informational "Chromecast is always lossy
  in this slice" row.

**Non-goals**

- **AirPlay.** No reliable Linux source library and no mature Dart
  RAOP sender; bespoke hi-res ALAC sender is out of scope.
- **Cloud relay / remote control from outside the LAN.** DLNA is
  LAN-only per spec invariant.
- **Multi-room group output.** Single receiver at a time.
- **Chromecast on Linux.** Caps hi-res; a second lossy path on the
  platform that already has DLNA isn't worth the maintenance.
- **Raw FLAC to Chromecast.** Inconsistent across firmware; we
  transcode.
- **DSD / MQA / DoP.** STR-DN1080 does not decode these.
- **Arbitrary UPnP MediaRenderer beyond STR-DN1080.** Standard
  surface; only STR-DN1080 is in verification.
- **In-app transcode for DLNA.** DLNA streams the file as-is.
- **Remote volume control on the receiver.** `RenderingControl` is
  deferred.

## 3. Dependencies

Depends on: 1
Unblocks: —

Slice 1 contributes `Track`, `PlaybackService`, `QueueService`, and
the Riverpod provider graph; slice 9 changes `PlaybackService` to
hold a `Transport` instead of an `AudioPlayer` directly. Leaf node.
Slices 2–8 are not required.

## 4. Docs to refresh

Run every command and save a ≤5-line API summary per entry in a
scratch file. UPnP and the Cast SDK both drift; local memory is
unreliable.

### UPnP AVTransport v1 service spec

- `WebFetch https://upnp.org/specs/av/av1/` — follow links to
  `UPnP-av-AVTransport-v1-Service.pdf` (version-pinned URL; record in
  scratch). Also `UPnP-av-ConnectionManager-v1-Service.pdf` for
  `GetProtocolInfo`'s return shape.

**API summary reminder:** actions are `SetAVTransportURI`,
`SetNextAVTransportURI`, `Play(Speed="1")`, `Pause`, `Stop`,
`Seek(Unit="REL_TIME", Target=HH:MM:SS)`, `GetTransportInfo`,
`GetPositionInfo`. `InstanceID` is `0` for a single-stream renderer.
`CurrentURIMetaData` is DIDL-Lite XML, escaped inside SOAP. SOAPAction
header is the full URN `"urn:schemas-upnp-org:service:AVTransport:1#<Action>"`.

### SSDP discovery

- `WebFetch https://datatracker.ietf.org/doc/html/draft-cai-ssdp-v1-03`
  — the closest canonical M-SEARCH reference.
- `WebFetch https://openconnectivity.org/upnp-specs/UPnP-arch-DeviceArchitecture-v1.1.pdf` for UPnP 1.1 discovery.

**API summary reminder:** M-SEARCH is a UDP datagram to
`239.255.255.250:1900`, headers `HOST`, `MAN: "ssdp:discover"`, `MX:
2`, `ST: urn:schemas-upnp-org:service:AVTransport:1`. Responses are
unicast HTTP/1.1-over-UDP with `LOCATION:` pointing at the device
description XML. Parse `LOCATION`, GET with `dio`, walk the service
list for AVTransport's `controlURL` and `serviceType`.

### Sony STR-DN1080 DLNA capabilities

- `WebFetch https://helpguide.sony.net/ha/strdn1080/v1/en/index.html`
  — navigate to "Enjoying Music Stored on Your Computer" and
  "Playing audio files in a high-resolution audio format".

**API summary reminder:** DLNA 1.5 MediaRenderer, hi-res PCM and
FLAC up to 24-bit / 192 kHz. Front-panel sample-rate readout is
authoritative. The exact `DLNA.ORG_PN` value is version-sensitive;
confirm against the description's `<dlna:X_DLNADOC>` block and the
`GetProtocolInfo` sink list, then pin in `didl_lite.dart`. If the
sink list tolerates it, omit `DLNA.ORG_PN` and rely on MIME alone
— Sony firmware commonly accepts `protocolInfo="http-get:*:audio/flac:*"`.

### Google Cast SDK for Android (Flutter binding)

- `WebFetch https://developers.google.com/cast/docs/android_sender`
  for the current sender API.
- Candidate Flutter packages — run `resolve-library-id` + `query-docs`
  on each and pick the one with active maintenance, Android embedding
  v2, and a `loadMedia` API accepting a content URL + MIME + duration:
  `cast`, `flutter_video_cast`, `google_cast`. Pin name + version
  inside `chromecast_transport.dart`.

**API summary reminder:** discover via mDNS
(`_googlecast._tcp.local.`) → `CastContext` →
`SessionManager.startSession(device)` →
`RemoteMediaClient.load(MediaLoadRequestData(...))`. `contentType`
is `audio/mp4` (AAC in M4A) for the transcode path. Disconnects
surface via a session listener; reconnect is manual.

### `shelf` (Dart HTTP server)

- `resolve-library-id libraryName: "shelf"` +
  `query-docs topic: "Server io handler Response headers Range file streaming"`. Fallback: `WebFetch https://pub.dev/documentation/shelf/latest/`.

**API summary reminder:** `shelf_io.serve(handler, address, port)`.
No built-in `Range:` support — construct `Response` with status 206,
headers `Content-Range`, `Content-Length`, `Accept-Ranges: bytes`,
body `Stream<List<int>>` from `File.openRead(start, end+1)`.

### `dio`

- `resolve-library-id libraryName: "dio"` +
  `query-docs topic: "post headers content-type xml text plain timeout"`.

**API summary reminder:** `dio.post(url, data: soapXml, options:
Options(headers: {'SOAPAction': '"<urn>#<action>"', 'Content-Type':
'text/xml; charset="utf-8"'}))`. Body is a `String`. Response `data`
is parsed via `package:xml`.

### `package:xml`

- `resolve-library-id libraryName: "xml"` +
  `query-docs topic: "XmlBuilder XmlDocument findAllElements text escape"`.

**API summary reminder:** Use `XmlBuilder` for SOAP envelope and
DIDL-Lite. DIDL is embedded as a string inside SOAP's
`<CurrentURIMetaData>` and so is XML-escaped a second time. Build
DIDL, `toXmlString()`, then pass through `XmlBuilder.text(...)` for
the outer envelope — it handles escaping.

### Dart `NetworkInterface`

- `WebFetch https://api.dart.dev/stable/dart-io/NetworkInterface-class.html`.

**API summary reminder:** `NetworkInterface.list(includeLoopback:
false, includeLinkLocal: false, type: InternetAddressType.IPv4)`.
Filter names containing `docker`, `veth`, `br-`, `virbr`, `lo`,
`tun`, `tap`, `wg` and any address in `127/8` or `169.254/16`.
Prefer the interface carrying the default route — typically `wlan0`
on Android; on Linux, one with a non-link-local IPv4 in `192.168/16`,
`10/8`, or `172.16/12`.

## 5. Architecture & data flow

```
               apps/mobile (Riverpod ProviderScope)
               ┌──────────────────────────────────────┐
               │ NowPlayingScreen ── cast icon ─► CastSheet │
               │ SettingsScreen ── "Cast & DLNA" section    │
               └──────────────────┬───────────────────┘
                                  │
                  ┌───────────────┼──────────────────┐
                  ▼               ▼                  ▼
         playbackServiceProvider  castDiscoveryProvider  transportProvider
                  │                                      │
                  ▼                                      │
         ┌─────────────────────┐                         │
         │ PlaybackService     │ ◄── setTransport(...) ──┘
         │  currentTransport   │
         └──────────┬──────────┘
                    │ play/pause/seek/setTrack/setNext
                    ▼
         ┌─────────────────────────────┐
         │ abstract CastTransport      │
         └──────────┬──────────────────┘
          ┌─────────┼──────────────┐
          ▼         ▼              ▼
     ┌─────────┐┌────────────┐┌──────────────────┐
     │ Local   ││ Dlna       ││ Chromecast       │
     │ (slice1 ││ (SSDP+SOAP ││ (Android only,   │
     │  player)││  +Media-   ││  Cast SDK + AAC  │
     │         ││  Server)   ││  via MediaServer)│
     └─────────┘└─────┬──────┘└────────┬─────────┘
                      ▼                 ▼
                 STR-DN1080         Chromecast device
                 (FLAC, native)     (AAC 128 kbps)
```

**DLNA SOAP sequence (per track).**

```
app                        MediaServer              STR-DN1080
 │ compute http://<lan>:<p>/<sha1>.flac                     │
 │─ SetAVTransportURI(URI + DIDL-Lite) ────────────────────►│
 │◄ 200 OK ─────────────────────────────────────────────────│
 │─ Play ──────────────────────────────────────────────────►│
 │◄ 200 OK ─────────────────────────────────────────────────│
 │                          │◄── GET /<sha1>.flac Range: 0- │
 │                          │── 206 Partial, streams ──────►│
 │─ every 1s: GetTransportInfo / GetPositionInfo ──────────►│
 │◄ CurrentTransportState, RelTime, duration ───────────────│
 │ when remaining < 5s:                                     │
 │─ SetNextAVTransportURI(next, DIDL-Lite) ────────────────►│
 │◄ 200 OK ─────────────────────────────────────────────────│
 │ track ends → receiver auto-advances to NextAVTransportURI│
 │ poll loop sees PLAYING on new URI                        │
 │ app: QueueService.advance(); setNext(peekAfter)          │
```

## 6. File layout (new files only)

```
/packages/cast/pubspec.yaml                               # deps: shelf, dio, xml, crypto + cast plugin (android)
/packages/cast/lib/cast.dart                              # barrel export
/packages/cast/lib/src/cast_transport.dart                # abstract class + TransportEvent + CastSession
/packages/cast/lib/src/local_transport.dart               # pass-through to slice-1 AudioPlayer
/packages/cast/lib/src/net/ip_selector.dart               # LAN interface picker
/packages/cast/lib/src/net/media_server.dart              # shelf, Range-honoring handler
/packages/cast/lib/src/net/transcoder.dart                # FLAC→AAC 128 kbps for Chromecast
/packages/cast/lib/src/dlna/discovery.dart                # SSDP M-SEARCH + description fetch
/packages/cast/lib/src/dlna/dlna_device.dart              # parsed description + control URL
/packages/cast/lib/src/dlna/soap.dart                     # envelope builder + AVTransport client
/packages/cast/lib/src/dlna/didl_lite.dart                # DIDL-Lite builder; hi-res FLAC PN pinned here
/packages/cast/lib/src/dlna/dlna_transport.dart           # SetAVTransportURI + Play + poll + next handoff
/packages/cast/lib/src/chromecast/chromecast_device.dart  # mDNS result + Cast SDK handle
/packages/cast/lib/src/chromecast/chromecast_transport.dart # load/play/pause via sender SDK
/packages/cast/test/media_server_test.dart                # Range handler correctness
/packages/cast/test/didl_lite_test.dart                   # DIDL-Lite escape + PN tag
/packages/cast/test/soap_test.dart                        # envelope shape + SOAPAction header
/apps/mobile/lib/widgets/cast_sheet.dart                  # bottom sheet with three sections
/apps/mobile/lib/providers/cast_providers.dart            # discoveryProvider, transportProvider
/apps/mobile/lib/settings/cast_section.dart               # devices + manual IP + lossy notice
```

Edits outside the new tree: `playback_service.dart` gains a
`currentTransport` field and delegates; `settings_screen.dart`
gains one `ListTile` opening `cast_section.dart`;
`now_playing_screen.dart` gains the cast icon in the AppBar actions.

## 7. Interfaces & key types

```dart
// packages/cast/lib/src/cast_transport.dart
sealed class TransportEvent { const TransportEvent(); }
class TransportPlaying extends TransportEvent { final Duration position; final Duration? duration; }
class TransportPaused  extends TransportEvent { final Duration position; }
class TransportStopped extends TransportEvent { final Object? reason; }
class TransportEnded   extends TransportEvent { const TransportEnded(); }
class TransportError   extends TransportEvent { final Object error; final StackTrace? stack; }

abstract class CastTransport {
  String get id;                       // 'local' | 'dlna:<uuid>' | 'cast:<id>'
  String get displayName;
  bool get isLossless;                 // false for ChromecastTransport
  Stream<TransportEvent> get events;   // broadcast
  Future<void> setTrack(Track t);
  Future<void> setNext(Track? t);      // null clears queued next
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration to);
  Future<void> stop();
  Future<void> dispose();
}

class DlnaDevice {
  final String uuid;                   // from USN
  final String friendlyName;           // from description XML
  final Uri descriptionUrl, controlUrl;
  final Set<String> sinkProtocolInfo;  // from GetProtocolInfo
  final String manufacturer, modelName;
  bool get looksLikeStrDn1080 => modelName.contains('STR-DN1080');
}

class DlnaTransport implements CastTransport {
  DlnaTransport({required this.device, required this.mediaServer});
  // Internal: Timer.periodic(1s) → GetTransportInfo + GetPositionInfo.
  // Schedules SetNextAVTransportURI when duration - position < 5s and
  // a non-null next track is queued.
}

class ChromecastTransport implements CastTransport {
  ChromecastTransport({required this.device, required this.mediaServer}) {
    assert(Platform.isAndroid, 'ChromecastTransport is Android-only');
  }
  @override bool get isLossless => false;
}

class MediaServer {
  Future<void> start({required InternetAddress bindAddress});
  Future<void> stop();
  int get port;
  Uri urlForFlac(Track t);             // http://<ip>:<port>/<sha1>.flac
  Uri urlForAac(Track t);              // http://<ip>:<port>/aac/<sha1>.m4a
}
```

DIDL-Lite template (pin the exact `DLNA.ORG_PN` after §4 refresh; a
`kUseDlnaOrgPn` compile-time toggle lets us fall back to bare MIME
when the sink list accepts `audio/flac` without a PN):

```
http-get:*:audio/flac:DLNA.ORG_PN={pn};DLNA.ORG_OP=01;DLNA.ORG_FLAGS=01700000000000000000000000000000
```

`PlaybackService` (modified): holds `CastTransport currentTransport`;
`setTransport(t)` stops the old one, preserves position + playing
flag, and resumes on the new one. `play / pause / seek / setTrack /
setNext` all delegate.

## 8. Implementation steps

Each step names its files and states a one-line pass criterion. Order
is MediaServer first (easiest to smoke-test with `curl -r`), then
discovery, then SOAP, then integration, then Chromecast last.

1. **Package skeleton + barrel.** `packages/cast/pubspec.yaml` deps
   `shelf`, `shelf_io`, `dio`, `xml`, `crypto`, `path_provider`; dev
   `test`. **Pass:** `melos bootstrap`; `dart analyze packages/cast`
   clean.

2. **`CastTransport` + `TransportEvent`.** Declare sealed events and
   abstract class. **Pass:** `dart analyze` clean.

3. **`IpSelector`.** `pickLanAddress()` + `listCandidates()`; filter
   loopback, link-local, `docker`, `virbr`, `veth`, `tun`, `tap`,
   `wg`. **Pass:** unit picks `192.168.1.42` over `172.17.0.1` and
   `169.254.*`.

4. **`MediaServer` with `Range:` support.** `shelf_io.serve` on
   ephemeral port. GET `/<sha1>.flac` streams with `Accept-Ranges:
   bytes` and parses `Range: bytes=<start>-<end>?` into 206 with
   correct headers. **Pass:** `media_server_test.dart` covers (a)
   full GET, (b) mid-range, (c) suffix range, (d) 404 on unknown
   sha1.

5. **`LocalTransport`.** Thin wrapper around slice-1's `AudioPlayer`
   (held externally). Translates player state into `TransportEvent`.
   `isLossless = true`. **Pass:** slice-1 verification §11 items 4–7
   still pass with delegation in place.

6. **`PlaybackService` transport seam.** Replace direct
   `AudioPlayer` calls with `currentTransport.*`. `loadQueue` calls
   `setTrack(current)` then `setNext(peekAfterCurrent)`.
   `setTransport` carries position + playing flag across the swap.
   **Pass:** swap to a `TestTransport` preserves position ±100 ms.

7. **SSDP M-SEARCH.** `RawDatagramSocket.bind(anyIPv4, 0)`, send to
   `239.255.255.250:1900` with the AVTransport ST, collect for 3 s,
   parse `LOCATION:` and `USN:`. **Pass:** on the user's LAN, list
   contains a `LOCATION` on a 192.168.x address.

8. **Device description fetch.** `dio.get` each location; parse XML
   for `friendlyName`, `manufacturer`, `modelName`, AVTransport
   `controlURL` (resolved against `<URLBase>` or the description
   URL), ConnectionManager `controlURL`. Call `GetProtocolInfo`;
   store the sink CSV. **Pass:** `DlnaDevice(modelName:
   'STR-DN1080', looksLikeStrDn1080: true)` on the user's LAN.

9. **SSDP refresh timer.** `DiscoveryService` broadcast
   `Stream<List<DlnaDevice>>`; M-SEARCH on start and every 5 min
   while subscribed; dedupe on `uuid`; pause while app is background.
   **Pass:** list updates when the receiver is powered off then on;
   no multicast traffic with the app backgrounded.

10. **SOAP envelope + AVTransport client.** `buildEnvelope(action,
    instanceId, args)` → XML string; `callAction(device, action,
    args)` posts with `SOAPAction` and parses the response.
    Implement the nine actions listed in §2. **Pass:**
    `soap_test.dart` asserts envelope byte-equality against a
    recorded `SetAVTransportURI` fixture and parses a recorded
    `GetTransportInfo` into `{state: 'PLAYING', speed: '1'}`.

11. **DIDL-Lite builder.** Emit `<DIDL-Lite><item>` with
    `<dc:title>`, `<upnp:class>object.item.audioItem.musicTrack`,
    `<res protocolInfo="..." size="..." duration="HH:MM:SS.fff"
    sampleFrequency="..." bitsPerSample="..."
    nrAudioChannels="...">http://...</res>`. Pin the FLAC PN (or
    MIME-only fallback) from §4. **Pass:** `didl_lite_test.dart`
    asserts `XmlDocument.parse` round-trip and SOAP double-escape
    survival.

12. **`DlnaTransport`.** Wires MediaServer + SOAP + device. On
    `setTrack`: URL → DIDL → `SetAVTransportURI`. On `setNext(t)`:
    `SetNextAVTransportURI` (empty URI clears). `Timer.periodic(1s)`
    drives the poll loop; emits `TransportPlaying / Paused`; when
    RelTime ~ end and state remains `PLAYING` on the next URI,
    emits `TransportEnded`. **Pass:** 24/96 FLAC plays on
    STR-DN1080; pause/resume/seek work; front panel reports `96 kHz
    / 24 bit`.

13. **Gapless handoff.** `PlaybackService` computes remaining via
    poll; when < 5 s and next track queued, `setNext(next)`. On
    `TransportEnded`, `QueueService.advance()` and
    `setNext(peekAfter)`. **Pass:** known gapless album pair is
    audibly gapless on STR-DN1080; no "stop" glyph flash.

14. **Cast UI.** `cast_sheet.dart`: *Local* (always present),
    *Speakers (DLNA)* from `discoveryProvider`, *Cast devices
    (Android only)* hidden on Linux with a "scanning…" subtitle
    during discovery on Android. Tap dispatches to
    `transportProvider.setTransport`. Cast icon in `NowPlayingScreen`
    opens the sheet. Settings mirrors the sheet plus manual-IP field
    and lossy notice. **Pass:** picking STR-DN1080 starts a DLNA
    session; picking Local restores built-in output.

15. **Chromecast plugin + transcode route.** `pubspec` adds the
    plugin picked in §4, gated `platforms: [android]`.
    `ChromecastTransport` calls `load(MediaInfo)` pointing at
    `mediaServer.urlForAac(t)`. `transcoder.dart` runs `ffmpeg -i
    <flac> -c:a aac -b:a 128k -f mp4 -` piped into the response body
    via an Android `ffmpeg_kit`-family package (exact name pinned
    during §4). On Linux, `ChromecastTransport` is excluded at
    compile time; the UI section is hidden. **Pass:** on Android, a
    Chromecast device appears, plays the current track at AAC
    quality, with the "always lossy" notice visible.

16. **Manual-IP fallback.** Settings text field; on save,
    `DiscoveryService.probeManual(ip)` GETs the description on the
    STR-DN1080's known port (`52323`) and common paths; if one
    parses with AVTransport present, it joins the device list.
    **Pass:** on a network with multicast blocked (LTE hotspot with
    client isolation), typing the receiver's IP yields a working
    session.

17. **Run §11.** **Pass:** every numbered item is green.

## 9. Alternatives considered

**Chromecast as primary hi-res path.** Rejected. Chromecast's audio
receiver does not honor hi-res FLAC reliably — the STR-DN1080's
Chromecast input caps to 16/48 regardless of source, which is the
exact behavior this slice exists to bypass.

**Roon RAAT.** Rejected on scope. RAAT is the cleanest hi-res
protocol for home audio but is proprietary, requires a Roon Core on
the network, and its SDK is not published as a Dart / Flutter
package. The STR-DN1080 is Roon-tested but not Roon-required — DLNA
already carries the lossless payload.

**AirPlay (RAOP).** Rejected. No mature Dart RAOP sender exists; the
ecosystem's JS/Python libraries are all receiver-side. A sender
would require implementing ALAC encoding and the encrypted handshake
on both Linux and Android. STR-DN1080 supports AirPlay 2, but the
engineering cost does not clear the bar when DLNA covers hi-res.

**Reconsider criteria.** Revisit (a) Chromecast-as-primary only if
Sony ships firmware that passes 24/96 bit-perfect (unlikely); (b)
Roon RAAT if the user adopts Roon Core on the laptop; (c) AirPlay
if a maintained Dart RAOP sender appears on pub.dev with a
permissive license and hi-res ALAC support.

## 10. Edge cases & known risks

| # | Risk | Mitigation |
|---|---|---|
| 1 | Multicast blocked on the user's network. M-SEARCH returns nothing. | Settings manual-IP field (step 16); cached in `SharedPreferences` and probed on launch. |
| 2 | STR-DN1080 firmware quirks, visible only at runtime. | `SoapClient` logs every request + response body at verbose level gated by a Settings toggle; `DlnaCompat` shim isolates quirk branches. |
| 3 | Chromecast Cast SDK bloats the APK. | Cast plugin declared `platforms: [android]` only; Linux build does not pull it. ABI split in `build.gradle` keeps native libs minimal. |
| 4 | `MediaServer` port collision on a busy dev laptop. | `port: 0` binds OS-ephemeral by default; `urlForFlac` recomputes against `mediaServer.port` each call. |
| 5 | STR-DN1080 probes metadata via several small `Range:` GETs before playback. | `shelf` handler uses `File.openRead(start, end+1)` — zero buffering; streams in 64 KiB chunks. Covered by `media_server_test`. |
| 6 | Chromecast mid-track disconnect (Wi-Fi roam, device power-save). | `ChromecastTransport` auto-reconnects once; on second failure, emits `TransportError`, UI shows "Cast lost — fell back to Local" banner, `PlaybackService` calls `setTransport(LocalTransport)`. |
| 7 | Android Wi-Fi sleep dropping the SOAP poll loop. | `audio_service`'s foreground service keeps the radio warm during active playback. Timer-driven poll is fine because the app is foreground. |
| 8 | `SetNextAVTransportURI` unsupported on some renderers. | On `501 Action Not Supported`, fall back to hard-next: on `TransportEnded`, compute next URL + `SetAVTransportURI` + `Play`. STR-DN1080 is known to support Next. |
| 9 | IPv4 interface changes mid-session (VPN up, Wi-Fi swap). | `MediaServer` binds to `0.0.0.0` on Linux and the specific Wi-Fi address on Android; `IpSelector.pickLanAddress()` re-runs on connectivity changes. One-time "reselect device" UX is acceptable. |
| 10 | SHA1 collision in `urlForFlac` path. | File content is identical by definition; `MediaServer` needs only a consistent lookup. No `path` on the URL is deliberate — cleaner and avoids path leakage. |
| 11 | Manual-IP probe hitting a non-UPnP server (e.g. printer). | `probeManual` requires the description XML to contain `urn:schemas-upnp-org:service:AVTransport:1`; otherwise surfaces `NotAMediaRenderer`. |
| 12 | Wrong `DLNA.ORG_PN` PN tag for 24/192 on a strict receiver. | Two builders in `didl_lite.dart` — `withPnTag()` and `mimeOnly()` — plus a "Strict DLNA profile" debug toggle. STR-DN1080 accepts bare MIME. |

## 11. Verification

Run in order. Requires STR-DN1080 powered on, on the same LAN as the
laptop and phone, and a known 24-bit / 96 kHz FLAC in the library.

1. `melos run test` in `packages/cast` passes: `media_server_test`,
   `didl_lite_test`, `soap_test`.
2. `flutter run -d linux` starts; the cast icon appears in
   `NowPlayingScreen`. Open the sheet; within 3 s, the STR-DN1080
   appears under "Speakers (DLNA)".
3. Pick the STR-DN1080. Play a 24/96 FLAC. The receiver's front
   panel reports `96 kHz / 24 bit`. **This is the gate.**
4. Pause from the app; front panel stops; resume; playback
   continues from the paused position (±200 ms).
5. Scrub with the slider; receiver reports the new position; audio
   resumes from the scrubbed position.
6. Skip to next within an album where the next track is also 24/96
   FLAC; transition is gapless — no audible silence, no front-panel
   "stop" glyph flicker. Uses `SetNextAVTransportURI`.
7. Repeat steps 3–6 on the Pixel 9 Pro Fold; outcomes match.
8. On the Pixel, open the cast sheet; a Chromecast speaker appears
   under "Cast devices (Android only)". Pick it; the current track
   plays at AAC quality; the sheet header shows "Lossy". The
   STR-DN1080 does not appear in the Chromecast section.
9. On Linux, the cast sheet shows no "Cast devices" section at all.
10. Switch the phone to a network that blocks multicast (LTE
    hotspot with client isolation); type the STR-DN1080's LAN IP
    into Settings → Cast & DLNA → manual IP; save; the receiver
    appears in the sheet; DLNA end-to-end works.
11. While a DLNA session is active, force-kill the app from
    recents; the receiver stops within one poll cycle.
12. Re-launch; the app does not re-bind to the prior transport —
    Local is the default on cold start.
13. Chromecast mid-track disconnect: interrupt Wi-Fi on the
    Chromecast; within ~10 s the UI shows "Cast lost — fell back
    to Local"; local playback continues from roughly the same
    position.
14. Verbose SOAP log toggle: enable; `SetAVTransportURI` body
    visible in `flutter logs`; disable; no further bodies appear.

## 12. Definition of done

- [ ] `packages/cast` exists with `CastTransport` abstract class,
  `LocalTransport`, `DlnaTransport`, `ChromecastTransport` (Android
  only), plus the net / DLNA / Chromecast subtrees from §6.
- [ ] `flutter analyze` clean on `packages/cast` and `apps/mobile`.
- [ ] `melos run test` passes `media_server_test`, `didl_lite_test`,
  `soap_test`, plus slice-1 tests preserved through the transport-
  seam refactor.
- [ ] `PlaybackService` holds `currentTransport`; `play / pause /
  seek / setTrack / setNext` delegate; `setTransport` preserves
  position ±100 ms in the `TestTransport` unit.
- [ ] SSDP M-SEARCH discovers the STR-DN1080 within 3 s of the
  cast sheet opening.
- [ ] A 24/96 FLAC pushed to the STR-DN1080 is reported as `96 kHz
  / 24 bit` on the receiver's front panel — the slice's headline
  condition.
- [ ] Pause, resume, seek, and track-skip work from the app with
  the receiver as the output.
- [ ] Gapless transition between consecutive 24/96 FLAC tracks via
  `SetNextAVTransportURI`.
- [ ] On Android, a Chromecast device plays the current track
  transcoded to 128 kbps AAC.
- [ ] On Linux, the "Cast devices" section is not shown.
- [ ] Manual IP entry in Settings → Cast & DLNA probes a DLNA
  description URL and surfaces the receiver into the device list
  on success.
- [ ] The `DLNA.ORG_PN` choice for hi-res FLAC on STR-DN1080 is
  pinned inline in `didl_lite.dart`, with the source (device
  description XML or `GetProtocolInfo` sink list) cited in a
  comment.
- [ ] `ChromecastTransport` is gated by `Platform.isAndroid`;
  constructing it on Linux throws an assertion.
- [ ] The §4 "Docs to refresh" commands were executed at session
  start and "API summary" notes written before any Dart file was
  touched. Chosen Google Cast Flutter package pinned by name and
  version in the commit message.
- [ ] No deferred-work sentinels remain — every unfinished item is
  scoped outside this slice (AirPlay, Roon, multi-room,
  RenderingControl volume).
