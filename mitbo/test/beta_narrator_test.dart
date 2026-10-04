import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:mitbo/services/beta_narrator.dart';

/// Records what's spoken; each cue finishes when the test says so.
class _FakeEngine implements SpeechEngine {
  final spoken = <String>[];
  final pending = <Completer<void>>[];
  int stops = 0;

  @override
  Future<void> speak(String text) {
    spoken.add(text);
    final completer = Completer<void>();
    pending.add(completer);
    return completer.future;
  }

  @override
  Future<void> stop() async {
    stops++;
    for (final c in pending) {
      if (!c.isCompleted) c.complete();
    }
  }

  void finishCurrent() => pending.last.complete();
}

Future<void> _flush() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.value();
  }
}

void main() {
  test('speaks cues one after another', () async {
    final engine = _FakeEngine();
    final narrator = BetaNarrator(engine: engine);
    final done = narrator.narrate(['one', 'two', 'three']);
    await _flush();
    expect(engine.spoken, ['one']);
    expect(narrator.speaking, isTrue);

    engine.finishCurrent();
    await _flush();
    expect(engine.spoken, ['one', 'two']);
    engine.finishCurrent();
    await _flush();
    engine.finishCurrent();
    await done;
    expect(engine.spoken, ['one', 'two', 'three']);
    expect(narrator.speaking, isFalse);
  });

  test('a new narration cuts off the old one', () async {
    final engine = _FakeEngine();
    final narrator = BetaNarrator(engine: engine);
    final first = narrator.narrate(['a1', 'a2']);
    await _flush();
    final second = narrator.narrate(['b1']);
    await _flush();
    await first;
    expect(engine.spoken, ['a1', 'b1']);
    expect(narrator.speaking, isTrue);
    engine.finishCurrent();
    await second;
    expect(narrator.speaking, isFalse);
  });

  test('stop cuts off the narration', () async {
    final engine = _FakeEngine();
    final narrator = BetaNarrator(engine: engine);
    final done = narrator.narrate(['x', 'y']);
    await _flush();
    await narrator.stop();
    await done;
    expect(engine.spoken, ['x']);
    expect(narrator.speaking, isFalse);
  });

  test('engine errors end the narration quietly', () async {
    final narrator = BetaNarrator(engine: _ThrowingEngine());
    await narrator.narrate(['boom']);
    expect(narrator.speaking, isFalse);
  });

  test('does nothing once disposed', () async {
    final engine = _FakeEngine();
    final narrator = BetaNarrator(engine: engine)..dispose();
    await narrator.narrate(['late']);
    expect(engine.spoken, isEmpty);
  });
}

class _ThrowingEngine implements SpeechEngine {
  @override
  Future<void> speak(String text) => Future.error(StateError('no tts'));

  @override
  Future<void> stop() async {}
}
