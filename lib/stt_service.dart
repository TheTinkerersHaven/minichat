import 'dart:async';
import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

/// Whisper model URL to download
const _modelTarballUrl =
    'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-whisper-base.tar.bz2';

/// Required files mapped (Original name -> Destination name on device)
const _tarballModelFiles = {
  'base-encoder.int8.onnx': 'encoder.int8.onnx',
  'base-decoder.int8.onnx': 'decoder.int8.onnx',
  'base-tokens.txt': 'tokens.txt',
};

/// Configuration passed to Isolate for extraction
class ExtractionConfig {
  final String archivePath;
  final String outputDirectory;
  ExtractionConfig(this.archivePath, this.outputDirectory);
}

/// Top-level function executed in background Isolate
void _extractSpecificModelFilesIsolate(ExtractionConfig config) {
  // InputFileStream reads in chunks from disk without saturating RAM
  final tarBytes = BZip2Decoder().decodeBytes(File(config.archivePath).readAsBytesSync());
  final archive = TarDecoder().decodeBytes(tarBytes);

  final targetDir = Directory(config.outputDirectory);
  if (!targetDir.existsSync()) {
    targetDir.createSync(recursive: true);
  }

  for (final file in archive) {
    if (!file.isFile) continue;
    final baseName = p.basename(file.name);
    final targetName = _tarballModelFiles[baseName];
    if (targetName != null) {
      final outputFile = File(p.join(targetDir.path, targetName));
      outputFile.writeAsBytesSync(file.content as List<int>);
    }
  }
}

class SttService {
  sherpa_onnx.OfflineRecognizer? _recognizer;
  String _currentLanguage = 'auto';
  final AudioRecorder _recorder = AudioRecorder();
  final int _sampleRate = 16000;

  // Async state notifiers for UI
  final ValueNotifier<double> _downloadProgress = ValueNotifier(0.0);
  final ValueNotifier<bool> _isExtracting = ValueNotifier(false);
  final ValueNotifier<bool> _isDownloading = ValueNotifier(false);

  String? _modelDirPath;

  bool get isInitialized => _recognizer != null;
  ValueNotifier<double> get downloadProgress => _downloadProgress;
  ValueNotifier<bool> get isExtracting => _isExtracting;
  ValueNotifier<bool> get isDownloading => _isDownloading;

  /// Checks local presence of Whisper model files
  Future<bool> isModelDownloaded() async {
    final modelDir = await _getModelDirectory();
    final present = await _modelFilesPresent(modelDir);
    if (present) {
      _downloadProgress.value = 1.0;
    }
    return present;
  }

  /// Forces check and optional model download/extraction.
  /// Returns model folder path on disk.
  Future<String> ensureModelDownloaded() async {
    if (_modelDirPath != null) {
      return _modelDirPath!;
    }
    final modelDir = await _getModelDirectory();
    if (!await _modelFilesPresent(modelDir)) {
      await startBackgroundDownload();
    }
    _modelDirPath = modelDir.path;
    return _modelDirPath!;
  }

  /// Starts async download and extraction in background
  Future<void> startBackgroundDownload() async {
    if (_isDownloading.value || _isExtracting.value) return;

    _isDownloading.value = true;
    _downloadProgress.value = 0.0;

    try {
      final modelDir = await _getModelDirectory();
      final appDocDir = await getApplicationDocumentsDirectory();
      final tempZipPath = p.join(appDocDir.path, 'whisper_model_temp.tar.bz2');

      // 1. Async chunked download (Zero Memory Bloat)
      final request = http.Request('GET', Uri.parse(_modelTarballUrl));
      final response = await http.Client().send(request);

      if (response.statusCode != 200 && response.statusCode != 302) {
        throw Exception('Model download error: HTTP ${response.statusCode}');
      }

      final contentLength = response.contentLength ?? -1;
      int downloadedBytes = 0;
      final tempFile = File(tempZipPath);
      final sink = tempFile.openWrite();

      await for (final chunk in response.stream) {
        sink.add(chunk);
        downloadedBytes += chunk.length;
        if (contentLength > 0) {
          _downloadProgress.value = downloadedBytes / contentLength;
        }
      }
      await sink.close();

      // 2. Transition to async extraction
      _isDownloading.value = false;
      _isExtracting.value = true;

      // 3. Execution of async extraction on separate Isolate
      final config = ExtractionConfig(tempZipPath, modelDir.path);
      await compute(_extractSpecificModelFilesIsolate, config);

      // Cleanup of temporary files on user disk
      if (await tempFile.exists()) {
        await tempFile.delete();
      }

      _modelDirPath = modelDir.path;
      _downloadProgress.value = 1.0;
    } catch (e) {
      debugPrint('Error during async download/extraction: $e');
    } finally {
      _isDownloading.value = false;
      _isExtracting.value = false;
    }
  }

