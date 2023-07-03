// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:html' as html;
import 'dart:html';
import 'dart:js_util';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:video_player_web_hls/hls.dart';
import 'package:video_player_web_hls/no_script_tag_exception.dart';

import 'duration_utils.dart';

// An error code value to error name Map.
// See: https://developer.mozilla.org/en-US/docs/Web/API/MediaError/code
const Map<int, String> _kErrorValueToErrorName = <int, String>{
  1: 'MEDIA_ERR_ABORTED',
  2: 'MEDIA_ERR_NETWORK',
  3: 'MEDIA_ERR_DECODE',
  4: 'MEDIA_ERR_SRC_NOT_SUPPORTED',
};

// An error code value to description Map.
// See: https://developer.mozilla.org/en-US/docs/Web/API/MediaError/code
const Map<int, String> _kErrorValueToErrorDescription = <int, String>{
  1: 'The user canceled the fetching of the video.',
  2: 'A network error occurred while fetching the video, despite having previously been available.',
  3: 'An error occurred while trying to decode the video, despite having previously been determined to be usable.',
  4: 'The video has been found to be unsuitable (missing or in a format not supported by your browser).',
  5: 'Could not load manifest'
};

// The default error message, when the error is an empty string
// See: https://developer.mozilla.org/en-US/docs/Web/API/MediaError/message
const String _kDefaultErrorMessage = 'No further diagnostic information can be determined or provided.';

/// Wraps a [html.VideoElement] so its API complies with what is expected by the plugin.
class VideoPlayer {
  /// Create a [VideoPlayer] from a [html.VideoElement] instance.
  VideoPlayer({
    required html.VideoElement videoElement,
    required this.uri,
    required this.headers,
    @visibleForTesting StreamController<VideoEvent>? eventController,
  })  : _videoElement = videoElement,
        _eventController = eventController ?? StreamController<VideoEvent>();

  final StreamController<VideoEvent> _eventController;
  final html.VideoElement _videoElement;
  final String uri;
  final Map<String, String> headers;

  bool _isInitialized = false;
  bool _isBuffering = false;
  Hls? _hls;

  /// Returns the [Stream] of [VideoEvent]s from the inner [html.VideoElement].
  Stream<VideoEvent> get events => _eventController.stream;

  /// Initializes the wrapped [html.VideoElement].
  ///
  /// This method sets the required DOM attributes so videos can [play] programmatically,
  /// and attaches listeners to the internal events from the [html.VideoElement]
  /// to react to them / expose them through the [VideoPlayer.events] stream.
  Future<void> initialize() async {
    _videoElement
      ..autoplay = false
      ..controls = false;

    // Allows Safari iOS to play the video inline
    _videoElement.setAttribute('playsinline', 'true');

    // Set autoplay to false since most browsers won't autoplay a video unless it is muted
    _videoElement.setAttribute('autoplay', 'false');

    if (await shouldUseHlsLibrary()) {
      try {
        _hls = Hls(
          HlsConfig(
            xhrSetup: allowInterop(
              (HttpRequest xhr, String _) {
                if (headers.isEmpty) {
                  return;
                }

                if (headers.containsKey('useCookies')) {
                  xhr.withCredentials = true;
                }
                headers.forEach((String key, String value) {
                  if (key != 'useCookies') {
                    xhr.setRequestHeader(key, value);
                  }
                });
              },
            ),
          ),
        );
        _hls!.attachMedia(_videoElement);
        _hls!.on('hlsMediaAttached', allowInterop((dynamic _, dynamic __) {
          _hls!.loadSource(uri.toString());
        }));
        _hls!.on('hlsError', allowInterop((dynamic _, dynamic data) {
          final ErrorData _data = ErrorData(data);
          if (_data.fatal) {
            _eventController.addError(PlatformException(
              code: _kErrorValueToErrorName[2]!,
              message: _data.type,
              details: _data.details,
            ));
          }
        }));
        _videoElement.onCanPlay.listen((dynamic _) {
          if (!_isInitialized) {
            _isInitialized = true;
            _sendInitialized();
          }
          setBuffering(false);
        });
      } catch (e) {
        throw NoScriptTagException();
      }
    } else {
      _videoElement.src = uri.toString();
      _videoElement.addEventListener('durationchange', (_) {
        if (_videoElement.duration == 0) {
          return;
        }
        if (!_isInitialized) {
          _isInitialized = true;
          _sendInitialized();
        }
      });
    }

    _videoElement.onCanPlayThrough.listen((dynamic _) {
      setBuffering(false);
    });

    _videoElement.onPlaying.listen((dynamic _) {
      setBuffering(false);
    });

    _videoElement.onWaiting.listen((dynamic _) {
      setBuffering(true);
      _sendBufferingRangesUpdate();
    });

    // The error event fires when some form of error occurs while attempting to load or perform the media.
    _videoElement.onError.listen((html.Event _) {
      setBuffering(false);
      // The Event itself (_) doesn't contain info about the actual error.
      // We need to look at the HTMLMediaElement.error.
      // See: https://developer.mozilla.org/en-US/docs/Web/API/HTMLMediaElement/error
      final html.MediaError error = _videoElement.error!;
      _eventController.addError(PlatformException(
        code: _kErrorValueToErrorName[error.code]!,
        message: error.message != '' ? error.message : _kDefaultErrorMessage,
        details: _kErrorValueToErrorDescription[error.code],
      ));
    });

    _videoElement.onEnded.listen((dynamic _) {
      setBuffering(false);
      _eventController.add(VideoEvent(eventType: VideoEventType.completed));
    });
  }

