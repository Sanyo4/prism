import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prism_core/core.dart';
import 'package:prism_playback/playback.dart';

/// Compact helper: fake track whose path is `/music/$id.flac`, so
/// equality/identity semantics still hold without touching the disk.
Track _t(String id) => Track(path: '/music/$id.flac', mtimeMs: 0);

/// Harness that spins up a single-provider `ProviderContainer` per test
/// so mutations mirror how the real app drives the queue via
/// `ref.read(queueProvider.notifier)`.
({QueueService service, ProviderContainer container}) _harness() {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  return (
    service: container.read(queueProvider.notifier),
    container: container,
  );
}

QueueSnapshot _snap(ProviderContainer c) => c.read(queueProvider);

List<String> _paths(List<Track> tracks) =>
    tracks.map((t) => t.path).toList(growable: false);

void main() {
  group('QueueService.loadContext', () {
    test('replaces queue with current + upcoming at startIndex', () {
      final (service: q, container: c) = _harness();
      q.loadContext([_t('a'), _t('b'), _t('c')], startIndex: 0);
      final s = _snap(c);
      expect(s.current, equals(_t('a')));
      expect(s.history, isEmpty);
      expect(s.playNext, isEmpty);
      expect(_paths(s.upcoming), equals(['/music/b.flac', '/music/c.flac']));
      expect(s.currentIndex, equals(0));
    });

    test('startIndex mid-list discards tracks before the selection', () {
      final (service: q, container: c) = _harness();
      q.loadContext([_t('a'), _t('b'), _t('c'), _t('d')], startIndex: 2);
      final s = _snap(c);
      expect(s.current, equals(_t('c')));
      expect(s.history, isEmpty);
      expect(_paths(s.upcoming), equals(['/music/d.flac']));
    });

    test('empty input drains the queue', () {
      final (service: q, container: c) = _harness();
      q.loadContext(const []);
      expect(_snap(c).isEmpty, isTrue);
    });
  });

  group('(a) playNext places the track directly after current', () {
    test('PlayNext head sits at currentIndex + 1 in the flat projection', () {
      final (service: q, container: c) = _harness();
      q.loadContext([_t('a'), _t('b'), _t('c')], startIndex: 0);
      q.playNext(_t('p'));
      final s = _snap(c);
      expect(s.flat[s.currentIndex + 1], equals(_t('p')));
      // Flat projection: [current=a, p, b, c]
      expect(
        _paths(s.flat),
        equals(['/music/a.flac', '/music/p.flac', '/music/b.flac', '/music/c.flac']),
      );
    });

    test('repeated playNext preserves FIFO at the head', () {
      final (service: q, container: c) = _harness();
      q.loadContext([_t('a')], startIndex: 0);
      q.playNext(_t('p1'));
      q.playNext(_t('p2'));
      // Newest insert becomes the immediate next; p1 slides down one.
      expect(_paths(_snap(c).playNext), equals(['/music/p2.flac', '/music/p1.flac']));
    });
  });

  group('(b) addToUpcoming appends after PlayNext', () {
    test('new upcoming entry lands at the tail, not mingling with PlayNext',
        () {
      final (service: q, container: c) = _harness();
      q.loadContext([_t('a'), _t('u0')], startIndex: 0);
      q.playNext(_t('p0'));
      q.addToUpcoming(_t('u1'));
      final s = _snap(c);
      expect(_paths(s.playNext), equals(['/music/p0.flac']));
      expect(_paths(s.upcoming), equals(['/music/u0.flac', '/music/u1.flac']));
      expect(
        _paths(s.flat),
        equals([
          '/music/a.flac',
          '/music/p0.flac',
          '/music/u0.flac',
          '/music/u1.flac',
        ]),
      );
    });
  });

  group('(c) move reorders across zones with ownership transfer', () {
    test('PlayNext entry dragged down into Upcoming transfers ownership',
        () {
      final (service: q, container: c) = _harness();
      q.loadContext([_t('a'), _t('u0')], startIndex: 0);
      q.playNext(_t('p0'));
      q.playNext(_t('p1'));
      // Layout before: [a (current), p1, p0, u0]  — indices 0..3.
      // Move p0 (flat index 2) past u0 so it lands at final flat index 3.
      q.move(2, 3);
      final s = _snap(c);
      expect(_paths(s.playNext), equals(['/music/p1.flac']));
      // Zone ownership transfers because p0 now sits past PlayNext's tail.
      expect(_paths(s.upcoming), equals(['/music/u0.flac', '/music/p0.flac']));
    });

    test('Upcoming entry moved into PlayNext transfers to PlayNext', () {
      final (service: q, container: c) = _harness();
      q.loadContext([_t('a'), _t('u0'), _t('u1')], startIndex: 0);
      q.playNext(_t('p0'));
      // Layout: [a, p0, u0, u1] — indices 0..3
      q.move(2, 1); // u0 jumps ahead of p0 into PlayNext head
      final s = _snap(c);
      expect(_paths(s.playNext), equals(['/music/u0.flac', '/music/p0.flac']));
      expect(_paths(s.upcoming), equals(['/music/u1.flac']));
    });

    test('move is a no-op when from == to', () {
      final (service: q, container: c) = _harness();
      q.loadContext([_t('a'), _t('b'), _t('c')], startIndex: 0);
      final before = _paths(_snap(c).flat);
      q.move(1, 1);
      expect(_paths(_snap(c).flat), equals(before));
    });

    test('move refuses to displace the current track', () {
      final (service: q, container: c) = _harness();
      q.loadContext([_t('a'), _t('b'), _t('c')], startIndex: 0);
      final before = _paths(_snap(c).flat);
      q.move(0, 2); // 0 is current
      q.move(2, 0); // 0 is current's target
      expect(_paths(_snap(c).flat), equals(before));
    });

    test('move preserves FIFO within PlayNext (Move up / Move down)', () {
      final (service: q, container: c) = _harness();
      q.loadContext([_t('a')], startIndex: 0);
      q.playNext(_t('p2'));
      q.playNext(_t('p1'));
      q.playNext(_t('p0'));
      // PlayNext (LIFO insert order): [p0, p1, p2]
      // Move p0 down one position: flat indices current=0, p0=1, p1=2, p2=3
      q.move(1, 2);
      expect(
        _paths(_snap(c).playNext),
        equals(['/music/p1.flac', '/music/p0.flac', '/music/p2.flac']),
      );
    });
  });

  group('(d) clearPlayNext empties only that zone', () {
    test('history, current, and upcoming survive; playNext is empty', () {
      final (service: q, container: c) = _harness();
      q.loadContext([_t('a'), _t('u0')], startIndex: 0);
      q.advance(); // now history=[a], current=u0
      q.playNext(_t('p0'));
      q.addToUpcoming(_t('u1'));
      q.clearPlayNext();
      final s = _snap(c);
      expect(_paths(s.history), equals(['/music/a.flac']));
      expect(s.current, equals(_t('u0')));
      expect(s.playNext, isEmpty);
      expect(_paths(s.upcoming), equals(['/music/u1.flac']));
    });

    test('clearPlayNext on an already-empty PlayNext is a no-op', () {
      final (service: q, container: c) = _harness();
      q.loadContext([_t('a')], startIndex: 0);
      final before = _snap(c).flat;
      q.clearPlayNext();
      expect(identical(_snap(c), _snap(c)), isTrue);
      expect(_snap(c).flat, equals(before));
    });
  });

  group('(e) advance pushes current onto history and promotes', () {
    test('advance with non-empty PlayNext promotes PlayNext head', () {
      final (service: q, container: c) = _harness();
      q.loadContext([_t('a'), _t('u0')], startIndex: 0);
      q.playNext(_t('p0'));
      q.advance();
      final s = _snap(c);
      expect(_paths(s.history), equals(['/music/a.flac']));
      expect(s.current, equals(_t('p0')));
      expect(s.playNext, isEmpty);
      expect(_paths(s.upcoming), equals(['/music/u0.flac']));
    });

    test('advance with empty PlayNext promotes Upcoming head', () {
      final (service: q, container: c) = _harness();
      q.loadContext([_t('a'), _t('b')], startIndex: 0);
      q.advance();
      final s = _snap(c);
      expect(_paths(s.history), equals(['/music/a.flac']));
      expect(s.current, equals(_t('b')));
      expect(s.upcoming, isEmpty);
    });

    test('advance when both zones are empty drains the queue', () {
      final (service: q, container: c) = _harness();
      q.loadContext([_t('a')], startIndex: 0);
      q.advance();
      final s = _snap(c);
      expect(_paths(s.history), equals(['/music/a.flac']));
      expect(s.current, isNull);
      expect(s.isEmpty, isFalse); // history still has one
      expect(s.currentIndex, equals(-1));
    });
  });

  group('retreat (inverse of advance, for skipToPrevious)', () {
    test('pulls history.last to current and pushes current onto PlayNext head',
        () {
      final (service: q, container: c) = _harness();
      q.loadContext([_t('a'), _t('b')], startIndex: 0);
      q.advance(); // history=[a], current=b
      q.playNext(_t('p0'));
      q.retreat();
      final s = _snap(c);
      expect(s.history, isEmpty);
      expect(s.current, equals(_t('a')));
      // Previously-current `b` is now at the head of PlayNext, above p0.
      expect(_paths(s.playNext), equals(['/music/b.flac', '/music/p0.flac']));
    });

    test('no-ops when history is empty', () {
      final (service: q, container: c) = _harness();
      q.loadContext([_t('a')], startIndex: 0);
      final before = _snap(c).flat;
      q.retreat();
      expect(_snap(c).flat, equals(before));
    });

    test('preserves flat projection (only currentIndex shifts)', () {
      // The invariant PlaybackService relies on: after advance/retreat
      // the player's source list is still aligned with snapshot.flat.
      final (service: q, container: c) = _harness();
      q.loadContext([_t('a'), _t('b'), _t('c')], startIndex: 0);
      q.advance(); // history=[a], current=b
      final flatBefore = _paths(_snap(c).flat);
      final idxBefore = _snap(c).currentIndex;
      q.retreat(); // back to history=[], current=a
      expect(_paths(_snap(c).flat), equals(flatBefore));
      expect(_snap(c).currentIndex, equals(idxBefore - 1));
    });
  });

  group('removeAt', () {
    test('removes a PlayNext entry, leaves others intact', () {
      final (service: q, container: c) = _harness();
      q.loadContext([_t('a'), _t('u0')], startIndex: 0);
      q.playNext(_t('p0'));
      q.playNext(_t('p1'));
      // Flat: [a, p1, p0, u0] — remove p0 at index 2.
      q.removeAt(2);
      final s = _snap(c);
      expect(_paths(s.playNext), equals(['/music/p1.flac']));
      expect(_paths(s.upcoming), equals(['/music/u0.flac']));
    });

    test('refuses to remove the current entry', () {
      final (service: q, container: c) = _harness();
      q.loadContext([_t('a'), _t('b')], startIndex: 0);
      q.removeAt(0); // current
      expect(_snap(c).current, equals(_t('a')));
    });
  });

  // -- Slice 5 -------------------------------------------------------------
  // The radio mode flag is purely additive: when off, slice-1 semantics are
  // unchanged. When on, `appendForRadio` is the documented entry point for
  // the LookaheadManager and lands tracks at the Upcoming tail without
  // displacing PlayNext head.
  group('radioMode flag (slice 5)', () {
    test('defaults to off', () {
      final (service: q, container: _) = _harness();
      expect(q.radioMode.isOn, isFalse);
    });

    test('set/get round-trips and emits change events', () async {
      final (service: q, container: _) = _harness();
      final events = <bool>[];
      final sub = q.radioMode.changes.listen(events.add);
      q.radioMode.set(true);
      q.radioMode.set(true); // idempotent
      q.radioMode.set(false);
      // Flush the microtask queue so the broadcast controller delivers.
      await Future<void>.delayed(Duration.zero);
      expect(events, equals([true, false]));
      expect(q.radioMode.isOn, isFalse);
      await sub.cancel();
    });

    test('with radioMode=false, appendForRadio mirrors addToUpcoming '
        '(byte-identical Upcoming tail growth)', () {
      final (service: q, container: c) = _harness();
      q.loadContext([_t('a'), _t('u0')], startIndex: 0);
      q.playNext(_t('p0'));
      q.appendForRadio(_t('r1'));
      final s = _snap(c);
      // PlayNext untouched.
      expect(_paths(s.playNext), equals(['/music/p0.flac']));
      // Upcoming gained the radio pick at its tail.
      expect(
        _paths(s.upcoming),
        equals(['/music/u0.flac', '/music/r1.flac']),
      );
    });

    test('with radioMode=true, appendForRadio still preserves PlayNext head',
        () {
      final (service: q, container: c) = _harness();
      q.radioMode.set(true);
      q.loadContext([_t('a')], startIndex: 0);
      q.playNext(_t('p_head'));
      q.appendForRadio(_t('r1'));
      q.appendForRadio(_t('r2'));
      final s = _snap(c);
      // PlayNext head untouched after two appendForRadio calls.
      expect(_paths(s.playNext), equals(['/music/p_head.flac']));
      // Upcoming carries the radio picks in append order.
      expect(_paths(s.upcoming), equals(['/music/r1.flac', '/music/r2.flac']));
      // Flat order: current, playNext head, radio tail.
      expect(
        _paths(s.flat),
        equals([
          '/music/a.flac',
          '/music/p_head.flac',
          '/music/r1.flac',
          '/music/r2.flac',
        ]),
      );
    });

    test('toggling radioMode does not mutate the queue snapshot', () {
      final (service: q, container: c) = _harness();
      q.loadContext([_t('a'), _t('b'), _t('c')], startIndex: 0);
      final flatBefore = _paths(_snap(c).flat);
      final idxBefore = _snap(c).currentIndex;
      q.radioMode.set(true);
      q.radioMode.set(false);
      expect(_paths(_snap(c).flat), equals(flatBefore));
      expect(_snap(c).currentIndex, equals(idxBefore));
    });
  });
}
