#import "FlutterSoundPlugin.h"
#import <AVFoundation/AVFoundation.h>

NSString* defaultExtensions [] =
{
	  @"sound.aac" 	// CODEC_DEFAULT
	, @"sound.aac" 	// CODEC_AAC
	, @"sound.opus"	// CODEC_OPUS
	, @"sound.caf"	// CODEC_CAF_OPUS
	, @"sound.mp3"	// CODEC_MP3
	, @"sound.ogg"	// CODEC_VORBIS
	, @"sound.wav"	// CODE_PCM
};

AudioFormatID formats [] =
{
	  kAudioFormatMPEG4AAC	// CODEC_DEFAULT
    , kAudioFormatMPEG4AAC	// CODEC_AAC
	, 0						// CODEC_OPUS
	, kAudioFormatOpus		// CODEC_CAF_OPUS
	, 0						// CODEC_MP3
	, 0						// CODEC_OGG
	, kAudioFormatLinearPCM  // CODEC_PCM
};


bool _isIosEncoderSupported [] =
{
    true, // DEFAULT
    true, // AAC
    false, // OGG/OPUS
    true, // CAF/OPUS
    false, // MP3
    false, // OGG/VORBIS
    false, // WAV/PCM
};


bool _isIosDecoderSupported [] =
{
    true, // DEFAULT
    true, // AAC
    false, // OGG/OPUS
    true, // CAF/OPUS
    true, // MP3
    false, // OGG/VORBIS
    true, // WAV/PCM
};


// post fix with _FlutterSound to avoid conflicts with common libs including path_provider
NSString* GetDirectoryOfType_FlutterSound(NSSearchPathDirectory dir) {
  NSArray* paths = NSSearchPathForDirectoriesInDomains(dir, NSUserDomainMask, YES);
  return [paths.firstObject stringByAppendingString:@"/"];
}

@implementation FlutterSoundPlugin  {
  NSURL *audioFileURL;
  AVAudioRecorder *audioRecorder;
  AVAudioPlayer *audioPlayer;
    AVAudioEngine *audioEngine;
    SFSpeechRecognizer *speechRecognizer;
    SFSpeechAudioBufferRecognitionRequest *request;
    SFSpeechRecognitionTask *recognitionTask;
    double lastRecog;
    bool recogComplete;
    NSString *transcript;
    NSString *transcriptErr;
  bool recordSpeech;
  NSMutableArray* speechBuffers;
  NSTimer *timer;
  NSTimer *dbPeakTimer;
    NSTimer *speechTimer;
}
double subscriptionDuration = 0.01;
double dbPeakInterval = 0.8;
bool shouldProcessDbLevel = false;
int speechBus = 1;
double msBeforeRecogComplete = 0.8;
FlutterMethodChannel* _channel;
NSError* _lastError;
NSString* _lastErrorCall;

- (id)init {
    NSLog(@"flutter sound init");
    NSError* err = nil;
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayAndRecord
                                     withOptions:AVAudioSessionCategoryOptionDefaultToSpeaker |
                                                    AVAudioSessionCategoryOptionMixWithOthers |
                                                    AVAudioSessionCategoryOptionAllowBluetooth |
                                                    AVAudioSessionCategoryOptionAllowBluetoothA2DP
                                           error:&err];
    if (err != nil) {
        NSLog([NSString stringWithFormat:@"error setting category: %@", [err localizedDescription]]);
        _lastError = err;
        _lastErrorCall = @"init -- set category";
    }
    [[AVAudioSession sharedInstance] setActive:true error:&err];
    if (err != nil) {
        NSLog([NSString stringWithFormat:@"error activating: %@", [err localizedDescription]]);
        _lastError = err;
        _lastErrorCall = @"init -- set active";
    }
    return self;
}

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
  NSLog(@"audioPlayerDidFinishPlaying");
  [self stopPlayer];

    NSNumber *duration = [NSNumber numberWithDouble:audioPlayer.duration * 1000];
    NSNumber *currentTime = [NSNumber numberWithDouble:audioPlayer.currentTime * 1000];

    NSString* status = [NSString stringWithFormat:@"{\"duration\": \"%@\", \"current_position\": \"%@\"}",
                            [duration stringValue],
                            [currentTime stringValue]
                        ];
  /*
  NSDictionary *status = @{
                           @"duration" : [duration stringValue],
                           @"current_position" : [currentTime stringValue],
                           };
  */
  [_channel invokeMethod:@"audioPlayerDidFinishPlaying" arguments:status];
}

