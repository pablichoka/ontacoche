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
import '../providers/vehicle_state_provider.dart';
import '../theme/app_colors.dart';
import '../widgets/dynamic_island.dart';
import '../widgets/expressive_indicator.dart';
import '../widgets/map_circle_marker.dart';

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
              Builder(
                builder: (BuildContext ctx) {
                  final List<Geofence> sourceList =
                      managedGeofencesState.hasValue
                      ? managedGeofencesState.value!
                      : (geofencesState.hasValue
                            ? geofencesState.value!
                            : const <Geofence>[]);
                  final bool hasParking = sourceList.any(
                    (g) => g.priority == 100,
                  );
                  if (!hasParking) {
                    return const SizedBox();
                  }

                  return Padding(
                    padding: const EdgeInsets.only(bottom: 20),
                    child: FloatingActionButton(
                      shape: const CircleBorder(),
                      clipBehavior: Clip.hardEdge,
                      backgroundColor: AppColors.surfaceContainerLow,
                      onPressed: () async {
                        if (_isParkingDeleting) return;

                        final searchList =
                            managedGeofencesState.valueOrNull ??
                            geofencesState.valueOrNull ??
                            const <Geofence>[];
                        final parking = searchList
                            .where((g) => g.priority == 100)
                            .firstOrNull;

                        if (parking == null) {
                          if (!context.mounted) return;
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

                          if (!context.mounted) return;

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
                          if (!mounted) return;
                          ScaffoldMessenger.of(context).hideCurrentSnackBar();
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              behavior: SnackBarBehavior.floating,
                              margin: const EdgeInsets.fromLTRB(16, 0, 16, 100),
                              content: Text('Error borrando: $e'),
                            ),
                          );
                        } finally {
                          if (context.mounted) {
                            setState(() => _isParkingDeleting = false);
                          }
                        }
                      },
                      child: _isParkingDeleting
                          ? const ExpressiveIndicator(
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
                },
              ),
              // FAB
              Builder(
                builder: (BuildContext ctx) {
                  final List<Geofence> sourceList2 =
                      managedGeofencesState.hasValue
                      ? managedGeofencesState.value!
                      : (geofencesState.hasValue
                            ? geofencesState.value!
                            : const <Geofence>[]);
                  final bool hasParking = sourceList2.any(
                    (g) => g.priority == 100,
                  );

                  return FloatingActionButton(
                    shape: const CircleBorder(),
                    clipBehavior: Clip.hardEdge,
                    backgroundColor: hasParking
                        ? AppColors.muted
                        : Color(0XFF063971),
                    onPressed: () async {
                      final searchList2 =
                          managedGeofencesState.valueOrNull ??
                          geofencesState.valueOrNull ??
                          const <Geofence>[];
                      final bool hasParkingActual = searchList2.any(
                        (g) => g.priority == 100,
                      );

                      if (hasParkingActual) {
                        if (!context.mounted) return;
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
                        if (!mounted) return;
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
                        final String deviceId = ref
                            .read(deviceIdentProvider)
                            .trim();
                        if (deviceId.isEmpty) {
                          if (!mounted) return;
                          ScaffoldMessenger.of(context).hideCurrentSnackBar();
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('DEVICE_IDENT no configurado.'),
                            ),
                          );
                          return;
                        }

                        final String name =
                            'parking-${DateTime.now().toUtc().millisecondsSinceEpoch}';
                        // get configured diameter (meters) from settings
                        double radiusMeters = 100.0;
                        try {
                          final settings = await ref.read(
                            settingsRepositoryProvider.future,
                          );
                          radiusMeters = settings.parkingRadiusMeters;
                        } catch (_) {
                          // fallback to default
                          radiusMeters = 100.0;
                        }

                        await ref
                            .read(vercelConnectorServiceProvider)
                            .createCircleGeofence(
                              deviceId: deviceId,
                              name: name,
                              radiusMeters: radiusMeters,
                              latitude: _latestPosition!.latitude,
                              longitude: _latestPosition!.longitude,
                            );

                        ref.invalidate(managedGeofencesProvider);
                        ref.invalidate(deviceGeofencesProvider);

                        if (!context.mounted) return;

                        ScaffoldMessenger.of(context).hideCurrentSnackBar();
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            behavior: SnackBarBehavior.floating,
                            margin: EdgeInsets.fromLTRB(16, 0, 16, 100),
                            content: Text('Parking creado.'),
                          ),
                        );
                      } catch (e) {
                        if (!mounted) return;
                        ScaffoldMessenger.of(context).hideCurrentSnackBar();
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            behavior: SnackBarBehavior.floating,
                            margin: const EdgeInsets.fromLTRB(16, 0, 16, 100),
                            content: Text('Error creando parking: $e'),
                          ),
                        );
                      } finally {
                        if (context.mounted) {
                          setState(() => _isParkingCreating = false);
                        }
                      }
                    },
                    child: _isParkingCreating
                        ? const ExpressiveIndicator(
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
                },
              ),
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
      Marker(
        point: center,
        width: 48,
        height: 48,
        child: const MapCircleMarker(),
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
        .map((Geofence geofence) {
          debugPrint(
            'map geofence id=${geofence.id} name=${geofence.name} radius_m=${geofence.radius}',
          );
          return CircleMarker(
            point: LatLng(geofence.latitude!, geofence.longitude!),
            // `geofence.radius` is in meters
            radius: geofence.radius!,
            useRadiusInMeter: true,
            color: Colors.blue.withValues(alpha: 0.18),
            borderColor: Colors.blue,
            borderStrokeWidth: 2,
          );
        })
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
                  (GeofencePoint point) =>
                      LatLng(point.latitude, point.longitude),
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

// using shared ExpressiveIndicator widget from widgets/expressive_indicator.dart

// using shared ExpressiveIndicator widget from widgets/expressive_indicator.dart