  /// Attempts to play the video.
  ///
  /// If this method is called programmatically (without user interaction), it
  /// might fail unless the video is completely muted (or it has no Audio tracks).
  ///
  /// When called from some user interaction (a tap on a button), the above
  /// limitation should disappear.
  Future<void> play() {
    return _videoElement.play().catchError((Object e) {
      // play() attempts to begin playback of the media. It returns
      // a Promise which can get rejected in case of failure to begin
      // playback for any reason, such as permission issues.
      // The rejection handler is called with a DomException.
      // See: https://developer.mozilla.org/en-US/docs/Web/API/HTMLMediaElement/play
      final html.DomException exception = e as html.DomException;
      _eventController.addError(PlatformException(
        code: exception.name,
        message: exception.message,
      ));
    }, test: (Object e) => e is html.DomException);
  }

  /// Pauses the video in the current position.
  void pause() {
    _videoElement.pause();
  }

  /// Controls whether the video should start again after it finishes.
  // ignore: use_setters_to_change_properties
  void setLooping(bool value) {
    _videoElement.loop = value;
  }

  /// Sets the volume at which the media will be played.
  ///
  /// Values must fall between 0 and 1, where 0 is muted and 1 is the loudest.
  ///
  /// When volume is set to 0, the `muted` property is also applied to the
  /// [html.VideoElement]. This is required for auto-play on the web.
  void setVolume(double volume) {
    assert(volume >= 0 && volume <= 1);

    // TODO(ditman): Do we need to expose a "muted" API?
    // https://github.com/flutter/flutter/issues/60721
    _videoElement.muted = !(volume > 0.0);
    _videoElement.volume = volume;
  }

  /// Sets the playback `speed`.
  ///
  /// A `speed` of 1.0 is "normal speed," values lower than 1.0 make the media
  /// play slower than normal, higher values make it play faster.
  ///
  /// `speed` cannot be negative.
  ///
  /// The audio is muted when the fast forward or slow motion is outside a useful
  /// range (for example, Gecko mutes the sound outside the range 0.25 to 4.0).
  ///
  /// The pitch of the audio is corrected by default.
  void setPlaybackSpeed(double speed) {
    assert(speed > 0);

    _videoElement.playbackRate = speed;
  }

  /// Moves the playback head to a new `position`.
  ///
  /// `position` cannot be negative.
  void seekTo(Duration position) {
    assert(!position.isNegative);

    _videoElement.currentTime = position.inMilliseconds.toDouble() / 1000;
  }

  /// Returns the current playback head position as a [Duration].
  Duration getPosition() {
    _sendBufferingRangesUpdate();
    return Duration(milliseconds: (_videoElement.currentTime * 1000).round());
  }