- (void) stopTimer{
    if (timer != nil) {
        [timer invalidate];
        timer = nil;
    }
}

- (void)updateRecorderProgress:(NSTimer*) timer
{
  NSNumber *currentTime = [NSNumber numberWithDouble:audioRecorder.currentTime * 1000];
    [audioRecorder updateMeters];

  NSString* status = [NSString stringWithFormat:@"{\"current_position\": \"%@\"}", [currentTime stringValue]];
  /*
  NSDictionary *status = @{
                           @"current_position" : [currentTime stringValue],
                           };
  */

  [_channel invokeMethod:@"updateRecorderProgress" arguments:status];
}

- (void)updateProgress:(NSTimer*) timer
{
    NSNumber *duration = [NSNumber numberWithDouble:audioPlayer.duration * 1000];
    NSNumber *currentTime = [NSNumber numberWithDouble:audioPlayer.currentTime * 1000];

    if ([duration intValue] == 0 && timer != nil) {
      [self stopTimer];
      return;
    }


    NSString* status = [NSString stringWithFormat:@"{\"duration\": \"%@\", \"current_position\": \"%@\"}", [duration stringValue], [currentTime stringValue]];
  /*
  NSDictionary *status = @{
                           @"duration" : [duration stringValue],
                           @"current_position" : [currentTime stringValue],
                           };
  */

  [_channel invokeMethod:@"updateProgress" arguments:status];
}

- (void)updateDbPeakProgress:(NSTimer*) dbPeakTimer
{
      NSNumber *normalizedPeakLevel = [NSNumber numberWithDouble:MIN(pow(10.0, [audioRecorder peakPowerForChannel:0] / 20.0) * 160.0, 160.0)];
      [_channel invokeMethod:@"updateDbPeakProgress" arguments:normalizedPeakLevel];
}

- (void)onSpeech:(NSString*) text
{
    [_channel invokeMethod:@"onSpeech" arguments:text];
}

- (void)onSpeechError:(NSString*) errtext {
    [_channel invokeMethod:@"onError" arguments:errtext];
}

- (void)startRecorderTimer
{
  dispatch_async(dispatch_get_main_queue(), ^{
      self->timer = [NSTimer scheduledTimerWithTimeInterval: subscriptionDuration
                                           target:self
                                           selector:@selector(updateRecorderProgress:)
                                           userInfo:nil
                                           repeats:YES];
  });
}

- (void)startTimer
{
  dispatch_async(dispatch_get_main_queue(), ^{
      self->timer = [NSTimer scheduledTimerWithTimeInterval:subscriptionDuration
                                           target:self
                                           selector:@selector(updateProgress:)
                                           userInfo:nil
                                           repeats:YES];
  });
}

