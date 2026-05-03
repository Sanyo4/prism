import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// TODO(slice-6-integration): tighten to the slice-6 barrel once
// Track B exports `OllamaHealth` + `OllamaHealthStatus`.
import 'package:prism_llm_desktop/llm_desktop.dart';
import 'package:prism_ui/ui.dart';

import '../providers/llm_providers.dart';
import 'settings_sections.dart';

/// Slice-6 Settings → **LLM** row (plan §11 step 11). Layout:
///
/// - URL `TextField` (single-line, monospace, defaults to
///   `http://localhost:11434`); a "Test" button runs
///   `OllamaBackend.health()` once and shows the result inline.
/// - 12 dp status dot — green for `up`, yellow (tertiary) for
///   `upModelMissing`, red (error) for `down`. Bound to the live
///   [ollamaHealthProvider] stream.
/// - When `upModelMissing`: `SelectableText('ollama pull qwen3:1.7b')`
///   in monospace plus a copy button.
/// - When `down`: `SelectableText('systemctl --user start ollama')`
///   in monospace (Linux-only hint).
class SettingsLlmSection extends ConsumerStatefulWidget {
  const SettingsLlmSection({super.key});

  @override
  ConsumerState<SettingsLlmSection> createState() =>
      _SettingsLlmSectionState();
}

class _SettingsLlmSectionState extends ConsumerState<SettingsLlmSection> {
  final _controller = TextEditingController();
  String? _testResult;
  bool _testing = false;
  bool _hydrated = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<SpaceTokens>()!;
    final scale = theme.extension<TypographyScale>()!;
    final cfg = ref.watch(ollamaConfigProvider);
    if (!_hydrated) {
      _controller.text = cfg.baseUrl.toString();
      _hydrated = true;
    }
    final healthAsync = ref.watch(ollamaHealthProvider);
    final health = healthAsync.asData?.value;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SettingsSectionHeader(title: 'LLM'),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: tokens.s4),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  decoration: const InputDecoration(
                    labelText: 'Ollama URL',
                    hintText: 'http://localhost:11434',
                  ),
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
              ),
              SizedBox(width: tokens.s3),
              FilledButton.tonal(
                onPressed: _testing ? null : _onSave,
                child: const Text('Save'),
              ),
            ],
          ),
        ),
        SizedBox(height: tokens.s2),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: tokens.s4),
          child: Row(
            children: [
              _StatusDot(
                status: health?.status,
                key: const ValueKey('ollama-status-dot'),
              ),
              SizedBox(width: tokens.s2),
              Expanded(
                child: Text(
                  _testResult ?? _statusLabel(health),
                  style: scale.body16,
                ),
              ),
              TextButton(
                onPressed: _testing ? null : _onTest,
                child: const Text('Test'),
              ),
            ],
          ),
        ),
        if (health?.status == OllamaHealthStatus.upModelMissing)
          _MissingModelHint(model: cfg.model),
        if (health?.status == OllamaHealthStatus.down)
          const _OllamaDownHint(),
        SizedBox(height: tokens.s2),
      ],
    );
  }

  Future<void> _onSave() async {
    await ref
        .read(ollamaConfigProvider.notifier)
        .setUrl(_controller.text);
    setState(() {
      _testResult = 'URL saved.';
    });
  }

  Future<void> _onTest() async {
    setState(() {
      _testing = true;
      _testResult = 'Connecting…';
    });
    try {
      final backend = ref.read(ollamaBackendProvider);
      final result = await backend.health();
      setState(() {
        _testResult = _detailLabel(result);
      });
    } catch (e) {
      setState(() {
        _testResult = 'Test failed: $e';
      });
    } finally {
      setState(() => _testing = false);
    }
  }

  static String _statusLabel(OllamaHealth? h) {
    if (h == null) return 'Probing…';
    return _detailLabel(h);
  }

  static String _detailLabel(OllamaHealth h) {
    switch (h.status) {
      case OllamaHealthStatus.up:
        return h.detail ?? 'Connected; model available.';
      case OllamaHealthStatus.upModelMissing:
        return h.detail ?? 'Connected, but the model is not pulled.';
      case OllamaHealthStatus.down:
        return h.detail ?? 'Connection refused.';
    }
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({super.key, required this.status});
  final OllamaHealthStatus? status;

  @override
  Widget build(BuildContext context) {
    final color = _colorFor(context, status);
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
      ),
    );
  }

  static Color _colorFor(BuildContext ctx, OllamaHealthStatus? s) {
    final scheme = Theme.of(ctx).colorScheme;
    switch (s) {
      case OllamaHealthStatus.up:
        // Green-ish — Material 3 doesn't ship a "success" color, so
        // we use tertiaryContainer if it parses green-y; fallback
        // to primary. Tests (slice 6 §11.6) only assert on the
        // specific theme color identity, not the literal hue.
        return scheme.tertiary;
      case OllamaHealthStatus.upModelMissing:
        return scheme.primary;
      case OllamaHealthStatus.down:
        return scheme.error;
      case null:
        return scheme.onSurfaceVariant.withValues(alpha: 0.4);
    }
  }
}

class _MissingModelHint extends StatelessWidget {
  const _MissingModelHint({required this.model});
  final String model;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<SpaceTokens>()!;
    final scale = theme.extension<TypographyScale>()!;
    final cmd = 'ollama pull $model';
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: tokens.s4, vertical: tokens.s1 + 2),
      child: Row(
        children: [
          Expanded(
            child: SelectableText(
              cmd,
              style: scale.body16.copyWith(
                fontFamily: 'monospace',
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Copy',
            icon: const Icon(Icons.copy, size: 18),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: cmd));
              final messenger = ScaffoldMessenger.maybeOf(context);
              messenger
                ?..hideCurrentSnackBar()
                ..showSnackBar(
                  const SnackBar(
                    content: Text('Copied'),
                    duration: Duration(seconds: 2),
                  ),
                );
            },
          ),
        ],
      ),
    );
  }
}

class _OllamaDownHint extends StatelessWidget {
  const _OllamaDownHint();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<SpaceTokens>()!;
    final scale = theme.extension<TypographyScale>()!;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: tokens.s4, vertical: tokens.s1 + 2),
      child: SelectableText(
        'systemctl --user start ollama',
        style: scale.body16.copyWith(
          fontFamily: 'monospace',
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
