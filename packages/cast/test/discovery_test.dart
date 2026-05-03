import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:prism_cast/cast.dart';

/// Slice-9 §8 step 7+8 contract: the M-SEARCH datagram emits the
/// IETF-required header set verbatim, and the description-XML
/// parser walks a recorded STR-DN1080-style fixture into a usable
/// [DlnaDevice] (controlURL resolved against URLBase / description
/// URL).
///
/// Live multicast / dio I/O is exercised on-device per slice-9 §11
/// items 2-4; this test suite stays deterministic.
void main() {
  group('M-SEARCH datagram shape', () {
    test('contains every required header from the IETF SSDP draft', () {
      final bytes = buildMSearchDatagram();
      final body = utf8.decode(bytes);
      // Request line.
      expect(body, startsWith('M-SEARCH * HTTP/1.1\r\n'));
      // Required headers (literal text, including the embedded
      // double-quotes around "ssdp:discover" per the IETF draft).
      expect(body, contains('HOST: 239.255.255.250:1900\r\n'));
      expect(body, contains('MAN: "ssdp:discover"\r\n'));
      expect(body, contains('MX: 2\r\n'));
      expect(
        body,
        contains('ST: urn:schemas-upnp-org:service:AVTransport:1\r\n'),
      );
      // Trailing blank line ending the headers.
      expect(body, endsWith('\r\n\r\n'));
    });

    test('honours the searchTarget + mxSeconds overrides', () {
      final body = utf8.decode(
        buildMSearchDatagram(
          searchTarget: 'ssdp:all',
          mxSeconds: 5,
        ),
      );
      expect(body, contains('ST: ssdp:all\r\n'));
      expect(body, contains('MX: 5\r\n'));
    });
  });

  group('parseSsdpResponse', () {
    test('lowercases header keys and trims values', () {
      const body = 'HTTP/1.1 200 OK\r\n'
          'LOCATION: http://192.168.1.42:52323/desc/aiosdevdesc.xml\r\n'
          'USN: uuid:00000000-0000-0000-0000-aabbccddeeff::urn:schemas-upnp-org:service:AVTransport:1\r\n'
          'ST: urn:schemas-upnp-org:service:AVTransport:1\r\n'
          'CACHE-CONTROL: max-age=1800\r\n'
          '\r\n';
      final headers = parseSsdpResponse(body);
      expect(
        headers['location'],
        'http://192.168.1.42:52323/desc/aiosdevdesc.xml',
      );
      expect(
        headers['usn'],
        'uuid:00000000-0000-0000-0000-aabbccddeeff::urn:schemas-upnp-org:service:AVTransport:1',
      );
      expect(
        headers['st'],
        'urn:schemas-upnp-org:service:AVTransport:1',
      );
      expect(headers['cache-control'], 'max-age=1800');
    });
  });

  group('extractUuidFromUsn', () {
    test('extracts UUID from a service-form USN', () {
      const usn =
          'uuid:00000000-0000-0000-0000-aabbccddeeff::urn:schemas-upnp-org:service:AVTransport:1';
      expect(
        extractUuidFromUsn(usn),
        '00000000-0000-0000-0000-aabbccddeeff',
      );
    });

    test('extracts UUID from a bare uuid: USN (no service suffix)', () {
      const usn = 'uuid:00000000-0000-0000-0000-aabbccddeeff';
      expect(
        extractUuidFromUsn(usn),
        '00000000-0000-0000-0000-aabbccddeeff',
      );
    });

    test('returns null for malformed input', () {
      expect(extractUuidFromUsn('not-a-uuid'), isNull);
    });
  });

  group('parseDescriptionXml', () {
    test('walks a STR-DN1080-style fixture into a usable DlnaDevice', () {
      final descriptionUrl = Uri.parse(
        'http://192.168.1.42:52323/desc/aiosdevdesc.xml',
      );
      final device = parseDescriptionXml(
        _strDn1080Fixture,
        descriptionUrl: descriptionUrl,
        usnUuid: '00000000-0000-0000-0000-aabbccddeeff',
      );
      expect(device.uuid, '00000000-0000-0000-0000-aabbccddeeff');
      expect(device.friendlyName, 'STR-DN1080');
      expect(device.manufacturer, 'Sony Corporation');
      expect(device.modelName, 'STR-DN1080');
      expect(device.looksLikeStrDn1080, isTrue);
      // controlURL is relative in the fixture — must be resolved
      // against URLBase.
      expect(
        device.controlUrl.toString(),
        'http://192.168.1.42:52323/upnp/control/AVTransport',
      );
      expect(
        device.connectionManagerControlUrl.toString(),
        'http://192.168.1.42:52323/upnp/control/ConnectionManager',
      );
    });

    test('falls back to descriptionUrl when URLBase is missing', () {
      // Strip the <URLBase> element from the fixture.
      final stripped = _strDn1080Fixture.replaceFirst(
        RegExp(r'<URLBase>[^<]*</URLBase>\s*'),
        '',
      );
      final descriptionUrl = Uri.parse(
        'http://192.168.1.42:52323/desc/aiosdevdesc.xml',
      );
      final device = parseDescriptionXml(
        stripped,
        descriptionUrl: descriptionUrl,
      );
      // Still resolves against the description URL's host:port.
      expect(
        device.controlUrl.host,
        '192.168.1.42',
      );
      expect(device.controlUrl.port, 52323);
      expect(
        device.controlUrl.path,
        '/upnp/control/AVTransport',
      );
    });

    test('throws FormatException on a description without AVTransport', () {
      const noAv = '''
<?xml version="1.0" encoding="utf-8"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <device>
    <friendlyName>Random Printer</friendlyName>
    <manufacturer>Acme</manufacturer>
    <modelName>RP-9000</modelName>
    <UDN>uuid:11111111-1111-1111-1111-111111111111</UDN>
    <serviceList>
      <service>
        <serviceType>urn:schemas-upnp-org:service:Printer:1</serviceType>
        <controlURL>/upnp/control/Printer</controlURL>
      </service>
    </serviceList>
  </device>
</root>
''';
      expect(
        () => parseDescriptionXml(
          noAv,
          descriptionUrl: Uri.parse('http://192.168.1.50:631/desc.xml'),
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('parses sinkProtocolInfo when supplied (post-GetProtocolInfo)', () {
      final descriptionUrl = Uri.parse(
        'http://192.168.1.42:52323/desc/aiosdevdesc.xml',
      );
      final device = parseDescriptionXml(
        _strDn1080Fixture,
        descriptionUrl: descriptionUrl,
        getProtocolInfoSink: const {
          'http-get:*:audio/flac:*',
          'http-get:*:audio/mpeg:*',
        },
      );
      expect(device.supportsFlacSink, isTrue);
      expect(device.sinkProtocolInfo, hasLength(2));
    });
  });
}

/// Hand-crafted STR-DN1080-shaped description XML. Mirrors the
/// public structure documented for Sony AV receivers — `<URLBase>`
/// declared, `<serviceList>` with AVTransport + ConnectionManager
/// (relative `<controlURL>`s), `<UDN>uuid:...` and the standard
/// device-info elements. Slice-9 §11 verifies the live receiver's
/// description against this expected shape.
const _strDn1080Fixture = '''
<?xml version="1.0" encoding="utf-8"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <specVersion>
    <major>1</major>
    <minor>0</minor>
  </specVersion>
  <URLBase>http://192.168.1.42:52323/</URLBase>
  <device>
    <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
    <friendlyName>STR-DN1080</friendlyName>
    <manufacturer>Sony Corporation</manufacturer>
    <manufacturerURL>http://www.sony.net/</manufacturerURL>
    <modelDescription>Multi Channel AV Receiver</modelDescription>
    <modelName>STR-DN1080</modelName>
    <UDN>uuid:00000000-0000-0000-0000-aabbccddeeff</UDN>
    <serviceList>
      <service>
        <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
        <serviceId>urn:upnp-org:serviceId:AVTransport</serviceId>
        <SCPDURL>/upnp/scpd/AVTransport.xml</SCPDURL>
        <controlURL>upnp/control/AVTransport</controlURL>
        <eventSubURL>/upnp/event/AVTransport</eventSubURL>
      </service>
      <service>
        <serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType>
        <serviceId>urn:upnp-org:serviceId:ConnectionManager</serviceId>
        <SCPDURL>/upnp/scpd/ConnectionManager.xml</SCPDURL>
        <controlURL>upnp/control/ConnectionManager</controlURL>
        <eventSubURL>/upnp/event/ConnectionManager</eventSubURL>
      </service>
      <service>
        <serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
        <serviceId>urn:upnp-org:serviceId:RenderingControl</serviceId>
        <SCPDURL>/upnp/scpd/RenderingControl.xml</SCPDURL>
        <controlURL>upnp/control/RenderingControl</controlURL>
        <eventSubURL>/upnp/event/RenderingControl</eventSubURL>
      </service>
    </serviceList>
  </device>
</root>
''';
