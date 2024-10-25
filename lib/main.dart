import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:buffered_list_stream/buffered_list_stream.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';
import 'package:logging/logging.dart';
import 'package:record/record.dart';
import 'package:simple_frame_app/simple_frame_app.dart';
import 'package:simple_frame_app/tx/text_sprite_block.dart';
import 'package:vosk_flutter/vosk_flutter.dart';

void main() => runApp(const MainApp());

final _log = Logger("MainApp");

class MainApp extends StatefulWidget {
  const MainApp({super.key});

  @override
  MainAppState createState() => MainAppState();
}

/// SimpleFrameAppState mixin helps to manage the lifecycle of the Frame connection outside of this file
class MainAppState extends State<MainApp> with SimpleFrameAppState {

  MainAppState() {
    Logger.root.level = Level.INFO;
    Logger.root.onRecord.listen((record) {
      debugPrint('${record.level.name}: [${record.loggerName}] ${record.time}: ${record.message}');
    });
  }

  /// translate application members
  static const _modelName = 'vosk-model-small-cn-0.22.zip';
  final _vosk = VoskFlutterPlugin.instance();
  late final Model _model;
  late final Recognizer _recognizer;
  static const _sampleRate = 16000; // Vosk models on mobile are 16kHz, Frame can for now only stream 16-bit PCM at 8kHz

  String _text = "N/A";
  String _translatedText = "N/A";

  final _translator = OnDeviceTranslator(
    sourceLanguage: TranslateLanguage.chinese,
    targetLanguage: TranslateLanguage.russian);

  @override
  void initState() {
    super.initState();
    currentState = ApplicationState.initializing;
    // asynchronously kick off Vosk initialization
    _initVosk();
  }

  @override
  void dispose() async {
    _model.dispose();
    _recognizer.dispose();
    _translator.close();
    super.dispose();
  }

  void _initVosk() async {
    final modelPath = await ModelLoader().loadFromAssets('assets/$_modelName');
    _model = await _vosk.createModel(modelPath);
    _recognizer = await _vosk.createRecognizer(model: _model, sampleRate: _sampleRate);
    // TODO don't ask for 1 alternative, because instead of a "text" block in the json you get "alternatives"
    //await _recognizer.setMaxAlternatives(1);
    await _recognizer.setPartialWords(partialWords: false);

    currentState = ApplicationState.disconnected;
    if (mounted) setState(() {});
  }

  /// Sets up the Audio used for the application.
  /// Returns true if the audio is set up correctly, in which case
  /// it also returns a reference to the AudioRecorder and the
  /// audioSampleBufferedStream
  Future<(bool, AudioRecorder?, Stream<List<int>>?)> startAudio() async {
    // create a fresh AudioRecorder each time we run - it will be dispose()d when we click stop
    AudioRecorder audioRecorder = AudioRecorder();

    // Check and request permission if needed
    if (!await audioRecorder.hasPermission()) {
      return (false, null, null);
    }

    try {
      // start the audio stream
      final recordStream = await audioRecorder.startStream(
        const RecordConfig(encoder: AudioEncoder.pcm16bits,
          numChannels: 1,
          sampleRate: _sampleRate));

      // buffer the audio stream into chunks of 4096 samples
      final audioSampleBufferedStream = bufferedListStream(
        recordStream.map((event) {
          return event.toList();
        }),
        // samples are PCM16, so 2 bytes per sample
        4096 * 2,
      );

      return (true, audioRecorder, audioSampleBufferedStream);
    } catch (e) {
      _log.severe('Error starting Audio: $e');
      return (false, null, null);
    }
  }

  Future<void> stopAudio(AudioRecorder recorder) async {
    // stop the audio
    await recorder.stop();
    await recorder.dispose();
  }

