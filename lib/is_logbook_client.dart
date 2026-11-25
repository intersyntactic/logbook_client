/// The one client for an is_logbook service: a [LogbookWriter] for its write
/// socket and a [LogbookReader] for its read socket.
///
/// The write socket takes one entry per connection: the request
/// `<kind>\n<previous>\n<body>`, the write side then closed, and one line
/// back, `ok <id>`, `refused <why>` or `failed <why>`. The service knows the
/// sender by the user at the other end of the socket, and its sender table
/// says which kinds that user may send.
///
/// An entry's id is the [ObjectId] of its bytes, the request exactly as
/// sent: the same bytes are always the same entry.
///
/// The read socket takes one line and can only read:
///
/// - `subscribe <kinds> from <id>|start`: every entry of those kinds after
///   that entry, then `caught-up <head>`, then each new entry as it is added.
///   Each entry comes with the trajectory that owns its chain, if one does.
/// - `tip <id>`: the tip of that entry's chain.
/// - `get <id>`: that entry, with the logbook's 96 bytes for it.
///
/// Everything the service sends is read strictly, and every entry is
/// checked against its id: a line or frame it never sends, or bytes that are
/// not the entry's, is a [ReadBroken], never a guess.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:is_logbook_format/is_logbook_format.dart';
import 'package:is_shapes/is_shapes.dart' show TrajectoryId;

export 'package:is_logbook_format/is_logbook_format.dart' show Kind, ObjectId;
export 'package:is_shapes/is_shapes.dart' show TrajectoryId;

/// What the writer said became of one entry.
sealed class WriteResult {
  const WriteResult();

  /// The writer's answer [text] to the request whose id is [sent], read
  /// strictly: anything but one line of one of its answers, or an id other
  /// than [sent] where the answer names the entry, is [Unanswered].
  static WriteResult read(String text, ObjectId sent) {
    final lines = text.split('\n');
    if (lines.length != 2 || lines.last.isNotEmpty) {
      return Unanswered('not one line: $text');
    }
    final line = lines.first;
    return switch (line.split(' ')) {
      ['ok', final hex] when hex == sent.hex => Written(sent),
      ['refused', 'duplicate', final hex] when hex == sent.hex =>
        AlreadyRecorded(sent),
      ['ok', _] || ['refused', 'duplicate', _] => Unanswered(
        'an answer for another entry than ${sent.hex}: $line',
      ),
      ['refused', 'not-tip', final hex] when ObjectId.parse(hex) != null =>
        NotTip(ObjectId.parse(hex)!),
      ['refused', _, ...] => WriteRefused(line.substring('refused '.length)),
      ['failed', _, ...] => WriteFailed(line.substring('failed '.length)),
      _ => Unanswered('not an answer the writer gives: $line'),
    };
  }
}

/// Recorded as [entry].
final class Written extends WriteResult {
  const Written(this.entry);

  final ObjectId entry;
}

/// Nothing was added, because exactly these bytes, kind, previous and body,
/// are already recorded as [entry]: by this writer before, if it is sending
/// them again, or by any sender who sent the same bytes.
final class AlreadyRecorded extends WriteResult {
  const AlreadyRecorded(this.entry);

  final ObjectId entry;
}

/// Refused, and nothing was added, because the entry named as previous is
/// not its chain's tip: [tip] is. Safe to send again naming [tip].
final class NotTip extends WriteResult {
  const NotTip(this.tip);

  final ObjectId tip;
}

/// Refused, and nothing was added: [why] is the service's reason, such as a
/// kind the sender table doesn't give this user.
final class WriteRefused extends WriteResult {
  const WriteRefused(this.why);

  final String why;
}

/// The add failed partway, and the entry may be in anyway. Sending the same
/// bytes again is safe: it is [Written] or [AlreadyRecorded], never twice.
final class WriteFailed extends WriteResult {
  const WriteFailed(this.why);

  final String why;
}

/// No answer could be read: the socket unreachable, closed before answering,
/// silent past the deadline, or an answer the writer doesn't give. The entry
/// may or may not be in; sending the same bytes again is safe.
final class Unanswered extends WriteResult {
  const Unanswered(this.why);