- (void)startDbTimer
{
    dispatch_async(dispatch_get_main_queue(), ^{
        self->dbPeakTimer = [NSTimer scheduledTimerWithTimeInterval:dbPeakInterval
                                                       target:self
                                                     selector:@selector(updateDbPeakProgress:)
                                                     userInfo:nil
                                                      repeats:YES];
    });
}

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  FlutterMethodChannel* channel = [FlutterMethodChannel
      methodChannelWithName:@"flutter_sound"
            binaryMessenger:[registrar messenger]];
  FlutterSoundPlugin* instance = [[FlutterSoundPlugin alloc] init];
  [registrar addMethodCallDelegate:instance channel:channel];
  _channel = channel;
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
    //if an error occurred in a previous call, return it now
    if (_lastError != nil) {
        result([FlutterError errorWithCode:_lastErrorCall
                                   message:[_lastError localizedDescription]
                                   details:nil
                ]);
        _lastError = nil;
        return;
    }
    
  if ([@"startRecorder" isEqualToString:call.method]) {
    NSString* path = (NSString*)call.arguments[@"path"];
    NSNumber* sampleRateArgs = (NSNumber*)call.arguments[@"sampleRate"];
    NSNumber* numChannelsArgs = (NSNumber*)call.arguments[@"numChannels"];
    NSNumber* iosQuality = (NSNumber*)call.arguments[@"iosQuality"];
    NSNumber* bitRate = (NSNumber*)call.arguments[@"bitRate"];
    NSNumber* codec = (NSNumber*)call.arguments[@"codec"];
    
    t_CODEC coder = CODEC_AAC;
    if (![codec isKindOfClass:[NSNull class]])
    {
        coder = [codec intValue];
    }

    float sampleRate = 44100;
    if (![sampleRateArgs isKindOfClass:[NSNull class]]) {
      sampleRate = [sampleRateArgs integerValue];
    }

    int numChannels = 2;
    if (![numChannelsArgs isKindOfClass:[NSNull class]]) {
      numChannels = (int) [numChannelsArgs integerValue];
    }

    [self startRecorder:path:[NSNumber numberWithInt:numChannels]:[NSNumber numberWithInt:sampleRate]:coder:iosQuality:bitRate result:result];

  } else if ([@"isEncoderSupported" isEqualToString:call.method]) {
    NSNumber* codec = (NSNumber*)call.arguments[@"codec"];
    [self isEncoderSupported:[codec intValue] result:result];
  } else if ([@"isDecoderSupported" isEqualToString:call.method]) {
     NSNumber* codec = (NSNumber*)call.arguments[@"codec"];
     [self isDecoderSupported:[codec intValue] result:result];
  } else if ([@"stopRecorder" isEqualToString:call.method]) {
    [self stopRecorder: result];
  } else if ([@"startPlayer" isEqualToString:call.method]) {
      NSString* path = (NSString*)call.arguments[@"path"];
      [self startPlayer:path result:result];
  } else if ([@"startPlayerFromBuffer" isEqualToString:call.method]) {
      FlutterStandardTypedData* dataBuffer = (FlutterStandardTypedData*)call.arguments[@"dataBuffer"];
      [self startPlayerFromBuffer:dataBuffer result:result];
  } else if ([@"stopPlayer" isEqualToString:call.method]) {
    [self stopPlayer:result];
  } else if ([@"pausePlayer" isEqualToString:call.method]) {
    [self pausePlayer:result];
  } else if ([@"resumePlayer" isEqualToString:call.method]) {
    [self resumePlayer:result];
  } else if ([@"seekToPlayer" isEqualToString:call.method]) {
    NSNumber* sec = (NSNumber*)call.arguments[@"sec"];
    [self seekToPlayer:sec result:result];
  } else if ([@"setSubscriptionDuration" isEqualToString:call.method]) {
    NSNumber* sec = (NSNumber*)call.arguments[@"sec"];
    [self setSubscriptionDuration:[sec doubleValue] result:result];
  } else if ([@"setVolume" isEqualToString:call.method]) {
    NSNumber* volume = (NSNumber*)call.arguments[@"volume"];
    [self setVolume:[volume doubleValue] result:result];
  }
  else if ([@"setDbPeakLevelUpdate" isEqualToString:call.method]) {
      NSNumber* intervalInSecs = (NSNumber*)call.arguments[@"intervalInSecs"];
      [self setDbPeakLevelUpdate:[intervalInSecs doubleValue] result:result];
  }
  else if ([@"setDbLevelEnabled" isEqualToString:call.method]) {
      BOOL enabled = [call.arguments[@"enabled"] boolValue];
      [self setDbLevelEnabled:enabled result:result];
  }
  else if ([@"supportedSpeechLocales" isEqualToString:call.method]) {
    [self supportedSpeechLocales: result];
  }
  else if ([@"getDeviceLanguage" isEqualToString:call.method]) {
    [self getDeviceLanguage: result];
  }
  else if ([@"getDeviceLanguageTag" isEqualToString:call.method]) {
    [self getDeviceLanguageTag: result];
  }
  else if ([@"requestSpeechRecognitionPermission" isEqualToString:call.method]) {
      [self requestSpeechRecognitionPermission: result];
  }
  else if ([@"recordAndRecognizeSpeech" isEqualToString:call.method]) {
      [self recordAndRecognizeSpeech: [call.arguments[@"toTmpFile"] boolValue] lang: (NSString*)call.arguments[@"langcode"] result:result];
  }
  else if ([@"stopRecognizeSpeech" isEqualToString:call.method]) {
      [self stopRecognizeSpeech: result];
  }
  else if ([@"getTempAudioFile" isEqualToString:call.method]) {
    result([self getTempAudioFile]);
  }
  else {
    result(FlutterMethodNotImplemented);
  }
}

