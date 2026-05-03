/// Slice 8 download card — the Settings → LLM "weights absent" state
/// (slice 8 §6 file `apps/mobile/lib/widgets/model_download_card.dart`).
///
/// Renders one of the six [DownloadPhase] states:
///
///   - `connecting` → spinner + "Connecting…"
///   - `downloading` → progress bar + receivedBytes/totalBytes + MB/s + ETA
///   - `verifying` → indeterminate bar + "Verifying…"
///   - `paused` → progress bar (greyed) + "Paused" / "Paused (Wi-Fi only)"
///   - `failed` → red banner + errorMessage + "Retry"
///   - `done` → "Ready" line (the Settings section swaps the card for
///     the "Ready" row at this point, so this state is rarely visible)
///
/// Plus a Wi-Fi-only enforcement gate: when
/// `wifiOnlyDownloadProvider` is `true` AND `connectivityProvider`'s
/// folded interface is `mobile` (or `none`), the card refuses to
/// `start()` and displays "Waiting for Wi-Fi". On the next Wi-Fi
/// flip the card auto-resumes (slice 8 §11 item 8).
///
/// The card consumes Track A's `ModelDownloader`; it doesn't manage
/// the download itself. Pause / Resume / Cancel call into the
/// downloader, and the `DownloadPhase` reflected in the rendered
/// state comes back through `modelDownloadStateProvider`.
library;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// TODO(slice-8-integration): tighten to the package barrel once
// Track A ships it. See providers/llm_providers_mobile.dart for the
// list of unresolved symbols.
import 'package:prism_llm_mobile/llm_mobile.dart';
import 'package:prism_ui/ui.dart';

import '../providers/llm_providers_mobile.dart';

/// The download card. Bind it in `SettingsLlmSectionMobile` for the
/// "weights absent" branch.
class ModelDownloadCard extends ConsumerStatefulWidget {
  const ModelDownloadCard({super.key});

  @override
  ConsumerState<ModelDownloadCard> createState() => _ModelDownloadCardState();
}

class _ModelDownloadCardState extends ConsumerState<ModelDownloadCard> {
  /// Last connectivity value we acted on. Used to detect the
  /// metered → Wi-Fi flip and auto-resume from a Wi-Fi-only pause.
  ConnectivityResult? _lastConnectivity;

  /// True iff we paused the download because we were on a metered
  /// network with the Wi-Fi-only toggle on. Cleared on Wi-Fi flip;
  /// auto-resumes when cleared.
  bool _pausedForWifiGate = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<SpaceTokens>()!;
    final scale = theme.extension<TypographyScale>()!;
    final spec = ref.watch(cactusModelSpecProvider);
    final progressAsync = ref.watch(modelDownloadStateProvider);
    final connectivityAsync = ref.watch(connectivityProvider);
    final wifiOnly = ref.watch(wifiOnlyDownloadProvider);

    // Auto-resume + auto-pause for the Wi-Fi-only gate. We watch the
    // connectivity stream as a side-effect; the gate decisions happen
    // in `_handleConnectivityChange` so the build itself remains
    // pure (no setState calls during build).
    ref.listen<AsyncValue<ConnectivityResult>>(
      connectivityProvider,
      (prev, next) {
        final value = next.asData?.value;
        if (value == null) return;
        _handleConnectivityChange(value, wifiOnly: wifiOnly);
      },
    );

    if (spec.sha256Hex.isEmpty) {
      return _PinMissingCard(spec: spec);
    }

