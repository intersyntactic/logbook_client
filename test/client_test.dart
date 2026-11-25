import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:is_logbook/is_logbook.dart';
import 'package:is_logbook/service.dart';
import 'package:is_logbook_client/is_logbook_client.dart';
import 'package:test/test.dart';

Uint8List bytesOf(String s) => utf8.encode(s);

Kind kind(String name) => Kind.parse(name)!;

/// A server at [path] that answers every connection with [answer], or never
/// answers when it is null.
Future<ServerSocket> fake(String path, String? answer) async {
  final server = await ServerSocket.bind(
    InternetAddress(path, type: InternetAddressType.unix),
    0,
  );
  server.listen((socket) {
    socket.listen((_) {}, onError: (Object _) {});
    if (answer == null) return;
    socket
      ..add(utf8.encode(answer))
      ..close();
  });
  return server;
}

void main() {
  final me = Process.runSync('id', ['-un']).stdout.toString().trim();
  late Directory dir;
  late LogbookService service;
  late LogbookWriter writer;
  late LogbookReader reader;

  setUp(() async {
    // Unix socket paths are short (about 104 bytes on macOS).
    dir = Directory('/tmp').createTempSync('jc');
    service = await LogbookService.start(
      Logbook.open(Directory('${dir.path}/j'))!,
      SenderTable.parse(bytesOf('$me turn witnessed\n')),
      File('${dir.path}/w.sock'),
      readSocket: File('${dir.path}/r.sock'),
    );
    writer = LogbookWriter('${dir.path}/w.sock');
    reader = LogbookReader('${dir.path}/r.sock');
  });
  tearDown(() async {
    await service.close();
    dir.deleteSync(recursive: true);
  });

  Future<ObjectId> write(String k, String body, [ObjectId? previous]) async =>
      switch (await writer.write(kind(k), bytesOf(body), previous: previous)) {
        Written(:final entry) => entry,
        final other => throw StateError('$other'),
      };

  group('the writer', () {
    test('writes an entry and answers its id, the id of its bytes', () async {
      final a = await write('turn', 'a');
      expect(a, ObjectId.of(bytesOf('turn\n-\na')));
      final got = await reader.get(a);
      expect(utf8.decode((got as GotEntry).entry.recorded), 'turn\n-\na');
    });

    test('says already recorded when the same bytes are sent again', () async {
      final a = await write('turn', 'a');
      final b = await write('turn', 'b', a);
      for (final (body, previous, id) in [('a', null, a), ('b', a, b)]) {
        final answer = await writer.write(
          kind('turn'),
          bytesOf(body),
          previous: previous,
        );
        expect((answer as AlreadyRecorded).entry, id);
      }
      expect(await reader.tip(a), b);
    });

    test('names the tip when previous is not it, and adds nothing', () async {
      final a = await write('turn', 'a');
      final b = await write('turn', 'b', a);
      final answer = await writer.write(
        kind('turn'),
        bytesOf('c'),
        previous: a,
      );
      expect((answer as NotTip).tip, b);
      expect(await reader.tip(a), b);
    });

    test('says refused for a kind the sender may not write', () async {
      final answer = await writer.write(kind('decided'), bytesOf('x'));
      expect((answer as WriteRefused).why, startsWith('kind decided'));
    });

    test('says unanswered when nothing listens', () async {
      final answer = await LogbookWriter('${dir.path}/nobody.sock')
          .write(kind('turn'), bytesOf('x'));
      expect(answer, isA<Unanswered>());
    });

    test('says unanswered when the answer does not come in time', () async {
      final server = await fake('${dir.path}/silent.sock', null);
      final answer = await LogbookWriter(
        '${dir.path}/silent.sock',
        timeout: const Duration(milliseconds: 200),
      ).write(kind('turn'), bytesOf('x'));
      expect((answer as Unanswered).why, startsWith('no answer within'));
      await server.close();
    });

    test('reads the answer strictly', () {
      final sent = ObjectId.of(bytesOf('x'));
      final hash = sent.hex;
      final other = ObjectId.of(bytesOf('y')).hex;
      WriteResult read(String text) => WriteResult.read(text, sent);
      expect(read('ok $hash\n'), isA<Written>());
      expect(read('refused duplicate $hash\n'), isA<AlreadyRecorded>());
      expect(read('failed disk full\n'), isA<WriteFailed>());
      expect(read('refused not-tip $other\n'), isA<NotTip>());
      expect(read('refused not-tip xyz\n'), isA<WriteRefused>());
      for (final bad in [
        'ok $hash',
        'ok xyz\n',
        'ok $other\n',
        'refused duplicate $other\n',
        'ok $hash\nok $hash\n',
        'OK $hash\n',
        'refused\n',
        'maybe\n',
      ]) {
        expect(read(bad), isA<Unanswered>(), reason: bad);
      }
    });
  });

  group('subscribe', () {
    test('sends the backlog, then caught-up, then new entries', () async {
      final a = await write('turn', 'a');
      final w = await write('witnessed', 'w');
      final items = StreamIterator(reader.subscribe(kinds: {kind('turn')}));
      expect(await items.moveNext(), isTrue);
      final first = items.current as Entry;
      expect(first.id, a);
      expect(first.kind, kind('turn'));
      expect(first.previous, isNull);
      expect(utf8.decode(first.body), 'a');
      expect(await items.moveNext(), isTrue);
      expect((items.current as CaughtUp).head, w);
      final b = await write('turn', 'b', a);
      expect(await items.moveNext(), isTrue);
      expect((items.current as Entry).id, b);
      expect((items.current as Entry).previous, a);
      await items.cancel();
    });

    test('cancel completes while the subscription waits for entries', () async {
      final arrived = Completer<void>();
      final got = <Subscribed>[];
      final subscription = reader.subscribe(kinds: {kind('turn')}).listen((s) {
        got.add(s);
        if (s is Entry) arrived.complete();
      });
      final a = await write('turn', 'a');
      await arrived.future;
      // Long enough for the subscription to be waiting on the socket again.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await subscription.cancel().timeout(const Duration(seconds: 2));
      expect(got.whereType<Entry>().single.id, a);
    });

    test('every kind when kinds is null, from a given entry', () async {
      final a = await write('turn', 'a');
      final w = await write('witnessed', 'w');
      final items = await reader.subscribe(from: a).take(2).toList();
      expect((items[0] as Entry).id, w);
      expect((items[1] as CaughtUp).head, w);
      final all = await reader.subscribe().take(1).toList();
      expect((all.single as Entry).kind, Kind.started);
    });

    test('errors with refused for an entry the service does not know', () {
      expect(
        reader.subscribe(from: ObjectId.of(bytesOf('nothing'))).toList(),
        throwsA(isA<ReadRefused>()),
      );
    });

    test('takes no empty set of kinds', () {
      expect(
        reader.subscribe(kinds: {}).toList(),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('errors with unreachable when nothing listens', () {
      expect(
        LogbookReader('${dir.path}/nobody.sock').subscribe().toList(),
        throwsA(isA<ReadUnreachable>()),
      );
    });

    test('errors with broken on a frame the service never sends', () async {
      for (final (name, odd) in [
        ('bad-entry', 'entry x y z 1\nq'),
        ('bad-line', 'hello there\n'),
        ('bad-head', 'caught-up -\n'),
      ]) {
        final server = await fake('${dir.path}/$name.sock', odd);
        await expectLater(
          LogbookReader('${dir.path}/$name.sock').subscribe().toList(),
          throwsA(isA<ReadBroken>()),
          reason: odd,
        );
        await server.close();
      }
    });

    test('errors with broken on an entry that does not check', () async {
      final a = ObjectId.of(bytesOf('turn\n-\na')).hex;
      final x = ObjectId.of(bytesOf('x')).hex;
      for (final (name, frame, why) in [
        ('other-bytes', 'entry $a turn - 8 -\nturn\n-\nb', 'another entry'),
        ('other-header', 'entry $a witnessed - 8 -\nturn\n-\na', 'header'),
        ('no-header', 'entry $x - - 1 -\nx', 'without a header'),
        ('previous-no-kind', 'entry $x - $a 1 -\nx', 'not an entry frame'),
      ]) {
        final server = await fake('${dir.path}/$name.sock', frame);
        await expectLater(
          LogbookReader('${dir.path}/$name.sock').subscribe().toList(),
          throwsA(isA<ReadBroken>().having((e) => e.why, 'why', contains(why))),
          reason: name,
        );
        await server.close();
      }
    });
  });

  group('tip', () {
    test("answers the chain's tip, refuses an unknown entry", () async {
      final a = await write('turn', 'a');
      expect(await reader.tip(a), a);
      final b = await write('turn', 'b', a);
      expect(await reader.tip(a), b);
      expect(
        reader.tip(ObjectId.of(bytesOf('nothing'))),
        throwsA(isA<ReadRefused>()),
      );
    });
  });

  group('get', () {
    test('answers the entry, checked against its id and 96 bytes', () async {
      final a = await write('turn', 'a');
      final b = await write('turn', 'b', a);
      final entry = (await reader.get(b) as GotEntry).entry;
      expect(entry.id, b);
      expect(entry.previous, a);
      expect(utf8.decode(entry.body), 'b');
    });

    test('answers bytes recorded without a header as their own', () async {
      final x = ObjectId.of(bytesOf('x'));
      final link = LogbookEntry(
        EntryHash.origin,
        FileSetId.fromDigest(Uint8List(32))!,
        x,
      ).encode().map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final server = await fake(
        '${dir.path}/bare.sock',
        'entry ${x.hex} - - 1 - $link\nx',
      );
      final got = await LogbookReader('${dir.path}/bare.sock').get(x);
      expect((got as GotEntryWithoutHeader).id, x);
      expect(utf8.decode(got.recorded), 'x');
      await server.close();
    });

    test('says none for an entry the logbook does not hold', () async {
      expect(await reader.get(ObjectId.of(bytesOf('x'))), isA<GotNone>());
    });

    test('says unreadable when the bytes are gone', () async {
      final a = await write('turn', 'a');
      // An entry's id is its object's name.
      File(
        '${dir.path}/j/objects/${a.hex.substring(0, 2)}/${a.hex.substring(2)}',
      ).deleteSync();
      expect(((await reader.get(a)) as GotUnreadable).why, Unreadable.missing);
    });

    test('is broken when the bytes are not the entry asked for', () async {
      // A real answer, then the same answer with its bytes changed.
      final a = await write('turn', 'a');
      final real = Socket.connect(
        InternetAddress('${dir.path}/r.sock', type: InternetAddressType.unix),
        0,
      );
      final s = await real;
      s.add(bytesOf('get ${a.hex}\n'));
      final answer = utf8.decode(await s.expand((c) => c).toList());
      s.destroy();
      expect(answer, endsWith('turn\n-\na'));
      final lied = '${answer.substring(0, answer.length - 1)}b';
      final server = await fake('${dir.path}/lie.sock', lied);
      expect(
        LogbookReader('${dir.path}/lie.sock').get(a),
        throwsA(
          isA<ReadBroken>().having(
            (e) => e.why,
            'why',
            contains('another entry'),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await server.close();
    });

    test('is broken when the 96 bytes name another object', () async {
      // The same answer, with one byte of the object's name in the 96 bytes
      // changed: the bytes still check against the id, the link does not.
      final a = await write('turn', 'a');
      final s = await Socket.connect(
        InternetAddress('${dir.path}/r.sock', type: InternetAddressType.unix),
        0,
      );
      s.add(bytesOf('get ${a.hex}\n'));
      final answer = utf8.decode(await s.expand((c) => c).toList());
      s.destroy();
      final words = answer.split(' ');
      final hex = words[6];
      // Hex characters 128 to 191 spell the object's name; flip the first.
      final flipped = hex.replaceRange(128, 129, hex[128] == '0' ? '1' : '0');
      final lied = [...words.sublist(0, 6), flipped].join(' ');
      final server = await fake('${dir.path}/link.sock', lied);
      expect(
        LogbookReader('${dir.path}/link.sock').get(a),
        throwsA(
          isA<ReadBroken>().having(
            (e) => e.why,
            'why',
            contains('another object'),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await server.close();
    });

    test('is broken when the answer names another entry', () async {
      final a = await write('turn', 'a');
      final other = ObjectId.of(bytesOf('other')).hex;
      final server = await fake('${dir.path}/other.sock', 'none $other\n');
      expect(
        LogbookReader('${dir.path}/other.sock').get(a),
        throwsA(isA<ReadBroken>()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await server.close();
    });
  });

  group('trajectory', () {
    final trajectory = TrajectoryId.parse('a1' * 32)!;

    setUp(() async {
      // A table where this user may assign a trajectory to itself, with a
      // suit of uid 9001, and reply-chunk attaches to a trajectory's chain.
      await service.close();
      service = await LogbookService.start(
        Logbook.open(Directory('${dir.path}/t'))!,
        SenderTable.parse(
          bytesOf(
            '$me users-assigned-to-trajectory turn reply-chunk\n'
            'attaching: reply-chunk\n',
          ),
        ),
        File('${dir.path}/w.sock'),
        readSocket: File('${dir.path}/r.sock'),
      );
    });

    test(
      'says which trajectory owns each entry, on subscribe and get',
      () async {
        final a = await write(
          'users-assigned-to-trajectory',
          '{"trajectory":"${trajectory.hex}","mission":"${'b1' * 32}",'
              '"loopUser":"$me","suit":"9001"}',
        );
        final t = await write('turn', 't', a);
        // An attached root names its parent in its first body line: it is the
        // parent's trajectory's, though it starts a chain of its own.
        final r = await write('reply-chunk', '$a\nchunk');
        final unowned = await write('turn', 'u');

        final expected = {
          a: trajectory,
          t: trajectory,
          r: trajectory,
          unowned: null,
        };
        final subscribed = await reader
            .subscribe(
              kinds: {
                Kind.usersAssignedToTrajectory,
                kind('turn'),
                kind('reply-chunk'),
              },
            )
            .takeWhile((s) => s is Entry)
            .cast<Entry>()
            .toList();
        expect({for (final e in subscribed) e.id: e.trajectory}, expected);
        for (final MapEntry(key: id, value: owner) in expected.entries) {
          final got = await reader.get(id);
          expect((got as GotEntry).entry.trajectory, owner, reason: id.hex);
        }
      },
    );

    test('is broken on a trajectory word the service never sends', () async {
      final a = ObjectId.of(bytesOf('turn\n-\na')).hex;
      final x = ObjectId.of(bytesOf('x')).hex;
      const frame = 'not an entry frame';
      for (final (name, odd, why) in [
        ('not-hex', 'entry $a turn - 8 xyz\nturn\n-\na', frame),
        ('upper-case', 'entry $a turn - 8 ${'A1' * 32}\nturn\n-\na', frame),
        ('short', 'entry $a turn - 8 ${'a1' * 31}\nturn\n-\na', frame),
        // Bytes without a header are in no chain, so no trajectory owns them.
        ('headerless-owned', 'entry $x - - 1 ${'a1' * 32}\nx', frame),
        // A service before is_logbook 0.5.0 sends no trajectory word.
        ('five-words', 'entry $a turn - 8\nturn\n-\na', 'not a subscribe'),
      ]) {
        final server = await fake('${dir.path}/$name.sock', odd);
        await expectLater(
          LogbookReader('${dir.path}/$name.sock').subscribe().toList(),
          throwsA(isA<ReadBroken>().having((e) => e.why, 'why', contains(why))),
          reason: name,
        );
        await server.close();
      }
    });
  });
}
