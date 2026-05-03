import 'dart:async';

import 'package:dio/dio.dart';
import 'package:xml/xml.dart';

import 'dlna_device.dart';

/// AVTransport service URN. Embedded in the SOAP envelope and the
/// `SOAPAction` HTTP header. Pinned at AV1; receivers like the
/// STR-DN1080 are revision-locked here.
const String kAvTransportUrn =
    'urn:schemas-upnp-org:service:AVTransport:1';

/// ConnectionManager service URN. Used only for the initial
/// `GetProtocolInfo` call that populates a [DlnaDevice]'s sink list.
const String kConnectionManagerUrn =
    'urn:schemas-upnp-org:service:ConnectionManager:1';

/// Raised when an AVTransport action is rejected with an HTTP 5xx
/// status. [statusCode] is the wire status; [body] is the verbatim
/// response (typically a SOAP `<s:Fault>`).
///
/// 501 is the §10 risk 8 trigger — `SetNextAVTransportURI` may
/// return 501 "Action Not Supported" on receivers without gapless
/// support; the caller falls back to hard-next.
class SoapException implements Exception {
  const SoapException(
    this.action, {
    required this.statusCode,
    required this.body,
  });

  /// AVTransport action that produced the fault.
  final String action;

  /// HTTP status code from the receiver.
  final int statusCode;

  /// Verbatim response body. Surfaced verbose-log mode for triage.
  final String body;

  /// `true` for `501 Action Not Supported`. Caller-side check.
  bool get isActionNotSupported => statusCode == 501;

  @override
  String toString() =>
      'SoapException($action, status=$statusCode): $body';
}

/// Builds SOAP envelopes for AVTransport actions and posts them via
/// `dio` to a [DlnaDevice]'s `controlUrl`.
///
/// Envelopes are constructed with `package:xml`'s `XmlBuilder`
/// — never string concatenation — so escape rules for `<` `>` `&`
/// `"` `'` are handled by the library. DIDL-Lite metadata is
/// embedded as a string inside `<CurrentURIMetaData>`; the outer
/// envelope's `builder.text(...)` performs the second escape pass
/// automatically.
class Soap {
  Soap({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 3),
              receiveTimeout: const Duration(seconds: 5),
              responseType: ResponseType.plain,
              validateStatus: (s) => s != null && s < 600,
            ));

  final Dio _dio;

  /// Constructs a SOAP envelope for [action] with [args] under the
  /// AVTransport service URN. [serviceUrn] is overridable so the
  /// same builder powers ConnectionManager calls (`GetProtocolInfo`).
  ///
  /// Order of [args] is preserved — UPnP services are forgiving but
  /// some implementations (notably Linn-firmware DSes) parse
  /// positionally.
  String buildEnvelope({
    required String action,
    required Map<String, String> args,
    int instanceId = 0,
    String serviceUrn = kAvTransportUrn,
    bool includeInstanceId = true,
  }) {
    final builder = XmlBuilder();
    builder.processing('xml', 'version="1.0" encoding="utf-8"');
    builder.element('s:Envelope', nest: () {
      builder.attribute(
        'xmlns:s',
        'http://schemas.xmlsoap.org/soap/envelope/',
      );
      builder.attribute(
        's:encodingStyle',
        'http://schemas.xmlsoap.org/soap/encoding/',
      );
      builder.element('s:Body', nest: () {
        builder.element('u:$action', nest: () {
          builder.attribute('xmlns:u', serviceUrn);
          if (includeInstanceId) {
            builder.element('InstanceID', nest: () {
              builder.text(instanceId.toString());
            });
          }
          for (final entry in args.entries) {
            builder.element(entry.key, nest: () {
              builder.text(entry.value);
            });
          }
        });
      });
    });
    return builder.buildDocument().toXmlString();
  }

  /// Posts [action] to [device]'s AVTransport `controlURL` with
  /// [args]. Returns a `Map<String, String>` of the response
  /// out-arguments (e.g. for `GetTransportInfo`,
  /// `{'CurrentTransportState': 'PLAYING', ...}`).
  ///
  /// Throws [SoapException] on a 5xx response (500, 501).
  /// `validateStatus` lets 4xx through so the caller can inspect
  /// device-specific error responses if needed.
  Future<Map<String, String>> callAction(
    DlnaDevice device,
    String action, {
    Map<String, String> args = const {},
    int instanceId = 0,
    String serviceUrn = kAvTransportUrn,
    bool includeInstanceId = true,
  }) async {
    final body = buildEnvelope(
      action: action,
      args: args,
      instanceId: instanceId,
      serviceUrn: serviceUrn,
      includeInstanceId: includeInstanceId,
    );
    final controlUrl = serviceUrn == kConnectionManagerUrn
        ? device.connectionManagerControlUrl
        : device.controlUrl;
    final res = await _dio.post<String>(
      controlUrl.toString(),
      data: body,
      options: Options(
        headers: <String, dynamic>{
          'SOAPAction': '"$serviceUrn#$action"',
          'Content-Type': 'text/xml; charset="utf-8"',
        },
        // Send raw XML; dio's ImplyContentTypeInterceptor would
        // otherwise stamp application/json on a String body.
        contentType: 'text/xml; charset="utf-8"',
        // Caller may construct Soap with their own Dio (e.g. tests'
        // hand-rolled adapter, which uses Dio's default
        // validateStatus = s < 500). Override per-call so 5xx /
        // 501 "Action Not Supported" surface as a Response we can
        // inspect, not a thrown DioException.
        validateStatus: (s) => s != null && s < 600,
        responseType: ResponseType.plain,
      ),
    );
    final text = res.data ?? '';
    if (res.statusCode == null || res.statusCode! >= 500) {
      throw SoapException(
        action,
        statusCode: res.statusCode ?? 0,
        body: text,
      );
    }
    return _parseResponse(text);
  }

  /// Parses the SOAP response body, walking the namespace-prefixed
  /// `<u:ActionResponse>` element and emitting its child element
  /// names + text content as a flat map. Robust against namespace
  /// prefix variation (some receivers use `s:`, others `SOAP-ENV:`)
  /// because we look up by local name.
  static Map<String, String> _parseResponse(String body) {
    if (body.trim().isEmpty) return const {};
    final doc = XmlDocument.parse(body);
    final result = <String, String>{};
    // The response element is typically `<u:ActionNameResponse>`.
    // Walk every element under <Body> with local-name ending in
    // 'Response'; emit its children's local-name → text content.
    final bodies = doc.findAllElements('Body', namespace: '*');
    for (final body in bodies) {
      for (final child in body.childElements) {
        for (final field in child.childElements) {
          result[field.localName] = field.innerText;
        }
      }
    }
    return result;
  }

  /// Releases the underlying dio handle. Safe to omit when the
  /// caller already manages a long-lived dio.
  void dispose() {
    _dio.close(force: true);
  }
}
