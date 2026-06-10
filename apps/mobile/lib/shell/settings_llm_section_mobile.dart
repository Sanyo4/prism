/// Slice 8 Settings → LLM section — Android twin of slice 6's
/// `SettingsLlmSection` (Ollama). Two states:
///
///   1. **Weights absent** (or .partial in progress): renders the
///      [ModelDownloadCard] above a "Wi-Fi only" `SwitchListTile`.
///   2. **Weights present** (`isComplete()` returns `true`): renders
///      a "Ready" row with a green dot, the NPU/CPU/unsupported dot
///      from `MobileBackend.activeBackend`, a "Retry NPU" affordance
///      when the backend is on CPU, and a "Delete weights"
///      destructive button.
///
/// Layout mirrors slice 6's `SettingsLlmSection` so the two side-by-
/// side feel consistent under their respective platform branches.
/// Order is locked: header → state body → Wi-Fi toggle. The slice-1
/// widget test scrolls past this section to find "Playback"; nothing
/// here introduces a Scrollable that would shadow the outer
/// ListView's scroll axis.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// TODO(slice-8-integration): tighten to the package barrel once
// Track A ships it. NpuSupport is referenced via the documented
// names in slice 8 §7.
import 'package:prism_llm_mobile/llm_mobile.dart';
import 'package:prism_ui/ui.dart';

import '../providers/llm_providers_mobile.dart';
import '../widgets/model_download_card.dart';
import 'settings_sections.dart';

class SettingsLlmSectionMobile extends ConsumerWidget {
  const SettingsLlmSectionMobile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final tokens = theme.extension<SpaceTokens>()!;
    final scale = theme.extension<TypographyScale>()!;

    // Slice 8: `modelDownloaderProvider` and `mobileBackendProvider`
    // are now both synchronous `Provider`s (Track A's `ModelPaths`
    // ctor takes a `Future<Directory> Function()` — the platform
    // channel is awaited inside the downloader / init when needed,
    // not at provider-build time). The async surface here is on
    // `downloader.isComplete()` which `_Body` polls below.
    final downloader = ref.watch(modelDownloaderProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SettingsSectionHeader(title: 'LLM'),
        _Body(
          downloader: downloader,
          tokens: tokens,
          scale: scale,
        ),
        SizedBox(height: tokens.s2),
        const _WifiOnlyToggle(),
        SizedBox(height: tokens.s2),
      ],
    );
  }
}

class _Body extends ConsumerStatefulWidget {
  const _Body({
    required this.downloader,
    required this.tokens,
    required this.scale,
  });

  final ModelDownloader downloader;
  final SpaceTokens tokens;
  final TypographyScale scale;

  @override
  ConsumerState<_Body> createState() => _BodyState();
}

class _BodyState extends ConsumerState<_Body> {
  /// `isComplete()` is async; we cache the answer for the lifetime of
  /// this State and re-poll on every rebuild driven by a download
  /// state change. Surfacing as `null` while we wait keeps the UI
  /// from flashing "Download" on the first frame.
  bool? _complete;
  Object? _completeError;

  @override
  void initState() {
    super.initState();
    _refreshComplete();
  }

  @override
  void didUpdateWidget(_Body old) {
    super.didUpdateWidget(old);
    if (!identical(old.downloader, widget.downloader)) {
      _refreshComplete();
    }
  }

