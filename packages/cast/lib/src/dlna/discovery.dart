import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:xml/xml.dart';

import 'dlna_device.dart';
import 'soap.dart';

/// SSDP multicast group + port. Pinned by RFC; not configurable.
const String kSsdpMulticastAddr = '239.255.255.250';
const int kSsdpMulticastPort = 1900;

/// Sony STR-DN1080's default UPnP description port. Used by
/// [Discovery.probeManual] when the user types just an IP.
const int kSonyDescriptionPort = 52323;

/// Builds the literal M-SEARCH datagram body. UPnP / IETF SSDP
/// requires:
/// - `MAN:` value `"ssdp:discover"` literally double-quoted.
/// - CRLF (`\r\n`) line endings between every header.
/// - A trailing blank line (`\r\n`) terminating the headers.
///
/// Exposed as a top-level function so the discovery test can assert
/// the wire format without binding a real socket.
List<int> buildMSearchDatagram({
  String searchTarget = 'urn:schemas-upnp-org:service:AVTransport:1',
  int mxSeconds = 2,
}) {
  final body = 'M-SEARCH * HTTP/1.1\r\n'
      'HOST: $kSsdpMulticastAddr:$kSsdpMulticastPort\r\n'
      'MAN: "ssdp:discover"\r\n'
      'MX: $mxSeconds\r\n'
      'ST: $searchTarget\r\n'
      '\r\n';
  return utf8.encode(body);
}

/// Parses an HTTP-over-UDP response into a key→value map. Headers
/// are lowercased (HTTP headers are case-insensitive). The status
/// line is dropped — only headers are surfaced.
Map<String, String> parseSsdpResponse(String body) {
  final out = <String, String>{};
  final lines = body.split('\r\n');
  for (final line in lines.skip(1)) {
    if (line.isEmpty) continue;
    final colon = line.indexOf(':');
    if (colon < 0) continue;
    final key = line.substring(0, colon).trim().toLowerCase();
    final value = line.substring(colon + 1).trim();
    out[key] = value;
  }
  return out;
}

/// Extracts the UUID from an SSDP `USN:` value.
///
/// `USN: uuid:<UUID>::urn:schemas-upnp-org:service:AVTransport:1`
/// → `<UUID>`. Returns `null` for malformed input.
String? extractUuidFromUsn(String usn) {
  final lower = usn.toLowerCase();
  const prefix = 'uuid:';
  if (!lower.startsWith(prefix)) return null;
  final rest = usn.substring(prefix.length);
  final sepIdx = rest.indexOf('::');
  return sepIdx < 0 ? rest : rest.substring(0, sepIdx);
}

/// Walks a UPnP device-description XML string and produces a
/// [DlnaDevice]. The [descriptionUrl] is needed because some
/// receivers omit `<URLBase>` and use relative `controlURL`s — we
/// resolve those against the description URL.
///
/// [getProtocolInfoSink] (optional) is the CSV sink list parsed
/// from a separate `GetProtocolInfo` SOAP call; pre-supplied to
/// keep the parser pure (no I/O).
DlnaDevice parseDescriptionXml(
  String xmlBody, {
  required Uri descriptionUrl,
  Set<String> getProtocolInfoSink = const <String>{},
  String? usnUuid,
}) {
  final doc = XmlDocument.parse(xmlBody);
  final root = doc.rootElement;

  String findText(String localName, {XmlElement? scope}) {
    final search = scope ?? root;
    for (final node in search.descendantElements) {
      if (node.localName == localName) return node.innerText.trim();
    }
    return '';
  }

  // <URLBase> may live under <root>; if absent we resolve against
  // descriptionUrl.
  final urlBaseText = findText('URLBase');
  final base = urlBaseText.isEmpty
      ? descriptionUrl.replace(path: '', query: '', fragment: '')
      : Uri.parse(urlBaseText);

  final friendlyName = findText('friendlyName');
  final manufacturer = findText('manufacturer');
  final modelName = findText('modelName');

  // Walk every <service> element; pick AVTransport + ConnectionManager
  // by its <serviceType>.
  Uri? avControl;
  Uri? cmControl;
  for (final svc in doc.findAllElements('service')) {
    String childText(String name) {
      for (final node in svc.descendantElements) {
        if (node.localName == name) return node.innerText.trim();
      }
      return '';
    }

    final svcType = childText('serviceType');
    final ctrl = childText('controlURL');
    if (ctrl.isEmpty) continue;
    final resolved = base.resolve(ctrl);
    if (svcType.contains('AVTransport')) {
      avControl = resolved;
    } else if (svcType.contains('ConnectionManager')) {
      cmControl = resolved;
    }
  }

  if (avControl == null) {
    throw const FormatException(
      'description XML has no AVTransport service / controlURL',
    );
  }
  // ConnectionManager is mandatory in the UPnP MediaRenderer profile;
  // if a description omits it, fall back to AVTransport's URL so
  // GetProtocolInfo at least addresses something. Slice-9's UI
  // gates on `supportsFlacSink` so the worst case is no auto-confirm.
  cmControl ??= avControl;

  final uuid = usnUuid ??
      _extractUuidFromUdn(findText('UDN')) ??
      'unknown:${descriptionUrl.host}:${descriptionUrl.port}';

  return DlnaDevice(
    uuid: uuid,
    friendlyName: friendlyName.isEmpty ? modelName : friendlyName,
    descriptionUrl: descriptionUrl,
    controlUrl: avControl,
    connectionManagerControlUrl: cmControl,
    manufacturer: manufacturer,
    modelName: modelName,
    sinkProtocolInfo: getProtocolInfoSink,
  );
}

