import 'dart:async';
import 'dart:core';
import 'dart:convert';
import 'dart:io';
import 'dart:developer';
import 'dart:typed_data' show Uint8List;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_sound/android_encoder.dart';
import 'package:flutter_sound/ios_quality.dart';
import 'dart:io' show Platform;

// this enum MUST be synchronized with fluttersound/AudioInterface.java  and ios/Classes/FlutterSoundPlugin.h
enum t_CODEC {
  DEFAULT,
  CODEC_AAC,
  CODEC_OPUS,
  CODEC_CAF_OPUS, // Apple encapsulates its bits in its own special envelope : .caf instead of a regular ogg/opus (.opus). This is completely stupid, this is Apple.
  CODEC_MP3,
  CODEC_VORBIS,
  CODEC_PCM,
}

enum t_AUDIO_STATE {
  IS_STOPPED,
  IS_PAUSED,
  IS_PLAYING,
  IS_RECORDING,
}

class FlutterSound {
  static const MethodChannel _channel = const MethodChannel('flutter_sound');
  static StreamController<RecordStatus> _recorderController;
  static StreamController<double> _dbPeakController;
  static StreamController<PlayStatus> _playerController;
  static StreamController<String> _onSpeechController;
  static StreamController<String> _onSpeechErrorController;

  /// Value ranges from 0 to 120
  Stream<double> get onRecorderDbPeakChanged => _dbPeakController.stream;
  Stream<RecordStatus> get onRecorderStateChanged => _recorderController.stream;
  Stream<PlayStatus> get onPlayerStateChanged => _playerController.stream;
  Stream<String> get onSpeech =>
      (_onSpeechController != null) ? _onSpeechController.stream : null;
  Stream<String> get onSpeechError => (_onSpeechErrorController != null)
      ? _onSpeechErrorController.stream
      : null;
  @Deprecated('Prefer to use audio_state variable')
  bool get isPlaying => _isPlaying();
  bool get isRecording => _isRecording();
  bool _speechPermissions = false;
  t_AUDIO_STATE get audioState => _audioState;

  bool _isRecording() => _audioState == t_AUDIO_STATE.IS_RECORDING;
  t_AUDIO_STATE _audioState = t_AUDIO_STATE.IS_STOPPED;
  bool _isPlaying() =>
      _audioState == t_AUDIO_STATE.IS_PLAYING ||
      _audioState == t_AUDIO_STATE.IS_PAUSED;

  FlutterSound() {
    _channel.setMethodCallHandler(methodCallHandler);
  }

  Future<bool> isEncoderSupported(t_CODEC codec) async {
    var result = await _channel.invokeMethod(
        'isEncoderSupported', <String, dynamic>{'codec': codec.index});
    return result is bool ? result : false;
  }

  Future<bool> isDecoderSupported(t_CODEC codec) async {
    var result = await _channel.invokeMethod(
        'isDecoderSupported', <String, dynamic>{'codec': codec.index});
    return result is bool ? result : false;
  }

  Future<String> setSubscriptionDuration(double sec) async {
    var result = await _channel
        .invokeMethod('setSubscriptionDuration', <String, dynamic>{
      'sec': sec,
    });
    if (result is FlutterError)
      return Future.value(result.toString());
    else
      return result;
  }

  Future<dynamic> methodCallHandler(MethodCall call) {
    switch (call.method) {
      case "onSpeech":
        String result = call.arguments;
        if (_onSpeechController != null) _onSpeechController.add(result);
        break;
      case "onError":
        String result = call.arguments;
        if (_onSpeechController != null) _onSpeechErrorController.add(result);
        break;

      case "updateRecorderProgress":
        Map<String, dynamic> result = json.decode(call.arguments);
        if (_recorderController != null)
          _recorderController.add(new RecordStatus.fromJSON(result));
        break;
      case "updateDbPeakProgress":
        if (_dbPeakController != null) _dbPeakController.add(call.arguments);
        break;

      case "updateProgress":
        Map<String, dynamic> result = jsonDecode(call.arguments);
        if (_playerController != null) {
          var status = new PlayStatus.fromJSON(result);
          _playerController.add(status);
        }
        break;
      case "audioPlayerDidFinishPlaying":
        Map<String, dynamic> result = jsonDecode(call.arguments);
        PlayStatus status = new PlayStatus.fromJSON(result);
        //Indicate clearly that we're past the end
        status.currentPosition = -1000;
        log(status.toString());
        if (_playerController != null) {
          _playerController.add(status);
        }
        _audioState = t_AUDIO_STATE.IS_STOPPED;
        // _removePlayerCallback();
        break;

      default:
        throw new ArgumentError('Unknown method ${call.method} ');
    }
    return null;
  }

  Future<void> _setSpeechCallback() async {
    if (_onSpeechController == null) {
      _onSpeechController = new StreamController.broadcast();
    }
    if (_onSpeechErrorController == null) {
      _onSpeechErrorController = new StreamController.broadcast();
    }
  }

  Future<void> _setRecorderCallback() async {
    if (_recorderController == null) {
      _recorderController = new StreamController.broadcast();
    }
    if (_dbPeakController == null) {
      _dbPeakController = new StreamController.broadcast();
    }
  }