  final String why;
}

/// The service's write socket at [socketPath].
final class LogbookWriter {
  const LogbookWriter(
    this.socketPath, {
    this.timeout = const Duration(seconds: 10),
  });

  final String socketPath;

  /// How long [write] waits for an answer before it says [Unanswered].
  final Duration timeout;

  /// Records [body] as an entry of [kind] after [previous], or starting a
  /// chain of its own when [previous] is null.
  ///
  /// The entry is its bytes, `<kind>\n<previous>\n<body>`, and not who sent
  /// them: two chain starts of one kind with one body are one entry, and the
  /// second is [AlreadyRecorded]. A writer that means two puts something in
  /// the body that tells them apart.
  Future<WriteResult> write(
    Kind kind,
    List<int> body, {
    ObjectId? previous,
  }) async {
    final request =
        (BytesBuilder(copy: false)
              ..add(utf8.encode('$kind\n${previous?.hex ?? '-'}\n'))
              ..add(body))
            .takeBytes();
    final sent = ObjectId.of(request);
    Socket? socket;
    try {
      return await () async {
        socket = await Socket.connect(
          InternetAddress(socketPath, type: InternetAddressType.unix),
          0,
        );
        socket!.add(request);
        // The service reads the request to its end: closing the write side
        // is what tells it the request is whole.
        await socket!.close();
        final text = await utf8.decoder.bind(socket!).join();
        return text.isEmpty
            ? const Unanswered('closed before answering')
            : WriteResult.read(text, sent);
      }().timeout(timeout);
    } on TimeoutException {
      return Unanswered('no answer within $timeout');
    } on SocketException catch (e) {
      return Unanswered('socket: ${e.message}');
    } on FormatException catch (e) {
      return Unanswered('not text: ${e.message}');
    } finally {
      socket?.destroy();
    }
  }
}

/// What a subscription hands on: an entry, or the moment its backlog ended.
sealed class Subscribed {
  const Subscribed();
}

/// One recorded entry: its [id], its [kind], the [previous] entry in its
/// chain (null when it starts one), the [trajectory] that owns its chain,
/// and its [recorded] bytes, the header included. They were checked: they
/// are the bytes [id] names, and their header is [kind] and [previous].
final class Entry extends Subscribed {
  const Entry({
    required this.id,
    required this.kind,
    required this.previous,
    required this.trajectory,
    required this.recorded,
  });

  final ObjectId id;
  final Kind kind;
  final ObjectId? previous;

  /// The trajectory whose chain this entry is on, as the service says: the
  /// chain starts at that trajectory's `users-assigned-to-trajectory`, or at
  /// a root of an attaching kind whose parent is on such a chain. Null when
  /// no trajectory owns the chain, which includes an entry that names a
  /// trajectory only in its body.
  final TrajectoryId? trajectory;

  final Uint8List recorded;

  /// The bytes after the `<kind>\n<previous>\n` header.
  Uint8List get body {
    final first = recorded.indexOf(0x0a);
    return Uint8List.sublistView(
      recorded,
      recorded.indexOf(0x0a, first + 1) + 1,
    );
  }
}

/// The backlog has been read: everything after this was added while
/// subscribed. [head] is the logbook's last entry of any kind when the
/// backlog ended (null when there was none), and a place to subscribe from
/// next time.
final class CaughtUp extends Subscribed {
  const CaughtUp(this.head);

  final ObjectId? head;
}

/// What `get` found.
sealed class Got {
  const Got();
}

/// The entry, checked against its id and the logbook's 96 bytes for it.
final class GotEntry extends Got {
  const GotEntry(this.entry);

  final Entry entry;
}

/// Bytes the logbook holds as an entry but that have no
/// `<kind>\n<previous>\n` header, so are in no chain: [recorded], checked
/// against [id]. Only something other than the service, writing to the
/// logbook's directory, records one.
final class GotEntryWithoutHeader extends Got {
  const GotEntryWithoutHeader(this.id, this.recorded);

  final ObjectId id;
  final Uint8List recorded;
}