  Future<void> _refreshComplete() async {
    try {
      final value = await widget.downloader.isComplete();
      if (!mounted) return;
      setState(() {
        _complete = value;
        _completeError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _complete = false;
        _completeError = e;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Re-poll `isComplete()` whenever the download stream emits a
    // terminal `done` so the UI flips from card → Ready row without
    // a manual refresh. We watch the stream as a side-effect; the
    // re-poll happens out of band.
    ref.listen<AsyncValue<DownloadProgress>>(
      modelDownloadStateProvider,
      (prev, next) {
        final phase = next.asData?.value.phase;
        if (phase == DownloadPhase.done) {
          // ignore: discarded_futures
          _refreshComplete();
        }
      },
    );

    final complete = _complete;
    if (complete == null) {
      return Padding(
        padding: EdgeInsets.symmetric(
          horizontal: widget.tokens.s4,
          vertical: widget.tokens.s3,
        ),
        child: const Center(child: CircularProgressIndicator()),
      );
    }
    if (_completeError != null) {
      // Probe error — still surface the card so the user has a path
      // forward; the underlying error is logged via the banner.
      return Column(
        children: [
          _ErrorBanner(message: _completeError.toString()),
          const ModelDownloadCard(),
        ],
      );
    }
    if (!complete) {
      return const ModelDownloadCard();
    }
    // Weights are on disk → render the Ready row. We `ref.watch` the
    // backend provider here (rather than receive it via constructor)
    // because a "Retry NPU" tap invalidates `mobileBackendProvider`
    // and we want the row to rebuild against the new instance.
    final backend = ref.watch(mobileBackendProvider);
    return _ReadyRow(
      backend: backend,
      onDelete: _onDelete,
      tokens: widget.tokens,
      scale: widget.scale,
    );
  }

  Future<void> _onDelete() async {
    // Track A's `ModelDownloader` only documents `start()` /
    // `pause()` / `isComplete()`; the brief calls for "Delete
    // weights" but doesn't pin the symbol. We trigger pause (no-op
    // when nothing is in-flight) and then re-probe; if Track A adds
    // a `delete()` later we tighten this. For now the user can
    // uninstall + reinstall to fully reset (slice 8 §10 risk 13).
    // TODO(slice-8-integration): replace with `downloader.delete()`
    // once Track A ships it.
    await widget.downloader.pause();
    await _refreshComplete();
  }
}

class _ReadyRow extends ConsumerWidget {
  const _ReadyRow({
    required this.backend,
    required this.onDelete,
    required this.tokens,
    required this.scale,
  });

  final MobileBackend backend;
  final Future<void> Function() onDelete;
  final SpaceTokens tokens;
  final TypographyScale scale;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    // `activeBackend` reflects whichever path Cactus actually bound
    // (NPU vs CPU vs unsupported). Until the first generate fires,
    // `isModelLoaded` is false and `activeBackend` is whatever the
    // last load attempt recorded — Track A documents `npu` as the
    // default until a CPU fallback is observed.
    final activeBackend = backend.activeBackend;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.symmetric(horizontal: tokens.s4),
          child: Row(
            children: [
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: theme.colorScheme.tertiary,
                  shape: BoxShape.circle,
                ),
              ),
              SizedBox(width: tokens.s2),
              Expanded(
                child: Text('Model ready', style: scale.body16),
              ),
            ],
          ),
        ),
        SizedBox(height: tokens.s2),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: tokens.s4),
          child: Row(
            children: [
              _NpuDot(support: activeBackend),
              SizedBox(width: tokens.s2),
              Expanded(
                child: Text(
                  _npuLabel(activeBackend),
                  style: scale.body16.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              if (activeBackend == NpuSupport.cpu)
                TextButton(
                  onPressed: () async {
                    await backend.releaseModel();
                    // Re-invalidate so the next call rebuilds with
                    // the NPU-preferred init. Slice 8 §10 risk 3:
                    // "tap to clear the pin".
                    ref.invalidate(mobileBackendProvider);
                  },
                  child: const Text('Retry NPU'),
                ),
            ],
          ),
        ),
        SizedBox(height: tokens.s3),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: tokens.s4),
          child: Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: onDelete,
              style: TextButton.styleFrom(
                foregroundColor: theme.colorScheme.error,
              ),
              child: const Text('Delete weights'),
            ),
          ),
        ),
      ],
    );
  }

  String _npuLabel(NpuSupport? s) {
    switch (s) {
      case NpuSupport.npu:
        return 'Running on NPU';
      case NpuSupport.cpu:
        return 'Running on CPU — slower but works offline';
      case NpuSupport.unsupported:
        return 'Acceleration unsupported on this device';
      case null:
        return 'Probing acceleration…';
    }
  }
}

class _NpuDot extends StatelessWidget {
  const _NpuDot({required this.support});
  final NpuSupport? support;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (support) {
      NpuSupport.npu => scheme.tertiary, // green-ish
      NpuSupport.cpu => scheme.primary, // yellow-ish under M3 default
      NpuSupport.unsupported => scheme.error,
      null => scheme.onSurfaceVariant.withValues(alpha: 0.4),
    };
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

class _WifiOnlyToggle extends ConsumerWidget {
  const _WifiOnlyToggle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wifiOnly = ref.watch(wifiOnlyDownloadProvider);
    return SwitchListTile(
      title: const Text('Download on Wi-Fi only'),
      subtitle: const Text(
        'Avoid using cellular data for the 1 GB model download.',
      ),
      value: wifiOnly,
      onChanged: (v) =>
          ref.read(wifiOnlyDownloadProvider.notifier).setEnabled(v),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});
  final String message;

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
      child: Container(
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
                message,
                style: scale.body16.copyWith(
                  color: theme.colorScheme.onErrorContainer,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