- (void)isDecoderSupported:(t_CODEC)codec result: (FlutterResult)result {
  NSNumber*  b = [NSNumber numberWithBool: _isIosDecoderSupported[codec] ];
  result(b);
}

- (void)isEncoderSupported:(t_CODEC)codec result: (FlutterResult)result {
  NSNumber*  b = [NSNumber numberWithBool: _isIosEncoderSupported[codec] ];
  result(b);
}

- (void)setSubscriptionDuration:(double)duration result: (FlutterResult)result {
  subscriptionDuration = duration;
  result(@"setSubscriptionDuration");
}

- (void)setDbPeakLevelUpdate:(double)intervalInSecs result: (FlutterResult)result {
    dbPeakInterval = intervalInSecs;
    result(@"setDbPeakLevelUpdate");
}

- (void)setDbLevelEnabled:(BOOL)enabled result: (FlutterResult)result {
    shouldProcessDbLevel = enabled == YES;
    result(@"setDbLevelEnabled");
}

- (void)startRecorder
        :(NSString*)path
        :(NSNumber*)numChannels
        :(NSNumber*)sampleRate
        :(t_CODEC) codec
        :(NSNumber*)iosQuality
        :(NSNumber*)bitRate
        result: (FlutterResult)result {
  if ([path class] == [NSNull class]) {
    audioFileURL = [NSURL fileURLWithPath:[GetDirectoryOfType_FlutterSound(NSCachesDirectory) stringByAppendingString:defaultExtensions[codec] ]];
  } else {
    audioFileURL = [NSURL fileURLWithPath: [GetDirectoryOfType_FlutterSound(NSCachesDirectory) stringByAppendingString:path]];
  }
  NSMutableDictionary *audioSettings = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                 [NSNumber numberWithFloat:[sampleRate doubleValue]],AVSampleRateKey,
                                 [NSNumber numberWithInt: formats[codec] ],AVFormatIDKey,
                                 [NSNumber numberWithInt: [numChannels intValue]],AVNumberOfChannelsKey,
                                 [NSNumber numberWithInt: [iosQuality intValue]],AVEncoderAudioQualityKey,
                                 nil];
    
    // If bitrate is defined, the use it, otherwise use the OS default
    if(![bitRate isEqual:[NSNull null]]) {
        [audioSettings setValue:[NSNumber numberWithInt: [bitRate intValue]]
                    forKey:AVEncoderBitRateKey];
    }

    NSError *err;
  audioRecorder = [[AVAudioRecorder alloc]
                        initWithURL:audioFileURL
                        settings:audioSettings
                        error:&err];
    if (err != nil) {
        result([FlutterError errorWithCode:@"start recorder" message:[err localizedDescription] details:nil]);
        return;
    }

  [audioRecorder setDelegate:self];
  [audioRecorder record];
  [self startRecorderTimer];

  [audioRecorder setMeteringEnabled:shouldProcessDbLevel];
  if(shouldProcessDbLevel == true) {
        [self startDbTimer];
  }

  NSString *filePath = self->audioFileURL.path;
  result(filePath);
}

- (void)stopRecorder:(FlutterResult)result {
  [audioRecorder stop];

  // Stop Db Timer
  [dbPeakTimer invalidate];
  dbPeakTimer = nil;
  [self stopTimer];
    
  NSString *filePath = audioFileURL.absoluteString;
  result(filePath);
}