/// The logbook holds no entry by that id.
final class GotNone extends Got {
  const GotNone();
}

/// Why a recorded entry's bytes can't be read.
enum Unreadable {
  /// The logbook has no bytes for it.
  missing,

  /// The bytes it has are not the ones the entry names.
  corrupt,
}

/// The entry was recorded, but its bytes are [why].
final class GotUnreadable extends Got {
  const GotUnreadable(this.why);

  final Unreadable why;
}

/// The service could not read the entry's bytes: [why].
final class GotFailed extends Got {
  const GotFailed(this.why);

  final String why;
}

/// Reading failed: the service was not reached ([ReadUnreachable]), it
/// refused the request ([ReadRefused]), or what it sent is not the protocol
/// or did not check ([ReadBroken]).
sealed class ReadFailure implements Exception {
  const ReadFailure(this.why);

  final String why;

  @override
  String toString() => '$runtimeType: $why';
}

/// The socket could not be reached, closed before answering, or was silent
/// past the deadline.
final class ReadUnreachable extends ReadFailure {
  const ReadUnreachable(super.why);
}

/// The service answered `refused <why>`: an entry it doesn't know, or a
/// request it doesn't take.
final class ReadRefused extends ReadFailure {
  const ReadRefused(super.why);
}

/// The service sent something it never sends, or an entry whose bytes do
/// not check: nothing after it is trusted.
final class ReadBroken extends ReadFailure {
  const ReadBroken(super.why);
}

/// The service's read socket at [socketPath].
final class LogbookReader {
  const LogbookReader(
    this.socketPath, {
    this.timeout = const Duration(seconds: 10),
  });

  final String socketPath;

  /// How long [tip] and [get] wait for their answer.
  final Duration timeout;

  /// Every entry of [kinds] (every kind, when null) after [from] (the
  /// logbook's start, when null), then a [CaughtUp], then each new entry as
  /// it is added, for as long as the stream is listened to. Cancelling it
  /// closes the socket. Errors with a [ReadFailure] and ends.
  ///
  /// Don't wrap it in an `async*` generator that relays it with `await for`:
  /// cancelling the wrapper waits for its next `yield`, which never comes
  /// while the logbook is quiet. Wrap it with `where`, `map`, `expand`,
  /// `asyncMap` or `transform`, or a `StreamController` whose `onCancel`
  /// cancels this subscription; each passes the cancel straight through.
  Stream<Subscribed> subscribe({Set<Kind>? kinds, ObjectId? from}) {
    // Not an async* generator: its cancel waits for the next yield, which
    // never comes while the subscription waits for an entry.
    final out = StreamController<Subscribed>();
    Socket? socket;
    _Frames? frames;
    var cancelled = false;

    Future<void> read() async {
      try {
        if (kinds != null && kinds.isEmpty) {
          throw ArgumentError.value(
            kinds,
            'kinds',
            'is empty; null means every',
          );
        }
        final names = kinds == null ? '*' : kinds.map((k) => k.name).join(',');
        socket = await _connect();
        if (cancelled) return;
        socket!.add(
          ascii.encode('subscribe $names from ${from?.hex ?? 'start'}\n'),
        );
        frames = _Frames(socket!);
        while (true) {
          final line = await frames!.line();
          if (line == null || cancelled) return;
          switch (line.split(' ')) {
            case ['caught-up', 'start']:
              out.add(const CaughtUp(null));
            case ['caught-up', final hex] when ObjectId.parse(hex) != null:
              out.add(CaughtUp(ObjectId.parse(hex)));
            case ['entry', final hex, _, _, _, _]:
              final read = await _readEntry(line, frames!);
              if (read is! GotEntry) {
                throw ReadBroken('entry $hex: subscribed without a header');
              }
              if (cancelled) return;
              out.add(read.entry);
            case ['refused', _, ...]:
              throw ReadRefused(line.substring('refused '.length));
            default:
              throw ReadBroken('not a subscribe frame: $line');
          }
        }
      } on SocketException catch (e) {
        if (!cancelled) out.addError(ReadUnreachable('socket: ${e.message}'));
      } on Object catch (e, trace) {
        if (!cancelled) out.addError(e, trace);
      } finally {
        socket?.destroy();
        // Not awaited: close completes only after a cancel, and a listener
        // that cancels on an error would wait on this read to finish.
        if (!cancelled) unawaited(out.close());
      }
    }

    late final Future<void> reading;
    out
      ..onListen = () {
        reading = read();
      }
      ..onCancel = () async {
        cancelled = true;
        // Ends a read waiting on the socket, so [reading] finishes.
        await frames?.cancel();
        socket?.destroy();
        await reading;
      };
    return out.stream;
  }

