import 'dart:io';

/// LAN-interface picker for the embedded [MediaServer].
///
/// On both Android and Linux we want the address the receiver
/// (STR-DN1080 or Chromecast) can dial to fetch the file. That's
/// almost always the Wi-Fi interface's RFC1918 IPv4 — `192.168/16`
/// on home routers, `10/8` on enterprise / VPN, `172.16/12` on
/// Docker bridge networks (typically excluded). Slice-9 §4 names
/// the filter rules; this class implements them.
///
/// Linux desktop dev environments routinely have a dozen interfaces
/// thanks to Docker (`docker0`, `br-*`, `veth*`), libvirt
/// (`virbr0`), Tailscale / WireGuard (`tun*`, `tap*`, `wg*`), and
/// loopback. Picking the wrong one writes URLs the receiver cannot
/// reach. The filter intentionally drops interface names + addresses
/// that almost never carry LAN traffic; the manual-IP fallback in
/// Track B's settings handles the case where automatic selection
/// gets it wrong.
class IpSelector {
  /// Hidden constructor — `IpSelector` is a static-only utility.
  IpSelector._();

  /// Names containing any of these substrings are filtered out
  /// during candidate generation. The check is case-insensitive
  /// because Android and Linux follow different conventions
  /// (`wlan0` vs `wlp3s0`, `Docker0` vs `docker0`).
  ///
  /// Slice-9 §4 lists these explicitly. We add `bridge` to catch
  /// macOS-flavoured `bridge100` style names from any cross-platform
  /// dev env that might reach this code; it does not reduce the
  /// Linux / Android coverage.
  static const _excludedNameSubstrings = <String>[
    'docker',
    'veth',
    'br-',
    'virbr',
    'lo',
    'tun',
    'tap',
    'wg',
    'bridge',
  ];

  /// Picks the LAN-facing IPv4 address. Returns `null` when no
  /// candidate survives the filter — typical when the dev laptop is
  /// offline or only has loopback + virtual adapters bound.
  ///
  /// Selection prefers `192.168/16`, then `10/8`, then `172.16/12`,
  /// preserving the OS-reported interface order within each tier so
  /// the active default-route iface (typically `wlan0` on Android,
  /// `wlp*` on Linux) wins without a heavyweight route-table probe.
  static Future<InternetAddress?> pickLanAddress() async {
    final candidates = await listCandidates();
    if (candidates.isEmpty) return null;

    InternetAddress? best;
    var bestTier = 4; // 0 = best (192.168/16), 1 = 10/8, 2 = 172.16/12, 3 = other
    for (final addr in candidates) {
      final tier = _tier(addr);
      if (tier < bestTier) {
        bestTier = tier;
        best = addr;
      }
    }
    return best ?? candidates.first;
  }

  /// Returns every IPv4 address that survives the filter, in the
  /// OS-reported interface order. Useful for the test seam and for
  /// future "ambiguous-LAN picker" UI.
  static Future<List<InternetAddress>> listCandidates({
    Future<List<NetworkInterface>> Function()? interfaceProvider,
  }) async {
    final interfaces = await (interfaceProvider ??
        () => NetworkInterface.list(
              includeLoopback: false,
              includeLinkLocal: false,
              type: InternetAddressType.IPv4,
            ))();
    final out = <InternetAddress>[];
    for (final iface in interfaces) {
      if (_isExcludedName(iface.name)) continue;
      for (final addr in iface.addresses) {
        if (addr.type != InternetAddressType.IPv4) continue;
        if (_isExcludedAddress(addr)) continue;
        out.add(addr);
      }
    }
    return out;
  }

  /// `true` when [name] matches any substring in [_excludedNameSubstrings].
  /// Visible for the test seam — public-static `static`-friendly.
  static bool _isExcludedName(String name) {
    final lower = name.toLowerCase();
    for (final pattern in _excludedNameSubstrings) {
      if (lower.contains(pattern)) return true;
    }
    return false;
  }

  /// Filters loopback (`127/8`), link-local (`169.254/16`), multicast
  /// (`224.0.0.0/4`), and the broadcast/zero special-cases. These
  /// shouldn't appear given `includeLoopback: false` +
  /// `includeLinkLocal: false`, but Android's older platform
  /// channels have surfaced 169.254 addresses through the gate; the
  /// guard is cheap.
  static bool _isExcludedAddress(InternetAddress addr) {
    final raw = addr.rawAddress;
    if (raw.length != 4) return true;
    final b0 = raw[0];
    final b1 = raw[1];
    if (b0 == 127) return true; // 127/8 loopback
    if (b0 == 169 && b1 == 254) return true; // link-local
    if (b0 >= 224 && b0 <= 239) return true; // multicast
    if (b0 == 0) return true; // 0.0.0.0
    if (b0 == 255) return true; // 255.255.255.255
    return false;
  }

  /// Returns 0 for `192.168/16`, 1 for `10/8`, 2 for `172.16/12`, 3
  /// for any other private-or-public IPv4. Lower is better.
  static int _tier(InternetAddress addr) {
    final raw = addr.rawAddress;
    if (raw.length != 4) return 3;
    final b0 = raw[0];
    final b1 = raw[1];
    if (b0 == 192 && b1 == 168) return 0;
    if (b0 == 10) return 1;
    if (b0 == 172 && b1 >= 16 && b1 <= 31) return 2;
    return 3;
  }
}
