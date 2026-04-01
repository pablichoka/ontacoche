import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../models/device_trip.dart';
import '../theme/app_colors.dart';
import '../widgets/map_circle_marker.dart';

class TripPlaybackScreen extends StatefulWidget {
  const TripPlaybackScreen({super.key, required this.trip});

  final DeviceTrip trip;

  @override
  State<TripPlaybackScreen> createState() => _TripPlaybackScreenState();
}

class _TripPlaybackScreenState extends State<TripPlaybackScreen> {
  static const List<double> _speedOptions = <double>[0.5, 1.0, 2.0];

  final MapController _mapController = MapController();
  Timer? _playbackTimer;
  int _currentIndex = 0;
  bool _isPlaying = false;
  double _playbackSpeed = 1.0;

  List<LatLng> get _points => widget.trip.pathPoints;

  TripPoint? get _activeTripPoint {
    if (widget.trip.tripPoints.isEmpty) {
      return null;
    }
    if (_currentIndex < 0 || _currentIndex >= widget.trip.tripPoints.length) {
      return null;
    }
    return widget.trip.tripPoints[_currentIndex];
  }

  @override
  void dispose() {
    _playbackTimer?.cancel();
    super.dispose();
  }

  Duration get _frameDuration {
    if (_points.length < 2) {
      return const Duration(milliseconds: 600);
    }
    final double baseMs = widget.trip.durationSec > 0
        ? (widget.trip.durationSec * 1000) / (_points.length - 1)
        : 900;
    final int adjusted = (baseMs / _playbackSpeed).round().clamp(80, 2500);
    return Duration(milliseconds: adjusted);
  }

  void _restartTimerIfPlaying() {
    if (!_isPlaying) {
      return;
    }
    _playbackTimer?.cancel();
    _playbackTimer = Timer.periodic(_frameDuration, (_) {
      if (_currentIndex >= _points.length - 1) {
        _pausePlayback();
        return;
      }
      _stepTo(_currentIndex + 1, initiatedByUser: false);
    });
  }

  void _startPlayback() {
    if (_points.length < 2) {
      return;
    }

    if (_currentIndex >= _points.length - 1) {
      setState(() {
        _currentIndex = 0;
      });
      _moveCameraToCurrentPoint();
    }

    setState(() {
      _isPlaying = true;
    });
    _restartTimerIfPlaying();
  }

  void _pausePlayback() {
    _playbackTimer?.cancel();
    if (!mounted) {
      return;
    }
    setState(() {
      _isPlaying = false;
    });
  }

  void _togglePlayback() {
    if (_isPlaying) {
      _pausePlayback();
      return;
    }
    _startPlayback();
  }

  void _moveCameraToCurrentPoint() {
    if (_points.isEmpty) {
      return;
    }
    final LatLng active = _points[_currentIndex];
    double zoom = 16;
    try {
      zoom = _mapController.camera.zoom;
    } catch (_) {
      zoom = 16;
    }
    _mapController.move(active, zoom);
  }

  void _stepTo(int index, {required bool initiatedByUser}) {
    if (_points.isEmpty) {
      return;
    }
    final int clamped = index.clamp(0, _points.length - 1);
    if (initiatedByUser && _isPlaying) {
      _pausePlayback();
    }
    setState(() {
      _currentIndex = clamped;
    });
    _moveCameraToCurrentPoint();
  }

  void _setSpeed(double speed) {
    if (_playbackSpeed == speed) {
      return;
    }
    setState(() {
      _playbackSpeed = speed;
    });
    _restartTimerIfPlaying();
  }

  @override
  Widget build(BuildContext context) {
    final List<LatLng> points = _points;
    final LatLng initial = points.isNotEmpty
        ? points.first
        : const LatLng(0, 0);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text(
          'Detalle del viaje',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
      body: points.isEmpty
          ? const Center(
              child: Text('Este viaje no tiene puntos para reproducir.'),
            )
          : Stack(
              children: <Widget>[
                FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: initial,
                    initialZoom: 15,
                    minZoom: 3,
                    maxZoom: 19,
                  ),
                  children: <Widget>[
                    TileLayer(
                      urlTemplate:
                          'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'com.ontacoche.app',
                    ),
                    PolylineLayer(
                      polylines: <Polyline>[
                        Polyline(
                          points: points,
                          strokeWidth: 4,
                          color: AppColors.brand,
                        ),
                        Polyline(
                          points: points
                              .take(_currentIndex + 1)
                              .toList(growable: false),
                          strokeWidth: 6,
                          color: AppColors.secondary,
                        ),
                      ],
                    ),
                    MarkerLayer(
                      markers: <Marker>[
                        if (points.length >= 2)
                          Marker(
                            point: points.first,
                            width: 30,
                            height: 30,
                            child: const MapCircleMarker(),
                          ),
                        Marker(
                          point: points[_currentIndex],
                          width: 220,
                          height: 110,
                          child: _ActivePointMarker(point: _activeTripPoint),
                        ),
                        if (points.length >= 2)
                          Marker(
                            point: points.last,
                            width: 30,
                            height: 30,
                            child: const MapCircleMarker(),
                          ),
                      ],
                    ),
                  ],
                ),
                Positioned(
                  top: 16,
                  left: 16,
                  right: 16,
                  child: _TripInfoOverlay(trip: widget.trip),
                ),
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 20,
                  child: _PlaybackControls(
                    currentIndex: _currentIndex,
                    totalPoints: points.length,
                    isPlaying: _isPlaying,
                    playbackSpeed: _playbackSpeed,
                    speedOptions: _speedOptions,
                    onPlayPause: _togglePlayback,
                    onPrevious: () =>
                        _stepTo(_currentIndex - 1, initiatedByUser: true),
                    onNext: () =>
                        _stepTo(_currentIndex + 1, initiatedByUser: true),
                    onSpeedChanged: _setSpeed,
                    onSliderChanged: (double value) =>
                        _stepTo(value.round(), initiatedByUser: true),
                  ),
                ),
              ],
            ),
    );
  }
}