  /// The tip of [entry]'s chain: [entry] itself until an entry names it as
  /// previous. Throws [ReadRefused] for an entry in no chain.
  Future<ObjectId> tip(ObjectId entry) =>
      _ask('tip ${entry.hex}', (line, _) async {
        return switch (line.split(' ')) {
          ['tip', final hex] when ObjectId.parse(hex) != null => ObjectId.parse(
            hex,
          )!,
          _ => throw ReadBroken('not a tip answer: $line'),
        };
      });

  /// The entry named [entry]: its bytes are the ones [entry] names, and the
  /// logbook's 96 bytes for it name them as their object.
  Future<Got> get(ObjectId entry) => _ask('get ${entry.hex}', (
    line,
    frames,
  ) async {
    switch (line.split(' ')) {
      case ['none', final hex] when hex == entry.hex:
        return const GotNone();
      case ['unreadable', final hex, final why]
          when hex == entry.hex && Unreadable.values.asNameMap()[why] != null:
        return GotUnreadable(Unreadable.values.asNameMap()[why]!);
      case ['failed', _, ...]:
        return GotFailed(line.substring('failed '.length));
      case ['entry', final hex, _, _, _, _, final link] when hex == entry.hex:
        final read = await _readEntry(line, frames);
        _checkLink(entry, link);
        return read;
      default:
        throw ReadBroken('not a get answer for ${entry.hex}: $line');
    }
  });

  /// Sends [request] and reads its answer with [answer], within [timeout].
  Future<T> _ask<T>(
    String request,
    Future<T> Function(String line, _Frames frames) answer,
  ) async {
    final socket = await _connect();
    try {
      return await () async {
        socket.add(ascii.encode('$request\n'));
        final frames = _Frames(socket);
        final line = await frames.line();
        if (line == null) {
          throw const ReadUnreachable('closed before answering');
        }
        if (line.startsWith('refused ')) {
          throw ReadRefused(line.substring('refused '.length));
        }
        return answer(line, frames);
      }().timeout(timeout);
    } on TimeoutException {
      throw ReadUnreachable('no answer within $timeout');
    } on SocketException catch (e) {
      throw ReadUnreachable('socket: ${e.message}');
    } finally {
      socket.destroy();
    }
  }

  Future<Socket> _connect() async {
    try {
      return await Socket.connect(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0,
      );
    } on SocketException catch (e) {
      throw ReadUnreachable('socket: ${e.message}');
    }
  }

  /// The entry framed by [line],
  /// `entry <id> <kind> <previous> <length> <trajectory>` (with a seventh
  /// word from `get`), and its bytes, checked: they are the bytes the id
  /// names, and their header is the frame's kind and previous. Kind and
  /// previous `-` frame bytes without a header, which are in no chain, so no
  /// trajectory owns them.
  static Future<Got> _readEntry(String line, _Frames frames) async {
    final words = line.split(' ');
    final id = ObjectId.parse(words[1]);
    final (kind, previous, trajectory) = switch ((
      _orNone(words[2], Kind.read),
      _orNone(words[3], ObjectId.parse),
      _orNone(words[5], TrajectoryId.parse),
    )) {
      ((final k,)?, (final p,)?, (final t,)?)
          when k != null || (p == null && t == null) =>
        (k, p, t),
      _ => throw ReadBroken('not an entry frame: $line'),
    };
    final length = int.tryParse(words[4]);
    if (id == null || length == null || length < 0 || words[4] != '$length') {
      throw ReadBroken('not an entry frame: $line');
    }
    final recorded = await frames.bytes(length);
    if (recorded == null) {
      throw ReadUnreachable('closed inside entry ${id.hex}');
    }
    if (ObjectId.of(recorded) != id) {
      throw ReadBroken('entry ${id.hex}: its bytes are another entry');
    }
    if (kind == null) return GotEntryWithoutHeader(id, recorded);
    final header = ascii.encode('$kind\n${words[3]}\n');
    if (recorded.length < header.length || !_startsWith(recorded, header)) {
      throw ReadBroken('entry ${id.hex}: its header is not $kind ${words[3]}');
    }
    return GotEntry(
      Entry(
        id: id,
        kind: kind,
        previous: previous,
        trajectory: trajectory,
        recorded: recorded,
      ),
    );
  }

