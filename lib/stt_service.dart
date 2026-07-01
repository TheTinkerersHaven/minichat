import 'dart:async';
import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

/// URL del modello Whisper da scaricare
const _modelTarballUrl =
    'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-whisper-base.tar.bz2';

/// File necessari mappati (Nome originale -> Nome di destinazione nel dispositivo)
const _tarballModelFiles = {
  'base-encoder.int8.onnx': 'encoder.int8.onnx',
  'base-decoder.int8.onnx': 'decoder.int8.onnx',
  'base-tokens.txt': 'tokens.txt',
};

/// Configurazione passata all'Isolate per l'estrazione
class ExtractionConfig {
  final String archivePath;
  final String outputDirectory;
  ExtractionConfig(this.archivePath, this.outputDirectory);
}

/// Funzione top-level che viene eseguita nell'Isolate in background
void _extractSpecificModelFilesIsolate(ExtractionConfig config) {
  // InputFileStream legge a blocchi dal disco senza saturare la RAM
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

  // Notificatori di stato per l'interfaccia utente (asincroni)
  final ValueNotifier<double> _downloadProgress = ValueNotifier(0.0);
  final ValueNotifier<bool> _isExtracting = ValueNotifier(false);
  final ValueNotifier<bool> _isDownloading = ValueNotifier(false);

  String? _modelDirPath;

  bool get isInitialized => _recognizer != null;
  ValueNotifier<double> get downloadProgress => _downloadProgress;
  ValueNotifier<bool> get isExtracting => _isExtracting;
  ValueNotifier<bool> get isDownloading => _isDownloading;

  /// Verifica la presenza locale dei file del modello Whisper
  Future<bool> isModelDownloaded() async {
    final modelDir = await _getModelDirectory();
    final present = await _modelFilesPresent(modelDir);
    if (present) {
      _downloadProgress.value = 1.0;
    }
    return present;
  }

  /// Forza il controllo e l'eventuale download/estrazione del modello.
  /// Restituisce il percorso della cartella del modello sul disco.
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

  /// Avvia il download e l'estrazione asincrona in background
  Future<void> startBackgroundDownload() async {
    if (_isDownloading.value || _isExtracting.value) return;

    _isDownloading.value = true;
    _downloadProgress.value = 0.0;

    try {
      final modelDir = await _getModelDirectory();
      final appDocDir = await getApplicationDocumentsDirectory();
      final tempZipPath = p.join(appDocDir.path, 'whisper_model_temp.tar.bz2');

      // 1. Download asincrono a blocchi (Zero Memory Bloat)
      final request = http.Request('GET', Uri.parse(_modelTarballUrl));
      final response = await http.Client().send(request);

      if (response.statusCode != 200 && response.statusCode != 302) {
        throw Exception('Errore download modello: HTTP ${response.statusCode}');
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

      // 2. Transizione verso l'estrazione asincrona
      _isDownloading.value = false;
      _isExtracting.value = true;

      // 3. Esecuzione dell'estrazione asincrona su Isolate separato
      final config = ExtractionConfig(tempZipPath, modelDir.path);
      await compute(_extractSpecificModelFilesIsolate, config);

      // Pulizia dei file temporanei sul disco dell'utente
      if (await tempFile.exists()) {
        await tempFile.delete();
      }

      _modelDirPath = modelDir.path;
      _downloadProgress.value = 1.0;
    } catch (e) {
      debugPrint('Errore durante download/estrazione asincrona: $e');
    } finally {
      _isDownloading.value = false;
      _isExtracting.value = false;
    }
  }

  /// Inizializza il riconoscitore se il modello è presente
  Future<void> initialize({String language = 'auto'}) async {
    final lang = language == 'auto' ? '' : language;
    if (_recognizer != null && _currentLanguage == lang) return;

    final modelDir = await _getModelDirectory();
    if (!await _modelFilesPresent(modelDir)) {
      throw Exception('Modello non presente sul dispositivo.');
    }

    _modelDirPath = modelDir.path;
    _currentLanguage = lang;

    // Configurazione del modulo Sherpa ONNX Whisper
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

  /// Restituisce la directory di destinazione del modello Whisper
  Future<Directory> _getModelDirectory() async {
    final appDocDir = await getApplicationDocumentsDirectory();
    return Directory(p.join(appDocDir.path, 'sherpa-onnx-whisper-base'));
  }

  /// Verifica la presenza effettiva e valida dei 3 file nel disco
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

  /// Permessi del microfono
  Future<bool> hasPermission() async {
    return await _recorder.hasPermission();
  }

  /// Avvia la registrazione audio a flusso continuo (PCM 16 bit mono)
  Future<Stream<Uint8List>> startRecording() async {
    return await _recorder.startStream(
      RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: _sampleRate,
        numChannels: 1,
      ),
    );
  }

  /// Interrompe la registrazione
  Future<void> stopRecording() async {
    await _recorder.stop();
  }

  /// Trascrizione asincrona dei dati audio PCM 16 bit tramite il modello ONNX locale
  Future<String> transcribe(Uint8List pcm16Data) async {
    if (_recognizer == null) {
      throw Exception('STT non inizializzato. Configura il modello.');
    }
    final floatSamples = _convertPcm16ToFloat32(pcm16Data);
    final stream = _recognizer!.createStream();
    stream.acceptWaveform(samples: floatSamples, sampleRate: _sampleRate);
    _recognizer!.decode(stream);
    
    // Recupera il risultato testuale tramite l'istanza del recognizer
    final result = _recognizer!.getResult(stream);
    final text = result.text;
    
    stream.free();
    return text;
  }

  /// Converte i byte PCM16 in Float32 (richiesto da sherpa_onnx)
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

  /// Rilascio delle risorse hardware
  void dispose() {
    _recorder.dispose();
    _recognizer?.free();
    _recognizer = null;
    _downloadProgress.dispose();
    _isExtracting.dispose();
    _isDownloading.dispose();
  }
}