package com.dooboolab.fluttersound;

import android.Manifest;
import android.app.AlertDialog;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.DialogInterface;
import android.content.pm.PackageManager;
import android.media.AudioManager;
import android.media.MediaPlayer;
import android.media.MediaRecorder;
import android.speech.RecognitionListener;
import android.speech.RecognizerIntent;
import android.speech.SpeechRecognizer;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.SystemClock;
import android.net.Uri;
import android.util.Log;
import android.app.Activity;
import android.app.NotificationManager;
import android.content.Intent;

import androidx.annotation.NonNull;
import androidx.annotation.RequiresApi;
import androidx.core.app.ActivityCompat;
import java.io.*;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.util.PathUtils;
import org.json.JSONException;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Timer;
import java.util.TimerTask;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.MethodChannel.MethodCallHandler;
import io.flutter.plugin.common.MethodChannel.Result;
import io.flutter.plugin.common.PluginRegistry;
import io.flutter.plugin.common.PluginRegistry.Registrar;

// SDK compatibility
// -----------------

class sdkCompat {
  static final int AUDIO_ENCODER_VORBIS = 6;  // MediaRecorder.AudioEncoder.VORBIS added in API level 21
  static final int AUDIO_ENCODER_OPUS   = 7;  // MediaRecorder.AudioEncoder.OPUS   added in API level 29
  static final int OUTPUT_FORMAT_OGG    = 11; // MediaRecorder.OutputFormat.OGG    added in API level 29
  static final int VERSION_CODES_M      = 23; // added in API level 23

  //New flutter plugin implementation
  static int checkRecordPermission(Activity activity, Context context) {
    if (Build.VERSION.SDK_INT >= sdkCompat.VERSION_CODES_M) {// Before Marshmallow, record permission was always granted.
      if (context.checkCallingOrSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
        ActivityCompat.requestPermissions(activity, new String[]{Manifest.permission.RECORD_AUDIO,}, 0);
        if (context.checkCallingOrSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED)
          return PackageManager.PERMISSION_DENIED;
      }
    }
    return PackageManager.PERMISSION_GRANTED;
  }
}
// *****************

/** FlutterSoundPlugin */
public class FlutterSoundPlugin implements FlutterPlugin, ActivityAware {
  private  static Registrar _reg;
  private static Context _context;
  private static Activity _activity;
  private static FlutterSoundMethodHandler _plugin;
  private static boolean _initCalled = false;


    /** Plugin registration. */
  public static void registerWith(Registrar registrar) {
    if (_plugin == null) {
      MethodChannel channel = new MethodChannel(registrar.messenger(), "flutter_sound");
      _plugin = new FlutterSoundMethodHandler(registrar.activeContext(), channel);
      _plugin.init();
      channel.setMethodCallHandler(_plugin);
      _reg = registrar;
    }
  }