  /// [word] read by [parse], or none for the wire's `-`: `(value,)`, `(null,)`
  /// for none, and null when it is neither.
  static (T?,)? _orNone<T extends Object>(
    String word,
    T? Function(String) parse,
  ) {
    // wire-ok: the frame's word for no kind, previous or trajectory
    if (word == '-') return (null,);
    return switch (parse(word)) {
      final value? => (value,),
      null => null,
    };
  }

  static bool _startsWith(Uint8List bytes, Uint8List prefix) {
    for (var i = 0; i < prefix.length; i++) {
      if (bytes[i] != prefix[i]) return false;
    }
    return true;
  }

  /// Throws unless [hex] spells the logbook's 96 bytes for an entry whose
  /// object is [id].
  static void _checkLink(ObjectId id, String hex) {
    final bytes = _unhex(hex);
    final link = bytes == null ? null : LogbookEntry.parse(bytes);
    if (link == null) {
      throw ReadBroken('entry ${id.hex}: not 96 bytes of an entry');
    }
    if (link.object != id) {
      throw ReadBroken('entry ${id.hex}: its 96 bytes name another object');
    }
  }

  static Uint8List? _unhex(String s) {
    if (s.length.isOdd || !RegExp(r'^[0-9a-f]*$').hasMatch(s)) return null;
    return Uint8List.fromList([
      for (var i = 0; i < s.length; i += 2)
        int.parse(s.substring(i, i + 2), radix: 16),
    ]);
  }
}

/// The socket's bytes, read as lines and as runs of exact length.
final class _Frames {
  _Frames(Stream<Uint8List> source) : _source = StreamIterator(source);

  final StreamIterator<Uint8List> _source;
  final _buffer = BytesBuilder(copy: false);
  var _held = Uint8List(0);

  /// The next line, without its newline, or null at the end. Lines are
  /// ASCII on this wire, and one longer than any frame is a broken service.
  Future<String?> line() async {
    while (true) {
      final at = _held.indexOf(0x0a);
      if (at >= 0) {
        final bytes = Uint8List.sublistView(_held, 0, at);
        _held = Uint8List.sublistView(_held, at + 1);
        if (bytes.any((b) => b > 0x7f)) {
          throw const ReadBroken('a frame line that is not ASCII');
        }
        return ascii.decode(bytes);
      }
      if (_held.length > 4096) {
        throw const ReadBroken('a frame line past 4096 bytes');
      }
      if (!await _more()) {
        if (_held.isEmpty) return null;
        throw const ReadUnreachable('closed inside a frame line');
      }
    }
  }

  /// Stops reading: a [line] or [bytes] waiting on the socket ends as if it
  /// had closed.
  Future<void> cancel() => _source.cancel();

  /// Exactly [length] bytes, or null if the socket closes first.
  Future<Uint8List?> bytes(int length) async {
    while (_held.length < length) {
      if (!await _more()) return null;
    }
    final out = Uint8List.fromList(Uint8List.sublistView(_held, 0, length));
    _held = Uint8List.sublistView(_held, length);
    return out;
  }

  Future<bool> _more() async {
    if (!await _source.moveNext()) return false;
    _buffer
      ..add(_held)
      ..add(_source.current);
    _held = _buffer.takeBytes();
    return true;
  }
}