  Future<void> _setPlayerCallback() async {
    if (_playerController == null) {
      _playerController = new StreamController.broadcast();
    }
  }

  Future<void> _removeSpeechCallback() async {
    if (_onSpeechController != null) {
      _onSpeechController
        ..add(null)
        ..close();
      _onSpeechController = null;
    }
  }

  Future<void> _removeRecorderCallback() async {
    if (_recorderController != null) {
      _recorderController
        ..add(null)
        ..close();
      _recorderController = null;
    }
  }

  Future<void> _removeDbPeakCallback() async {
    if (_dbPeakController != null) {
      _dbPeakController
        ..add(null)
        ..close();
      _dbPeakController = null;
    }
  }

  Future<void> _removePlayerCallback() async {
    if (_playerController != null) {
      _playerController
        ..add(null)
        ..close();
      _playerController = null;
    }
  }

  Future<String> startRecorder(
    String uri, {
    int sampleRate,
    int numChannels,
    int bitRate,
    t_CODEC codec = t_CODEC.DEFAULT,
    AndroidEncoder androidEncoder = AndroidEncoder.AAC,
    AndroidAudioSource androidAudioSource = AndroidAudioSource.MIC,
    AndroidOutputFormat androidOutputFormat = AndroidOutputFormat.DEFAULT,
    IosQuality iosQuality = IosQuality.LOW,
  }) async {
    if (_audioState != t_AUDIO_STATE.IS_STOPPED) {
      throw new RecorderRunningException('Recorder is not stopped.');
    }
    if (!await isEncoderSupported(codec))
      throw new RecorderRunningException('Codec not supported.');
    try {
      var result =
          await _channel.invokeMethod('startRecorder', <String, dynamic>{
        'path': uri,
        'sampleRate': sampleRate,
        'numChannels': numChannels,
        'bitRate': bitRate,
        'codec': codec.index,
        'androidEncoder': androidEncoder?.value,
        'androidAudioSource': androidAudioSource?.value,
        'androidOutputFormat': androidOutputFormat?.value,
        'iosQuality': iosQuality?.value
      });
      _setRecorderCallback();
      _audioState = t_AUDIO_STATE.IS_RECORDING;
      if (result is FlutterError)
        return Future.value(result.toString());
      else
        return result;
    } catch (err) {
      throw new Exception(err);
    }
  }

  Future<String> stopRecorder() async {
    if (_audioState != t_AUDIO_STATE.IS_RECORDING) {
      throw new RecorderStoppedException('Recorder is not recording.');
    }

    var result = await _channel.invokeMethod('stopRecorder');

    _audioState = t_AUDIO_STATE.IS_STOPPED;
    _removeRecorderCallback();
    _removeDbPeakCallback();

    if (result is FlutterError)
      return Future.value(result.toString());
    else
      return result;
  }

  Future<String> _startPlayer(String method, Map<String, dynamic> what) async {
    if (_audioState == t_AUDIO_STATE.IS_PAUSED) {
      this.resumePlayer();
      _audioState = t_AUDIO_STATE.IS_PLAYING;
      return 'Player resumed';
      // throw PlayerRunningException('Player is already playing.');
    }
    if (_audioState != t_AUDIO_STATE.IS_STOPPED) {
      throw PlayerRunningException('Player is not stopped.');
    }

    try {
      var result = await _channel.invokeMethod(method, what);

      if (result != null) {
        print('startPlayer result: $result');
        _setPlayerCallback();
        print('_setPlayerCallback complete');
        _audioState = t_AUDIO_STATE.IS_PLAYING;
      }

      if (result is FlutterError)
        return Future.value(result.toString());
      else
        return result;
    } catch (err) {
      throw Exception(err);
    }
  }

  Future<String> startPlayer(String uri) async {
    var result = _startPlayer('startPlayer', {'path': uri});
    if (result is FlutterError)
      return Future.value(result.toString());
    else
      return result;
  }

  Future<String> startPlayerFromBuffer(Uint8List dataBuffer) async {
    var result =
        _startPlayer('startPlayerFromBuffer', {'dataBuffer': dataBuffer});
    if (result is FlutterError)
      return Future.value(result.toString());
    else
      return result;
  }

  Future<String> stopPlayer() async {
    if (_audioState != t_AUDIO_STATE.IS_PAUSED &&
        _audioState != t_AUDIO_STATE.IS_PLAYING) {
      throw PlayerRunningException('Player is not playing.');
    }

    _audioState = t_AUDIO_STATE.IS_STOPPED;

    var result = await _channel.invokeMethod('stopPlayer');
    _removePlayerCallback();
    if (result is FlutterError)
      return Future.value(result.toString());
    else
      return result;
  }

  Future<String> pausePlayer() async {
    if (_audioState != t_AUDIO_STATE.IS_PLAYING) {
      throw PlayerRunningException('Player is not playing.');
    }

    try {
      var result = await _channel.invokeMethod('pausePlayer');
      if (result != null) _audioState = t_AUDIO_STATE.IS_PAUSED;
      if (result is FlutterError)
        return Future.value(result.toString());
      else
        return result;
    } catch (err) {
      print('err: $err');
      _audioState = t_AUDIO_STATE
          .IS_STOPPED; // In fact _audio_state is in an unknown state
      return Future.value(err.toString());
    }
  }

