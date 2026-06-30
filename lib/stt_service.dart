import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

/// Copy an asset file from the bundle to a writable directory and return its path.
Future<String> _copyAsset(String assetPath) async {
  final dir = await getApplicationDocumentsDirectory();
  final destPath = p.join(dir.path, p.basename(assetPath));

  // Avoid re-copying if already extracted
  if (File(destPath).existsSync()) {
    return destPath;
  }

  debugPrint('Copying asset $assetPath to $destPath');
  final data = await rootBundle.load(assetPath);
  final file = File(destPath);
  await file.writeAsBytes(data.buffer.asUint8List());
  return destPath;
}

/// Resolve the filesystem path for a Flutter asset.
///
/// On desktop (Linux, macOS, Windows) assets are already files on disk.
/// On mobile (Android, iOS) they are bundled inside the APK/IPA, so we
/// copy them to the app's documents directory first.
Future<String> _resolveAssetPath(String assetPath) async {
  // Desktop: assets are files on disk relative to the executable
  if (!kIsWeb && (Platform.isLinux || Platform.isWindows || Platform.isMacOS)) {
    final execPath = Platform.resolvedExecutable;
    final execDir = Directory(execPath).parent;

    // Linux / Windows: <exec_dir>/data/flutter_assets/
    final linuxPath = '${execDir.path}/data/flutter_assets/$assetPath';
    if (File(linuxPath).existsSync()) {
      return linuxPath;
    }

    // macOS: <exec_dir>/../Resources/flutter_assets/
    final macPath =
        '${execDir.parent.path}/Resources/flutter_assets/$assetPath';
    if (File(macPath).existsSync()) {
      return macPath;
    }

    // Fallback: try from current working directory (debug runs)
    if (File(assetPath).existsSync()) {
      return assetPath;
    }
  }

  // Mobile / fallback: copy from asset bundle
  return _copyAsset(assetPath);
}

/// Service that provides speech-to-text using sherpa_onnx.
class SttService {
  sherpa_onnx.OfflineRecognizer? _recognizer;
  String _currentLanguage = 'auto';
  final AudioRecorder _recorder = AudioRecorder();
  final int _sampleRate = 16000;

  bool get isInitialized => _recognizer != null;

  /// Check and request microphone permission.
  Future<bool> hasPermission() async {
    return await _recorder.hasPermission();
  }

  /// Initialize the recognizer with the Whisper base multilingual model.
  /// If [language] changes from the previous call, the recognizer is
  /// re-created so the model uses the correct language.
  Future<void> initialize({String language = 'auto'}) async {
    final lang = language == 'auto' ? '' : language;
    if (_recognizer != null && _currentLanguage == lang) return;

    // Dispose previous recognizer if language changed
    _recognizer?.free();
    _recognizer = null;

    // Init native bindings
    sherpa_onnx.initBindings();

    // Resolve model file paths (copy from bundle on mobile)
    final modelDir = 'assets/sherpa-onnx-whisper-base';
    final encoderPath = await _resolveAssetPath('$modelDir/encoder.int8.onnx');
    final decoderPath = await _resolveAssetPath('$modelDir/decoder.int8.onnx');
    final tokensPath = await _resolveAssetPath('$modelDir/tokens.txt');

    debugPrint('STT encoder: $encoderPath');
    debugPrint('STT decoder: $decoderPath');
    debugPrint('STT tokens: $tokensPath');

    final whisperConfig = sherpa_onnx.OfflineWhisperModelConfig(
      encoder: encoderPath,
      decoder: decoderPath,
      language: lang,
      task: 'transcribe',
    );

    final modelConfig = sherpa_onnx.OfflineModelConfig(
      whisper: whisperConfig,
      tokens: tokensPath,
      modelType: 'whisper',
      numThreads: 2,
      debug: false,
    );

    final config = sherpa_onnx.OfflineRecognizerConfig(model: modelConfig);
    _recognizer = sherpa_onnx.OfflineRecognizer(config);
    _currentLanguage = lang;

    debugPrint('STT initialized successfully (language=$lang)');
  }

  /// Start recording audio from the microphone.
  /// Returns a stream of raw PCM16 audio bytes.
  Future<Stream<Uint8List>> startRecording() async {
    return await _recorder.startStream(
      RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: _sampleRate,
        numChannels: 1,
      ),
    );
  }

  /// Stop recording audio.
  Future<void> stopRecording() async {
    await _recorder.stop();
  }

  /// Transcribe raw PCM16 audio data.
  /// [pcm16Data] must be 16-bit signed integer PCM, little-endian, mono.
  /// Returns the transcribed text.
  Future<String> transcribe(Uint8List pcm16Data) async {
    if (_recognizer == null) {
      throw Exception('STT not initialized. Call initialize() first.');
    }

    // Convert PCM16 (signed 16-bit integers) to Float32List (-1.0 to 1.0)
    final samples = _convertPcm16ToFloat32(pcm16Data);

    final stream = _recognizer!.createStream();
    stream.acceptWaveform(
      samples: samples,
      sampleRate: _sampleRate,
    );

    _recognizer!.decode(stream);
    final result = _recognizer!.getResult(stream);
    stream.free();

    return result.text;
  }

  Float32List _convertPcm16ToFloat32(Uint8List bytes) {
    final numSamples = bytes.lengthInBytes ~/ 2;
    final result = Float32List(numSamples);
    final byteData =
        ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.lengthInBytes);
    for (int i = 0; i < numSamples; i++) {
      final int16 = byteData.getInt16(i * 2, Endian.little);
      result[i] = int16 / 32768.0;
    }
    return result;
  }

  /// Clean up resources.
  void dispose() {
    _recorder.dispose();
    _recognizer?.free();
    _recognizer = null;
  }
}
