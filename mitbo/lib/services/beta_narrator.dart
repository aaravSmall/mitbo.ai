import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// Speaks text aloud; injectable so narration can be tested without a
/// platform TTS engine.
abstract class SpeechEngine {
  /// Speaks [text] and completes when it has finished (or was stopped).
  Future<void> speak(String text);

  /// Stops speaking immediately.
  Future<void> stop();
}

/// The phone's built-in, on-device text-to-speech (no cloud voice).
class DeviceSpeechEngine implements SpeechEngine {
  DeviceSpeechEngine({FlutterTts? tts}) : _tts = tts ?? FlutterTts();

  final FlutterTts _tts;
  Future<void>? _setup;

  Future<void> _ensureSetUp() => _setup ??= () async {
    await _tts.awaitSpeakCompletion(true);
    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(0.5);
    await _tts.setPitch(1.0);
  }();

  @override
  Future<void> speak(String text) async {
    await _ensureSetUp();
    await _tts.speak(text);
  }

  @override
  Future<void> stop() async {
    await _tts.stop();
  }
}

/// Reads a list of cues aloud, one after another. Starting a new
/// narration or calling [stop] cuts off the current one.
class BetaNarrator extends ChangeNotifier {
  BetaNarrator({SpeechEngine? engine}) : _injected = engine;

  final SpeechEngine? _injected;
  SpeechEngine? _created;

  // Created on first use, so screens that never narrate never touch the
  // platform TTS plugin.
  SpeechEngine get _engine => _injected ?? (_created ??= DeviceSpeechEngine());
  int _run = 0;
  bool _speaking = false;
  bool _disposed = false;

  /// Whether a narration is in progress.
  bool get speaking => _speaking;

  /// Speaks [cues] in order. Completes when done or cut off.
  Future<void> narrate(List<String> cues) async {
    if (_disposed) return;
    final run = ++_run;
    _setSpeaking(true);
    try {
      await _engine.stop();
      for (final cue in cues) {
        if (_disposed || run != _run) return;
        await _engine.speak(cue);
      }
    } catch (e) {
      debugPrint('Narration failed: $e');
    } finally {
      if (run == _run) _setSpeaking(false);
    }
  }

  /// Cuts off any narration in progress.
  Future<void> stop() async {
    _run++;
    _setSpeaking(false);
    try {
      await _engine.stop();
    } catch (e) {
      debugPrint('Stopping narration failed: $e');
    }
  }

  void _setSpeaking(bool value) {
    if (_disposed || _speaking == value) return;
    _speaking = value;
    notifyListeners();
  }

  @override
  void dispose() {
    _run++;
    _disposed = true;
    final engine = _injected ?? _created;
    engine?.stop().catchError((Object _) {});
    super.dispose();
  }
}
