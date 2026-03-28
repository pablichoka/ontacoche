import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:ontacoche/providers/settings_provider.dart';

import '../models/device_alert.dart';
import '../models/device_position.dart';
import '../models/geofence.dart';
import '../models/tracking_flow.dart';
import '../providers/api_provider.dart';
import '../providers/telemetry_provider.dart';
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
  bool _isParkingCreating = false;
  bool _isParkingDeleting = false;
  ProviderSubscription<InitialTrackingState>? _initialTrackingSubscription;
  ProviderSubscription<AsyncValue<DevicePosition>>? _positionSubscription;
  ProviderSubscription<AsyncValue<DeviceAlert>>? _alertSubscription;
  Timer? _geofenceRefreshTimer;

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
            _latestPosition == null ||
            _hasAnimatedToPosition ||
            next.source == InitialTrackingSource.remote;
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

    _geofenceRefreshTimer?.cancel();
    _geofenceRefreshTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (!mounted) {
        return;
      }
      ref.invalidate(deviceGeofencesProvider);
    });
  }

  @override
  void dispose() {
    _initialTrackingSubscription?.close();
    _positionSubscription?.close();
    _alertSubscription?.close();
    _geofenceRefreshTimer?.cancel();
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
      _mapController.move(
        target,
        _hasAnimatedToPosition ? _mapController.camera.zoom : 16,
      );
      _hasAnimatedToPosition = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    final InitialTrackingState initialTrackingState = ref.watch(
      initialTrackingProvider,
    );
    final AsyncValue<List<Geofence>> geofencesState = ref.watch(
      deviceGeofencesProvider,
    );
    final AsyncValue<List<Geofence>> managedGeofencesState = ref.watch(
      managedGeofencesProvider,
    );

    final DevicePosition? displayPosition =
        _latestPosition ?? initialTrackingState.position;

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
              PolygonLayer(
                polygons: _buildGeofencePolygons(geofencesState.value!),
              ),
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
        // Quick action: create parking geofence (bottom-right)
        Positioned(
          right: 16,
          bottom: 150,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              // delete parking button (shown when parking exists)
              Builder(builder: (BuildContext ctx) {
                final List<Geofence> sourceList = managedGeofencesState.hasValue
                    ? managedGeofencesState.value!
                    : (geofencesState.hasValue ? geofencesState.value! : const <Geofence>[]);
                final bool hasParking = sourceList.any((g) => g.priority == 100);
                if (!hasParking) {
                  return const SizedBox(
                    
                  );
                }

                return Padding(
                  padding: const EdgeInsets.only(bottom: 20),
                  child: FloatingActionButton(
                    shape: const CircleBorder(),
                    clipBehavior: Clip.hardEdge,
                    backgroundColor: Colors.white,
                    onPressed: () async {
                      if (_isParkingDeleting) return;
                      Geofence? parking;
                      final List<Geofence> searchList = managedGeofencesState.hasValue
                          ? managedGeofencesState.value!
                          : (geofencesState.hasValue ? geofencesState.value! : const <Geofence>[]);
                      for (final Geofence g in searchList) {
                        if (g.priority == 100) {
                          parking = g;
                          break;
                        }
                      }
                      if (parking == null) {
                        ScaffoldMessenger.of(context).hideCurrentSnackBar();
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('No se encontró parking a borrar.'),
                          ),
                        );
                        return;
                      }

                      setState(() => _isParkingDeleting = true);
                      try {
                        await ref
                            .read(vercelConnectorServiceProvider)
                            .deleteGeofence(parking.id);
                        ref.invalidate(managedGeofencesProvider);
                        ref.invalidate(deviceGeofencesProvider);
                        ScaffoldMessenger.of(context).hideCurrentSnackBar();
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            behavior: SnackBarBehavior.floating,
                            margin: EdgeInsets.fromLTRB(16, 0, 16, 100),
                            content: Text('Parking eliminado.'),
                          ),
                        );
                      } catch (e) {
                        ScaffoldMessenger.of(context).hideCurrentSnackBar();
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            behavior: SnackBarBehavior.floating,
                            margin: const EdgeInsets.fromLTRB(16, 0, 16, 100),
                            content: Text('Error borrando: $e'),
                          ),
                        );
                      } finally {
                        if (mounted) setState(() => _isParkingDeleting = false);
                      }
                    },
                    child: _isParkingDeleting
                        ? const _ExpressiveIndicator(
                            color: Colors.redAccent,
                            strokeWidth: 3,
                            size: 20,
                          )
                        : const Icon(
                            Icons.delete_outline_rounded,
                            color: Colors.redAccent,
                            size: 24,
                          ),
                  ),
                );
              }),
              // FAB
              Builder(builder: (BuildContext ctx) {
                final List<Geofence> sourceList2 = managedGeofencesState.hasValue
                    ? managedGeofencesState.value!
                    : (geofencesState.hasValue ? geofencesState.value! : const <Geofence>[]);
                final bool hasParking = sourceList2.any((g) => g.priority == 100);

                return FloatingActionButton(
                  shape: const CircleBorder(),
                  clipBehavior: Clip.hardEdge,
                  backgroundColor:
                      hasParking ? Colors.grey.shade400 : Colors.blue,
                    onPressed: () async {
                    if (hasParking) {
                      ScaffoldMessenger.of(context).hideCurrentSnackBar();
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          behavior: SnackBarBehavior.floating,
                          margin: EdgeInsets.fromLTRB(16, 0, 16, 100),
                          content: Text('Ya existe un parking creado.'),
                        ),
                      );
                      return;
                    }

                    if (_latestPosition == null) {
                      ScaffoldMessenger.of(context).hideCurrentSnackBar();
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          behavior: SnackBarBehavior.floating,
                          margin: EdgeInsets.fromLTRB(16, 0, 16, 100),
                          content: Text('No hay ubicación disponible.'),
                        ),
                      );
                      return;
                    }

                    if (_isParkingCreating) return;

                    setState(() => _isParkingCreating = true);
                    try {
                      final String deviceId = ref.read(deviceIdentProvider).trim();
                      if (deviceId.isEmpty) {
                        ScaffoldMessenger.of(context).hideCurrentSnackBar();
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('DEVICE_IDENT no configurado.'),
                          ),
                        );
                        return;
                      }

                      final String name = 'parking-${DateTime.now().toUtc().millisecondsSinceEpoch}';
                      // get configured diameter (meters) from settings
                      double diameterMeters = 100.0;
                      try {
                        final settings = await ref.read(settingsRepositoryProvider.future);
                        diameterMeters = settings.parkingDiameterMeters;
                      } catch (_) {
                        // fallback to default
                        diameterMeters = 100.0;
                      }
                      final double radiusKm = (diameterMeters / 2.0) / 1000.0;

                      await ref
                          .read(vercelConnectorServiceProvider)
                          .createCircleGeofence(
                        deviceId: deviceId,
                        name: name,
                        priority: 100,
                        latitude: _latestPosition!.latitude,
                        longitude: _latestPosition!.longitude,
                        radiusKm: radiusKm,
                      );

                      ref.invalidate(managedGeofencesProvider);
                      ref.invalidate(deviceGeofencesProvider);

                        ScaffoldMessenger.of(context).hideCurrentSnackBar();
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            behavior: SnackBarBehavior.floating,
                            margin: EdgeInsets.fromLTRB(16, 0, 16, 100),
                            content: Text('Parking creado.'),
                          ),
                        );
                    } catch (e) {
                        ScaffoldMessenger.of(context).hideCurrentSnackBar();
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            behavior: SnackBarBehavior.floating,
                            margin: const EdgeInsets.fromLTRB(16, 0, 16, 100),
                            content: Text('Error creando parking: $e'),
                          ),
                        );
                    } finally {
                      if (mounted) setState(() => _isParkingCreating = false);
                    }
                  },
                  child: _isParkingCreating
                      ? const _ExpressiveIndicator(
                          color: Colors.white,
                          strokeWidth: 3,
                          size: 20,
                        )
                      : const Icon(
                          Icons.local_parking,
                          size: 24,
                          color: Colors.white,
                        ),
                );
              }),
            ],
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
      Marker(point: center, width: 48, height: 48, child: const _GpsMarker()),
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
              geofence.type == GeofenceType.polygon &&
              geofence.points.isNotEmpty,
        )
        .map(
          (Geofence geofence) => Polygon(
            points: geofence.points
                .map(
                  (GeofencePoint point) => LatLng(point.latitude, point.longitude),
                )
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

class _ExpressiveIndicator extends StatefulWidget {
  const _ExpressiveIndicator({
    this.color = Colors.white,
    this.strokeWidth = 3.0,
    this.size = 20.0,
  });

  final Color color;
  final double strokeWidth;
  final double size;

  @override
  State<_ExpressiveIndicator> createState() => _ExpressiveIndicatorState();
}

class _ExpressiveIndicatorState extends State<_ExpressiveIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
    _scale = TweenSequence<double>(
      <TweenSequenceItem<double>>[
        TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.08), weight: 40),
        TweenSequenceItem(tween: Tween(begin: 1.08, end: 0.94), weight: 40),
        TweenSequenceItem(tween: Tween(begin: 0.94, end: 1.0), weight: 20),
      ],
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: ScaleTransition(
        scale: _scale,
        child: CircularProgressIndicator(
          strokeWidth: widget.strokeWidth,
          valueColor: AlwaysStoppedAnimation<Color>(widget.color),
          backgroundColor: widget.color.withOpacity(0.24),
        ),
      ),
    );
  }
}