  @Override
  public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
    if (_plugin == null) {
      MethodChannel channel = new MethodChannel(binding.getBinaryMessenger(), "flutter_sound");
      _plugin = new FlutterSoundMethodHandler(binding.getApplicationContext(), channel);
      _plugin.init();
      _context = binding.getApplicationContext();
      channel.setMethodCallHandler(_plugin);
    }
  }

  @Override
  public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
    _plugin.terminate();
  }

  @Override
  public void onAttachedToActivity(@NonNull ActivityPluginBinding binding) {
    _activity = binding.getActivity();
  }

  @Override
  public void onDetachedFromActivityForConfigChanges() {

  }

  @Override
  public void onReattachedToActivityForConfigChanges(@NonNull ActivityPluginBinding binding) {

  }

  @Override
  public void onDetachedFromActivity() {

  }

  private static void checkDoNotDisturb() {
    //https://stackoverflow.com/questions/39151453/in-android-7-api-level-24-my-app-is-not-allowed-to-mute-phone-set-ringer-mode
    NotificationManager notificationManager = (NotificationManager) _context.getSystemService(Context.NOTIFICATION_SERVICE);
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && !notificationManager.isNotificationPolicyAccessGranted()) {
      getDoNotDisturbPermission();
    }
  }

  private static void getDoNotDisturbPermission() {
    //Tell the user why we're bringing up the do not disturb activity
    AlertDialog.Builder builder1 = new AlertDialog.Builder(_activity);
    builder1.setMessage("In order for speech recognition to work well, we need permission to set Do Not Disturb. Proceed?");
    builder1.setCancelable(true);

    builder1.setPositiveButton(
            "Yes",
            new DialogInterface.OnClickListener() {
              public void onClick(DialogInterface dialog, int id) {
                dialog.cancel();
                Intent intent = new Intent(android.provider.Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS);
                _activity.startActivity(intent);
              }
            });

    builder1.setNegativeButton(
            "No",
            new DialogInterface.OnClickListener() {
              public void onClick(DialogInterface dialog, int id) {
                dialog.cancel();
              }
            });

    AlertDialog alert11 = builder1.create();
    alert11.show();
  }

  private static class FlutterSoundMethodHandler implements MethodCallHandler, PluginRegistry.RequestPermissionsResultListener, AudioInterface, RecognitionListener {
    final static String TAG = "FlutterSoundPlugin";
    final static String RECORD_STREAM = "com.dooboolab.fluttersound/record";
    final static String PLAY_STREAM= "com.dooboolab.fluttersound/play";

    private static final String LOG_TAG = "FlutterSoundPlugin";

    private static final String ERR_UNKNOWN = "ERR_UNKNOWN";
    private static final String ERR_PLAYER_IS_NULL = "ERR_PLAYER_IS_NULL";
    private static final String ERR_PLAYER_IS_PLAYING = "ERR_PLAYER_IS_PLAYING";
    private static final String ERR_RECORDER_IS_NULL = "ERR_RECORDER_IS_NULL";
    private static final String ERR_RECORDER_IS_RECORDING = "ERR_RECORDER_IS_RECORDING";

    private final ExecutorService taskScheduler = Executors.newSingleThreadExecutor();

    final private AudioModel model = new AudioModel();
    private Timer mTimer = new Timer();
    final private Handler recordHandler = new Handler();
    private Intent recognizerIntent;
    private SpeechRecognizer speech;
    private List<String> _supportedLanguages;
    private boolean saveUserAudio = false;
    private Uri audioUri;
    private MethodChannel flutterSoundChannel;
    private HashMap<Integer, Integer> cachedVolumes = new HashMap<Integer, Integer>();
    String transcription = "";
    private Context context;

    //mainThread handler
    final private Handler mainHandler = new Handler();
    final private Handler dbPeakLevelHandler = new Handler();

    final static int CODEC_OPUS = 2;
    final static int CODEC_VORBIS = 5;

    static boolean _isAndroidEncoderSupported [] = {
            true, // DEFAULT
            true, // AAC
            false, // OGG/OPUS
            false, // CAF/OPUS
            false, // MP3
            false, // OGG/VORBIS
            false, // WAV/PCM
    };

    static boolean _isAndroidDecoderSupported [] = {
            true, // DEFAULT
            true, // AAC
            true, // OGG/OPUS
            false, // CAF/OPUS
            true, // MP3
            true, // OGG/VORBIS
            true, // WAV/PCM
    };

    static int codecArray[] = {
            0 // DEFAULT
            , MediaRecorder.AudioEncoder.AAC
            , sdkCompat.AUDIO_ENCODER_OPUS
            , 0 // CODEC_CAF_OPUS (specific Apple)
            , 0 // CODEC_MP3 (not implemented)
            , sdkCompat.AUDIO_ENCODER_VORBIS
            , 0 // CODEC_PCM (not implemented)
    };

    static int formatsArray[] = {
            MediaRecorder.OutputFormat.MPEG_4 // DEFAULT
            , MediaRecorder.OutputFormat.MPEG_4 // CODEC_AAC
            , sdkCompat.OUTPUT_FORMAT_OGG       // CODEC_OPUS
            , 0                                 // CODEC_CAF_OPUS (this is apple specific)
            , 0                                 // CODEC_MP3
            , sdkCompat.OUTPUT_FORMAT_OGG       // CODEC_VORBIS
            , 0                                 // CODEC_PCM
    };

    static String pathArray[] = {
            "sound.acc"   // DEFAULT
            , "sound.acc"   // CODEC_AAC
            , "sound.opus"  // CODEC_OPUS
            , "sound.caf"   // CODEC_CAF_OPUS (this is apple specific)
            , "sound.mp3"   // CODEC_MP3
            , "sound.ogg"   // CODEC_VORBIS
            , "sound.wav"   // CODEC_PCM
    };

    String extentionArray[] = {
            "acc"   // DEFAULT
            , "acc"   // CODEC_AAC
            , "opus"  // CODEC_OPUS
            , "caf"   // CODEC_CAF_OPUS (this is apple specific)
            , "mp3"   // CODEC_MP3
            , "ogg"   // CODEC_VORBIS
            , "wav"   // CODEC_PCM
    };

    int streamVolumes[] = {
//          AudioManager.STREAM_ALARM
//          , AudioManager.STREAM_MUSIC
            AudioManager.STREAM_NOTIFICATION
//          , AudioManager.STREAM_SYSTEM
//          , AudioManager.STREAM_RING
    };

    FlutterSoundMethodHandler(Context context, MethodChannel channel) {
      this.context = context;
      this.flutterSoundChannel = channel;
    }

    public void init() {
      AudioManager audio = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
      for (Integer stream : streamVolumes) {
        cachedVolumes.put(stream, audio.getStreamVolume(stream));
        Log.d(TAG, String.format("cached %d volume to %d", stream, cachedVolumes.get(stream)));
      }

      //https://stackoverflow.com/questions/10538791/how-to-set-the-language-in-speech-recognition-on-android/10548680#10548680
      Intent detailsIntent = new Intent(RecognizerIntent.ACTION_GET_LANGUAGE_DETAILS);
      context.sendOrderedBroadcast(detailsIntent, null, new BroadcastReceiver() {
        @Override
        public void onReceive(Context context, Intent intent) {
          Bundle results = getResultExtras(true);
          if (results.containsKey(RecognizerIntent.EXTRA_SUPPORTED_LANGUAGES)) {
            _supportedLanguages = results.getStringArrayList(RecognizerIntent.EXTRA_SUPPORTED_LANGUAGES);
          }
        }
      }, null, Activity.RESULT_OK, null, null);
    }

    public void terminate() {
      if (context == null || cachedVolumes.size() == 0)
        return;

      //restore the audio settings when this goes away
      AudioManager audio = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
      if (audio == null) return;
      for (Integer stream : cachedVolumes.keySet()) {
        Log.d(TAG, String.format("setting %d to %d", stream, cachedVolumes.get(stream)));
        audio.setStreamVolume(stream, cachedVolumes.get(stream), AudioManager.FLAG_SHOW_UI);
      }
    }

    boolean checkedPermissions = false;

    @Override
    public void onMethodCall(final MethodCall call, final Result result) {
      if (!checkedPermissions) {
        FlutterSoundPlugin.checkDoNotDisturb();
        checkedPermissions = true;
      }

      final String path = call.argument("path");
      switch (call.method) {
        case "isDecoderSupported": {
          int _codec = call.argument("codec");
          boolean b = _isAndroidDecoderSupported[_codec];
          if (Build.VERSION.SDK_INT < 23) {
            if ((_codec == CODEC_OPUS) || (_codec == CODEC_VORBIS))
              b = false;
          }

          result.success(b);
        }
        break;
        case "isEncoderSupported": {
          int _codec = call.argument("codec");
          boolean b = _isAndroidEncoderSupported[_codec];
          if (Build.VERSION.SDK_INT < 29) {
            if ((_codec == CODEC_OPUS) || (_codec == CODEC_VORBIS))
              b = false;
          }
          result.success(b);
        }
        break;
        case "startRecorder":
          taskScheduler.submit(() -> {
            Integer sampleRate = call.argument("sampleRate");
            Integer numChannels = call.argument("numChannels");
            Integer bitRate = call.argument("bitRate");
            int androidEncoder = call.argument("androidEncoder");
            int _codec = call.argument("codec");
            t_CODEC codec = t_CODEC.values()[_codec];
            int androidAudioSource = call.argument("androidAudioSource");
            int androidOutputFormat = call.argument("androidOutputFormat");
            startRecorder(numChannels, sampleRate, bitRate, codec, androidEncoder, androidAudioSource, androidOutputFormat, path, result);
          });
          break;
        case "stopRecorder":
          taskScheduler.submit(() -> stopRecorder(result));
          break;
        case "startPlayer":
          this.startPlayer(path, result);
          break;

        case "startPlayerFromBuffer":
          Integer _codec = call.argument("codec");
          t_CODEC codec = t_CODEC.values()[(_codec != null) ? _codec : 0];
          byte[] dataBuffer = call.argument("dataBuffer");
          this.startPlayerFromBuffer(dataBuffer, codec, result);
          break;

        case "stopPlayer":
          this.stopPlayer(result);
          break;
        case "pausePlayer":
          this.pausePlayer(result);
          break;
        case "resumePlayer":
          this.resumePlayer(result);
          break;
        case "seekToPlayer":
          int sec = call.argument("sec");
          this.seekToPlayer(sec, result);
          break;
        case "setVolume":
          double volume = call.argument("volume");
          this.setVolume(volume, result);
          break;
        case "setDbPeakLevelUpdate":
          double intervalInSecs = call.argument("intervalInSecs");
          this.setDbPeakLevelUpdate(intervalInSecs, result);
          break;
        case "setDbLevelEnabled":
          boolean enabled = call.argument("enabled");
          this.setDbLevelEnabled(enabled, result);
          break;
        case "setSubscriptionDuration":
          if (call.argument("sec") == null) return;
          double duration = call.argument("sec");
          this.setSubscriptionDuration(duration, result);
          break;
        case "supportedSpeechLocales":
          this.supportedSpeechLocales(result);
          break;
        case "getDeviceLanguage":
          this.getDeviceLanguage(result);
          break;
        case "getDeviceLanguageTag":
          this.getDeviceLanguageTag(result);
          break;
        case "requestSpeechRecognitionPermission":
          this.requestSpeechRecognitionPermission(result);
          break;
        case "recordAndRecognizeSpeech":
          boolean save = (call.argument("toTmpFile") != null) ? call.argument("toTmpFile") : false;
          String langcode = (call.argument("langcode") != null) ? call.argument("langcode") : null;
          boolean mute = (call.argument("mute") != null) ? call.argument("mute") : false;
          this.recordAndRecognizeSpeech(save, langcode, mute, result);
          break;
        case "stopRecognizeSpeech":
          boolean unmute = (call.argument("unmute") != null) ? call.argument("unmute") : false;
          this.stopRecognizeSpeech(unmute, result);
          break;
        case "getTempAudioFile":
          this.getTempAudioFile(result);
          break;
        default:
          result.notImplemented();
          break;
      }
    }

    @Override
    public boolean onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
      final int REQUEST_RECORD_AUDIO_PERMISSION = 200;
      switch (requestCode) {
        case REQUEST_RECORD_AUDIO_PERMISSION:
          if (grantResults[0] == PackageManager.PERMISSION_GRANTED)
            return true;
          break;
      }
      return false;
    }

    @Override
    public void startRecorder(Integer numChannels, Integer sampleRate, Integer bitRate, t_CODEC codec, int androidEncoder, int androidAudioSource, int androidOutputFormat, String path, final Result result) {
      final int v = Build.VERSION.SDK_INT;

      int perm = (_reg != null) ? sdkCompat.checkRecordPermission(_reg.activity(), _reg.activity().getApplicationContext()) : sdkCompat.checkRecordPermission(_activity, _context);
      if (perm != PackageManager.PERMISSION_GRANTED) {
        result.error(TAG, "NO PERMISSION GRANTED", Manifest.permission.RECORD_AUDIO + " or " + Manifest.permission.WRITE_EXTERNAL_STORAGE);
        return;
      }

      String datadir = (_reg != null) ? PathUtils.getDataDirectory(_reg.activity().getApplicationContext()) : PathUtils.getDataDirectory(_context);
      path = datadir + "/" + path; // SDK 29 : you may not write in getExternalStorageDirectory() [LARPOUX]
      MediaRecorder mediaRecorder = model.getMediaRecorder();

      if (mediaRecorder == null) {
        model.setMediaRecorder(new MediaRecorder());
        mediaRecorder = model.getMediaRecorder();
      } else {
        mediaRecorder.reset();
      }
      mediaRecorder.setAudioSource(androidAudioSource);
      if (codecArray[codec.ordinal()] == 0) {
        result.error(TAG, "UNSUPPORTED", "Unsupported encoder");
        return;
      }
      androidEncoder = codecArray[codec.ordinal()];
      androidOutputFormat = formatsArray[codec.ordinal()];
      mediaRecorder.setOutputFormat(androidOutputFormat);

      if (path == null)
        path = pathArray[codec.ordinal()];

      mediaRecorder.setOutputFile(path);
      mediaRecorder.setAudioEncoder(androidEncoder);

      if (numChannels != null) {
        mediaRecorder.setAudioChannels(numChannels);
      }

      if (sampleRate != null) {
        mediaRecorder.setAudioSamplingRate(sampleRate);
      }

      // If bitrate is defined, then use it, otherwise use the OS default
      if (bitRate != null) {
        mediaRecorder.setAudioEncodingBitRate(bitRate);
      }


      try {
        mediaRecorder.prepare();
        mediaRecorder.start();

        // Remove all pending runnables, this is just for safety (should never happen)
        recordHandler.removeCallbacksAndMessages(null);
        final long systemTime = SystemClock.elapsedRealtime();
        this.model.setRecorderTicker(() -> {

          long time = SystemClock.elapsedRealtime() - systemTime;
//          Log.d(TAG, "elapsedTime: " + SystemClock.elapsedRealtime());
//          Log.d(TAG, "time: " + time);

//          DateFormat format = new SimpleDateFormat("mm:ss:SS", Locale.US);
//          String displayTime = format.format(time);
//          model.setRecordTime(time);
          try {
            JSONObject json = new JSONObject();
            json.put("current_position", String.valueOf(time));
            flutterSoundChannel.invokeMethod("updateRecorderProgress", json.toString());
            recordHandler.postDelayed(model.getRecorderTicker(), model.subsDurationMillis);
          } catch (JSONException je) {
            Log.d(TAG, "Json Exception: " + je.toString());
          }
        });
        recordHandler.post(this.model.getRecorderTicker());

        if (this.model.shouldProcessDbLevel) {
          dbPeakLevelHandler.removeCallbacksAndMessages(null);
          this.model.setDbLevelTicker(() -> {

            MediaRecorder recorder = model.getMediaRecorder();
            if (recorder != null) {
              double maxAmplitude = recorder.getMaxAmplitude();

              // Calculate db based on the following article.
              // https://stackoverflow.com/questions/10655703/what-does-androids-getmaxamplitude-function-for-the-mediarecorder-actually-gi
              //
              double ref_pressure = 51805.5336;
              double p = maxAmplitude / ref_pressure;
              double p0 = 0.0002;

              double db = 20.0 * Math.log10(p / p0);

              // if the microphone is off we get 0 for the amplitude which causes
              // db to be infinite.
              if (Double.isInfinite(db))
                db = 0.0;

              Log.d(TAG, "rawAmplitude: " + maxAmplitude + " Base DB: " + db);

              flutterSoundChannel.invokeMethod("updateDbPeakProgress", db);
              dbPeakLevelHandler.postDelayed(model.getDbLevelTicker(),
                      (FlutterSoundMethodHandler.this.model.peakLevelUpdateMillis));
            }
          });
          dbPeakLevelHandler.post(this.model.getDbLevelTicker());
        }


        String finalPath = path;
        mainHandler.post(new Runnable() {
          @Override
          public void run() {
            result.success(finalPath);
          }
        });
      } catch (Exception e) {
        Log.e(TAG, "Exception: ", e);
      }
    }

    @Override
    public void stopRecorder(final Result result) {
      // This remove all pending runnables
      recordHandler.removeCallbacksAndMessages(null);
      dbPeakLevelHandler.removeCallbacksAndMessages(null);

      if (this.model.getMediaRecorder() == null) {
        Log.d(TAG, "stopRecorder failed: mediaRecorder is null");
        result.error(ERR_RECORDER_IS_NULL, ERR_RECORDER_IS_NULL, ERR_RECORDER_IS_NULL);
        return;
      }
      this.model.getMediaRecorder().stop();
      this.model.getMediaRecorder().reset();
      this.model.getMediaRecorder().release();
      this.model.setMediaRecorder(null);
      mainHandler.post(new Runnable() {
        @Override
        public void run() {
          result.success("recorder stopped.");
        }
      });

    }

    public void startPlayer(final String path, final Result result) {
      if (this.model.getMediaPlayer() != null) {
        Boolean isPaused = !this.model.getMediaPlayer().isPlaying()
                && this.model.getMediaPlayer().getCurrentPosition() > 1;

        if (isPaused) {
          this.model.getMediaPlayer().start();
          result.success("player resumed.");
        } else {
          Log.e(TAG, "Player is already running. Stop it first.");
          result.success("player is already running.");
        }
        return;
      }

      this.model.setMediaPlayer(new MediaPlayer());
      mTimer = new Timer();

      try {
        if (path == null) {
          this.model.getMediaPlayer().setDataSource(AudioModel.DEFAULT_FILE_LOCATION);
        } else {
          this.model.getMediaPlayer().setDataSource(path);
        }

        this.model.getMediaPlayer().setOnPreparedListener(mp -> {
          Log.d(TAG, "mediaPlayer prepared and start");
          mp.start();

          /*
           * Set timer task to send event to RN.
           */
          TimerTask mTask = new TimerTask() {
            @Override
            public void run() {
              // long time = mp.getCurrentPosition();
              // DateFormat format = new SimpleDateFormat("mm:ss:SS", Locale.US);
              // final String displayTime = format.format(time);
              try {
                //safe-guard this in case the media player becomes null before this is called.
                MediaPlayer _mp = FlutterSoundMethodHandler.this.model.getMediaPlayer();
                if (_mp == null) return;

                JSONObject json = new JSONObject();
                json.put("duration", String.valueOf(mp.getDuration()));
                json.put("current_position", String.valueOf(mp.getCurrentPosition()));
                mainHandler.post(new Runnable() {
                  @Override
                  public void run() {
                    //safe-guard this in case the media player becomes null before this is called.
                    if (FlutterSoundMethodHandler.this.model.getMediaPlayer() != null)
                      flutterSoundChannel.invokeMethod("updateProgress", json.toString());
                    else
                      Log.d(TAG, "Media player is null, so we're not calling updateProgress");
                  }
                });
              } catch (JSONException je) {
                Log.d(TAG, "Json Exception: " + je.toString());
              }
            }
          };

          mTimer.schedule(mTask, 0, model.subsDurationMillis);
          String resolvedPath = (path == null) ? AudioModel.DEFAULT_FILE_LOCATION : path;
          result.success((resolvedPath));
        });
        /*
         * Detect when finish playing.
         */
        this.model.getMediaPlayer().setOnCompletionListener(mp -> {
          /*
           * Reset player.
           */
          Log.d(TAG, "Plays completed.");

          try {
            JSONObject json = new JSONObject();
            json.put("duration", String.valueOf(mp.getDuration()));
            json.put("current_position", String.valueOf(mp.getCurrentPosition()));
            flutterSoundChannel.invokeMethod("audioPlayerDidFinishPlaying", json.toString());
          } catch (JSONException je) {
            Log.d(TAG, "Json Exception: " + je.toString());
          }

          mTimer.cancel();
          if (mp.isPlaying()) {
            mp.stop();
          }
          mp.reset();
          mp.release();
          model.setMediaPlayer(null);
        });
        this.model.getMediaPlayer().prepare();
      } catch (Exception e) {
        Log.e(TAG, "startPlayer() exception: " + e.getLocalizedMessage());
        result.error(ERR_UNKNOWN, ERR_UNKNOWN, e.getMessage());
      }
    }

    public void startPlayerFromBuffer(final byte[] dataBuffer, t_CODEC codec, final Result result) {
      try {
        File f = File.createTempFile("flutter_sound", extentionArray[codec.ordinal()]);
        FileOutputStream fos = new FileOutputStream(f);
        fos.write(dataBuffer);
        startPlayer(f.getAbsolutePath(), result);
      } catch (Exception e) {
        Log.e(TAG, "startPlayerFromBuffer() exception: " + e.getLocalizedMessage());
        result.error(ERR_UNKNOWN, ERR_UNKNOWN, e.getMessage());
      }
    }


    @Override
    public void stopPlayer(final Result result) {
      mTimer.cancel();

      if (this.model.getMediaPlayer() == null) {
        Log.e(TAG, "stopPlayer() failed, mediaPlayer is NULL");
        result.error(ERR_PLAYER_IS_NULL, ERR_PLAYER_IS_NULL, ERR_PLAYER_IS_NULL);
        return;
      }

      try {
        this.model.getMediaPlayer().stop();
        this.model.getMediaPlayer().reset();
        this.model.getMediaPlayer().release();
        this.model.setMediaPlayer(null);
        result.success("stopped player.");
      } catch (Exception e) {
        Log.e(TAG, "stopPlay exception: " + e.getMessage());
        result.error(ERR_UNKNOWN, ERR_UNKNOWN, e.getMessage());
      }
    }

    @Override
    public void pausePlayer(final Result result) {
      if (this.model.getMediaPlayer() == null) {
        Log.e(TAG, "pausePlayer failed: mediaPlayer is NULL");
        result.error(ERR_PLAYER_IS_NULL, ERR_PLAYER_IS_NULL, ERR_PLAYER_IS_NULL);
        return;
      }

      try {
        this.model.getMediaPlayer().pause();
        result.success("paused player.");
      } catch (Exception e) {
        Log.e(TAG, "pausePlay exception: " + e.getMessage());
        result.error(ERR_UNKNOWN, ERR_UNKNOWN, e.getMessage());
      }
    }

    @Override
    public void resumePlayer(final Result result) {
      if (this.model.getMediaPlayer() == null) {
        Log.e(TAG, "resumePlayer failed: mediaPlayer is null");
        result.error(ERR_PLAYER_IS_NULL, ERR_PLAYER_IS_NULL, ERR_PLAYER_IS_NULL);
        return;
      }

      if (this.model.getMediaPlayer().isPlaying()) {
        Log.e(TAG, "resumePlayer failed: player already playing");
        result.error(ERR_PLAYER_IS_PLAYING, ERR_PLAYER_IS_PLAYING, ERR_PLAYER_IS_PLAYING);
        return;
      }

      try {
        this.model.getMediaPlayer().seekTo(this.model.getMediaPlayer().getCurrentPosition());
        this.model.getMediaPlayer().start();
        result.success("resumed player.");
      } catch (Exception e) {
        Log.e(TAG, "mediaPlayer resume: " + e.getMessage());
        result.error(ERR_UNKNOWN, ERR_UNKNOWN, e.getMessage());
      }
    }

    @Override
    public void seekToPlayer(int millis, final Result result) {
      if (this.model.getMediaPlayer() == null) {
        Log.e(TAG, "seekToPlayer failed: mediaPlayer is NULL");
        result.error(ERR_PLAYER_IS_NULL, ERR_PLAYER_IS_NULL, ERR_PLAYER_IS_NULL);
        return;
      }

      int currentMillis = this.model.getMediaPlayer().getCurrentPosition();
      Log.d(TAG, "currentMillis: " + currentMillis);
      // millis += currentMillis; [This was the problem for me]

      Log.d(TAG, "seekTo: " + millis);

      this.model.getMediaPlayer().seekTo(millis);
      result.success(String.valueOf(millis));
    }

    @Override
    public void setVolume(double volume, final Result result) {
      if (this.model.getMediaPlayer() == null) {
        Log.e(TAG, "setVolume failed: mediaPlayer is NULL");
        result.error(ERR_PLAYER_IS_NULL, ERR_PLAYER_IS_NULL, ERR_PLAYER_IS_NULL);
        return;
      }

      float mVolume = (float) volume;
      this.model.getMediaPlayer().setVolume(mVolume, mVolume);
      result.success("Set volume");
    }

    @Override
    public void setDbPeakLevelUpdate(double intervalInSecs, Result result) {
      this.model.peakLevelUpdateMillis = (long) (intervalInSecs * 1000);
      result.success("setDbPeakLevelUpdate: " + this.model.peakLevelUpdateMillis);
    }

    @Override
    public void setDbLevelEnabled(boolean enabled, MethodChannel.Result result) {
      this.model.shouldProcessDbLevel = enabled;
      result.success("setDbLevelEnabled: " + this.model.shouldProcessDbLevel);
    }

    @Override
    public void setSubscriptionDuration(double sec, Result result) {
      this.model.subsDurationMillis = (int) (sec * 1000);
      result.success("setSubscriptionDuration: " + this.model.subsDurationMillis);
    }

    @Override
    public void getTempAudioFile(MethodChannel.Result result) {
      result.success(audioUri == null ? null : audioUri.getPath());
    }

    @Override
    public void supportedSpeechLocales(MethodChannel.Result result) {
      result.success(_supportedLanguages);
    }

    @Override
    public void getDeviceLanguage(MethodChannel.Result result) {
      result.success(Locale.getDefault().getDisplayLanguage());
    }

    @Override
    public void getDeviceLanguageTag(MethodChannel.Result result) {
      if (Build.VERSION.SDK_INT < 21) {
        result.success("");
      } else {
        result.success(Locale.getDefault().toLanguageTag());
      }
    }

    @Override
    public void requestSpeechRecognitionPermission(MethodChannel.Result result) {
      result.success(true);
      Locale locale = context.getResources().getConfiguration().locale;
      Log.d(LOG_TAG, "Current Locale : " + locale.toString());
    }

    @Override
    public void recordAndRecognizeSpeech(boolean saveAudio, String langcode, boolean mute, MethodChannel.Result result) {
      saveUserAudio = saveAudio;
      audioUri = null;
      if (speech != null)
        stopRecognizeSpeech(false);

      Log.d(LOG_TAG, String.format("IsRecogAvailable: %b", SpeechRecognizer.isRecognitionAvailable(this.context)));
      speech = SpeechRecognizer.createSpeechRecognizer(this.context);
      speech.setRecognitionListener(this);
      transcription = "";

      recognizerIntent = new Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH);
      recognizerIntent.putExtra(RecognizerIntent.EXTRA_LANGUAGE, langcode != null ? langcode : "en-US");
      recognizerIntent.putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM);
      recognizerIntent.putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true);
      recognizerIntent.putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 3);
      if (saveUserAudio) {
        recognizerIntent.putExtra("android.speech.extra.GET_AUDIO_FORMAT", "audio/AMR");
        recognizerIntent.putExtra("android.speech.extra.GET_AUDIO", true);
      }
      speech.startListening(recognizerIntent);

      muteAudio(true);

      result.success("recordAndRecognizeSpeech successful");
    }

    @Override
    public void stopRecognizeSpeech(boolean unmute, MethodChannel.Result result) {
      stopRecognizeSpeech(unmute);
      result.success(transcription);
      transcription = "";
      if (saveUserAudio) {
        audioUri = recognizerIntent.getData();
      }
    }

    private void stopRecognizeSpeech(boolean unmute) {
      if (speech != null) {
        speech.stopListening();
        speech.destroy();
        speech = null;
      }
      if (unmute) muteAudio(false);
    }

    private void muteAudio(boolean shouldMute) {
      AudioManager audio = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
      if (shouldMute) {
        //If we don't have Do Not Disturb permission, we can't totally mute audio
        int muteVolume = 0;
        NotificationManager notificationManager = (NotificationManager) context.getSystemService(Context.NOTIFICATION_SERVICE);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && !notificationManager.isNotificationPolicyAccessGranted())
          muteVolume = 1;

        for (Integer stream : cachedVolumes.keySet()) {
          int tmpVolume = audio.getStreamVolume(stream);
          if (tmpVolume != muteVolume)
            cachedVolumes.put(stream, tmpVolume);
          if ((Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && !audio.isStreamMute(stream)) || tmpVolume > muteVolume) {
            Log.d(LOG_TAG, String.format("Muting %d from %d", stream, audio.getStreamVolume(stream)));
            audio.setStreamVolume(stream, muteVolume, 0);
          }
        }
      } else {
        for (Integer stream : cachedVolumes.keySet()) {
          Log.d(LOG_TAG, String.format("Unmuting %d from %d to %d", stream, audio.getStreamVolume(stream), cachedVolumes.get(stream)));
          audio.setStreamVolume(stream, AudioManager.ADJUST_UNMUTE, 0);
          audio.setStreamVolume(stream, cachedVolumes.get(stream), 0);
        }
      }
    }

    @Override
    public void onReadyForSpeech(Bundle params) {
      Log.d(LOG_TAG, "onReadyForSpeech");
      flutterSoundChannel.invokeMethod("onSpeechAvailability", true);
    }

    @Override
    public void onBeginningOfSpeech() {
      Log.d(LOG_TAG, "onRecognitionStarted");
      transcription = "";

      flutterSoundChannel.invokeMethod("onRecognitionStarted", null);
    }

    @Override
    public void onRmsChanged(float rmsdB) {
      //Log.d(LOG_TAG, "onRmsChanged : " + rmsdB);
    }

    @Override
    public void onBufferReceived(byte[] buffer) {
      Log.d(LOG_TAG, "onBufferReceived");
    }

    @Override
    public void onEndOfSpeech() {
      Log.d(LOG_TAG, "onEndOfSpeech");
      flutterSoundChannel.invokeMethod("onRecognitionComplete", transcription);
    }

    @Override
    public void onError(int error) {
      Log.d(LOG_TAG, "onError : " + error);
      flutterSoundChannel.invokeMethod("onSpeechAvailability", false);
      flutterSoundChannel.invokeMethod("onError", String.valueOf(error));
    }

    @Override
    public void onPartialResults(Bundle partialResults) {
      Log.d(LOG_TAG, "onPartialResults...");
      ArrayList<String> matches = partialResults.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION);
      transcription = matches.get(0);
      Log.d(LOG_TAG, "onPartialResults -> " + transcription);
      sendTranscription(false);
    }

    @Override
    public void onEvent(int eventType, Bundle params) {
      Log.d(LOG_TAG, "onEvent : " + eventType);
    }

    @Override
    public void onResults(Bundle results) {
      Log.d(LOG_TAG, "onResults...");
      ArrayList<String> matches = results.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION);
      transcription = matches.get(0);
      Log.d(LOG_TAG, "onResults -> " + transcription);
      sendTranscription(true);

      if (saveUserAudio) {
        audioUri = recognizerIntent.getData();
      }
    }

    private void sendTranscription(boolean isFinal) {
      // String method = isFinal ? "onRecognitionComplete" : "onSpeech";
      // Log.d(LOG_TAG, "invoke " + method + "(" + transcription + ")");
      // speechChannel.invokeMethod(method, transcription);
      if (isFinal) {
        String method = "onSpeech";
        Log.d(LOG_TAG, "invoke " + method + "(" + transcription + ")");
        flutterSoundChannel.invokeMethod(method, transcription);
      }
    }
  }
}
