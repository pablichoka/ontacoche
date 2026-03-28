import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../models/trip.dart';
import '../theme/app_colors.dart';
import '../widgets/map_circle_marker.dart';

class TripPlaybackScreen extends StatefulWidget {
  const TripPlaybackScreen({super.key, required this.trip});

  final Trip trip;

  @override
  State<TripPlaybackScreen> createState() => _TripPlaybackScreenState();
}

class _TripPlaybackScreenState extends State<TripPlaybackScreen>
    with SingleTickerProviderStateMixin {
  late final List<LatLng> _points;
  late final MapController _mapController;
  late AnimationController _animController;
  late Animation<double> _animation;

  int _currentIndex = 0;
  bool _playing = false;
  int _speedMultiplier = 1;
  LatLng _currentPosition = const LatLng(0, 0);

  static const int _baseMs = 3000;

  @override
  void initState() {
    super.initState();
    _points = widget.trip.routePoints
        .map((RoutePoint p) => LatLng(p.lat, p.lng))
        .toList(growable: false);
    _currentPosition = _points.isNotEmpty ? _points.first : const LatLng(0, 0);
    _mapController = MapController();
    _animController = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: _baseMs),
    );
    _animation = Tween<double>(begin: 0, end: 1).animate(_animController);
    _animation.addListener(_onAnimationTick);
    _animController.addStatusListener(_onAnimationStatus);
  }

  @override
  void dispose() {
    _animController.removeListener(_onAnimationTick);
    _animController.removeStatusListener(_onAnimationStatus);
    _animController.dispose();
    _mapController.dispose();
    super.dispose();
  }

  void _onAnimationTick() {
    if (_currentIndex >= _points.length - 1) return;
    final LatLng from = _points[_currentIndex];
    final LatLng to = _points[_currentIndex + 1];
    final double t = _animation.value;
    final double lat = from.latitude + (to.latitude - from.latitude) * t;
    final double lng = from.longitude + (to.longitude - from.longitude) * t;
    setState(() {
      _currentPosition = LatLng(lat, lng);
    });
    try {
      _mapController.move(_currentPosition, _mapController.camera.zoom);
    } catch (_) {}
  }

  void _onAnimationStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      if (_currentIndex < _points.length - 2) {
        setState(() {
          _currentIndex++;
        });
        _animController.duration = Duration(
          milliseconds: _baseMs ~/ _speedMultiplier,
        );
        _animController.forward(from: 0);
      } else {
        setState(() {
          _playing = false;
          _currentIndex = _points.length - 1;
          _currentPosition = _points.last;
        });
      }
    }
  }

  void _togglePlayPause() {
    if (_points.length < 2) return;
    if (_playing) {
      _animController.stop();
      setState(() => _playing = false);
    } else {
      if (_currentIndex >= _points.length - 1) {
        _currentIndex = 0;
        _currentPosition = _points.first;
      }
      _animController.duration = Duration(
        milliseconds: _baseMs ~/ _speedMultiplier,
      );
      _animController.forward(from: 0);
      setState(() => _playing = true);
    }
  }

  void _setSpeed(int multiplier) {
    setState(() => _speedMultiplier = multiplier);
    if (_playing) {
      final double currentValue = _animController.value;
      _animController.duration = Duration(milliseconds: _baseMs ~/ multiplier);
      _animController.forward(from: currentValue);
    }
  }

  RoutePoint get _currentRoutePoint {
    final int idx = _currentIndex.clamp(0, widget.trip.routePoints.length - 1);
    return widget.trip.routePoints[idx];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text(
          'Reproducir trayecto',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
      body: Stack(
        children: <Widget>[
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _points.isNotEmpty
                  ? _points.first
                  : const LatLng(0, 0),
              initialZoom: 15,
              minZoom: 3,
              maxZoom: 19,
            ),
            children: <Widget>[
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.ontacoche.app',
              ),
              PolylineLayer(
                polylines: <Polyline>[
                  Polyline(
                    points: _points,
                    strokeWidth: 4,
                    color: AppColors.brand,
                  ),
                ],
              ),
              MarkerLayer(
                markers: <Marker>[
                  if (_points.isNotEmpty)
                    Marker(
                      point: _points.first,
                      width: 36,
                      height: 36,
                      child: const MapCircleMarker(),
                    ),
                  if (_points.length >= 2)
                    Marker(
                      point: _points.last,
                      width: 36,
                      height: 36,
                      child: const MapCircleMarker(),
                    ),
                  Marker(
                    point: _currentPosition,
                    width: 40,
                    height: 40,
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
            child: _InfoOverlay(point: _currentRoutePoint),
          ),
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: _ControlPanel(
              playing: _playing,
              speedMultiplier: _speedMultiplier,
              onPlayPause: _togglePlayPause,
              onSetSpeed: _setSpeed,
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoOverlay extends StatelessWidget {
  const _InfoOverlay({required this.point});

  final RoutePoint point;

  @override
  Widget build(BuildContext context) {
    String twoDigits(int v) => v.toString().padLeft(2, '0');
    final DateTime t = point.timestamp.toLocal();
    final String time =
        '${twoDigits(t.hour)}:${twoDigits(t.minute)}:${twoDigits(t.second)}';

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
            icon: Icons.speed_rounded,
            value: '${point.speed.toStringAsFixed(0)} km/h',
          ),
          const SizedBox(width: 12),
          _InfoChip(icon: Icons.schedule_rounded, value: time),
          const SizedBox(width: 12),
          Expanded(
            child: _InfoChip(
              icon: Icons.pin_drop_rounded,
              value:
                  '${point.lat.toStringAsFixed(4)}, ${point.lng.toStringAsFixed(4)}',
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

class _ControlPanel extends StatelessWidget {
  const _ControlPanel({
    required this.playing,
    required this.speedMultiplier,
    required this.onPlayPause,
    required this.onSetSpeed,
  });

  final bool playing;
  final int speedMultiplier;
  final VoidCallback onPlayPause;
  final ValueChanged<int> onSetSpeed;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(
        24,
        20,
        24,
        20 + MediaQuery.of(context).padding.bottom,
      ),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 20,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          IconButton(
            onPressed: onPlayPause,
            icon: Icon(
              playing
                  ? Icons.pause_circle_filled_rounded
                  : Icons.play_circle_filled_rounded,
              size: 48,
              color: AppColors.brand,
            ),
          ),
          const SizedBox(width: 24),
          _SpeedButton(
            label: 'x1',
            active: speedMultiplier == 1,
            onTap: () => onSetSpeed(1),
          ),
          const SizedBox(width: 8),
          _SpeedButton(
            label: 'x2',
            active: speedMultiplier == 2,
            onTap: () => onSetSpeed(2),
          ),
          const SizedBox(width: 8),
          _SpeedButton(
            label: 'x4',
            active: speedMultiplier == 4,
            onTap: () => onSetSpeed(4),
          ),
        ],
      ),
    );
  }
}

class _SpeedButton extends StatelessWidget {
  const _SpeedButton({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: active ? AppColors.brand : AppColors.brandSoft,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: active ? AppColors.surface : AppColors.brand,
          ),
        ),
      ),
    );
  }
}

