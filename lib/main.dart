import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_sse_http/simple_sse_http.dart';

import 'stt_service.dart';

final ValueNotifier<ThemeMode> themeModeNotifier = ValueNotifier(
  ThemeMode.light,
);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF6366F1),
              brightness: Brightness.light,
            ),
          ),
          darkTheme: ThemeData(
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
  final String role; // "user" o "assistant"
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
          "Ciao! 👋 Sono il tuo assistente. Scrivi qualcosa per iniziare!\nNOTA BENE: Se è la prima volta che usi l'app, vai nelle impostazioni per configurare le tue credenziali API.",
    ),
  ];
  final List<Map<String, String>> _messages = [
    {"role": "system", "content": "You are a helpful assistant."},
  ];
  bool isLoading = false;

  // STT
  final SttService _sttService = SttService();
  bool _isListening = false;
  bool _isTranscribing = false;
  StreamSubscription<Uint8List>? _audioSubscription;
  List<int> _audioBuffer = [];
  String _modelName = '';

  @override
  void initState() {
    super.initState();
    _loadModelName();
  }

  Future<void> _loadModelName() async {
    final settings = await AppSettings().loadSettings();
    setState(() => _modelName = settings.model);
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: Duration(milliseconds: 300),
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

    // Aggiunge un messaggio placeholder vuoto per il bot
    _messages.add({"role": "assistant", "content": ""});
    setState(() {
      _chatMessages.add(ChatMessage(role: "assistant", content: ""));
    });
    final int botIndex = _chatMessages.length - 1;

    String fullReply = "";
    try {
      final stream = await Request().sendRequestStreaming(
        _messages.sublist(0, _messages.length - 1), // esclude placeholder
        await AppSettings().loadSettings(),
      );
      await for (final chunk in stream) {
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

    setState(() => isLoading = false);
    _scrollToBottom();
  }

  Future<void> _toggleListening() async {
    if (_isListening) {
      // Stop recording and transcribe
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
            _controller.text = _controller.text.isNotEmpty
                ? '${_controller.text} $text'
                : text;
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

      setState(() => _isTranscribing = false);
    } else {
      // Start recording
      try {
        // Richiedi permesso microfono su Android/iOS
        final hasPermission = await _sttService.hasPermission();
        if (!hasPermission) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Permesso microfono non concesso')),
          );
          return;
        }

        // Carica lingua dalle impostazioni e inizializza (o aggiorna)
        final settings = await AppSettings().loadSettings();
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
  void dispose() {
    _audioSubscription?.cancel();
    _sttService.dispose();
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.title,
          style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.2),
        ),
        centerTitle: true,
        actions: [
          IconButton(
            icon: Icon(Icons.settings),
            onPressed: () async {
              final darkMode = await Navigator.push<bool>(
                context,
                MaterialPageRoute(builder: (_) => const AppSettingsPage()),
              );
              if (darkMode != null) {
                themeModeNotifier.value = darkMode
                    ? ThemeMode.dark
                    : ThemeMode.light;
              }
              // Ricarica nome modello (potrebbe essere cambiato)
              _loadModelName();
            },
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
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
                      padding: EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: isUser
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(
                                context,
                              ).colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.only(
                          topLeft: Radius.circular(16),
                          topRight: Radius.circular(16),
                          bottomLeft: Radius.circular(isUser ? 16 : 4),
                          bottomRight: Radius.circular(isUser ? 4 : 16),
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
                          SizedBox(height: 4),
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
              Padding(
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
                children: [
                  if (_isTranscribing)
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 8),
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  else
                    IconButton(
                      icon: Icon(
                        _isListening ? Icons.stop : Icons.mic,
                        color: _isListening ? Colors.red : null,
                      ),
                      onPressed: isLoading ? null : _toggleListening,
                      tooltip: _isListening
                          ? 'Ferma registrazione'
                          : 'Avvia riconoscimento vocale',
                    ),
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      decoration: InputDecoration(
                        hintText: 'Scrivi un messaggio...',
                        border: OutlineInputBorder(),
                      ),
                      onSubmitted: (_) => _sendMessage(),
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.send),
                    onPressed: () {
                      if (!isLoading) {
                        _sendMessage();
                      }
                    },
                    tooltip: 'Invia messaggio',
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 8.0),
              child: Text(
                "L'AI può generare risposte non accurate o inappropriate. Usa con cautela.",
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
  const AppSettingsPage({super.key});

  @override
  State<StatefulWidget> createState() => _AppSettingsPageState();
}

class _AppSettingsPageState extends State<AppSettingsPage> {
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _apiKeyController = TextEditingController();
  final TextEditingController _modelController = TextEditingController();
  String _sttLanguage = 'auto';
  bool _darkMode = false;

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

@override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Impostazioni'), centerTitle: true),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              children: [
                TextField(
                  controller: _urlController,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText:
                        'URL completo (es. api.openai.com/v1/chat/completions)',
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _apiKeyController,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: 'API Key',
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _modelController,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: 'Modello (es. poolside/laguna-xs.2)',
                  ),
                ),
                const SizedBox(height: 24),
                const Divider(),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
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
                Center(
                  child: Text(
                    "Per il riconoscimento vocale viene usato un modello Whisper locale.",
                    style: TextStyle(
                      fontSize: 10,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
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
            subtitle: const Text('Usa tema scuro per l\'interfaccia'),
            value: _darkMode,
            onChanged: (v) async {
              setState(() => _darkMode = v);
              themeModeNotifier.value =
                  v ? ThemeMode.dark : ThemeMode.light;
              final settings = AppSettings();
              settings.darkMode = v;
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
        body: JsonEncoder().convert(body),
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
