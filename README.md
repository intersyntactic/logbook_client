# is_logbook_client

The one client for an [is_logbook](https://pub.dev/packages/is_logbook)
service: a writer for its write socket and a reader for its read socket. It
replaces the copies of the socket protocol that each program used to carry.

It depends on [is_logbook_format](https://pub.dev/packages/is_logbook_format),
the entry format alone, and not on is_logbook: a program on this client
reaches the logbook only through the service's sockets, never by opening its
directory. `Kind` and `ObjectId` are re-exported from here.

An entry is its bytes, `<kind>\n<previous>\n<body>`, and its id is their
`ObjectId` (their sha256). The same bytes are always the same entry.

## Writing

    final writer = LogbookWriter('/path/to/write.sock');
    switch (await writer.write(Kind.parse('turn')!, body, previous: tip)) {
      case Written(:final entry):         // recorded as entry
      case AlreadyRecorded(:final entry): // these bytes were already entry
      case NotTip(:final tip):            // nothing added; send again after tip
      case WriteRefused(:final why):      // nothing added
      case WriteFailed(:final why):       // may be in: send the same again
      case Unanswered(:final why):        // may be in: send the same again
    }

One connection per entry. The service knows the sender by the user at the
other end of the socket, and its sender table says which kinds that user may
send. `previous` is the entry before this one in its chain, or null to start
a chain. `timeout` (10 seconds unless given) bounds the wait for an answer.

Sending the same bytes again is always safe: they are recorded once, and
the second answer is `AlreadyRecorded`. The sender is not in the bytes, so
two chain starts of one kind with one body are one entry, whoever sent them.
To record two, put something in the body that tells them apart.

## Reading

    final reader = LogbookReader('/path/to/read.sock');
    await for (final item in reader.subscribe(kinds: {turn}, from: last)) {
      switch (item) {
        case Entry(): // an entry: id, kind, previous, recorded, body
        case CaughtUp(:final head): // the backlog ended at head
      }
    }

- `subscribe` sends every entry of those kinds (every kind when `kinds` is
  null) after `from` (the logbook's start when null), then `CaughtUp`, then
  each new entry while the stream is listened to. `CaughtUp.head` is also a
  place to subscribe from next time. To wrap it, use stream operators
  (`where`, `map`, `expand`, `asyncMap`, `transform`), not an `async*`
  generator: cancelling an `async*` wrapper waits for its next `yield`,
  which never comes while the logbook is quiet.
- `tip(entry)` answers the tip of that entry's chain.
- `get(entry)` answers `GotEntry`, `GotNone`, `GotUnreadable`
  (`Unreadable.missing` or `Unreadable.corrupt`) or `GotFailed`, or
  `GotEntryWithoutHeader` for bytes something other than the service wrote
  to the logbook's directory. `get` also checks that the logbook's 96 bytes
  for the entry name its bytes as their object.

Every entry, from `subscribe` or `get`, is checked: its bytes are the ones
its id names, and their header is its kind and previous.

Everything the service sends is read strictly. A failure is a `ReadFailure`:
`ReadUnreachable` (not reached, closed early, or too slow), `ReadRefused`
(the service said `refused`, for example an entry it doesn't know) or
`ReadBroken` (something the service never sends, or bytes that don't check).
