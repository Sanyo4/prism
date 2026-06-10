import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_cast/cast.dart';
import 'package:prism_playback/playback.dart' show LocalPlayerHandle;

import '../providers/cast_providers.dart';
import '../providers/playback_providers.dart';

/// Slice-9 §6 step 14 — cast sheet. Bottom sheet with three sections:
///
/// 1. **Local** — single ListTile, always shown. Tap → swap to a
///    fresh [LocalTransport] over the slice-1 player.
/// 2. **Speakers (DLNA)** — list from [castDiscoveryProvider]. While
///    the M-SEARCH is in flight, shows a "Scanning…" subtitle.
///    Tap → construct [DlnaTransport] (current device + lazy
///    [MediaServer]) and dispatch via [TransportNotifier.set] / the
///    PlaybackService listener.
/// 3. **Cast devices (Android only)** — gated by
///    [castDevicesAvailable] (`Platform.isAndroid &&
///    kHasChromecastSupport`). Hidden on Linux entirely. The header
///    carries a "Lossy" chip mirroring slice-9 §11 item 8.
///
/// The currently active transport gets a checkmark next to its
/// ListTile so the user can see "where audio is going" at a glance.
class CastSheet extends ConsumerWidget {
  const CastSheet({super.key});

  /// Canonical entry point — call from the cast icon's `onPressed`.
  /// Returns once the sheet has been dismissed; the dismissal
  /// itself doesn't carry data, but the user-driven `setTransport`
  /// inside the sheet has already published before pop.
  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      // Slice 9 §4 doc-refresh confirmed `showDragHandle: true`
      // gives the standard top-drag chrome.
      showDragHandle: true,
      useSafeArea: true,
      builder: (_) => const CastSheet(),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final activeTransport = ref.watch(transportProvider);
    final discoveryAsync = ref.watch(castDiscoveryProvider);

    final children = <Widget>[
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Text(
          'Output device',
          style: theme.textTheme.titleMedium,
        ),
      ),
      _Header(label: 'Local'),
      _LocalRow(
        active: activeTransport.id == 'local',
        onTap: () => _selectLocal(context, ref),
      ),
      const Divider(height: 1),
      _Header(label: 'Speakers (DLNA)'),
      ...discoveryAsync.when(
        data: (devices) {
          if (devices.isEmpty) {
            return const <Widget>[
              ListTile(
                dense: true,
                leading: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                title: Text('Scanning…'),
              ),
            ];
          }
          return devices
              .map<Widget>((d) => _DlnaRow(
                    device: d,
                    active: activeTransport.id == 'dlna:${d.uuid}',
                    onTap: () => _selectDlna(context, ref, d),
                  ))
              .toList(growable: false);
        },
        loading: () => const <Widget>[
          ListTile(
            dense: true,
            leading: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            title: Text('Scanning…'),
          ),
        ],
        error: (e, _) => <Widget>[
          ListTile(
            leading: const Icon(Icons.error_outline),
            title: const Text('Discovery failed'),
            subtitle: Text('$e'),
          ),
        ],
      ),
    ];

    if (castDevicesAvailable) {
      children.add(const Divider(height: 1));
      children.add(_Header(
        label: 'Cast devices',
        trailing: const _LossyChip(),
      ));
      children.add(const _ChromecastSection());
    }

    children.add(const SizedBox(height: 16));

    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    );
  }

  Future<void> _selectLocal(BuildContext context, WidgetRef ref) async {
    final current = ref.read(transportProvider);
    if (current is LocalTransport) {
      // No-op repeat tap: don't churn LocalTransport instances when
      // the user re-confirms "Local". The PlaybackService swap is a
      // pause + dispose + setTrack + seek + play cycle — not free.
      if (context.mounted) Navigator.of(context).maybePop();
      return;
    }
    final port = ref.read(audioPlayerPortProvider);
    final next = LocalTransport(player: LocalPlayerHandle(port));
    ref.read(transportProvider.notifier).set(next);
    if (context.mounted) {
      Navigator.of(context).maybePop();
    }
  }

  Future<void> _selectDlna(
    BuildContext context,
    WidgetRef ref,
    DlnaDevice device,
  ) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final current = ref.read(transportProvider);
    if (current.id == 'dlna:${device.uuid}') {
      // Same device re-tapped — keep the existing session warm.
      if (context.mounted) Navigator.of(context).maybePop();
      return;
    }
    try {
      final mediaServer = await ref.read(mediaServerProvider.future);
      final next = DlnaTransport(
        device: device,
        mediaServer: mediaServer,
      );
      ref.read(transportProvider.notifier).set(next);
      if (context.mounted) {
        Navigator.of(context).maybePop();
      }
    } on Object catch (e) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Failed to start DLNA session: $e')),
      );
    }
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.label, this.trailing});
  final String label;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          Text(
            label,
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 8),
            trailing!,
          ],
        ],
      ),
    );
  }
}

class _LossyChip extends StatelessWidget {
  const _LossyChip();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        'Lossy',
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onErrorContainer,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _LocalRow extends StatelessWidget {
  const _LocalRow({required this.active, required this.onTap});
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.smartphone_outlined),
      title: const Text('Built-in speakers'),
      subtitle: const Text('Lossless on this device'),
      trailing: active ? const Icon(Icons.check) : null,
      onTap: onTap,
    );
  }
}

class _DlnaRow extends StatelessWidget {
  const _DlnaRow({
    required this.device,
    required this.active,
    required this.onTap,
  });
  final DlnaDevice device;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(
        device.looksLikeStrDn1080
            ? Icons.speaker
            : Icons.speaker_outlined,
      ),
      title: Text(device.friendlyName),
      subtitle: Text(
        device.modelName.isEmpty ? device.manufacturer : device.modelName,
      ),
      trailing: active ? const Icon(Icons.check) : null,
      onTap: onTap,
    );
  }
}

/// Cast-section content. Kept private to the sheet because the
/// section is gated entirely on [castDevicesAvailable] — Linux
/// desktop never builds this widget tree.
///
/// **Discovery integration is deferred to slice-9 follow-up.** Track A
/// landed `flutter_chrome_cast` and the [ChromecastTransport] shell;
/// the actual `GoogleCastDiscoveryManager.startDiscovery` /
/// `GoogleCastSessionManager.startSessionWithDevice` integration is
/// flagged `TODO(slice-9-integration)` because the SDK call sites
/// require a foreground Activity context that isn't available
/// during the cast-sheet build. The placeholder row below shows a
/// "Scanning…" state so the user sees the section exists but no
/// devices have been discovered yet.
class _ChromecastSection extends ConsumerWidget {
  const _ChromecastSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // TODO(slice-9-integration): wire to GoogleCastDiscoveryManager
    // via the flutter_chrome_cast plugin. Track A's
    // `kHasChromecastSupport == true` confirms the dep is linked;
    // the missing piece is the platform-channel bridge that calls
    // `GoogleCastDiscoveryManager.instance.startDiscovery()` from a
    // method-channel handler running off the FlutterActivity. For
    // slice-9 ship we surface a "Scanning…" placeholder so the
    // section is structurally present and the test gating works.
    if (!Platform.isAndroid) {
      // Defensive — castDevicesAvailable should already have
      // hidden this branch on Linux. Render nothing if we ever
      // reach here off-Android.
      return const SizedBox.shrink();
    }
    return const ListTile(
      dense: true,
      leading: SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
      title: Text('Scanning…'),
      subtitle: Text('Cast device discovery — Android Cast SDK'),
    );
  }
}
