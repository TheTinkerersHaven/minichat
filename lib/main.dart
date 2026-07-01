// MiniChat - Chat per modelli con API OpenAI-compatible.
//
// Questo file (main.dart) contiene:
// - L'interfaccia utente (schermata chat, impostazioni)
// - La logica di invio richieste all'API OpenAI-compatible con risposte in streaming SSE
// - Le classi Request (chiamate HTTP) e AppSettings (cache con SharedPreferences)
// - Il tema chiaro/scuro persistente tramite ValueNotifier
//
// Il file stt_service.dart gestisce il riconoscimento vocale locale:
// - Usa sherpa_onnx per eseguire il modello Whisper in locale (ONNX)
// - Il modello viene scaricato automaticamente da GitHub alla prima esecuzione
// - Viene estratto da un archivio tar.bz2 e salvato su disco
// - Serve perché Linux non supporta l'API STT di Google (plugin speech_to_text)
// - I file del modello sono esclusi da git tramite .gitignore
//
// Per il rendering dei messaggi vengono usati gpt_markdown (markdown)
// e flutter_math_fork (formule LaTeX con $...$).
//
// Status funzionalità per piattaforma:
// - ANDROID e LINUX: funzionante
// - IOS/WINDOWS/MACOS: non testato
// - WEB: non funziona e non supportato (incompatibile)

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_sse_http/simple_sse_http.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

import 'stt_service.dart';

final ValueNotifier<ThemeMode> themeModeNotifier = ValueNotifier(
  ThemeMode.light,
);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Inizializzazione della libreria nativa di sherpa_onnx 
  // all'avvio globale per evitare l'eccezione "Please initialize sherpa-onnx first"
  try {
    sherpa_onnx.initBindings();
    debugPrint('Libreria nativa sherpa_onnx caricata con successo.');
  } catch (e) {
    debugPrint('Errore nell\'inizializzazione nativa globale di sherpa_onnx: $e');
  }

  final settings = await AppSettings().loadSettings();
  themeModeNotifier.value = settings.darkMode
      ? ThemeMode.dark
      : ThemeMode.light;
  runApp(const MiniChatApp());
}

class MiniChatApp extends StatelessWidget {
  const MiniChatApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (context, mode, _) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'MiniChat',
          theme: ThemeData(
            fontFamily: GoogleFonts.robotoMono().fontFamily,
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF6366F1),
              brightness: Brightness.light,
            ),
          ),
          darkTheme: ThemeData(
            fontFamily: GoogleFonts.robotoMono().fontFamily,
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF818CF8),
              brightness: Brightness.dark,
            ),
          ),
          themeMode: mode,
          home: const MyHomePage(title: 'MiniChat'),
        );
      },
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  State<StatefulWidget> createState() => _MyHomePageState();
}

class ChatMessage {
  final String role;
  final String content;

  ChatMessage({required this.role, required this.content});
}