  /// Initializes recognizer if model is present
  Future<void> initialize({String language = 'auto'}) async {
    final lang = language == 'auto' ? '' : language;
    if (_recognizer != null && _currentLanguage == lang) return;

    final modelDir = await _getModelDirectory();
    if (!await _modelFilesPresent(modelDir)) {
      throw Exception('Model not present on device.');
    }

    _modelDirPath = modelDir.path;
    _currentLanguage = lang;

    // Configuration of Sherpa ONNX Whisper module
    final config = sherpa_onnx.OfflineRecognizerConfig(
      model: sherpa_onnx.OfflineModelConfig(
        tokens: p.join(_modelDirPath!, 'tokens.txt'),
        whisper: sherpa_onnx.OfflineWhisperModelConfig(
          encoder: p.join(_modelDirPath!, 'encoder.int8.onnx'),
          decoder: p.join(_modelDirPath!, 'decoder.int8.onnx'),
          language: _currentLanguage,
          task: 'transcribe',
        ),
      ),
    );

    _recognizer = sherpa_onnx.OfflineRecognizer(config);
  }

  /// Returns Whisper model destination directory
  Future<Directory> _getModelDirectory() async {
    final appDocDir = await getApplicationDocumentsDirectory();
    return Directory(p.join(appDocDir.path, 'sherpa-onnx-whisper-base'));
  }

  /// Verifies actual presence and validity of 3 files on disk
  Future<bool> _modelFilesPresent(Directory modelDir) async {
    if (!await modelDir.exists()) return false;
    for (final targetName in _tarballModelFiles.values) {
      final file = File(p.join(modelDir.path, targetName));
      if (!await file.exists()) return false;
      final size = await file.length();
      if (size == 0) return false;
    }
    return true;
  }

  /// Microphone permissions
  Future<bool> hasPermission() async {
    return await _recorder.hasPermission();
  }

  /// Starts continuous audio recording stream (PCM 16-bit mono)
  Future<Stream<Uint8List>> startRecording() async {
    return await _recorder.startStream(
      RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: _sampleRate,
        numChannels: 1,
      ),
    );
  }

  /// Stops recording
  Future<void> stopRecording() async {
    await _recorder.stop();
  }

  /// Async transcription of PCM 16-bit audio data via local ONNX model
  Future<String> transcribe(Uint8List pcm16Data) async {
    if (_recognizer == null) {
      throw Exception('STT not initialized. Configure the model.');
    }
    final floatSamples = _convertPcm16ToFloat32(pcm16Data);
    final stream = _recognizer!.createStream();
    stream.acceptWaveform(samples: floatSamples, sampleRate: _sampleRate);
    _recognizer!.decode(stream);
    
    // Retrieves text result via recognizer instance
    final result = _recognizer!.getResult(stream);
    final text = result.text;
    
    stream.free();
    return text;
  }

  /// Converts PCM16 bytes to Float32 (required by sherpa_onnx)
  Float32List _convertPcm16ToFloat32(Uint8List bytes) {
    final numSamples = bytes.lengthInBytes ~/ 2;
    final result = Float32List(numSamples);
    final byteData = ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.lengthInBytes);
    for (int i = 0; i < numSamples; i++) {
      final int16 = byteData.getInt16(i * 2, Endian.little);
      result[i] = int16 / 32768.0;
    }
    return result;
  }

  /// Release hardware resources
  void dispose() {
    _recorder.dispose();
    _recognizer?.free();
    _recognizer = null;
    _downloadProgress.dispose();
    _isExtracting.dispose();
    _isDownloading.dispose();
  }
}