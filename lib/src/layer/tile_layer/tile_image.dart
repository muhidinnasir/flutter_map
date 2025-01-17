import 'package:flutter/widgets.dart';
import 'package:flutter_map/src/layer/tile_layer/tile_coordinates.dart';
import 'package:flutter_map/src/layer/tile_layer/tile_display.dart';

class TileImage extends ChangeNotifier {
  bool _disposed = false;

  // Controls fade-in opacity.
  AnimationController? _animationController;

  // Whether the tile is displayable. See [readyToDisplay].
  bool _readyToDisplay = false;

  /// Used by animationController. Still required if animation is disabled in
  /// case the tile display is changed at a later point.
  final TickerProvider vsync;

  /// The z of the coordinate is the TileImage's zoom level whilst the x and y
  /// indicate the position of the tile at that zoom level.
  final TileCoordinates coordinates;

  /// Callback fired when loading finishes with or withut an error. This
  /// callback is not triggered after this TileImage is disposed.
  final void Function(TileCoordinates coordinates) onLoadComplete;

  /// Callback fired when an error occurs whilst loading the tile image.
  /// [onLoadComplete] will be called immediately afterwards. This callback is
  /// not triggered after this TileImage is disposed.
  final void Function(TileImage tile, Object error, StackTrace? stackTrace)
      onLoadError;

  /// Options for how the tile image is displayed.
  TileDisplay _tileDisplay;

  /// An optional image to show when a loading error occurs.
  final ImageProvider? errorImage;

  ImageProvider imageProvider;

  /// True if an error occurred during loading.
  bool loadError = false;

  /// When loading started.
  DateTime? loadStarted;

  /// When loading finished.
  DateTime? loadFinishedAt;

  ImageInfo? imageInfo;
  ImageStream? _imageStream;
  late ImageStreamListener _listener;

  TileImage({
    required this.vsync,
    required this.coordinates,
    required this.imageProvider,
    required this.onLoadComplete,
    required this.onLoadError,
    required TileDisplay tileDisplay,
    required this.errorImage,
  })  : _tileDisplay = tileDisplay,
        _animationController = tileDisplay.when(
          instantaneous: (_) => null,
          fadeIn: (fadeIn) => AnimationController(
            vsync: vsync,
            duration: fadeIn.duration,
          ),
        );

  double get opacity => _tileDisplay.when(
        instantaneous: (instantaneous) =>
            _readyToDisplay ? instantaneous.opacity : 0.0,
        fadeIn: (fadeIn) => _animationController!.value,
      )!;

  AnimationController? get animation => _animationController;

  String get coordinatesKey => coordinates.key;

  /// Whether the tile is displayable. This means that either:
  ///   * Loading errored but an error image is configured.
  ///   * Loading succeeded and the fade animation has finished.
  ///   * Loading succeeded and there is no fade animation.
  ///
  /// Note that [opacity] can be less than 1 when this is true if instantaneous
  /// tile display is used with a maximum opacity less than 1.
  bool get readyToDisplay => _readyToDisplay;

  // Used to sort TileImages by their distance from the current zoom.
  double zIndex(double maxZoom, int currentZoom) =>
      maxZoom - (currentZoom - coordinates.z).abs();

  /// Change the tile display options.
  set tileDisplay(TileDisplay newTileDisplay) {
    final oldTileDisplay = _tileDisplay;
    _tileDisplay = newTileDisplay;

    // Handle disabling/enabling of animation controller if necessary
    oldTileDisplay.when(
      instantaneous: (instantaneous) {
        newTileDisplay.when(
          fadeIn: (fadeIn) {
            // Became animated.
            _animationController = AnimationController(
              duration: fadeIn.duration,
              vsync: vsync,
              value: _readyToDisplay ? 1.0 : 0.0,
            );
          },
        );
      },
      fadeIn: (fadeIn) {
        newTileDisplay.when(instantaneous: (instantaneous) {
          // No longer animated.
          _animationController!.dispose();
          _animationController = null;
        }, fadeIn: (fadeIn) {
          // Still animated with different fade.
          _animationController!.duration = fadeIn.duration;
        });
      },
    );

    if (!_disposed) notifyListeners();
  }

  /// Initiate loading of the image.
  void load() {
    loadStarted = DateTime.now();

    try {
      final oldImageStream = _imageStream;
      _imageStream = imageProvider.resolve(ImageConfiguration.empty);

      if (_imageStream!.key != oldImageStream?.key) {
        oldImageStream?.removeListener(_listener);

        _listener = ImageStreamListener(
          _onImageLoadSuccess,
          onError: _onImageLoadError,
        );
        _imageStream!.addListener(_listener);
      }
    } catch (e, s) {
      // Make sure all exceptions are handled - #444 / #536
      _onImageLoadError(e, s);
    }
  }

  void _onImageLoadSuccess(ImageInfo imageInfo, bool synchronousCall) {
    loadError = false;
    this.imageInfo = imageInfo;

    if (!_disposed) {
      _display();
      onLoadComplete(coordinates);
    }
  }

  void _onImageLoadError(Object exception, StackTrace? stackTrace) {
    loadError = true;

    if (!_disposed) {
      if (errorImage != null) _display();
      onLoadError(this, exception, stackTrace);
      onLoadComplete(coordinates);
    }
  }

  // Initiates fading in and marks this TileImage as readyToDisplay when fading
  // finishes. If fading is disabled or a loading error occurred this TileImage
  // becomes readyToDisplay immediately.
  void _display() {
    final previouslyLoaded = loadFinishedAt != null;
    loadFinishedAt = DateTime.now();

    if (loadError) {
      assert(
        errorImage != null,
        'A TileImage should not be displayed if loading errors and there is no '
        'errorImage to show.',
      );
      _readyToDisplay = true;
      if (!_disposed) notifyListeners();
      return;
    }

    _tileDisplay.when(
      instantaneous: (_) {
        _readyToDisplay = true;
        if (!_disposed) notifyListeners();
      },
      fadeIn: (fadeIn) {
        final fadeStartOpacity =
            previouslyLoaded ? fadeIn.reloadStartOpacity : fadeIn.startOpacity;

        if (fadeStartOpacity == 1.0) {
          _readyToDisplay = true;
          if (!_disposed) notifyListeners();
        } else {
          _animationController!.reset();
          _animationController!.forward(from: fadeStartOpacity).then((_) {
            _readyToDisplay = true;
            if (!_disposed) notifyListeners();
          });
        }
      },
    );
  }

  @override
  void dispose({bool evictImageFromCache = false}) {
    assert(
      !_disposed,
      'The TileImage dispose() method was called multiple times',
    );
    _disposed = true;

    if (evictImageFromCache) {
      try {
        // ignore: avoid_types_on_closure_parameters
        imageProvider.evict().catchError((Object e) {
          debugPrint(e.toString());
          return false;
        });
      } catch (e) {
        // This may be never called because catchError will handle errors, however
        // we want to avoid random crashes like in #444 / #536
        debugPrint(e.toString());
      }
    }

    _readyToDisplay = false;
    _animationController?.stop(canceled: false);
    _animationController?.value = 0.0;
    notifyListeners();

    _animationController?.dispose();
    _imageStream?.removeListener(_listener);
    super.dispose();
  }

  @override
  int get hashCode => coordinates.hashCode;

  @override
  bool operator ==(Object other) {
    return other is TileImage && coordinates == other.coordinates;
  }

  @override
  String toString() {
    return 'TileImage($coordinates, readyToDisplay: $_readyToDisplay)';
  }
}