class _MyHomePageState extends State<MyHomePage> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<ChatMessage> _chatMessages = [
    ChatMessage(
      role: "assistant",
      content:
          "Ciao e benvenuto in *MiniChat!* 👋\nSe è la prima volta che usi l'app, vai nelle **impostazioni** per **configurare le tue credenziali API.**\nFatto ciò, scrivi un messaggio per iniziare!",
    ),
  ];
  final List<Map<String, String>> _messages = [
    {"role": "system", "content": "You are a helpful assistant."},
  ];
  bool isLoading = false;

  // Cache Impostazioni e STT
  AppSettings? _currentSettings; // Cache in memoria per evitare letture I/O continue
  String _modelName = '';
  final SttService _sttService = SttService();
  bool _isListening = false;
  bool _isTranscribing = false;
  StreamSubscription<Uint8List>? _audioSubscription;
  List<int> _audioBuffer = [];

  @override
  void initState() {
    super.initState();
    _reloadSettings();

    // Semplificato: All'avvio dell'app notifichiamo l'utente con una SnackBar se il modello non è presente
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final isDownloaded = await _sttService.isModelDownloaded();
      if (!isDownloaded && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Dettatura offline disponibile! Configura il modello locale.'),
            duration: const Duration(seconds: 6),
            behavior: SnackBarBehavior.floating,
            action: SnackBarAction(
              label: 'Configura',
              onPressed: () => _navigateToSettings(),
            ),
          ),
        );
      }
    });
  }

  // Carica le impostazioni una sola volta o alla modifica
  Future<void> _reloadSettings() async {
    final settings = await AppSettings().loadSettings();
    if (!mounted) return;
    setState(() {
      _currentSettings = settings;
      _modelName = settings.model;
    });
  }

  Future<void> _navigateToSettings() async {
    final darkMode = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => AppSettingsPage(sttService: _sttService),
      ),
    );
    if (darkMode != null) {
      themeModeNotifier.value = darkMode
          ? ThemeMode.dark
          : ThemeMode.light;
    }
    _reloadSettings(); // Aggiorna la cache locale dei setting al ritorno
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;

    _messages.add({"role": "user", "content": text});
    setState(() {
      isLoading = true;
      _chatMessages.add(ChatMessage(role: "user", content: text));
    });
    _controller.clear();
    _scrollToBottom();

    _messages.add({"role": "assistant", "content": ""});
    setState(() {
      _chatMessages.add(ChatMessage(role: "assistant", content: ""));
    });
    final int botIndex = _chatMessages.length - 1;

    String fullReply = "";
    try {
      // Usa le impostazioni in cache (fall-back di sicurezza se nullo)
      final settings = _currentSettings ?? await AppSettings().loadSettings();
      final stream = await Request().sendRequestStreaming(
        _messages.sublist(0, _messages.length - 1),
        settings,
      );

      await for (final chunk in stream) {
        if (!mounted) {
          return; // Previene crash se l'utente esce dalla schermata durante lo streaming
        }
        fullReply += chunk;
        setState(() {
          _chatMessages[botIndex] = ChatMessage(
            role: "assistant",
            content: fullReply,
          );
        });
        _scrollToBottom();
      }
      _messages[_messages.length - 1] = {
        "role": "assistant",
        "content": fullReply,
      };
    } catch (e) {
      final errorMsg = "Errore durante lo streaming: $e";
      setState(() {
        _chatMessages[botIndex] = ChatMessage(
          role: "assistant",
          content: errorMsg,
        );
      });
      _messages[_messages.length - 1] = {
        "role": "assistant",
        "content": errorMsg,
      };
    }

    if (!mounted) return;
    setState(() => isLoading = false);
    _scrollToBottom();
  }

  Future<void> _toggleListening() async {
    if (_isListening) {
      _isListening = false;
      await _audioSubscription?.cancel();
      await _sttService.stopRecording();
      setState(() => _isTranscribing = true);

      try {
        final audioData = Uint8List.fromList(_audioBuffer);
        _audioBuffer = [];
        if (audioData.isNotEmpty) {
          final text = await _sttService.transcribe(audioData);
          if (text.isNotEmpty) {
            final trimmed = text.trim();
            _controller.text = _controller.text.isNotEmpty
                ? '${_controller.text} $trimmed'
                : trimmed;
            _controller.selection = TextSelection.collapsed(
              offset: _controller.text.length,
            );
          }
        }
      } catch (e) {
        debugPrint('STT error: $e');
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Errore STT: $e')));
      }

      if (!mounted) return;
      setState(() => _isTranscribing = false);
    } else {
      try {
        final hasPermission = await _sttService.hasPermission();
        if (!hasPermission) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Permesso microfono non concesso')),
          );
          return;
        }

        // Semplificato: Se il modello non è scaricato, mostriamo un avviso SnackBar con azione diretta
        final isModelDownloaded = await _sttService.isModelDownloaded();
        if (!isModelDownloaded) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('Il modello Whisper offline non è ancora pronto.'),
              behavior: SnackBarBehavior.floating,
              action: SnackBarAction(
                label: 'Scarica',
                onPressed: () => _navigateToSettings(),
              ),
            ),
          );
          return;
        }

        final settings = _currentSettings ?? await AppSettings().loadSettings();
        await _sttService.initialize(language: settings.sttLanguage);
        _audioBuffer = [];
        final stream = await _sttService.startRecording();
        _audioSubscription = stream.listen(
          (data) => _audioBuffer.addAll(data),
          onError: (e) => debugPrint('Recording error: $e'),
        );
        setState(() => _isListening = true);
      } catch (e) {
        debugPrint('STT start error: $e');
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Errore avvio STT: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        // Indicatore del progresso asincrono asimmetrico nel leading dell'AppBar
        leading: ValueListenableBuilder<bool>(
          valueListenable: _sttService.isDownloading,
          builder: (context, isDownloading, _) {
            return ValueListenableBuilder<bool>(
              valueListenable: _sttService.isExtracting,
              builder: (context, isExtracting, _) {
                if (isDownloading) {
                  return ValueListenableBuilder<double>(
                    valueListenable: _sttService.downloadProgress,
                    builder: (context, progress, _) {
                      return Tooltip(
                        message: 'Download Whisper in background...',
                        child: Center(
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              CircularProgressIndicator(
                                value: progress,
                                strokeWidth: 3.0,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                              Text(
                                '${(progress * 100).toInt()}%',
                                style: const TextStyle(
                                  fontSize: 8,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  );
                } else if (isExtracting) {
                  return const Tooltip(
                    message: 'Estrazione in corso...',
                    child: Center(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          color: Colors.orange,
                        ),
                      ),
                    ),
                  );
                } else {
                  return const SizedBox.shrink();
                }
              },
            );
          },
        ),
        title: Padding(
          padding: const EdgeInsets.only(bottom: 4.0),
          child: Text(
            widget.title,
            style: GoogleFonts.silkscreen(fontSize: 30, letterSpacing: 1.2),
          ),
        ),
        centerTitle: true,
        actionsPadding: const EdgeInsets.only(right: 4.0),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_rounded),
            onPressed: _navigateToSettings,
          ),
        ],
      ),
      body: SafeArea(
        top: true,
        bottom: true,
        child: Column(
          children: [
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                itemCount: _chatMessages.length,
                itemBuilder: (context, index) {
                  final msg = _chatMessages[index];
                  final isUser = msg.role == "user";
                  return Align(
                    alignment: isUser
                        ? Alignment.centerRight
                        : Alignment.centerLeft,
                    child: Container(
                      constraints: BoxConstraints(
                        maxWidth: MediaQuery.of(context).size.width * 0.78,
                      ),
                      margin: EdgeInsets.only(
                        top: 6,
                        bottom: 6,
                        left: isUser ? 60 : 0,
                        right: isUser ? 0 : 60,
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: isUser
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(
                                context,
                              ).colorScheme.surfaceContainerHighest,
                        borderRadius: const BorderRadius.all(
                          Radius.circular(12),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            isUser
                                ? 'Tu'
                                : (_modelName.isNotEmpty
                                      ? 'Bot ($_modelName)'
                                      : 'Bot'),
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 11,
                              color: isUser
                                  ? Theme.of(context).colorScheme.onPrimary
                                  : Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 4),
                          DefaultTextStyle(
                            style: TextStyle(
                              color: isUser
                                  ? Theme.of(context).colorScheme.onPrimary
                                  : Theme.of(context).colorScheme.onSurface,
                              fontSize: 15,
                              height: 1.4,
                            ),
                            child: GptMarkdown(
                              msg.content,
                              latexWorkaround: (tex) =>
                                  tex.replaceAll('\\\\', '\\'),
                              useDollarSignsForLatex: true,
                              latexBuilder: (context, tex, textStyle, inline) {
                                return SingleChildScrollView(
                                  scrollDirection: Axis.horizontal,
                                  child: Math.tex(
                                    tex,
                                    textStyle: textStyle,
                                    mathStyle: MathStyle.display,
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            if (isLoading)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Row(
                  children: [
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 8),
                    Text(
                      'Il bot sta scrivendo...',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(10),
              child: Row(
                spacing: 4,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  if (_isTranscribing)
                    const SizedBox(
                      width: 56,
                      height: 56,
                      child: Center(
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    )
                  else
                    IconButton.filledTonal(
                      // FIX CHIRURGICO: Consentiamo la pressione per mostrare la SnackBar descrittiva se non scaricato!
                      onPressed: isLoading ? null : _toggleListening,
                      icon: Icon(
                        _isListening ? Icons.stop_rounded : Icons.mic_rounded,
                        color: _isListening ? Colors.red : null,
                      ),
                      style: IconButton.styleFrom(
                        fixedSize: const Size(56, 56),
                        shape: const RoundedRectangleBorder(
                          borderRadius: BorderRadius.all(Radius.circular(12.0)),
                        ),
                        padding: EdgeInsets.zero,
                      ),
                      tooltip: _isListening
                          ? 'Ferma registrazione'
                          : 'Avvia riconoscimento vocale',
                    ),
                  Expanded(
                    child: TextField(
                      // FIX CHIRURGICO: Utilizzato _controller corretto per evitare l'errore di compilazione
                      controller: _controller,
                      style: const TextStyle(fontFamily: ''),
                      decoration: const InputDecoration(
                        hintText: 'Scrivi un messaggio...',
                        border: OutlineInputBorder(),
                      ),
                      onSubmitted: (_) => _sendMessage(),
                    ),
                  ),
                  IconButton.filled(
                    onPressed: isLoading ? null : _sendMessage,
                    icon: const Icon(Icons.send_rounded),
                    style: IconButton.styleFrom(
                      fixedSize: const Size(56, 56),
                      shape: const RoundedRectangleBorder(
                        borderRadius: BorderRadius.all(Radius.circular(12.0)),
                      ),
                      padding: EdgeInsets.zero,
                    ),
                    tooltip: 'Invia messaggio',
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 8.0),
              child: Text(
                "L'AI può generare risposte non accurate o inappropriate.",
                style: TextStyle(
                  fontSize: 10,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class AppSettingsPage extends StatefulWidget {
  final SttService sttService;

  const AppSettingsPage({super.key, required this.sttService});

  @override
  State<StatefulWidget> createState() => _AppSettingsPageState();
}

class _AppSettingsPageState extends State<AppSettingsPage> {
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _apiKeyController = TextEditingController();
  final TextEditingController _modelController = TextEditingController();
  String _sttLanguage = 'auto';
  bool _darkMode = false;
  bool _isModelDownloaded = false;

  static const _sttLanguages = {
    'auto': 'Auto-detect',
    'it': 'Italiano',
    'en': 'English',
    'fr': 'Français',
    'de': 'Deutsch',
    'es': 'Español',
    'pt': 'Português',
    'nl': 'Nederlands',
    'pl': 'Polski',
    'zh': '中文',
    'ja': '日本語',
    'ko': '한국어',
  };

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _checkModelStatus();
  }

  Future<void> _checkModelStatus() async {
    final downloaded = await widget.sttService.isModelDownloaded();
    if (mounted) {
      setState(() {
        _isModelDownloaded = downloaded;
      });
    }
  }

  Future<void> _loadSettings() async {
    final settings = await AppSettings().loadSettings();
    setState(() {
      _urlController.text = settings.url;
      _apiKeyController.text = settings.apiKey;
      _modelController.text = settings.model;
      _sttLanguage = settings.sttLanguage;
      _darkMode = settings.darkMode;
    });
  }

  Future<void> _saveSettings() async {
    final settings = AppSettings(
      url: _urlController.text,
      apiKey: _apiKeyController.text,
      model: _modelController.text,
      sttLanguage: _sttLanguage,
      darkMode: _darkMode,
    );
    await settings.saveSettings();
    themeModeNotifier.value = _darkMode ? ThemeMode.dark : ThemeMode.light;
    if (!mounted) return;
    Navigator.pop(context, _darkMode);
  }

  void _onExtractionFinished() {
    if (!widget.sttService.isExtracting.value &&
        !widget.sttService.isDownloading.value) {
      _checkModelStatus();
      widget.sttService.isExtracting.removeListener(_onExtractionFinished);
    }
  }

  Widget _buildWhisperDownloadSection() {
    if (_isModelDownloaded) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(
            context,
          ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
          border: Border.all(color: Colors.green.withValues(alpha: 0.5)),
          borderRadius: const BorderRadius.all(Radius.circular(12.0)),
        ),
        child: Row(
          children: [
            const Icon(Icons.check_circle, color: Colors.green),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Modello Whisper già scaricato (~200MB) e pronto all\'uso locale.',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return ValueListenableBuilder<bool>(
      valueListenable: widget.sttService.isDownloading,
      builder: (context, isDownloading, _) {
        return ValueListenableBuilder<bool>(
          valueListenable: widget.sttService.isExtracting,
          builder: (context, isExtracting, _) {
            if (isDownloading) {
              return ValueListenableBuilder<double>(
                valueListenable: widget.sttService.downloadProgress,
                builder: (context, progress, _) {
                  return Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerHighest,
                      borderRadius: const BorderRadius.all(
                        Radius.circular(12.0),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'Download Whisper in corso...',
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              '${(progress * 100).toInt()}%',
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        LinearProgressIndicator(
                          value: progress.clamp(0.0, 1.0),
                        ),
                      ],
                    ),
                  );
                },
              );
            } else if (isExtracting) {
              return Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: const BorderRadius.all(Radius.circular(12.0)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Estrazione modello in corso...',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const LinearProgressIndicator(
                      value: null,
                    ), // Barra indeterminata
                  ],
                ),
              );
            } else {
              return SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.all(Radius.circular(12.0)),
                    ),
                  ),
                  onPressed: () {
                    widget.sttService.startBackgroundDownload();
                    widget.sttService.isExtracting.addListener(
                      _onExtractionFinished,
                    );
                  },
                  icon: const Icon(Icons.download_rounded),
                  label: const Text('Scarica Modello Whisper Offline'),
                ),
              );
            }
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Padding(
          padding: EdgeInsets.only(bottom: 4.0),
          child: Text('Impostazioni'),
        ),
        centerTitle: true,
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              children: [
                TextField(
                  controller: _urlController,
                  style: const TextStyle(fontFamily: ''),
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText:
                        'URL completo (es. api.openai.com/v1/chat/completions)',
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _apiKeyController,
                  style: const TextStyle(fontFamily: ''),
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: 'API Key',
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _modelController,
                  style: const TextStyle(fontFamily: ''),
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: 'Modello (es. poolside/laguna-xs.2)',
                  ),
                ),
                const SizedBox(height: 8),
                Center(
                  child: Text(
                    "ATTENZIONE: La chiave API viene salvata in chiaro sul dispositivo.\nSono compatibili solo modelli con API OpenAI-compatible.",
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 10,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                const Divider(),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  // FIX CHIRURGICO: Utilizzato initialValue (non deprecato e corretto) come suggerito
                  initialValue: _sttLanguage,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: 'Lingua riconoscimento vocale',
                  ),
                  items: _sttLanguages.entries.map((e) {
                    return DropdownMenuItem(value: e.key, child: Text(e.value));
                  }).toList(),
                  onChanged: (v) {
                    if (v != null) setState(() => _sttLanguage = v);
                  },
                ),
                const SizedBox(height: 8),
                Text(
                  "Per il riconoscimento vocale viene usato un modello Whisper locale, scaricato e custodito nel dispositivo. Non vengono inviati dati a server esterni.",
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 10,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),
                _buildWhisperDownloadSection(),
                const SizedBox(height: 24),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _saveSettings,
                      child: const Text('Salva Impostazioni'),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          SwitchListTile(
            title: const Text('Tema scuro'),
            subtitle: const Text(
              'Usa tema scuro per l\'interfaccia\n(fidati, è più bello così)',
            ),
            value: _darkMode,
            onChanged: (v) async {
              setState(() => _darkMode = v);
              themeModeNotifier.value = v ? ThemeMode.dark : ThemeMode.light;
              final settings = AppSettings(
                url: _urlController.text,
                apiKey: _apiKeyController.text,
                model: _modelController.text,
                sttLanguage: _sttLanguage,
                darkMode: v,
              );
              await settings.saveSettings();
            },
          ),
        ],
      ),
    );
  }
}

String _stripProtocol(String url) {
  if (url.startsWith('https://')) return url.substring(8);
  if (url.startsWith('http://')) return url.substring(7);
  return url;
}

String? _validateUrl(String url) {
  if (url.isEmpty) return null;
  final cleanUrl = _stripProtocol(url);
  final parts = cleanUrl.split('/');
  if (parts.length < 2) return null;
  return cleanUrl;
}

class Request {
  // FIX CHIRURGICO: Ripristinata l'implementazione completa dello streaming SSE per OpenAI
  Future<Stream<String>> sendRequestStreaming(
    List<Map<String, String>> messages,
    AppSettings settings,
  ) async {
    final cleanUrl = _validateUrl(settings.url);
    if (cleanUrl == null) {
      throw Exception(
        'URL non valido. Inserisci un URL completo (es. api.openai.com/v1/chat/completions)',
      );
    }

    final host = cleanUrl.substring(0, cleanUrl.indexOf('/'));
    final path = cleanUrl.substring(cleanUrl.indexOf('/') + 1);
    final url = Uri.https(host, '/$path');

    final client = HttpSseClient();
    final events = client.connect(
      url,
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${settings.apiKey}',
      },
      body: {"model": settings.model, "messages": messages, "stream": true},
    );

    return events
        .where((event) => event.data != '[DONE]')
        .map((event) {
          final json = jsonDecode(event.data) as Map<String, dynamic>;
          final delta = json['choices'][0]['delta'] as Map<String, dynamic>?;
          return delta?['content'] as String? ?? '';
        })
        .where((chunk) => chunk.isNotEmpty);
  }

  // FIX CHIRURGICO: Ripristinato il metodo standard di richiesta asincrona POST
  Future<Map<String, dynamic>> sendRequest(
    List<Map<String, String>> messages,
    AppSettings settings,
  ) async {
    try {
      final cleanUrl = _validateUrl(settings.url);
      if (cleanUrl == null) {
        return {
          "error":
              "URL non valido. Inserisci un URL completo (es. api.openai.com/v1/chat/completions)",
        };
      }

      final host = cleanUrl.substring(0, cleanUrl.indexOf('/'));
      final path = cleanUrl.substring(cleanUrl.indexOf('/') + 1);
      final url = Uri.https(host, '/$path');

      final headers = {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${settings.apiKey}',
      };
      final body = {"model": settings.model, "messages": messages};
      final response = await http.post(
        url,
        headers: headers,
        body: jsonEncode(body),
      );
      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      } else {
        return {
          "error":
              "Errore ${response.statusCode}: Hai inserito correttamente l'URL, la chiave API e il modello?",
        };
      }
    } catch (e) {
      return {
        "error":
            "Errore nella richiesta. Hai inserito correttamente l'URL, la chiave API e il modello?\n$e",
      };
    }
  }
}

class AppSettings {
  String url;
  String apiKey;
  String model;
  String sttLanguage;
  bool darkMode;

  static const _kUrl = 'URL';
  static const _kApiKey = 'apiKey';
  static const _kModel = 'model';
  static const _kSttLanguage = 'sttLanguage';
  static const _kDarkMode = 'darkMode';

  AppSettings({
    this.url = '',
    this.apiKey = '',
    this.model = '',
    this.sttLanguage = 'auto',
    this.darkMode = false,
  });

  Future<void> saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kUrl, url);
    await prefs.setString(_kApiKey, apiKey);
    await prefs.setString(_kModel, model);
    await prefs.setString(_kSttLanguage, sttLanguage);
    await prefs.setBool(_kDarkMode, darkMode);
  }

  Future<AppSettings> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    return AppSettings(
      url: prefs.getString(_kUrl) ?? '',
      apiKey: prefs.getString(_kApiKey) ?? '',
      model: prefs.getString(_kModel) ?? '',
      sttLanguage: prefs.getString(_kSttLanguage) ?? 'auto',
      darkMode: prefs.getBool(_kDarkMode) ?? false,
    );
  }
}