// MiniChat - Chat for models with OpenAI-compatible API.
//
// This file (main.dart) contains:
// - User interface (chat screen, settings)
// - Logic for sending requests to OpenAI-compatible API with SSE streaming responses
// - Request classes (HTTP calls) and AppSettings (cache with SharedPreferences)
// - Persistent light/dark theme via ValueNotifier
//
// The stt_service.dart file handles local speech recognition:
// - Uses sherpa_onnx to run Whisper model locally (ONNX)
// - Model is automatically downloaded from GitHub on first run
// - Extracted from tar.bz2 archive and saved to disk
// - Needed because Linux doesn't support Google STT API (speech_to_text plugin)
// - Model files are excluded from git via .gitignore
//
// For message rendering, gpt_markdown (markdown) and flutter_math_fork (LaTeX formulas with $...$) are used.
//
// Feature status by platform:
// - ANDROID and LINUX: working
// - IOS/WINDOWS/MACOS: not tested
// - WEB: doesn't work and not supported (incompatible)

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_sse_http/simple_sse_http.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

import 'stt_service.dart';

final ValueNotifier<ThemeMode> themeModeNotifier = ValueNotifier(
  ThemeMode.light,
);

/// App entry point: loads settings, initializes sherpa_onnx native bindings, and launches the app.
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Initialize sherpa_onnx native library at global startup to avoid "Please initialize sherpa-onnx first" exception
  try {
    sherpa_onnx.initBindings();
    debugPrint('sherpa_onnx native library loaded successfully.');
  } catch (e) {
    debugPrint('Error in sherpa_onnx global native initialization: $e');
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
  /// Builds the MaterialApp with light/dark theme based on themeModeNotifier.
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (context, mode, _) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'MiniChat',
          theme: ThemeData(
            fontFamily: 'RobotoMono',
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF6366F1),
              brightness: Brightness.light,
            ),
          ),
          darkTheme: ThemeData(
            fontFamily: 'RobotoMono',
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
          "Hi and welcome to *MiniChat!* 👋\nIf it's your first time using the app, go to **settings** to **configure your API credentials.**\nThen, write a message to get started!",
    ),
  ];
  final List<Map<String, String>> _messages = [
    {"role": "system", "content": "You are a helpful assistant."},
  ];
  bool isLoading = false;

  // Settings and STT Cache
  AppSettings?
  _currentSettings; // In-memory cache to avoid continuous I/O reads
  String _modelName = '';
  final SttService _sttService = SttService();
  bool _isListening = false;
  bool _isTranscribing = false;
  StreamSubscription<Uint8List>? _audioSubscription;
  List<int> _audioBuffer = [];

  @override
  /// Initializes the chat screen: loads settings and shows a SnackBar if the Whisper model is missing.
  void initState() {
    super.initState();
    _reloadSettings();

    // Simplified: At app startup we notify user with SnackBar if model is not present
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final isDownloaded = await _sttService.isModelDownloaded();
      if (!isDownloaded && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              'Offline dictation available! Configure local model.',
            ),
            duration: const Duration(seconds: 6),
            behavior: SnackBarBehavior.floating,
            action: SnackBarAction(
              label: 'Configure',
              onPressed: () => _navigateToSettings(),
            ),
          ),
        );
      }
    });
  }

  /// Loads settings from SharedPreferences and updates the local cache.
  Future<void> _reloadSettings() async {
    final settings = await AppSettings().loadSettings();
    if (!mounted) return;
    setState(() {
      _currentSettings = settings;
      _modelName = settings.model;
    });
  }

  /// Opens the settings page and refreshes local settings on return.
  Future<void> _navigateToSettings() async {
    final darkMode = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => AppSettingsPage(sttService: _sttService),
      ),
    );
    if (darkMode != null) {
      themeModeNotifier.value = darkMode ? ThemeMode.dark : ThemeMode.light;
    }
    _reloadSettings(); // Update local settings cache on return
  }

  /// Scrolls the chat list to the bottom with a smooth animation.
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

  /// Sends the user message to the API, streams the response, and updates the chat UI.
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
      // Use cached settings (safety fallback if null)
      final settings = _currentSettings ?? await AppSettings().loadSettings();
      final stream = await Request().sendRequestStreaming(
        _messages.sublist(0, _messages.length - 1),
        settings,
      );

      await for (final chunk in stream) {
        if (!mounted) {
          return; // Prevents crash if user leaves the screen during streaming
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
      final errorMsg = "Streaming error: $e";
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

  /// Toggles speech recognition: starts/stops recording and transcribes audio with Whisper.
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
        ).showSnackBar(SnackBar(content: Text('STT error: $e')));
      }

      if (!mounted) return;
      setState(() => _isTranscribing = false);
    } else {
      try {
        final hasPermission = await _sttService.hasPermission();
        if (!hasPermission) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Microphone permission not granted')),
          );
          return;
        }

        // Simplified implementation of voice model notification with direct action
        final isModelDownloaded = await _sttService.isModelDownloaded();
        if (!isModelDownloaded) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text(
                'The offline Whisper model is not ready yet.',
              ),
              behavior: SnackBarBehavior.floating,
              action: SnackBarAction(
                label: 'Download',
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
        ).showSnackBar(SnackBar(content: Text('STT start error: $e')));
      }
    }
  }

  @override
  /// Builds the main chat UI: message list, input row, STT button, and loading indicators.
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        // Asymmetric async progress indicator in AppBar leading
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
                    message: 'Extracting...',
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
            style: const TextStyle(fontSize: 30, letterSpacing: 1.2, fontFamily: 'Silkscreen'),
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
                      'Bot is writing...',
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
                          ? 'Stop recording'
                          : 'Start speech recognition',
                    ),
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      style: const TextStyle(fontFamily: ''),
                      decoration: const InputDecoration(
                        hintText: 'Write a message...',
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
                    tooltip: 'Send message',
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 8.0),
              child: Text(
                "AI may generate inaccurate or inappropriate responses.",
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
  /// Initialises the settings page: loads saved settings and checks Whisper model status.
  void initState() {
    super.initState();
    _loadSettings();
    _checkModelStatus();
  }

  /// Checks whether the Whisper model is already downloaded and updates the UI state.
  Future<void> _checkModelStatus() async {
    final downloaded = await widget.sttService.isModelDownloaded();
    if (mounted) {
      setState(() {
        _isModelDownloaded = downloaded;
      });
    }
  }

  /// Loads settings from SharedPreferences and populates the form fields.
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

  /// Saves the current form values to SharedPreferences and returns the dark mode setting.
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

  /// Called when model extraction finishes; re-checks model status and removes the listener.
  void _onExtractionFinished() {
    if (!widget.sttService.isExtracting.value &&
        !widget.sttService.isDownloading.value) {
      _checkModelStatus();
      widget.sttService.isExtracting.removeListener(_onExtractionFinished);
    }
  }

  /// Builds the Whisper download section: shows status card or download/extract progress UI.
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
                'Whisper model already downloaded (~200MB) and ready for local use.',
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
                              'Downloading Whisper...',
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
                      'Extracting model...',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const LinearProgressIndicator(
                      value: null,
                    ), // Indeterminate bar
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
                  label: const Text('Download Offline Whisper Model'),
                ),
              );
            }
          },
        );
      },
    );
  }

  @override
  /// Builds the settings page: API configuration, language picker, Whisper download, and dark theme toggle.
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
                        'Full URL (e.g. api.openai.com/v1/chat/completions)',
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
                    labelText: 'Model (e.g. poolside/laguna-xs.2)',
                  ),
                ),
                const SizedBox(height: 8),
                Center(
                  child: Text(
                    "WARNING: API key is stored in plaintext on device.\nOnly OpenAI-compatible API models are supported.",
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
                  initialValue: _sttLanguage,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: 'Speech recognition language',
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
                  "For speech recognition, a local Whisper model is used, downloaded and stored on the device. No data is sent to external servers.",
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
                      child: const Text('Save Settings'),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          SwitchListTile(
            title: const Text('Dark theme'),
            subtitle: const Text(
              'Use dark interface theme\n(trust me, it looks better)',
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

/// Removes the protocol prefix (http:// or https://) from a URL string.
String _stripProtocol(String url) {
  if (url.startsWith('https://')) return url.substring(8);
  if (url.startsWith('http://')) return url.substring(7);
  return url;
}

/// Validates that the URL has at least a host and a path after stripping the protocol.
String? _validateUrl(String url) {
  if (url.isEmpty) return null;
  final cleanUrl = _stripProtocol(url);
  final parts = cleanUrl.split('/');
  if (parts.length < 2) return null;
  return cleanUrl;
}

class Request {
  /// Sends a streaming POST request to the OpenAI-compatible API and returns a stream of text chunks.
  Future<Stream<String>> sendRequestStreaming(
    List<Map<String, String>> messages,
    AppSettings settings,
  ) async {
    final cleanUrl = _validateUrl(settings.url);
    if (cleanUrl == null) {
      throw Exception(
        'Invalid URL. Enter a full URL (e.g. api.openai.com/v1/chat/completions)',
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
}

class AppSettings {
  String url;
  String apiKey;
  String model;
  String sttLanguage;
  bool darkMode;

  static const _keyUrl = 'URL';
  static const _keyApiKey = 'apiKey';
  static const _keyModel = 'model';
  static const _keySttLanguage = 'sttLanguage';
  static const _keyDarkMode = 'darkMode';

  AppSettings({
    this.url = '',
    this.apiKey = '',
    this.model = '',
    this.sttLanguage = 'auto',
    this.darkMode = false,
  });

  /// Persists all settings to SharedPreferences.
  Future<void> saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyUrl, url);
    await prefs.setString(_keyApiKey, apiKey);
    await prefs.setString(_keyModel, model);
    await prefs.setString(_keySttLanguage, sttLanguage);
    await prefs.setBool(_keyDarkMode, darkMode);
  }

  /// Loads all settings from SharedPreferences; missing keys fall back to defaults.
  Future<AppSettings> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    return AppSettings(
      url: prefs.getString(_keyUrl) ?? '',
      apiKey: prefs.getString(_keyApiKey) ?? '',
      model: prefs.getString(_keyModel) ?? '',
      sttLanguage: prefs.getString(_keySttLanguage) ?? 'auto',
      darkMode: prefs.getBool(_keyDarkMode) ?? false,
    );
  }
}