- (void)startPlayer:(NSString*)path result: (FlutterResult)result {
  bool isRemote = false;
  if ([path class] == [NSNull class]) {
    audioFileURL = [NSURL fileURLWithPath:[GetDirectoryOfType_FlutterSound(NSCachesDirectory) stringByAppendingString:@"sound.aac"]];
  } else {
    NSURL *remoteUrl = [NSURL URLWithString:path];
    if(remoteUrl && remoteUrl.scheme && remoteUrl.host){
        audioFileURL = remoteUrl;
        isRemote = true;
    } else {
        audioFileURL = [NSURL URLWithString:path];
    }
  }

  if (isRemote) {
    NSURLSessionDataTask *downloadTask = [[NSURLSession sharedSession]
        dataTaskWithURL:audioFileURL completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            // NSData *data = [NSData dataWithContentsOfURL:audioFileURL];
            
        NSError* err;
        // We must create a new Audio Player instance to be able to play a different Url
        self->audioPlayer = [[AVAudioPlayer alloc] initWithData:data error:&err];
        if (err != nil) {
            result([FlutterError errorWithCode:@"startPlayer in download task audioplayer init"
                                       message:[err localizedDescription]
                                       details:nil]);
            return;
        }
        self->audioPlayer.delegate = self;

        [self->audioPlayer play];
        [self startTimer];
        NSString *filePath = self->audioFileURL.absoluteString;
        result(filePath);
    }];

    [downloadTask resume];
  } else {
      NSError* err;
      audioPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:audioFileURL error:&err];
      if (err != nil) {
          result([FlutterError errorWithCode:@"startPlayer audioplayer init"
                                     message:[err localizedDescription]
                                     details:nil]);
          return;
      }
      audioPlayer.delegate = self;

    [audioPlayer play];
    [self startTimer];

    NSString *filePath = audioFileURL.absoluteString;
    result(filePath);
  }
}

- (void)startPlayerFromBuffer:(FlutterStandardTypedData*)dataBuffer result: (FlutterResult)result {
    NSError* err;
  audioPlayer = [[AVAudioPlayer alloc] initWithData: [dataBuffer data] error: &err];
  if (err != nil) {
      result([FlutterError errorWithCode:@"startPlayerFromBuffer audioplayer init"
                                 message:[err localizedDescription]
                                 details:nil]);
      return;
  }
  audioPlayer.delegate = self;
  [audioPlayer play];
    
  [self startTimer];
  result(@"Playing from buffer");
}

- (void)stopPlayer:(FlutterResult)result {
    NSLog(@"stopping player");
  if (audioPlayer) {
    [self stopPlayer];
    result(@"stop play");
  } else {
    result(@"nothing to stop");
  }
}

-(void)stopPlayer {
  [audioPlayer stop];
  [self stopTimer];
  audioPlayer = nil;
}

- (void)pausePlayer:(FlutterResult)result {
    if (audioPlayer && [audioPlayer isPlaying]) {
        [audioPlayer pause];
        if (timer != nil) {
            [timer invalidate];
            timer = nil;
        }
        result(@"pause play");
    }
  else {
    result([FlutterError
        errorWithCode:@"Audio Player"
        message:@"player is not set"
        details:nil]);
  }
}

- (void)resumePlayer:(FlutterResult)result {
  if (!audioFileURL) {
    result([FlutterError
            errorWithCode:@"Audio Player"
            message:@"fileURL is not defined"
            details:nil]);
    return;
  }

  if (!audioPlayer) {
    result([FlutterError
            errorWithCode:@"Audio Player"
            message:@"player is not set"
            details:nil]);
    return;
  }

  [audioPlayer play];
  [self startTimer];
  NSString *filePath = audioFileURL.absoluteString;
  result(filePath);
}

- (void)seekToPlayer:(nonnull NSNumber*) time result: (FlutterResult)result {
  if (audioPlayer) {

      audioPlayer.currentTime = [time doubleValue] / 1000;
      [self updateProgress:nil];
      result([time stringValue]);
  } else {
    result([FlutterError
        errorWithCode:@"Audio Player"
        message:@"player is not set"
        details:nil]);
  }
}

- (void)setVolume:(double) volume result: (FlutterResult)result {
    if (audioPlayer) {
        [audioPlayer setVolume:volume];
        result(@"volume set");
    } else {
        result([FlutterError
                errorWithCode:@"Audio Player"
                message:@"player is not set"
                details:nil]);
    }
}

- (void) supportedSpeechLocales: (FlutterResult)result {
  NSSet* locales = [SFSpeechRecognizer supportedLocales];
  NSMutableArray* codes = [[NSMutableArray alloc] init];
  for (NSLocale* l in locales) {
    [codes addObject:[l localeIdentifier]];
  }
  result(codes);
}

- (void) getDeviceLanguage: (FlutterResult)result {
  NSString* langCode = [[NSLocale preferredLanguages] objectAtIndex:0];
  result([[NSLocale currentLocale] displayNameForKey:NSLocaleLanguageCode value:langCode]);
}

- (void) getDeviceLanguageTag: (FlutterResult)result {
  result([[NSLocale preferredLanguages] objectAtIndex:0]);
}