    final progress = progressAsync.asData?.value;
    final phase = progress?.phase ?? DownloadPhase.paused;

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: tokens.s4,
        vertical: tokens.s3,
      ),
      child: Card(
        child: Padding(
          padding: EdgeInsets.all(tokens.s4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Header(spec: spec, scale: scale),
              SizedBox(height: tokens.s2),
              _SizeRow(
                spec: spec,
                progress: progress,
                phase: phase,
                scale: scale,
                pausedForWifi: _pausedForWifiGate,
              ),
              SizedBox(height: tokens.s3),
              _PhaseBody(
                progress: progress,
                phase: phase,
                pausedForWifi: _pausedForWifiGate,
                tokens: tokens,
                scale: scale,
              ),
              SizedBox(height: tokens.s3),
              _ButtonRow(
                phase: phase,
                pausedForWifi: _pausedForWifiGate,
                wifiOnly: wifiOnly,
                connectivity: connectivityAsync.asData?.value,
                onDownload: _onDownload,
                onPause: _onPause,
                onResume: _onResume,
                onCancel: _onCancel,
                onRetry: _onRetry,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _handleConnectivityChange(
    ConnectivityResult value, {
    required bool wifiOnly,
  }) {
    final previous = _lastConnectivity;
    _lastConnectivity = value;
    if (previous == value) return;
    if (!wifiOnly) {
      // User explicitly disabled the gate — don't intervene.
      return;
    }
    final isWifiOrEth = value == ConnectivityResult.wifi ||
        value == ConnectivityResult.ethernet;
    if (isWifiOrEth && _pausedForWifiGate) {
      // Wi-Fi just came back — auto-resume.
      // ignore: discarded_futures
      _onResume();
      setState(() => _pausedForWifiGate = false);
    }
  }

  Future<void> _onDownload() async {
    final wifiOnly = ref.read(wifiOnlyDownloadProvider);
    final connectivityAsync = ref.read(connectivityProvider);
    final connectivity = connectivityAsync.asData?.value;
    if (wifiOnly &&
        connectivity != ConnectivityResult.wifi &&
        connectivity != ConnectivityResult.ethernet) {
      setState(() => _pausedForWifiGate = true);
      return;
    }
    final downloader = ref.read(modelDownloaderProvider);
    // ignore: discarded_futures
    downloader.start();
  }

  Future<void> _onPause() async {
    final downloader = ref.read(modelDownloaderProvider);
    setState(() => _pausedForWifiGate = false);
    await downloader.pause();
  }

  Future<void> _onResume() async {
    final wifiOnly = ref.read(wifiOnlyDownloadProvider);
    final connectivityAsync = ref.read(connectivityProvider);
    final connectivity = connectivityAsync.asData?.value;
    if (wifiOnly &&
        connectivity != ConnectivityResult.wifi &&
        connectivity != ConnectivityResult.ethernet) {
      setState(() => _pausedForWifiGate = true);
      return;
    }
    final downloader = ref.read(modelDownloaderProvider);
    // ignore: discarded_futures
    downloader.start();
  }

  Future<void> _onCancel() async {
    final downloader = ref.read(modelDownloaderProvider);
    // Track A's `ModelDownloader` exposes `pause()` (which leaves the
    // .partial intact). The brief calls Cancel "stops + deletes
    // .partial"; that delete is a Track A responsibility — Track B's
    // UI just signals the intent. If Track A hasn't shipped a
    // dedicated `cancel()` we fall back to pause; the user can
    // manually delete weights via the "Delete weights" button in the
    // ready state.
    await downloader.pause();
    setState(() => _pausedForWifiGate = false);
  }

  Future<void> _onRetry() async {
    // Same shape as Download, but the explicit "Retry" surfaces in
    // the failed-phase branch so analytics can distinguish the user
    // intent.
    return _onDownload();
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.spec, required this.scale});
  final CactusModelSpec spec;
  final TypographyScale scale;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('On-device LLM', style: scale.display20),
        const SizedBox(height: 4),
        Text(
          'Required for offline vibe playlists',
          style: scale.body16.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _SizeRow extends StatelessWidget {
  const _SizeRow({
    required this.spec,
    required this.progress,
    required this.phase,
    required this.scale,
    required this.pausedForWifi,
  });

  final CactusModelSpec spec;
  final DownloadProgress? progress;
  final DownloadPhase phase;
  final TypographyScale scale;
  final bool pausedForWifi;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final received = progress?.receivedBytes ?? 0;
    final total = (progress?.totalBytes ?? -1) <= 0
        ? spec.sizeBytes
        : (progress?.totalBytes ?? spec.sizeBytes);
    final muted = scale.caption13.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final left = phase == DownloadPhase.downloading ||
            phase == DownloadPhase.paused ||
            phase == DownloadPhase.verifying
        ? '${formatBytes(received)} / ${formatBytes(total)}'
        : formatBytes(spec.sizeBytes);
    final right = _rightLabel(progress: progress, phase: phase);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(left, style: muted),
        if (right != null) Text(right, style: muted),
      ],
    );
  }

  String? _rightLabel({
    required DownloadProgress? progress,
    required DownloadPhase phase,
  }) {
    if (progress == null) return null;
    if (phase != DownloadPhase.downloading) return null;
    final mbps = progress.bytesPerSecond / (1024 * 1024);
    final eta = progress.eta;
    final etaLabel = eta == null ? '' : ' · ${formatDuration(eta)}';
    return '${mbps.toStringAsFixed(1)} MB/s$etaLabel';
  }
}

class _PhaseBody extends StatelessWidget {
  const _PhaseBody({
    required this.progress,
    required this.phase,
    required this.pausedForWifi,
    required this.tokens,
    required this.scale,
  });

  final DownloadProgress? progress;
  final DownloadPhase phase;
  final bool pausedForWifi;
  final SpaceTokens tokens;
  final TypographyScale scale;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    switch (phase) {
      case DownloadPhase.connecting:
        return Row(
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: tokens.s2),
            Text('Connecting…', style: scale.body16),
          ],
        );
      case DownloadPhase.downloading:
        final value = _safeProgressValue(progress);
        return LinearProgressIndicator(value: value);
      case DownloadPhase.verifying:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const LinearProgressIndicator(),
            SizedBox(height: tokens.s1),
            Text('Verifying…', style: scale.caption13.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            )),
          ],
        );
      case DownloadPhase.paused:
        final value = _safeProgressValue(progress);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Greyed-out paused bar: render with a subdued color
            // override so the user sees state but not motion.
            LinearProgressIndicator(
              value: value,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
              backgroundColor:
                  theme.colorScheme.surfaceContainerHighest,
            ),
            SizedBox(height: tokens.s1),
            Text(
              pausedForWifi ? 'Waiting for Wi-Fi' : 'Paused',
              style: scale.caption13.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        );
      case DownloadPhase.failed:
        final msg = progress?.errorMessage ?? 'Download failed.';
        return Container(
          padding: EdgeInsets.all(tokens.s3),
          decoration: BoxDecoration(
            color: theme.colorScheme.errorContainer,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.error_outline,
                color: theme.colorScheme.onErrorContainer,
                size: 18,
              ),
              SizedBox(width: tokens.s2),
              Expanded(
                child: Text(
                  msg,
                  style: scale.body16.copyWith(
                    color: theme.colorScheme.onErrorContainer,
                  ),
                ),
              ),
            ],
          ),
        );
      case DownloadPhase.done:
        return Row(
          children: [
            Icon(Icons.check_circle, color: theme.colorScheme.tertiary),
            SizedBox(width: tokens.s2),
            Expanded(
              child: Text('Ready', style: scale.body16),
            ),
          ],
        );
    }
  }

  double? _safeProgressValue(DownloadProgress? p) {
    if (p == null) return null;
    if (p.totalBytes <= 0) return null; // indeterminate
    final v = p.receivedBytes / p.totalBytes;
    if (v.isNaN || v.isInfinite) return null;
    return v.clamp(0.0, 1.0);
  }
}

