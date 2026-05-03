import 'package:flutter/material.dart';
// TODO(slice-6-integration): tighten to the playlist_engine barrel
// once Track A appends the slice-6 exports.
import 'package:prism_playlist_engine/llm_backend.dart';
import 'package:prism_ui/ui.dart';

/// Single Material-3 card the New Vibe sheet renders while the
/// pipeline is running. Shows:
///
/// - The current `PlaylistStep` as a chip ("Building intent…",
///   "Picking candidates…", "Ranking…", "Flowing…", "Narrating…").
/// - Last ~400 chars of streamed LLM tokens in a monospace `Text`,
///   auto-scrolled to the end so the most recent tokens stay
///   visible.
/// - A cancel `IconButton(Icons.close)` top-right.
///
/// Token-preview coalescing is handled by [NewVibeNotifier] (60 ms
/// timer); this widget only renders the current state. Re-builds at
/// the cadence of state writes — at most ~16 times per second under
/// active streaming.
class LlmProgressCard extends StatefulWidget {
  const LlmProgressCard({
    super.key,
    required this.step,
    required this.tokenPreview,
    required this.onCancel,
  });

  /// Current pipeline stage. The chip's label maps from this value.
  final PlaylistStep step;

  /// Last ~400 chars of LLM tokens — already trimmed by the
  /// notifier. Empty string while no chunks have arrived yet.
  final String tokenPreview;

  /// Tapped via the close (X) button. Should both cancel the
  /// active backend request and pop the sheet.
  final VoidCallback onCancel;

  @override
  State<LlmProgressCard> createState() => _LlmProgressCardState();
}

class _LlmProgressCardState extends State<LlmProgressCard> {
  late final ScrollController _scroll;

  @override
  void initState() {
    super.initState();
    _scroll = ScrollController();
  }

  @override
  void didUpdateWidget(covariant LlmProgressCard old) {
    super.didUpdateWidget(old);
    if (old.tokenPreview != widget.tokenPreview) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scroll.hasClients) return;
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<SpaceTokens>()!;
    final scale = theme.extension<TypographyScale>()!;
    return Card(
      margin: EdgeInsets.all(tokens.s4),
      child: Padding(
        padding: EdgeInsets.fromLTRB(tokens.s4, tokens.s3, tokens.s2, tokens.s4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                _StepChip(step: widget.step),
                const Spacer(),
                IconButton(
                  tooltip: 'Cancel',
                  icon: const Icon(Icons.close),
                  onPressed: widget.onCancel,
                ),
              ],
            ),
            SizedBox(height: tokens.s2),
            ConstrainedBox(
              constraints: const BoxConstraints(
                maxHeight: 180,
                minHeight: 60,
              ),
              child: SingleChildScrollView(
                controller: _scroll,
                child: SelectableText(
                  widget.tokenPreview.isEmpty
                      ? '…'
                      : widget.tokenPreview,
                  style: scale.caption13.copyWith(
                    fontFamily: 'monospace',
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StepChip extends StatelessWidget {
  const _StepChip({required this.step});
  final PlaylistStep step;

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
      label: Text(_label(step)),
    );
  }

  static String _label(PlaylistStep step) {
    switch (step) {
      case PlaylistStep.intent:
        return 'Building intent…';
      case PlaylistStep.pool:
        return 'Picking candidates…';
      case PlaylistStep.rank:
        return 'Ranking…';
      case PlaylistStep.flow:
        return 'Flowing…';
      case PlaylistStep.narrative:
        return 'Narrating…';
      case PlaylistStep.ready:
        return 'Ready';
    }
  }
}