  /// Disposes of the current [html.VideoElement].
  void dispose() {
    _videoElement.removeAttribute('src');
    _videoElement.load();
    _hls?.stopLoad();
  }

  // Sends an [VideoEventType.initialized] [VideoEvent] with info about the wrapped video.
  void _sendInitialized() {
    final Duration? duration = convertNumVideoDurationToPluginDuration(_videoElement.duration);

    final Size? size = _videoElement.videoHeight.isFinite
        ? Size(
            _videoElement.videoWidth.toDouble(),
            _videoElement.videoHeight.toDouble(),
          )
        : null;

    _eventController.add(
      VideoEvent(
        eventType: VideoEventType.initialized,
        duration: duration,
        size: size,
      ),
    );
  }

  /// Caches the current "buffering" state of the video.
  ///
  /// If the current buffering state is different from the previous one
  /// ([_isBuffering]), this dispatches a [VideoEvent].
  @visibleForTesting
  void setBuffering(bool buffering) {
    if (_isBuffering != buffering) {
      _isBuffering = buffering;
      _eventController.add(VideoEvent(
        eventType: _isBuffering ? VideoEventType.bufferingStart : VideoEventType.bufferingEnd,
      ));
    }
  }

  // Broadcasts the [html.VideoElement.buffered] status through the [events] stream.
  void _sendBufferingRangesUpdate() {
    _eventController.add(VideoEvent(
      buffered: _toDurationRange(_videoElement.buffered),
      eventType: VideoEventType.bufferingUpdate,
    ));
  }

  // Converts from [html.TimeRanges] to our own List<DurationRange>.
  List<DurationRange> _toDurationRange(html.TimeRanges buffered) {
    final List<DurationRange> durationRange = <DurationRange>[];
    for (int i = 0; i < buffered.length; i++) {
      durationRange.add(DurationRange(
        Duration(milliseconds: (buffered.start(i) * 1000).round()),
        Duration(milliseconds: (buffered.end(i) * 1000).round()),
      ));
    }
    return durationRange;
  }

  bool canPlayHlsNatively() {
    bool canPlayHls = false;
    try {
      final String canPlayType = _videoElement.canPlayType('application/vnd.apple.mpegurl');
      canPlayHls = canPlayType != '';
    } catch (e) {}
    return canPlayHls;
  }

  Future<bool> shouldUseHlsLibrary() async {
    return isSupported() && (uri.toString().contains('m3u8') || await _testIfM3u8()) && !canPlayHlsNatively();
  }

  Future<bool> _testIfM3u8() async {
    try {
      final Map<String, String> headers = Map<String, String>.of(this.headers);
      if (headers.containsKey('Range') || headers.containsKey('range')) {
        final List<int> range = (headers['Range'] ?? headers['range'])!.split('bytes')[1].split('-').map((String e) => int.parse(e)).toList();
        range[1] = min(range[0] + 1023, range[1]);
        headers['Range'] = 'bytes=${range[0]}-${range[1]}';
      } else {
        headers['Range'] = 'bytes=0-1023';
      }
      final http.Response response = await http.get(Uri.parse(this.uri), headers: headers);
      final String body = response.body;
      if (!body.contains('#EXTM3U')) {
        return false;
      }
      return true;
    } catch (e) {
      return false;
    }
  }

  dynamic getVideoTracks() {
    List<dynamic> tracks = _hls?.levels ?? [];
    List<int> res = <int>[];
    if (tracks.isNotEmpty) {
      for (var l in tracks) {
        res.add(getProperty(l, 'height'));
      }
    }
    return res;
  }

  Future<void> setVideoTrack(int trackIndex) async {
    _hls?.currentLevel = trackIndex;
    _hls?.loadLevels = trackIndex;
    _hls?.autoLevelCapping = trackIndex;
  }

  Future<void> setMaxBufferLength(Duration duration) async {
    setProperty(_hls?.config as Object, 'maxBufferLength', duration.inSeconds);
    setProperty(_hls?.config as Object, 'maxMaxBufferLength', duration.inSeconds);
  }
}