  /// This application uses vosk speech-to-text to listen to audio from the host mic in a selected
  /// source language, convert to text, translate the text to the target language,
  /// and send the text to the Frame in real-time. It has a running main loop in this function
  /// and also on the Frame (frame_app.lua)
  @override
  Future<void> run() async {
    currentState = ApplicationState.running;
    _text = '';
    _translatedText = '';
    if (mounted) setState(() {});

    try {
      var (ok, audioRecorder, audioSampleBufferedStream) = await startAudio();
      if (!ok) {
        currentState = ApplicationState.ready;
        if (mounted) setState(() {});
        return;
      }

      String prevText = '';

      // loop over the incoming audio data and send reults to Frame
      await for (var audioSample in audioSampleBufferedStream!) {
        // if the user has clicked Stop we want to jump out of the main loop and stop processing
        if (currentState != ApplicationState.running) {
          break;
        }

        // recognizer blocks until it has something
        final resultReady = await _recognizer.acceptWaveformBytes(Uint8List.fromList(audioSample));

        // ignore partials, if any come through (even though we don't ask for them)
        if (!resultReady) {
          continue;
        }

        // Disabled alternatives and partial words for now - partials jump around a lot
        var json = await _recognizer.getResult();
        _text = jsonDecode(json)['text'];

        // If the text is the same as the previous one, we don't send it to Frame and force a redraw
        // The recognizer often produces a bunch of empty string in a row too, so this means
        // we send the first one (clears the display) but not subsequent ones
        // If we ask for partials, then often the final result matches the last partial,
        // so if it's a final result then show it on the phone but don't send it
        if (_text == prevText) {
          continue;
        }
        else if (_text.isEmpty) {
          // turn the empty string into a single space and send
          // still can't put it through the wrapped-text-chunked-sender
          // because it will be zero bytes payload so no message will
          // be sent.
          // Users might say this first empty partial
          // comes a bit soon and hence the display is cleared a little sooner
          // than they want (not like audio hangs around in the air though
          // after words are spoken!)
          // TODO for now don't clear the display, it will auto-clear after 10 seconds of no updates
          // TODO if I do decide to clear from here, switch to TxCode(msgCode: 0x10)
          //await frame!.sendMessage(TxPlainText(msgCode: 0x0b, text: ' '));
          prevText = '';
          continue;
        }
        else {
          _translatedText = (await _translator.translateText(_text)).trim();
          _log.fine(() => 'Translated text: "$_text" => "$_translatedText"');
        }

        // some utterances (e.g. just a 'de' in Chinese) might translate into nothing, an empty string
        // which we can't pass in to TextSpriteBlock, so skip these
        if (_translatedText.isEmpty) {
          continue;
        }

        // send the last N rows of the current text to Frame
        // TODO if we could be more sure of which rows would have changed since last time we could
        // send a diff with only the new lines, but for now every time there's new text we send the last N rows of it
        // which should give a scrolling effect for long text
        var tsb = TxTextSpriteBlock(
          msgCode: 0x20,
          width: 620,
          fontSize: 24,
          maxDisplayRows: 10,
          text: _translatedText);

        // TODO selectively rasterize lines and send them instead? ComputeMetrics gives us all the lines
        // but we can't necessarily know how many of the last N rows have changed (1? 2?) in the last update
        // so for now send them all
        // update: but by not sending partials, maybe there's no benefit in checking if we've rasterized/sent
        // these ones before, because they'll be from different utterances
        await tsb.rasterize(startLine: 0, endLine: tsb.numLines - 1);

        // send the header and the lines over to Frame for display
        await frame!.sendMessage(tsb);

        for (var sprite in tsb.rasterizedSprites) {
          await frame!.sendMessage(sprite);
        }

        // update the phone UI too
        if (mounted) setState(() {});
        prevText = _text;
      }

      await stopAudio(audioRecorder!);

    } catch (e) {
      _log.fine('Error executing application logic: $e');
    }

    currentState = ApplicationState.ready;
    if (mounted) setState(() {});
  }

  /// The run()) function will keep running until we interrupt it here
  /// and tell it to stop listening to audio
  @override
  Future<void> cancel() async {
    currentState = ApplicationState.ready;
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Translation',
      theme: ThemeData.dark(),
      home: Scaffold(
        appBar: AppBar(
          title: const Text("Translation"),
          actions: [getBatteryWidget()]
        ),
        body: Center(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(_text, style: const TextStyle(fontSize: 30)),
                const Divider(),
                Text(_translatedText, style: const TextStyle(fontSize: 30, fontStyle: FontStyle.italic)),
              ],
            ),
          ),
        ),
        floatingActionButton: getFloatingActionButtonWidget(const Icon(Icons.mic), const Icon(Icons.mic_off)),
        persistentFooterButtons: getFooterButtonsWidget(),
      ),
    );
  }
}
