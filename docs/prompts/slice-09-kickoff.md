# Slice 9 kickoff prompt

Paste the entire fenced block below into a fresh Claude Code chat opened
against `/home/sanyo/Projects/music-player`.

**Prerequisites:** slice 1 merged to `main`. Sony STR-DN1080 powered on and
on the same LAN as the laptop / phone for verification. Independent of
slices 2–8 — run any time after slice 1.

---

````
I'm executing slice 9 of Prism: cast & DLNA — lossless push to a Sony STR-DN1080 receiver over UPnP AVTransport, with an Android-only Chromecast fallback. The repo is at /home/sanyo/Projects/music-player. Slice 1 is merged. The Sony STR-DN1080 is on the LAN.

Today the app owns a local `AudioPlayer` writing to the OS audio stack. This slice makes that one of three interchangeable output transports behind a single `abstract class CastTransport`. PlaybackService keeps one `currentTransport` reference; all play/pause/seek/setTrack go through it. Swapping is `setTransport(...)` and nothing more.

## Read in order before doing anything else

1. /home/sanyo/Projects/music-player/docs/spec.md — "DLNA is LAN-only" invariant; "Chromecast is lossy and Android-only" invariant.
2. /home/sanyo/Projects/music-player/docs/plans/README.md — slice index.
3. /home/sanyo/Projects/music-player/docs/plans/slice-09-cast-and-dlna.md — the slice you're executing.

## Confirm the receiver is reachable

Before code: ping the Sony's IP from the laptop (find it in your router admin or the receiver's network settings menu). The STR-DN1080 should respond. SSDP discovery will be tested in code, but a basic ping confirms LAN routing.

## Before writing ANY Dart

Slice 9 §4 lists docs to refresh: **UPnP AVTransport v1 service spec** (PDF from upnp.org — DIDL-Lite res@protocolInfo + DLNA.ORG_PN values for hi-res FLAC are critical), SSDP discovery (RFC 5999 draft + reference implementations), `shelf` (the embedded HTTP server with HTTP Range support), the chosen Flutter Cast SDK plugin (you'll pick during the refresh — check pub.dev for an active maintainer; the historical `flutter_cast` plugin has been variably maintained), and the **Sony STR-DN1080 help guide** for documented DLNA capabilities (max sample rate, supported codecs, known protocolInfo gotchas). Write ≤5-line summaries; the exact `DLNA.ORG_PN` value for 24/96 FLAC must be pinned inline in `didl_lite.dart` from the refresh, not from memory.

## Execution

Follow slice 9 §8 step-by-step. New package: `packages/cast` — pure Dart + Flutter (Android plugin channel for Chromecast only). PlaybackService gets a `setTransport(...)` method.

## Hard constraints

- **DLNA is LAN-only.** No cloud relay, no remote control from outside the LAN, ever. Spec invariant.
- **Hi-res lossless via DLNA only.** Chromecast on Android transcodes to 128 kbps AAC and is labeled **lossy** in every UI surface. Not optional — Chromecast cannot reliably carry 24/96 FLAC and the existing Symphonium-via-Cast workflow is exactly what this slice replaces.
- **External truth condition for "slice 9 works":** Push a 24/96 FLAC to the STR-DN1080 → its **front panel** reports `96 kHz / 24 bit`. Anything less is a bug, not a feature.
- **Embedded HTTP server (shelf) honors `Range:` requests.** Receivers buffer, scrub, and probe — without Range support, scrubbing breaks.
- **Gapless on DLNA via `SetNextAVTransportURI` queued ~5 s before track end.** Not optional; gapless is a slice-1 invariant that survives transport switching.
- **DIDL-Lite metadata on `SetAVTransportURI` must carry the correct `res@protocolInfo` MIME + `DLNA.ORG_PN` tag.** Wrong PN → STR-DN1080 may refuse the stream or downsample silently. Pin the exact value from the §4 refresh, inline in `didl_lite.dart`, with a code comment explaining why.
- **`ChromecastTransport` Android-only.** Wrap behind `Platform.isAndroid` checks. No Chromecast on Linux (a second lossy path on the platform that already has DLNA isn't worth maintaining).
- **No AirPlay.** No reliable Linux source library, no mature Dart RAOP sender. Out of scope.
- **No multi-room group output.** Single receiver at a time.
- **IP selection skips loopback, docker bridges, virtual adapters.** Ambiguous case → user picker. Manual IP entry in Settings as fallback.

## When done

Run §11 verification + check §12 DoD. Key external truth: 24/96 FLAC plays via the cast button → bottom sheet shows the STR-DN1080 → tap → audio comes out the receiver → **front panel shows 96 kHz / 24 bit**. Pause/resume/skip from the app all work. SSDP rediscovery picks up the receiver again after a router cycle.
````
