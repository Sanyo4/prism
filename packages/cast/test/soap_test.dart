import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prism_cast/cast.dart';
import 'package:xml/xml.dart';

/// Slice-9 §8 step 10 contract: envelope shape (verifiable via
/// XML round-trip), exact `SOAPAction` HTTP header, and parse of
/// recorded `GetTransportInfo` / `GetPositionInfo` responses.
///
/// Hand-rolled dio adapter mirrors the slice-2/8 pattern — no
/// `http_mock_adapter` dep.
void main() {
  late _StubAdapter adapter;
  late Dio dio;
  late Soap soap;
  late DlnaDevice device;

  setUp(() {
    adapter = _StubAdapter();
    dio = Dio()..httpClientAdapter = adapter;
    soap = Soap(dio: dio);
    device = DlnaDevice(
      uuid: '00000000-0000-0000-0000-aabbccddeeff',
      friendlyName: 'STR-DN1080',
      descriptionUrl: Uri.parse(
        'http://192.168.1.42:52323/desc/aiosdevdesc.xml',
      ),
      controlUrl: Uri.parse(
        'http://192.168.1.42:52323/upnp/control/AVTransport',
      ),
      connectionManagerControlUrl: Uri.parse(
        'http://192.168.1.42:52323/upnp/control/ConnectionManager',
      ),
      manufacturer: 'Sony Corporation',
      modelName: 'STR-DN1080',
    );
  });

  group('Soap.buildEnvelope', () {
    test('emits the canonical AVTransport SetAVTransportURI envelope shape',
        () {
      final envelope = soap.buildEnvelope(
        action: 'SetAVTransportURI',
        args: {
          'CurrentURI': 'http://192.168.1.42:54321/track.flac',
          'CurrentURIMetaData': '',
        },
      );
      final doc = XmlDocument.parse(envelope);
      // <s:Envelope xmlns:s="..." s:encodingStyle="...">
      final envelopeEl = doc.rootElement;
      expect(envelopeEl.name.local, 'Envelope');
      expect(
        envelopeEl.getAttribute('xmlns:s'),
        'http://schemas.xmlsoap.org/soap/envelope/',
      );
      expect(
        envelopeEl.getAttribute('s:encodingStyle'),
        'http://schemas.xmlsoap.org/soap/encoding/',
      );
      // <s:Body>
      final body = envelopeEl.childElements.single;
      expect(body.name.local, 'Body');
      // <u:SetAVTransportURI xmlns:u="urn:...AVTransport:1">
      final action = body.childElements.single;
      expect(action.name.local, 'SetAVTransportURI');
      expect(
        action.getAttribute('xmlns:u'),
        'urn:schemas-upnp-org:service:AVTransport:1',
      );
      // Children: InstanceID, CurrentURI, CurrentURIMetaData (in order).
      final children = action.childElements.toList();
      expect(
        children.map((e) => e.name.local).toList(),
        ['InstanceID', 'CurrentURI', 'CurrentURIMetaData'],
      );
      expect(children[0].innerText, '0');
      expect(
        children[1].innerText,
        'http://192.168.1.42:54321/track.flac',
      );
    });

    test('Play envelope omits CurrentURIMetaData and includes Speed=1', () {
      final envelope = soap.buildEnvelope(
        action: 'Play',
        args: {'Speed': '1'},
      );
      final doc = XmlDocument.parse(envelope);
      final action = doc
          .findAllElements('Play', namespace: '*')
          .single;
      expect(action.findElements('Speed').single.innerText, '1');
    });

    test('GetProtocolInfo envelope on ConnectionManager omits InstanceID',
        () {
      final envelope = soap.buildEnvelope(
        action: 'GetProtocolInfo',
        args: const {},
        serviceUrn: kConnectionManagerUrn,
        includeInstanceId: false,
      );
      final doc = XmlDocument.parse(envelope);
      final action =
          doc.findAllElements('GetProtocolInfo', namespace: '*').single;
      expect(action.getAttribute('xmlns:u'), kConnectionManagerUrn);
      expect(
        action.findElements('InstanceID', namespace: '*'),
        isEmpty,
      );
    });
  });

  group('Soap.callAction', () {
    test('sets SOAPAction header with embedded double-quotes per '
        'SOAP 1.1 / HTTP binding', () async {
      adapter.handler = (RequestOptions ro) {
        return ResponseBody.fromString(
          _getTransportInfoResponse,
          200,
          headers: {
            'content-type': ['text/xml; charset="utf-8"'],
          },
        );
      };
      await soap.callAction(device, 'GetTransportInfo');
      final actual = adapter.calls.single.headers['SOAPAction'] ??
          adapter.calls.single.headers['soapaction'];
      expect(
        actual,
        '"urn:schemas-upnp-org:service:AVTransport:1#GetTransportInfo"',
      );
    });

    test('Content-Type is text/xml with charset=utf-8', () async {
      adapter.handler = (_) => ResponseBody.fromString(
            _getTransportInfoResponse,
            200,
            headers: {
              'content-type': ['text/xml; charset="utf-8"'],
            },
          );
      await soap.callAction(device, 'GetTransportInfo');
      final ct = adapter.calls.single.headers['Content-Type'] ??
          adapter.calls.single.headers['content-type'];
      expect(ct, contains('text/xml'));
      expect(ct, contains('charset="utf-8"'));
    });

    test('parses GetTransportInfo into {state, status, speed}', () async {
      adapter.handler = (_) => ResponseBody.fromString(
            _getTransportInfoResponse,
            200,
            headers: {
              'content-type': ['text/xml; charset="utf-8"'],
            },
          );
      final result = await soap.callAction(device, 'GetTransportInfo');
      expect(result['CurrentTransportState'], 'PLAYING');
      expect(result['CurrentTransportStatus'], 'OK');
      expect(result['CurrentSpeed'], '1');
    });

    test('parses GetPositionInfo into {RelTime, TrackDuration, TrackURI}',
        () async {
      adapter.handler = (_) => ResponseBody.fromString(
            _getPositionInfoResponse,
            200,
            headers: {
              'content-type': ['text/xml; charset="utf-8"'],
            },
          );
      final result = await soap.callAction(device, 'GetPositionInfo');
      expect(result['RelTime'], '00:01:23.456');
      expect(result['TrackDuration'], '00:04:32.100');
      expect(
        result['TrackURI'],
        'http://192.168.1.42:54321/abc123.flac',
      );
    });

    test('501 SetNextAVTransportURI surfaces SoapException with '
        'isActionNotSupported=true', () async {
      adapter.handler = (_) => ResponseBody.fromString(
            _faultBody,
            501,
            headers: {
              'content-type': ['text/xml; charset="utf-8"'],
            },
          );
      try {
        await soap.callAction(
          device,
          'SetNextAVTransportURI',
          args: {'NextURI': '', 'NextURIMetaData': ''},
        );
        fail('expected SoapException');
      } on SoapException catch (e) {
        expect(e.isActionNotSupported, isTrue);
        expect(e.statusCode, 501);
        expect(e.action, 'SetNextAVTransportURI');
      }
    });
  });
}