String? _extractUuidFromUdn(String udn) {
  // `<UDN>uuid:00000000-0000-0000-0000-aabbccddeeff</UDN>`
  if (udn.isEmpty) return null;
  final lower = udn.toLowerCase();
  const prefix = 'uuid:';
  if (!lower.startsWith(prefix)) return udn;
  return udn.substring(prefix.length);
}

/// SSDP discovery service.
///
/// Drives M-SEARCH on subscription and every 5 minutes while the
/// returned stream has listeners; pauses when the listener detaches.
/// Description fetch + `GetProtocolInfo` runs on every newly-seen
/// device; existing devices are not re-fetched on subsequent
/// refreshes. Devices are deduped on UUID.
///
/// Track B's UI subscribes to [stream] and pumps each list into the
/// cast-sheet picker.
class Discovery {
  Discovery({
    Soap? soap,
    Dio? dio,
    Future<RawDatagramSocket> Function()? socketFactory,
    Duration searchWindow = const Duration(seconds: 3),
    Duration refreshInterval = const Duration(minutes: 5),
  })  : _soap = soap ?? Soap(dio: dio),
        _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 3),
              receiveTimeout: const Duration(seconds: 3),
              responseType: ResponseType.plain,
            )),
        _socketFactory = socketFactory ??
            (() => RawDatagramSocket.bind(InternetAddress.anyIPv4, 0)),
        _searchWindow = searchWindow,
        _refreshInterval = refreshInterval;

  final Soap _soap;
  final Dio _dio;
  final Future<RawDatagramSocket> Function() _socketFactory;
  final Duration _searchWindow;
  final Duration _refreshInterval;

  final Map<String, DlnaDevice> _known = {};
  // The lint can't see [dispose] closes the controller when non-null.
  // ignore: close_sinks
  StreamController<List<DlnaDevice>>? _controller;
  Timer? _refreshTimer;

  /// Broadcast stream of the current device list. Track B's UI
  /// listens and rebuilds the cast-sheet on every emission.
  /// Subscribing triggers the first M-SEARCH; cancelling the last
  /// listener stops the refresh timer.
  Stream<List<DlnaDevice>> get stream {
    _controller ??= StreamController<List<DlnaDevice>>.broadcast(
      onListen: _start,
      onCancel: _stop,
    );
    return _controller!.stream;
  }

  /// Manual-IP probe (slice 9 §8 step 16). Fetches the description
  /// XML at common paths and returns the parsed [DlnaDevice] if
  /// AVTransport is present; otherwise `null`.
  Future<DlnaDevice?> probeManual(
    InternetAddress ip, {
    int port = kSonyDescriptionPort,
    List<String> paths = const [
      '/desc/aiosdevdesc.xml',
      '/dmr.xml',
      '/description.xml',
      '/MediaRenderer.xml',
    ],
  }) async {
    for (final path in paths) {
      final url = Uri(scheme: 'http', host: ip.address, port: port, path: path);
      try {
        final res = await _dio.get<String>(url.toString());
        if (res.statusCode != 200) continue;
        final body = res.data ?? '';
        if (!body.contains('AVTransport')) continue;
        final device = parseDescriptionXml(
          body,
          descriptionUrl: url,
        );
        final withSink = await _addProtocolInfo(device);
        _known[device.uuid] = withSink;
        _emit();
        return withSink;
      } on Object {
        // Try next path.
      }
    }
    return null;
  }

  /// Synchronously surfaces the most recently emitted device list.
  /// Useful for tests that already drove a refresh.
  List<DlnaDevice> snapshot() => List.unmodifiable(_known.values);

  /// Releases the stream controller + cancels the refresh timer.
  Future<void> dispose() async {
    _refreshTimer?.cancel();
    _refreshTimer = null;
    final c = _controller;
    _controller = null;
    if (c != null && !c.isClosed) {
      await c.close();
    }
  }

  void _start() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(_refreshInterval, (_) {
      unawaited(_refresh());
    });
    unawaited(_refresh());
  }

  void _stop() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
  }

  Future<void> _refresh() async {
    try {
      final socket = await _socketFactory();
      try {
        socket.broadcastEnabled = true;
        socket.joinMulticast(InternetAddress(kSsdpMulticastAddr));

        final responses = <String, Map<String, String>>{};
        final completer = Completer<void>();
        final sub = socket.listen((event) {
          if (event != RawSocketEvent.read) return;
          final dg = socket.receive();
          if (dg == null) return;
          final body = utf8.decode(dg.data, allowMalformed: true);
          final headers = parseSsdpResponse(body);
          final usn = headers['usn'];
          if (usn == null) return;
          final uuid = extractUuidFromUsn(usn);
          if (uuid == null) return;
          responses[uuid] = headers;
        });

        socket.send(
          buildMSearchDatagram(),
          InternetAddress(kSsdpMulticastAddr),
          kSsdpMulticastPort,
        );

        Timer(_searchWindow, () {
          if (!completer.isCompleted) completer.complete();
        });
        await completer.future;
        await sub.cancel();

        for (final entry in responses.entries) {
          final uuid = entry.key;
          if (_known.containsKey(uuid)) continue;
          final location = entry.value['location'];
          if (location == null) continue;
          try {
            final device = await _fetchDevice(
              Uri.parse(location),
              uuidHint: uuid,
            );
            _known[uuid] = device;
          } on Object {
            // Skip — can't reach LOCATION or it's not a MediaRenderer.
          }
        }
      } finally {
        socket.close();
      }
    } on Object {
      // M-SEARCH failed wholesale (e.g. no Wi-Fi). Keep the existing
      // list — Track B's UI shows "No devices found" when empty.
    }
    _emit();
  }

  Future<DlnaDevice> _fetchDevice(
    Uri descriptionUrl, {
    String? uuidHint,
  }) async {
    final res = await _dio.get<String>(descriptionUrl.toString());
    if (res.statusCode != 200) {
      throw HttpException('description fetch failed: ${res.statusCode}');
    }
    final body = res.data ?? '';
    final device = parseDescriptionXml(
      body,
      descriptionUrl: descriptionUrl,
      usnUuid: uuidHint,
    );
    return _addProtocolInfo(device);
  }

  Future<DlnaDevice> _addProtocolInfo(DlnaDevice device) async {
    try {
      final res = await _soap.callAction(
        device,
        'GetProtocolInfo',
        serviceUrn: kConnectionManagerUrn,
        includeInstanceId: false,
      );
      final sinkCsv = res['Sink'] ?? '';
      final entries = sinkCsv
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toSet();
      return DlnaDevice(
        uuid: device.uuid,
        friendlyName: device.friendlyName,
        descriptionUrl: device.descriptionUrl,
        controlUrl: device.controlUrl,
        connectionManagerControlUrl: device.connectionManagerControlUrl,
        manufacturer: device.manufacturer,
        modelName: device.modelName,
        sinkProtocolInfo: entries,
      );
    } on Object {
      // Receiver returned no protocol info; the device still works —
      // the UI won't show a green "FLAC sink confirmed" badge but
      // SetAVTransportURI will still be attempted.
      return device;
    }
  }

  void _emit() {
    final c = _controller;
    if (c == null || c.isClosed) return;
    c.add(snapshot());
  }
}