- (void) requestSpeechRecognitionPermission: (FlutterResult)result {
    if (SFSpeechRecognizer.authorizationStatus == SFSpeechRecognizerAuthorizationStatusAuthorized) {
        result([NSNumber numberWithBool:true]);
    }
    else {
        [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status) {
            result([NSNumber numberWithBool:status == SFSpeechRecognizerAuthorizationStatusAuthorized]);
        }];
    }
}

- (NSString*) getTempAudioFile {
  return [NSString stringWithFormat:@"%@/tmpaudio.wav", NSTemporaryDirectory()];
}

- (void) isRecogDone: (NSTimer*) timer {
    double curr = [[NSDate date] timeIntervalSince1970];
    if (lastRecog > 0 && curr - lastRecog >= msBeforeRecogComplete) {
        recogComplete = true;
        lastRecog = 0;
        [timer invalidate];
//        NSLog([NSString stringWithFormat:@"complete: %f", curr]);
        NSLog([NSString stringWithFormat:@"transcript: %@", transcript]);
        [self onSpeech:transcript];
        [self stopRecognizeSpeech:nil];

        if (recordSpeech && [speechBuffers count] > 0) {
          NSURL* tmpFile = [NSURL fileURLWithPath: [self getTempAudioFile]];
          NSError* err;
          AVAudioPCMBuffer* buff = [speechBuffers objectAtIndex:0];
          AVAudioFile* audio = [[AVAudioFile alloc] initForWriting:tmpFile settings: [[buff format] settings] error:&err];
          if (err != nil)
            NSLog([NSString stringWithFormat: @"avaudiofile init error: %@, file: %@", [err localizedDescription], [tmpFile absoluteString]]);
          for (AVAudioPCMBuffer* b in speechBuffers) {
            [audio writeFromBuffer: b error: &err];
            if (err != nil)
              NSLog([NSString stringWithFormat: @"avaudiofile write error: %@", [err localizedDescription]]);
          }
        }
    }
}