  Future<String> resumePlayer() async {
    if (_audioState != t_AUDIO_STATE.IS_PAUSED) {
      throw PlayerRunningException('Player is not paused.');
    }

    try {
      var result = await _channel.invokeMethod('resumePlayer');

      if (result is FlutterError)
        return Future.value(result.toString());
      else {
        _audioState = t_AUDIO_STATE.IS_PLAYING;
        return result;
      }
    } catch (err) {
      print('err: $err');
      return Future.value(err.toString());
    }
  }

  Future<String> seekToPlayer(int milliSecs) async {
    try {
      var result =
          await _channel.invokeMethod('seekToPlayer', <String, dynamic>{
        'sec': milliSecs,
      });
      if (result is FlutterError)
        return Future.value(result.toString());
      else
        return result;
    } catch (err) {
      print('err: $err');
      return Future.value(err.toString());
    }
  }

  Future<String> setVolume(double volume) async {
    double indexedVolume = Platform.isIOS ? volume * 100 : volume;
    var result;
    if (volume < 0.0 || volume > 1.0) {
      result = 'Value of volume should be between 0.0 and 1.0.';
      return result;
    }

    result = await _channel.invokeMethod('setVolume', <String, dynamic>{
      'volume': indexedVolume,
    });
    if (result is FlutterError)
      return Future.value(result.toString());
    else
      return result;
  }

  /// Defines the interval at which the peak level should be updated.
  /// Default is 0.8 seconds
  Future<String> setDbPeakLevelUpdate(double intervalInSecs) async {
    var result =
        await _channel.invokeMethod('setDbPeakLevelUpdate', <String, dynamic>{
      'intervalInSecs': intervalInSecs,
    });
    if (result is FlutterError)
      return Future.value(result.toString());
    else
      return result;
  }

  /// Enables or disables processing the Peak level in db's. Default is disabled
  Future<String> setDbLevelEnabled(bool enabled) async {
    var result =
        await _channel.invokeMethod('setDbLevelEnabled', <String, dynamic>{
      'enabled': enabled,
    });
    if (result is FlutterError)
      return Future.value(result.toString());
    else
      return result;
  }

  Future<List<String>> supportedSpeechLocales() {
    return _channel.invokeListMethod('supportedSpeechLocales');
  }

  Future<String> getDeviceLanguage() {
    return _channel.invokeMethod('getDeviceLanguage');
  }

  Future<String> getDeviceLanguageTag() {
    return _channel.invokeMethod('getDeviceLanguageTag');
  }

  Future<String> recordAndRecognizeSpeech(
      {bool toTmpFile = false,
      String langcode = 'en_US',
      bool mute = true}) async {
    if (!_speechPermissions) {
      //need to check permissions before we listen
      return _channel
          .invokeMethod('requestSpeechRecognitionPermission')
          .then((b) {
        _speechPermissions = b;
        if (b) {
          _setSpeechCallback();
          return _channel.invokeMethod(
              'recordAndRecognizeSpeech', <String, dynamic>{
            'toTmpFile': toTmpFile,
            'langcode': langcode,
            'mute': mute
          });
        } else
          return Future.value('error: permission for speech not granted');
      });
    } else {
      _setSpeechCallback();
      return _channel.invokeMethod(
          'recordAndRecognizeSpeech', <String, dynamic>{
        'toTmpFile': toTmpFile,
        'langcode': langcode,
        'mute': mute
      });
    }
  }

  Future<String> stopRecognizeSpeech({bool unmute = false}) async {
    _removeSpeechCallback();
    var result = await _channel.invokeMethod(
        'stopRecognizeSpeech', <String, dynamic>{'unmute': unmute});
    if (result is FlutterError)
      return Future.value(result.toString());
    else
      return result;
  }

  Future<String> getTempAudioFile() async {
    return _channel.invokeMethod('getTempAudioFile');
  }
}

class RecordStatus {
  final double currentPosition;

  RecordStatus.fromJSON(Map<String, dynamic> json)
      : currentPosition = double.parse(json['current_position']);

  @override
  String toString() {
    return 'currentPosition: $currentPosition';
  }
}

class PlayStatus {
  final double duration;
  double currentPosition;

  PlayStatus.fromJSON(Map<String, dynamic> json)
      : duration = double.parse(json['duration']),
        currentPosition = double.parse(json['current_position']);

  @override
  String toString() {
    return 'duration: $duration, '
        'currentPosition: $currentPosition';
  }
}

class PlayerRunningException implements Exception {
  final String message;
  PlayerRunningException(this.message);
}

class PlayerStoppedException implements Exception {
  final String message;
  PlayerStoppedException(this.message);
}

class RecorderRunningException implements Exception {
  final String message;
  RecorderRunningException(this.message);
}

class RecorderStoppedException implements Exception {
  final String message;
  RecorderStoppedException(this.message);
}
