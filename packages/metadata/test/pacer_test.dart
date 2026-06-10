import 'package:prism_metadata/metadata.dart';
import 'package:test/test.dart';

void main() {
  group('Pacer', () {
    test('5 sequential calls take >= 4 * interval (FIFO spacing)', () async {
      // Use a short interval so the test is fast but the floor is tight
      // enough to catch a Pacer that accidentally bursts.
      const interval = Duration(milliseconds: 50);
      final pacer = Pacer(interval: interval);
      final stopwatch = Stopwatch()..start();
      for (var i = 0; i < 5; i++) {
        await pacer.run(() async => i);
      }
      stopwatch.stop();

      // The first call should fire immediately; subsequent four fire at
      // 1*, 2*, 3*, 4* the interval. `>= 4 * interval - 20 ms` allows for
      // the host's timer-coalescing slop without permitting a true burst.
      expect(
        stopwatch.elapsed,
        greaterThanOrEqualTo(interval * 4 - const Duration(milliseconds: 20)),
        reason: 'four spacings should add up to >= 4 * interval',
      );
    });

    test('concurrent callers serialize through the same slot', () async {
      const interval = Duration(milliseconds: 50);
      final pacer = Pacer(interval: interval);
      final order = <int>[];
      final futures = <Future<void>>[];
      for (var i = 0; i < 4; i++) {
        // Capture index by value before scheduling; otherwise the closure
        // would capture the loop var by reference.
        final idx = i;
        futures.add(pacer.run(() async {
          order.add(idx);
        }));
      }
      await Future.wait(futures);

      // FIFO: the order of completion must match the order of `pacer.run`
      // invocations. A bursting Pacer would interleave or reorder.
      expect(order, equals([0, 1, 2, 3]));
    });

    test('first 503 backs off and retries once with doubled spacing',
        () async {
      const interval = Duration(milliseconds: 50);
      final pacer = Pacer(interval: interval);
      var attempts = 0;
      final stopwatch = Stopwatch()..start();
      final result = await pacer.run<int>(() async {
        attempts++;
        if (attempts == 1) throw const Pacer503Exception();
        return 42;
      });
      stopwatch.stop();

      expect(result, 42);
      expect(attempts, 2, reason: 'one retry expected after first 503');
      // Doubled = 2 * 50 ms = 100 ms; allow for scheduler jitter.
      expect(
        stopwatch.elapsed,
        greaterThanOrEqualTo(const Duration(milliseconds: 80)),
        reason: 'retry should wait at least the doubled interval',
      );
    });

    test('second 503 in the same run() bubbles', () async {
      const interval = Duration(milliseconds: 20);
      final pacer = Pacer(interval: interval);
      var attempts = 0;
      expect(
        () => pacer.run<void>(() async {
          attempts++;
          throw const Pacer503Exception();
        }),
        throwsA(isA<Pacer503Exception>()),
      );
      // Drain the slot release so the next test starts clean.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(attempts, lessThanOrEqualTo(2),
          reason: 'we never retry more than once');
    });

    test('explicit retryAfter on the exception is respected (clamped to max)',
        () async {
      const interval = Duration(milliseconds: 10);
      final pacer = Pacer(
        interval: interval,
        maxBackoff: const Duration(milliseconds: 80),
      );
      var attempts = 0;
      final stopwatch = Stopwatch()..start();
      await pacer.run<void>(() async {
        attempts++;
        if (attempts == 1) {
          // 200 ms requested, but maxBackoff caps it at 80 ms.
          throw const Pacer503Exception(Duration(milliseconds: 200));
        }
      });
      stopwatch.stop();

      expect(attempts, 2);
      expect(
        stopwatch.elapsed,
        greaterThanOrEqualTo(const Duration(milliseconds: 60)),
        reason: 'capped backoff still delays >= 60 ms (max 80 - jitter)',
      );
      expect(
        stopwatch.elapsed,
        lessThan(const Duration(milliseconds: 200)),
        reason: 'cap should prevent the full 200 ms request',
      );
    });
  });
}
