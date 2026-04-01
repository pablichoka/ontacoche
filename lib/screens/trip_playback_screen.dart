import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../models/device_trip.dart';
import '../theme/app_colors.dart';
import '../widgets/map_circle_marker.dart';

class TripPlaybackScreen extends StatelessWidget {
  const TripPlaybackScreen({super.key, required this.trip});

  final DeviceTrip trip;

  @override
  Widget build(BuildContext context) {
    final List<LatLng> points = trip.pathPoints;
    final LatLng initial = points.isNotEmpty ? points.first : const LatLng(0, 0);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text(
          'Detalle del viaje',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
      body: Stack(
        children: <Widget>[
          FlutterMap(
            options: MapOptions(
              initialCenter: initial,
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
                    points: points,
                    strokeWidth: 4,
                    color: AppColors.brand,
                  ),
                ],
              ),
              MarkerLayer(
                markers: <Marker>[
                  if (points.isNotEmpty)
                    Marker(
                      point: points.first,
                      width: 36,
                      height: 36,
                      child: const MapCircleMarker(),
                    ),
                  if (points.length >= 2)
                    Marker(
                      point: points.last,
                      width: 36,
                      height: 36,
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
            child: _TripInfoOverlay(trip: trip),
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