/// Hand-rolled dio adapter — mirrors slice-2's `_StubAdapter`
/// pattern; no `http_mock_adapter` dependency.
class _StubAdapter implements HttpClientAdapter {
  ResponseBody Function(RequestOptions)? handler;
  final List<RequestOptions> calls = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<dynamic>? cancelFuture,
  ) async {
    calls.add(options);
    final h = handler;
    if (h == null) throw StateError('handler not set');
    return h(options);
  }

  @override
  void close({bool force = false}) {}
}

// --- Recorded fixtures (representative AVTransport response bodies) ---

const _getTransportInfoResponse = '''
<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
            s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:GetTransportInfoResponse xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <CurrentTransportState>PLAYING</CurrentTransportState>
      <CurrentTransportStatus>OK</CurrentTransportStatus>
      <CurrentSpeed>1</CurrentSpeed>
    </u:GetTransportInfoResponse>
  </s:Body>
</s:Envelope>
''';

const _getPositionInfoResponse = '''
<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
            s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:GetPositionInfoResponse xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <Track>1</Track>
      <TrackDuration>00:04:32.100</TrackDuration>
      <TrackMetaData></TrackMetaData>
      <TrackURI>http://192.168.1.42:54321/abc123.flac</TrackURI>
      <RelTime>00:01:23.456</RelTime>
      <AbsTime>00:01:23.456</AbsTime>
      <RelCount>0</RelCount>
      <AbsCount>0</AbsCount>
    </u:GetPositionInfoResponse>
  </s:Body>
</s:Envelope>
''';

const _faultBody = '''
<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
            s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <s:Fault>
      <faultcode>s:Client</faultcode>
      <faultstring>UPnPError</faultstring>
      <detail>
        <UPnPError xmlns="urn:schemas-upnp-org:control-1-0">
          <errorCode>501</errorCode>
          <errorDescription>Action Not Supported</errorDescription>
        </UPnPError>
      </detail>
    </s:Fault>
  </s:Body>
</s:Envelope>
''';