class _ButtonRow extends StatelessWidget {
  const _ButtonRow({
    required this.phase,
    required this.pausedForWifi,
    required this.wifiOnly,
    required this.connectivity,
    required this.onDownload,
    required this.onPause,
    required this.onResume,
    required this.onCancel,
    required this.onRetry,
  });

  final DownloadPhase phase;
  final bool pausedForWifi;
  final bool wifiOnly;
  final ConnectivityResult? connectivity;
  final Future<void> Function() onDownload;
  final Future<void> Function() onPause;
  final Future<void> Function() onResume;
  final Future<void> Function() onCancel;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<SpaceTokens>()!;
    final children = <Widget>[];
    switch (phase) {
      case DownloadPhase.connecting:
      case DownloadPhase.downloading:
        children.add(FilledButton.tonal(
          onPressed: onPause,
          child: const Text('Pause'),
        ));
        children.add(SizedBox(width: tokens.s2));
        children.add(TextButton(
          onPressed: onCancel,
          child: const Text('Cancel'),
        ));
        break;
      case DownloadPhase.paused:
        children.add(FilledButton(
          onPressed: pausedForWifi
              ? null // disabled while waiting for Wi-Fi
              : onResume,
          child: const Text('Resume'),
        ));
        children.add(SizedBox(width: tokens.s2));
        children.add(TextButton(
          onPressed: onCancel,
          child: const Text('Cancel'),
        ));
        break;
      case DownloadPhase.verifying:
        // No buttons — verification is short and non-cancellable.
        break;
      case DownloadPhase.failed:
        children.add(FilledButton(
          onPressed: onRetry,
          child: const Text('Retry'),
        ));
        break;
      case DownloadPhase.done:
        // Caller swaps the card; no buttons here.
        break;
    }
    if (children.isEmpty) {
      // Initial idle state — no progress event yet, no .partial on
      // disk: surface the "Download" CTA.
      children.add(FilledButton(
        onPressed: onDownload,
        child: const Text('Download'),
      ));
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: children,
    );
  }
}

