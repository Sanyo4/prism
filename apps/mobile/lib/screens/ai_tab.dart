import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// TODO(slice-6-integration): tighten to the slice-6 barrel once
// Track B exports `OllamaHealthStatus`.
import 'package:prism_llm_desktop/llm_desktop.dart';

import '../providers/llm_providers.dart';
import '../shell/app_shell.dart';
import 'new_vibe.dart';

/// AI tab — slice 6 step 14. A landing card with a Compose FAB that
/// pushes the [NewVibeSheet]. The card surfaces the LLM-health
/// state so a user with Ollama down sees the issue before tapping
/// Compose.
class AiTabScreen extends ConsumerWidget {
  const AiTabScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final healthAsync = ref.watch(ollamaHealthProvider);
    final status = healthAsync.asData?.value.status;
    final canCompose = status == OllamaHealthStatus.up;

    return AppShell(
      title: 'AI',
      currentTab: AppTab.ai,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    Icon(
                      Icons.auto_awesome,
                      size: 48,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Compose a vibe',
                      style: theme.textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Describe a mood, era, or moment in your own '
                      'words. Prism will assemble a 12-track '
                      'playlist that fits.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 24),
                    FilledButton.icon(
                      onPressed: canCompose
                          ? () => Navigator.of(context)
                              .pushNamed(NewVibeSheet.routeName)
                          : null,
                      icon: const Icon(Icons.create),
                      label: const Text('Compose'),
                    ),
                    if (!canCompose)
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: Text(
                          status == OllamaHealthStatus.upModelMissing
                              ? 'Pull qwen3:1.7b in Settings → LLM '
                                  'before composing.'
                              : 'Ollama is unreachable. See Settings → '
                                  'LLM for setup.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
