import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// TODO(slice-6-integration): tighten to the playlist_engine barrel
// once Track A appends the slice-6 exports.
import 'package:prism_playlist_engine/llm_backend.dart';
import 'package:prism_ui/ui.dart';

import '../providers/llm_providers.dart';
import '../providers/playlist_engine_providers.dart';
import '../widgets/llm_progress_card.dart';
import '../widgets/playlist_result_card.dart';

/// Modal sheet (mobile) / pushed page (desktop) that drives the
/// slice-6 LLM playlist pipeline. Three states render in order:
///
/// 1. **Compose** — autofocus multi-line `TextField` (300 dp tall on
///    mobile) + `Go` button. Disabled while the field is empty /
///    whitespace-only.
/// 2. **Progress** — [LlmProgressCard] showing the current
///    `PlaylistStep` and the last ~400 chars of streamed tokens.
/// 3. **Result** — [PlaylistResultCard] with the blurb, 12 rows, and
///    the "Play" FAB.
///
/// Sheet close cancels the active backend request via
/// `ollamaBackendProvider.cancel()` and `invalidates` the family
/// notifier; reopening the sheet starts a fresh run. On
/// `PlaylistResult.ready` the sheet stays open until the user taps
/// "Play" or closes it.
class NewVibeSheet extends ConsumerStatefulWidget {
  const NewVibeSheet({super.key});

  /// Push this screen via the named route registered in
  /// [PrismApp.routes]. Returns when the user dismisses.
  static const routeName = '/new-vibe';

  @override
  ConsumerState<NewVibeSheet> createState() => _NewVibeSheetState();
}

class _NewVibeSheetState extends ConsumerState<NewVibeSheet> {
  final _controller = TextEditingController();
  String? _activeVibe;

  @override
  void dispose() {
    final vibe = _activeVibe;
    if (vibe != null) {
      // Cancel any in-flight request; ref is invalidated below.
      // ignore: discarded_futures
      ref.read(ollamaBackendProvider).cancel();
      ref.invalidate(newVibeProvider(vibe));
    }
    _controller.dispose();
    super.dispose();
  }

  Future<bool> _onWillPop() async {
    // The dispose() handler also cancels, but we run the backend
    // cancel synchronously here so the request is aborted before
    // the route is popped (avoiding a token-stream tail in the
    // logs). Doubled cleanup is harmless — cancel() is idempotent.
    final vibe = _activeVibe;
    if (vibe != null) {
      // ignore: discarded_futures
      ref.read(ollamaBackendProvider).cancel();
    }
    return true;
  }

  void _submit() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    setState(() => _activeVibe = text);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final vibe = _activeVibe;
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) await _onWillPop();
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: const Text('New Vibe'),
          // Aurora paints the backdrop; AppBar stays default-Material.
        ),
        body: AuroraBackground(
          variant: AuroraVariant.ai,
          child: vibe == null
            ? _ComposeView(
                controller: _controller,
                onSubmit: _submit,
              )
            : _GenerateView(
                vibe: vibe,
                onCancel: () {
                  setState(() => _activeVibe = null);
                  // ignore: discarded_futures
                  ref.read(ollamaBackendProvider).cancel();
                  ref.invalidate(newVibeProvider(vibe));
                },
                onPlayed: () {
                  if (Navigator.of(context).canPop()) {
                    Navigator.of(context).pop();
                  }
                },
                themeOverride: theme,
              ),
        ),
      ),
    );
  }
}

class _ComposeView extends StatelessWidget {
  const _ComposeView({
    required this.controller,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<SpaceTokens>()!;
    return Padding(
      padding: EdgeInsets.all(tokens.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 300,
            child: TextField(
              controller: controller,
              autofocus: true,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              decoration: const InputDecoration(
                hintText:
                    'Describe a vibe — e.g. "rainy Sunday morning, '
                    'low BPM, no vocals".',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          SizedBox(height: tokens.s4),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, value, _) {
              final canSubmit = value.text.trim().isNotEmpty;
              return FilledButton.icon(
                onPressed: canSubmit ? onSubmit : null,
                icon: const Icon(Icons.auto_awesome),
                label: const Text('Go'),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _GenerateView extends ConsumerWidget {
  const _GenerateView({
    required this.vibe,
    required this.onCancel,
    required this.onPlayed,
    required this.themeOverride,
  });

  final String vibe;
  final VoidCallback onCancel;
  final VoidCallback onPlayed;
  final ThemeData themeOverride;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(newVibeProvider(vibe));
    final state = async.asData?.value;

    if (async.isLoading && state == null) {
      return const Center(child: CircularProgressIndicator());
    }

    if (state == null) {
      // Error path — `async.error` is set when build() raised.
      return _ErrorView(
        error: async.error ?? 'Unknown error',
        onRetry: () => ref.invalidate(newVibeProvider(vibe)),
      );
    }

    if (state.cancelled) {
      // Sheet cancellation — render a minimal confirmation
      // surface; the parent will pop on the next frame anyway in
      // most flows.
      return const Center(
        child: Text('Cancelled'),
      );
    }

    if (state.error != null) {
      // Show an inline snackbar via post-frame callback.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final messenger = ScaffoldMessenger.maybeOf(context);
        messenger
          ?..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text('Pipeline failed: ${state.error}'),
              duration: const Duration(seconds: 4),
            ),
          );
      });
    }

    if (state.step == PlaylistStep.ready && state.result != null) {
      return PlaylistResultCard(
        result: state.result!,
        vibe: vibe,
        onPlayed: onPlayed,
      );
    }

    return LlmProgressCard(
      step: state.step,
      tokenPreview: state.tokenPreview,
      onCancel: onCancel,
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.error, required this.onRetry});
  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<SpaceTokens>()!;
    final scale = theme.extension<TypographyScale>()!;
    return Padding(
      padding: EdgeInsets.all(tokens.s6),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.error_outline,
              size: 48, color: theme.colorScheme.error),
          SizedBox(height: tokens.s4),
          Text(
            'Pipeline failed',
            style: scale.display20,
          ),
          SizedBox(height: tokens.s2),
          Text(
            '$error',
            textAlign: TextAlign.center,
            style: scale.body16.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          SizedBox(height: tokens.s4),
          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('Try again'),
          ),
        ],
      ),
    );
  }
}