class _PinMissingCard extends StatelessWidget {
  const _PinMissingCard({required this.spec});
  final CactusModelSpec spec;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<SpaceTokens>()!;
    final scale = theme.extension<TypographyScale>()!;
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: tokens.s4,
        vertical: tokens.s3,
      ),
      child: Card(
        color: theme.colorScheme.errorContainer,
        child: Padding(
          padding: EdgeInsets.all(tokens.s4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'On-device LLM — pin missing',
                style: scale.display20.copyWith(
                  color: theme.colorScheme.onErrorContainer,
                ),
              ),
              SizedBox(height: tokens.s2),
              Text(
                'Download blocked: SHA256 pin is empty. Run '
                '`dart run packages/llm_mobile/tool/refresh_spec.dart` '
                '(slice 8 §4) to populate `kQwen3_1_7B_INT4.sha256Hex` '
                'from the HuggingFace revision before first download.',
                style: scale.body16.copyWith(
                  color: theme.colorScheme.onErrorContainer,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Formats bytes as "1.0 GB" / "256.0 MB" / "12.0 KB" / "12 B" with
/// one decimal place above 1 KB. Used by the size row + the size
/// progress label.
String formatBytes(int bytes) {
  if (bytes < 0) return '—';
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  double v = bytes / 1024.0;
  int idx = 0;
  while (v >= 1024 && idx < units.length - 1) {
    v /= 1024;
    idx++;
  }
  return '${v.toStringAsFixed(1)} ${units[idx]}';
}

/// Formats a `Duration` ETA as "~2 min" / "~12 sec" / "~3 hr". Used
/// by the size row's right label.
String formatDuration(Duration d) {
  if (d.inHours >= 1) {
    return '~${d.inHours} hr';
  }
  if (d.inMinutes >= 1) {
    return '~${d.inMinutes} min';
  }
  final s = d.inSeconds;
  return '~${s.clamp(1, 99)} sec';
}