- (void)recordAndRecognizeSpeech: (BOOL)tmpFile lang: (NSString*) langcode result:(FlutterResult)result {
    recordSpeech = tmpFile;
    if (request != nil) {
        if (result != nil)
            result(@"Already listening");
        return; //we're already listening.
    }
    
    transcript = [[NSString alloc] init];
    lastRecog = 0;
    recogComplete = false;
    if (recordSpeech)
      speechBuffers = [[NSMutableArray alloc] init];
    request = [[SFSpeechAudioBufferRecognitionRequest alloc] init];

    if (audioEngine == nil)
        audioEngine = [[AVAudioEngine alloc] init];

    AVAudioInputNode* node = [audioEngine inputNode];
    [node removeTapOnBus:speechBus];
    AVAudioFormat* inputFormat = [node inputFormatForBus:speechBus];
    AVAudioFormat* outputFormat = [node outputFormatForBus:speechBus];
    AVAudioConverter* converter = [[AVAudioConverter alloc] initFromFormat:inputFormat toFormat:outputFormat];
    @try {
        [node installTapOnBus:speechBus bufferSize:1024 format:outputFormat block:^(AVAudioPCMBuffer *buf, AVAudioTime *when) {
            if (self->recogComplete)
                return;
            
            __block bool newBufferAvailable = true;
            
            AVAudioFrameCount frameCap = (outputFormat.sampleRate * buf.frameLength) / buf.format.sampleRate;
            AVAudioPCMBuffer* convertedBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:outputFormat frameCapacity:frameCap];
            NSError* err;
            [converter convertToBuffer:convertedBuffer
                                 error:&err
                    withInputFromBlock:^(AVAudioPacketCount inNumPackets, AVAudioConverterInputStatus *outputStatus) {
                if (self->recogComplete)
                    return (AVAudioBuffer*)nil;
                
                if (newBufferAvailable) {
                    *outputStatus = AVAudioConverterInputStatus_HaveData;
                    newBufferAvailable = false;
                    return (AVAudioBuffer*)buf;
                } else {
                    *outputStatus = AVAudioConverterInputStatus_NoDataNow;
                    return (AVAudioBuffer*) nil;
                }
            }];
            
            if (self->recordSpeech)
                [self->speechBuffers addObject:convertedBuffer];
            [self->request appendAudioPCMBuffer:convertedBuffer];
        }];
    }
    @catch (NSException* e) {
        NSString* msg = [NSString stringWithFormat:@"%@: %@", [e name], [e reason]];
        [self onSpeechError: msg];
//        UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Speech Failed"
//                                                        message:msg
//                                                       delegate:self
//                                              cancelButtonTitle:@"OK"
//                                              otherButtonTitles:nil];
//        [alert show];
    }
    
    if (![audioEngine isRunning]) {
        NSLog(@"listener starting engine");
        NSError* err;
        [audioEngine prepare];
        [audioEngine startAndReturnError:&err];
        
        if (err != nil) {
            [self onSpeechError:[err localizedDescription]];
            if (result != nil) {
                result([FlutterError errorWithCode:@"recordAndRecognizeSpeech - audioEngine start"
                                           message:[err localizedDescription]
                                           details:nil]);
                return;
            }
        }
    }
    //NSLog([NSString stringWithFormat:@"start listener engine running: %d", [audioEngine isRunning]]);
    bool langSet = (langcode != nil && [langcode length] > 0);
    if (langSet) {
      NSLocale* locale = [NSLocale localeWithLocaleIdentifier:langcode];
      speechRecognizer = [[SFSpeechRecognizer alloc] initWithLocale:locale];
    }
    if (!langSet || speechRecognizer == nil)
      speechRecognizer = [[SFSpeechRecognizer alloc] init];
    if (speechRecognizer == nil) {
      NSLog(@"failed to get recognizer");
      if (result != nil)
        result([FlutterError errorWithCode:@"Audio Speech" message:@"failed to get recognizer" details:nil]);
      return;
    }
    if (![speechRecognizer isAvailable]) {
      NSLog(@"no recognizer available");
      if (result != nil)
        result([FlutterError errorWithCode:@"Audio Speech" message:@"no recognizer available" details:nil]);
      return;
    }

    recognitionTask = [speechRecognizer recognitionTaskWithRequest:request
                                                     resultHandler:^(SFSpeechRecognitionResult* recogResult, NSError* err) {
        if (err != nil) {
            NSLog([err localizedDescription]);
            if (![[err localizedDescription] containsString:@"error 209"])
                //Don't report 209 errors (not recognized, I think: https://github.com/macdonst/SpeechRecognitionPlugin/issues/88)
                [self onSpeechError:[err localizedDescription]];
//            _lastErrorCall = @"recognition result";
//            _lastError = err;
        }
        else if (!self->recogComplete) {
            if ([recogResult.bestTranscription.formattedString length] > 0) {
                self->lastRecog = [[NSDate date] timeIntervalSince1970];
//                NSLog([NSString stringWithFormat:@"last recog (result): %f", self->lastRecog]);
                self->transcript = recogResult.bestTranscription.formattedString;
                NSLog(self->transcript);
            }
        }
    }];

    if ([recognitionTask error] != nil) {
        [self onSpeechError:[[recognitionTask error] localizedDescription]];
        if (result != nil)
          result([FlutterError errorWithCode:@"Error starting" message:[[recognitionTask error] localizedDescription] details:nil]);
        return;
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        self->timer = [NSTimer scheduledTimerWithTimeInterval: subscriptionDuration
                                                       target:self
                                                     selector:@selector(isRecogDone:)
                                                     userInfo:nil
                                                      repeats:YES];
    });

    if (result != nil) {
        NSString* langCode = [[speechRecognizer locale] languageCode];
        NSString* dispCode = [[NSLocale currentLocale] displayNameForKey:NSLocaleLanguageCode value:langCode];
        result([NSString stringWithFormat:@"recordAndRecognizeSpeech successful: %@", dispCode]);
    }
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex{
    //We're not doing anything in response to the alert
}

- (void)stopRecognizeSpeech: (FlutterResult)result {
    [[audioEngine inputNode] removeTapOnBus:speechBus];
    [request endAudio];
    request = nil;
    [recognitionTask finish];
    recognitionTask = nil;
    [audioEngine stop];
    audioEngine = nil;
    speechRecognizer = nil;
    NSLog([NSString stringWithFormat:@"stop listener engine running: %d", [self->audioEngine isRunning]]);

    if (result != nil)
        result(transcript);
}
@end
