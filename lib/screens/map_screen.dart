import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../models/device_alert.dart';
import '../models/device_position.dart';
import '../models/geofence.dart';
import '../models/tracking_flow.dart';
import '../providers/api_provider.dart';
import '../providers/mqtt_provider.dart';
import '../providers/tracking_provider.dart';
import '../widgets/dynamic_island.dart';


class MapScreen extends ConsumerStatefulWidget {

  const MapScreen({super.key});

  @override
  ConsumerState<MapScreen> createState() => _MapScreenState();
}


class _MapScreenState extends ConsumerState<MapScreen> {
  static const LatLng _fallbackCenter = LatLng(0, 0);

  final MapController _mapController = MapController();
  DevicePosition? _latestPosition;
  bool _hasAnimatedToPosition = false;
  ProviderSubscription<InitialTrackingState>? _initialTrackingSubscription;
  ProviderSubscription<AsyncValue<DevicePosition>>? _positionSubscription;
  ProviderSubscription<AsyncValue<DeviceAlert>>? _alertSubscription;

  @override
  void initState() {
    super.initState();

    _initialTrackingSubscription = ref.listenManual<InitialTrackingState>(
      initialTrackingProvider,
      (_, InitialTrackingState next) {
        if (next.position == null) {
          return;
        }

        final bool shouldMoveMap =
            _latestPosition == null || _hasAnimatedToPosition || next.source == InitialTrackingSource.remote;
        _primePosition(next.position!, moveMap: shouldMoveMap);
      },
    );

    _positionSubscription = ref.listenManual<AsyncValue<DevicePosition>>(
      positionStreamProvider,
      (_, AsyncValue<DevicePosition> next) {
        next.whenData((DevicePosition position) {
          _primePosition(position, moveMap: true);
        });
      },
    );

    _alertSubscription = ref.listenManual<AsyncValue<DeviceAlert>>(
      alertStreamProvider,
      (_, AsyncValue<DeviceAlert> next) {
        next.whenData((DeviceAlert alert) {
          if (alert.type == DeviceAlertType.geofence) {
            ref.invalidate(deviceGeofencesProvider);
          }
        });
      },
    );
  }

  @override
  void dispose() {
    _initialTrackingSubscription?.close();
    _positionSubscription?.close();
    _alertSubscription?.close();
    _mapController.dispose();
    super.dispose();
  }

  void _primePosition(DevicePosition position, {bool moveMap = false}) {

    if (!mounted) {
      return;
    }

    setState(() {
      _latestPosition = position;
    });

    if (moveMap) {
      final LatLng target = LatLng(position.latitude, position.longitude);
      _mapController.move(target, _hasAnimatedToPosition ? _mapController.camera.zoom : 16);
      _hasAnimatedToPosition = true;
    }
  }

@override
  Widget build(BuildContext context) {
    final InitialTrackingState initialTrackingState = ref.watch(initialTrackingProvider);
    final AsyncValue<List<Geofence>> geofencesState = ref.watch(deviceGeofencesProvider);
    
    final DevicePosition? displayPosition = _latestPosition ?? initialTrackingState.position;

    final LatLng initialMapCenter = displayPosition == null
        ? _fallbackCenter
        : LatLng(displayPosition.latitude, displayPosition.longitude);
    final double initialMapZoom = displayPosition != null ? 12.0 : 3.0;

    final LatLng center = displayPosition == null
        ? initialMapCenter
        : LatLng(displayPosition.latitude, displayPosition.longitude);

    return Stack(
      children: <Widget>[
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: initialMapCenter,
            initialZoom: initialMapZoom,
            minZoom: 3,
            maxZoom: 19,
          ),
          children: <Widget>[
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.ontacoche.app',
            ),
            if (geofencesState.hasValue && geofencesState.value!.isNotEmpty)
              CircleLayer(
                circles: _buildGeofenceCircles(geofencesState.value!),
              ),
            if (geofencesState.hasValue && geofencesState.value!.isNotEmpty)
              PolygonLayer(polygons: _buildGeofencePolygons(geofencesState.value!)),
            MarkerLayer(markers: _buildMarkers(displayPosition, center)),
          ],
        ),
        // Dynamic Island Pill
        const Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Align(
                alignment: Alignment.topCenter,
                child: DynamicIsland(),
              ),
            ),
          ),
        ),
      ],
    );
  }

  List<Marker> _buildMarkers(DevicePosition? position, LatLng center) {
    if (position == null) {
      return const <Marker>[];
    }

    return <Marker>[
      Marker(
        point: center,
        width: 48,
        height: 48,
        child: const _GpsMarker(),
      ),
    ];
  }

  List<CircleMarker> _buildGeofenceCircles(List<Geofence> geofences) {
    return geofences
        .where(
          (Geofence geofence) =>
              geofence.type == GeofenceType.circle &&
              geofence.latitude != null &&
              geofence.longitude != null &&
              geofence.radius != null,
        )
        .map(
          (Geofence geofence) => CircleMarker(
            point: LatLng(geofence.latitude!, geofence.longitude!),
            radius: geofence.radius! * 1000,
            useRadiusInMeter: true,
            color: Colors.blue.withValues(alpha: 0.18),
            borderColor: Colors.blue,
            borderStrokeWidth: 2,
          ),
        )
        .toList(growable: false);
  }

  List<Polygon> _buildGeofencePolygons(List<Geofence> geofences) {
    return geofences
        .where(
          (Geofence geofence) =>
              geofence.type == GeofenceType.polygon && geofence.points.isNotEmpty,
        )
        .map(
          (Geofence geofence) => Polygon(
            points: geofence.points
                .map((GeofencePoint point) => LatLng(point.latitude, point.longitude))
                .toList(growable: false),
            color: Colors.blue.withValues(alpha: 0.18),
            borderColor: Colors.blue,
            borderStrokeWidth: 2,
          ),
        )
        .toList(growable: false);
  }
}

class _GpsMarker extends StatelessWidget {
  const _GpsMarker();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white,
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 18,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: DecoratedBox(
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: Color(0xFF1D4ED8),
          ),
          child: const Icon(
            Icons.navigation_rounded,
            color: Colors.white,
            size: 30,
          ),
        ),
      ),
    );
  }
}

