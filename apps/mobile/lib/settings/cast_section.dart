import 'dart:io' show InternetAddress;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/cast_providers.dart';
import '../shell/settings_sections.dart';

/// Slice-9 §6 step 14 / §8 step 16 — Settings → Cast & DLNA section.
///
/// Five rows in order:
///
/// 1. **Header** "Cast & DLNA".
/// 2. **Discovered devices** mirror — read-only list pulled from
///    [castDiscoveryProvider]. Identical content to the cast sheet
///    minus the "Local" entry (Settings is the diagnostics surface;
///    Local isn't a remote endpoint to "configure").
/// 3. **Add device by IP** — text field + Probe button. On submit:
///    parse with `InternetAddress.tryParse(ip)`, call
///    `Discovery.probeManual(addr)`. On success the device joins the
///    discovery stream (Track A's `Discovery` calls `_emit()` on
///    every successful probe); on failure the snackbar surfaces the
///    cause.
/// 4. **Persisted manual IPs** — chip list with delete buttons. Tied
///    to [manualIpListProvider] which reads/writes
///    `prism.cast.manual_ips` in SharedPreferences.
/// 5. **Lossy notice** — informational row. Always visible
///    (informational on Linux too) per the brief: "always lossy in
///    this slice".
/// 6. **Verbose SOAP log** — debug `SwitchListTile` flipping
///    [verboseSoapLogProvider]. Persisted to
///    `prism.cast.verbose_soap`.
class CastSection extends ConsumerStatefulWidget {
  const CastSection({super.key});

  @override
  ConsumerState<CastSection> createState() => _CastSectionState();
}

class _CastSectionState extends ConsumerState<CastSection> {
  late final TextEditingController _ipController;
  bool _probing = false;

  @override
  void initState() {
    super.initState();
    _ipController = TextEditingController();
  }

  @override
  void dispose() {
    _ipController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final discoveryAsync = ref.watch(castDiscoveryProvider);
    final manualIpsAsync = ref.watch(manualIpListProvider);
    final verboseSoapAsync = ref.watch(verboseSoapLogProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SettingsSectionHeader(title: 'Cast & DLNA'),

        // 2. Discovered devices mirror.
        ...discoveryAsync.when(
          data: (devices) {
            if (devices.isEmpty) {
              return const <Widget>[
                ListTile(
                  dense: true,
                  leading: Icon(Icons.search),
                  title: Text('No devices discovered yet'),
                  subtitle: Text(
                      'SSDP scans run for 3 s on the cast sheet, '
                      'and refresh every 5 min while the sheet is open.'),
                ),
              ];
            }
            return devices
                .map<Widget>((d) => ListTile(
                      dense: true,
                      leading: Icon(
                        d.looksLikeStrDn1080
                            ? Icons.speaker
                            : Icons.speaker_outlined,
                      ),
                      title: Text(d.friendlyName),
                      subtitle: Text(
                        d.modelName.isEmpty ? d.manufacturer : d.modelName,
                      ),
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

        // 3. Add by IP.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _ipController,
                  decoration: const InputDecoration(
                    labelText: 'Add device by IP',
                    hintText: '192.168.1.42',
                    isDense: true,
                  ),
                  keyboardType: TextInputType.number,
                  onSubmitted: (_) => _onProbe(context),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.tonal(
                onPressed: _probing ? null : () => _onProbe(context),
                child: _probing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Probe'),
              ),
            ],
          ),
        ),

        // 4. Persisted manual IPs.
        manualIpsAsync.when(
          data: (ips) => ips.isEmpty
              ? const SizedBox.shrink()
              : Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      for (final ip in ips)
                        InputChip(
                          label: Text(ip),
                          onDeleted: () => ref
                              .read(manualIpListProvider.notifier)
                              .remove(ip),
                        ),
                    ],
                  ),
                ),
          loading: () => const SizedBox.shrink(),
          error: (e, _) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text('Failed to load saved IPs: $e'),
          ),
        ),

        // 5. Lossy notice — informational, no platform gate.
        const ListTile(
          dense: true,
          leading: Icon(Icons.info_outline),
          title: Text('Chromecast quality is always 128 kbps AAC'),
          subtitle: Text(
              'Chromecast cannot reliably carry hi-res FLAC. DLNA '
              'pushes the original file at source rate.'),
        ),

        // 6. Verbose SOAP log toggle.
        SwitchListTile(
          dense: true,
          secondary: const Icon(Icons.bug_report_outlined),
          title: const Text('Verbose SOAP log (debug)'),
          subtitle: const Text(
              'Logs every AVTransport request + response body. '
              'Off by default.'),
          value: verboseSoapAsync.value ?? false,
          onChanged: verboseSoapAsync.hasValue
              ? (v) => ref.read(verboseSoapLogProvider.notifier).set(v)
              : null,
        ),
      ],
    );
  }

  Future<void> _onProbe(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final raw = _ipController.text.trim();
    if (raw.isEmpty) return;
    final addr = InternetAddress.tryParse(raw);
    if (addr == null) {
      messenger?.showSnackBar(
        const SnackBar(content: Text('Not a valid IPv4 address.')),
      );
      return;
    }
    setState(() => _probing = true);
    try {
      final discovery = ref.read(discoveryProvider);
      final device = await discovery.probeManual(addr);
      if (device == null) {
        messenger?.showSnackBar(
          SnackBar(
              content: Text('No DLNA MediaRenderer at ${addr.address}')),
        );
        return;
      }
      // Persist on success so the IP re-probes on next launch.
      await ref.read(manualIpListProvider.notifier).add(addr.address);
      _ipController.clear();
      messenger?.showSnackBar(
        SnackBar(content: Text('Added ${device.friendlyName}')),
      );
    } on Object catch (e) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Probe failed: $e')),
      );
    } finally {
      if (mounted) {
        setState(() => _probing = false);
      }
    }
  }
}