class _ActivePointMarker extends StatelessWidget {
  const _ActivePointMarker({required this.point});

  final TripPoint? point;

  @override
  Widget build(BuildContext context) {
    final String speed = point?.speed == null
        ? 'N/D'
        : '${point!.speed!.toStringAsFixed(1)} km/h';
    final String altitude = point?.altitude == null
        ? 'N/D'
        : '${point!.altitude!.toStringAsFixed(1)} m';

    String time = 'N/D';
    if (point?.ts != null) {
      final DateTime local = point!.ts!.toLocal();
      String twoDigits(int v) => v.toString().padLeft(2, '0');
      time =
          '${twoDigits(local.hour)}:${twoDigits(local.minute)}:${twoDigits(local.second)}';
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: AppColors.surfaceContainerLow.withValues(alpha: 0.96),
            borderRadius: BorderRadius.circular(12),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.14),
                blurRadius: 12,
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _MarkerChip(icon: Icons.speed_rounded, value: speed),
              const SizedBox(width: 8),
              _MarkerChip(icon: Icons.height_rounded, value: altitude),
              const SizedBox(width: 8),
              _MarkerChip(icon: Icons.schedule_rounded, value: time),
            ],
          ),
        ),
        const SizedBox(height: 6),
        const MapCircleMarker(),
      ],
    );
  }
}

class _MarkerChip extends StatelessWidget {
  const _MarkerChip({required this.icon, required this.value});

  final IconData icon;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(icon, size: 14, color: AppColors.muted),
        const SizedBox(width: 2),
        Text(
          value,
          style: Theme.of(
            context,
          ).textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
      ],
    );
  }
}

class _PlaybackControls extends StatelessWidget {
  const _PlaybackControls({
    required this.currentIndex,
    required this.totalPoints,
    required this.isPlaying,
    required this.playbackSpeed,
    required this.speedOptions,
    required this.onPlayPause,
    required this.onPrevious,
    required this.onNext,
    required this.onSpeedChanged,
    required this.onSliderChanged,
  });

  final int currentIndex;
  final int totalPoints;
  final bool isPlaying;
  final double playbackSpeed;
  final List<double> speedOptions;
  final VoidCallback onPlayPause;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final ValueChanged<double> onSpeedChanged;
  final ValueChanged<double> onSliderChanged;

  @override
  Widget build(BuildContext context) {
    final int maxIndex = totalPoints - 1;

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(18),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 14,
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(
                'Punto ${currentIndex + 1}/$totalPoints',
                style: Theme.of(
                  context,
                ).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              Wrap(
                spacing: 6,
                children: speedOptions
                    .map(
                      (double speed) => ChoiceChip(
                        label: Text('${speed}x'),
                        selected: playbackSpeed == speed,
                        onSelected: (_) => onSpeedChanged(speed),
                        selectedColor: AppColors.brand.withValues(alpha: 0.2),
                        labelStyle: Theme.of(context).textTheme.labelSmall,
                        visualDensity: VisualDensity.compact,
                      ),
                    )
                    .toList(growable: false),
              ),
            ],
          ),
          Slider(
            value: currentIndex.toDouble(),
            min: 0,
            max: maxIndex.toDouble(),
            divisions: maxIndex > 0 && maxIndex <= 300 ? maxIndex : null,
            onChanged: onSliderChanged,
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              IconButton(
                onPressed: currentIndex > 0 ? onPrevious : null,
                icon: const Icon(Icons.skip_previous_rounded),
              ),
              const SizedBox(width: 6),
              FilledButton.icon(
                onPressed: onPlayPause,
                icon: Icon(
                  isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                ),
                label: Text(isPlaying ? 'Pausar' : 'Reproducir'),
              ),
              const SizedBox(width: 6),
              IconButton(
                onPressed: currentIndex < maxIndex ? onNext : null,
                icon: const Icon(Icons.skip_next_rounded),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TripInfoOverlay extends StatelessWidget {
  const _TripInfoOverlay({required this.trip});

  final DeviceTrip trip;

  @override
  Widget build(BuildContext context) {
    String twoDigits(int v) => v.toString().padLeft(2, '0');
    final DateTime start = trip.startedAt.toLocal();
    final DateTime end = trip.endedAt.toLocal();
    final String time =
        '${twoDigits(start.hour)}:${twoDigits(start.minute)} - ${twoDigits(end.hour)}:${twoDigits(end.minute)}';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(16),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 12,
          ),
        ],
      ),
      child: Row(
        children: <Widget>[
          _InfoChip(
            icon: Icons.alt_route_rounded,
            value: '${(trip.distanceM / 1000).toStringAsFixed(2)} km',
          ),
          const SizedBox(width: 12),
          _InfoChip(icon: Icons.schedule_rounded, value: time),
          const SizedBox(width: 12),
          Expanded(
            child: _InfoChip(
              icon: Icons.speed_rounded,
              value: '${trip.maxSpeedKph.toStringAsFixed(0)} km/h',
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.icon, required this.value});

  final IconData icon;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(icon, size: 16, color: AppColors.muted),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            value,
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w600),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
