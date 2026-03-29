import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:ontacoche/theme/app_colors.dart';
import 'package:ontacoche/widgets/expressive_indicator.dart';
import 'package:ontacoche/widgets/map_circle_marker.dart';

import '../models/geofence.dart';
import '../providers/api_provider.dart';
import '../providers/vehicle_state_provider.dart';
import '../widgets/geofence/geofence_editor_card.dart';
import '../widgets/geofence/geofence_list_tile.dart';

class GeofenceManagerScreen extends ConsumerStatefulWidget {
  const GeofenceManagerScreen({super.key});

  @override
  ConsumerState<GeofenceManagerScreen> createState() =>
      _GeofenceManagerScreenState();
}

class _GeofenceManagerScreenState extends ConsumerState<GeofenceManagerScreen> {
  final MapController _mapController = MapController();
  double _currentZoom = 15.0;
  StreamSubscription? _mapEventSub;
  bool _didRecentreEditor = false;
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _radiusController = TextEditingController(
    text: '100',
  );
  final String _radiusUnitDefault = 'm';
  String _radiusUnit = 'm';

  LatLng? _draftCenter;
  bool _isPickingCenter = false;
  // Polygon draft state
  List<LatLng> _draftPath = <LatLng>[];
  bool _isDrawingPolygon = false;
  // editor type: circle (default) or polygon
  GeofenceType _editorType = GeofenceType.circle;
  int? _selectedVertexIndex;
  bool _isMovingVertex = false;
  bool _isSaving = false;
  int? _editingGeofenceId;
  bool _showEditor = false;
  final Set<int> _deletingIds = <int>{};

  @override
  void dispose() {
    _mapEventSub?.cancel();
    _nameController.dispose();
    _radiusController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    // keep track of zoom via map events to preserve user zoom
    _mapEventSub = _mapController.mapEventStream.listen((dynamic ev) {
      try {
        final dynamic z = (ev as dynamic).zoom;
        if (z is double) {
          _currentZoom = z;
        }
      } catch (_) {
        // ignore events that don't have zoom
      }
    });
  }

  void _startCreateMode() {
    setState(() {
      _editingGeofenceId = null;
      _nameController.text = '';
      _radiusController.text = '100';
      _radiusUnit = _radiusUnitDefault;
      _draftCenter = null;
      _isPickingCenter = false;
      _draftPath = <LatLng>[];
      _isDrawingPolygon = false;
      _editorType = GeofenceType.circle;
      _showEditor = true;
      _didRecentreEditor = false;
    });
  }

  void _exitEditor() {
    setState(() {
      _editingGeofenceId = null;
      _nameController.text = '';
      _radiusController.text = '100';
      _radiusUnit = _radiusUnitDefault;
      _draftCenter = null;
      _draftPath = <LatLng>[];
      _isDrawingPolygon = false;
      _editorType = GeofenceType.circle;
      _selectedVertexIndex = null;
      _isMovingVertex = false;
      _showEditor = false;
      _didRecentreEditor = false;
    });
  }

  void _loadForEdit(Geofence geofence) {
    setState(() {
      _showEditor = true;
      _editingGeofenceId = geofence.id;
      _nameController.text = geofence.name;
      _isPickingCenter = false;

      if (geofence.type == GeofenceType.circle &&
          geofence.latitude != null &&
          geofence.longitude != null &&
          geofence.radius != null) {
        _editorType = GeofenceType.circle;
        // geofence.radius is in meters; display converted value according to selected unit
        final double meters = geofence.radius!;
        final double displayFactor = _radiusUnit == 'km'
            ? 1000.0
            : (_radiusUnit == 'hm' ? 100.0 : 1.0);
        final double displayValue = meters / displayFactor;
        _radiusController.text = displayValue.toStringAsFixed(
          _radiusUnit == 'm' ? 0 : 3,
        );
        _draftCenter = LatLng(geofence.latitude!, geofence.longitude!);
        _draftPath = <LatLng>[];
        _isDrawingPolygon = false;
        // mark as recentred so the generic "recenter to vehicle" logic
        // in build() does not override this intended recentering.
        _didRecentreEditor = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          try {
            _mapController.move(_draftCenter!, _currentZoom);
          } catch (_) {
            // ignore if controller not ready
          }
        });
      } else if (geofence.type == GeofenceType.polygon &&
          geofence.points.isNotEmpty) {
        _editorType = GeofenceType.polygon;
        _draftPath = geofence.points
            .map((p) => LatLng(p.latitude, p.longitude))
            .toList(growable: true);
        _draftCenter = null;
        _isDrawingPolygon = false;
        // compute a simple centroid for the polygon and recentre to it.
        // also mark as recentred to prevent the vehicle recenter logic
        // from overriding this.
        _didRecentreEditor = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          try {
            double sumLat = 0.0;
            double sumLon = 0.0;
            for (final p in _draftPath) {
              sumLat += p.latitude;
              sumLon += p.longitude;
            }
            final LatLng centroid = LatLng(
              sumLat / _draftPath.length,
              sumLon / _draftPath.length,
            );
            _mapController.move(centroid, _currentZoom);
          } catch (_) {
            // ignore if controller not ready
          }
        });
      } else {
        final messenger = ScaffoldMessenger.of(context);
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(
          const SnackBar(
            behavior: SnackBarBehavior.fixed,
            content: Text('Tipo de geovalla no editable en este modo.'),
          ),
        );
        _editingGeofenceId = null;
      }
    });
  }

  Future<void> _save() async {
    if (_isSaving) return;

    final String name = _nameController.text.trim();
    final double? radiusValue = double.tryParse(
      _radiusController.text.trim().replaceAll(',', '.'),
    );

    if (name.isEmpty) {
      _showError('El nombre es obligatorio.');
      return;
    }
    if (_editorType == GeofenceType.circle && _draftCenter == null) {
      _showError('Selecciona un centro en el mapa.');
      return;
    }
    if (_editorType == GeofenceType.circle &&
        (radiusValue == null || radiusValue <= 0)) {
      _showError('El radio debe ser un numero mayor que 0.');
      return;
    }
    if (_editorType == GeofenceType.polygon && _draftPath.length < 3) {
      _showError('Un polígono necesita al menos 3 puntos.');
      return;
    }

    final String deviceId = ref.read(deviceIdentProvider).trim();
    if (deviceId.isEmpty) {
      _showError('No hay DEVICE_IDENT configurado.');
      return;
    }

    setState(() => _isSaving = true);

    try {
      final service = ref.read(vercelConnectorServiceProvider);
      if (_editorType == GeofenceType.circle) {
        final double factor = _radiusUnit == 'km'
            ? 1000.0
            : (_radiusUnit == 'hm' ? 100.0 : 1.0);
        final double radiusMeters = (radiusValue ?? 0.0) * factor;

        if (_editingGeofenceId == null) {
          await service.createCircleGeofence(
            deviceId: deviceId,
            name: name,
            latitude: _draftCenter!.latitude,
            longitude: _draftCenter!.longitude,
            radiusMeters: radiusMeters,
          );
        } else {
          await service.updateCircleGeofence(
            geofenceId: _editingGeofenceId!,
            name: name,
            latitude: _draftCenter!.latitude,
            longitude: _draftCenter!.longitude,
            radiusMeters: radiusMeters,
          );
        }
      } else {
        final List<Map<String, double>> path = _draftPath
            .map(
              (LatLng p) => <String, double>{
                'lat': p.latitude,
                'lon': p.longitude,
              },
            )
            .toList(growable: false);
        if (_editingGeofenceId == null) {
          await service.createPolygonGeofence(
            deviceId: deviceId,
            name: name,
            path: path,
          );
        } else {
          await service.updatePolygonGeofence(
            geofenceId: _editingGeofenceId!,
            name: name,
            path: path,
          );
        }
      }

      ref.invalidate(managedGeofencesProvider);
      ref.invalidate(deviceGeofencesProvider);
      if (mounted) {
        final messenger = ScaffoldMessenger.of(context);
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(
          const SnackBar(
            behavior: SnackBarBehavior.fixed,
            content: Text('Geovalla guardada correctamente.'),
          ),
        );
      }
      _exitEditor();
    } catch (error) {
      _showError('No se pudo guardar: $error');
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  Future<void> _delete(Geofence geofence) async {
    // ensure no TextField remains focused (which could open the keyboard)
    if (mounted) FocusScope.of(context).unfocus();

    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Eliminar geovalla'),
          content: Text(
            'Se eliminara "${geofence.name}". Esta accion no se puede deshacer.',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Eliminar'),
            ),
          ],
        );
      },
    );

    if (confirmed != true) return;

    setState(() => _deletingIds.add(geofence.id));
    try {
      await ref.read(vercelConnectorServiceProvider).deleteGeofence(geofence.id);
      ref.invalidate(managedGeofencesProvider);
      ref.invalidate(deviceGeofencesProvider);
      if (mounted) {
        // ensure focus remains cleared after deletion
        FocusScope.of(context).unfocus();
        final messenger = ScaffoldMessenger.of(context);
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(
          const SnackBar(
            behavior: SnackBarBehavior.fixed,
            content: Text('Geovalla eliminada.'),
          ),
        );
      }
      if (_editingGeofenceId == geofence.id) _exitEditor();
    } catch (error) {
      _showError('No se pudo eliminar: $error');
    } finally {
      if (mounted) setState(() => _deletingIds.remove(geofence.id));
    }
  }

  void _showError(String message) {
    if (!mounted) {
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(behavior: SnackBarBehavior.fixed, content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final MediaQueryData media = MediaQuery.of(context);
    final bool keyboardOpen = media.viewInsets.bottom > 0;
    final geofencesState = ref.watch(managedGeofencesProvider);
    final initialPosition = ref.watch(initialTrackingProvider).position;
    final LatLng initialCenter = initialPosition != null
        ? LatLng(initialPosition.latitude, initialPosition.longitude)
        : const LatLng(38.052972, -1.216263);

    // if editor is shown, ensure map recenters to latest vehicle position
    // but only do this once when the editor is opened to avoid moving on every rebuild
    if (_showEditor && initialPosition != null && !_didRecentreEditor) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        try {
          _mapController.move(
            LatLng(initialPosition.latitude, initialPosition.longitude),
            _currentZoom,
          );
          _didRecentreEditor = true;
        } catch (_) {
          // ignore if controller not ready
        }
      });
    }

    final List<Geofence> geofences =
        geofencesState.valueOrNull ?? const <Geofence>[];

    final List<CircleMarker> circles = geofences
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
            // `geofence.radius` is expressed in meters
            radius: geofence.radius!,
            useRadiusInMeter: true,
            color: Colors.blue.withValues(alpha: 0.14),
            borderColor: Colors.blue,
            borderStrokeWidth: 2,
          ),
        )
        .toList();

    final double? draftRadius = double.tryParse(
      _radiusController.text.trim().replaceAll(',', '.'),
    );
    if (_draftCenter != null && draftRadius != null && draftRadius > 0) {
      final double factor = _radiusUnit == 'km'
          ? 1000.0
          : (_radiusUnit == 'hm' ? 100.0 : 1.0);
      debugPrint(
        'geofence draft: input=$draftRadius unit=$_radiusUnit factor=$factor preview_m=${draftRadius * factor}',
      );
      circles.add(
        CircleMarker(
          point: _draftCenter!,
          // draftRadius is entered by the user in the selected unit; convert to meters
          radius: draftRadius * factor,
          useRadiusInMeter: true,
          color: Colors.orange.withValues(alpha: 0.20),
          borderColor: Colors.orange,
          borderStrokeWidth: 2,
        ),
      );
    }

    Widget content = ColoredBox(
      color: AppColors.surface,
      child: SafeArea(
        bottom: false,
        child: CustomScrollView(
          physics: const BouncingScrollPhysics(),
          slivers: <Widget>[
            SliverToBoxAdapter(
              child: Container(
                color: AppColors.surface,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: const Text(
                  'Gestión de geovallas',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 20,
                    color: AppColors.foreground,
                    letterSpacing: -0.5,
                  ),
                ),
              ),
            ),
            if (_showEditor)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: GeofenceEditorCard(
                    editingGeofenceId: _editingGeofenceId,
                    editorType: _editorType,
                    nameController: _nameController,
                    radiusController: _radiusController,
                    radiusUnit: _radiusUnit,
                    onUnitChanged: (String? v) {
                      final String newUnit = v ?? _radiusUnitDefault;
                      setState(() {
                        final double? current = double.tryParse(
                          _radiusController.text.trim().replaceAll(',', '.'),
                        );
                        final double oldFactor = _radiusUnit == 'km'
                            ? 1000.0
                            : (_radiusUnit == 'hm' ? 100.0 : 1.0);
                        final double newFactor = newUnit == 'km'
                            ? 1000.0
                            : (newUnit == 'hm' ? 100.0 : 1.0);
                        if (current != null && current > 0) {
                          final double meters = current * oldFactor;
                          final double newDisplay = meters / newFactor;
                          _radiusController.text = newDisplay.toStringAsFixed(
                            newUnit == 'm' ? 0 : 3,
                          );
                        }
                        _radiusUnit = newUnit;
                      });
                    },
                    isDrawingPolygon: _isDrawingPolygon,
                    isPickingCenter: _isPickingCenter,
                    draftPath: _draftPath,
                    isSaving: _isSaving,
                    onToggleEditorType: (int idx) {
                      setState(() {
                        _editorType = idx == 0
                            ? GeofenceType.circle
                            : GeofenceType.polygon;
                        if (_editorType == GeofenceType.circle) {
                          _draftPath = <LatLng>[];
                          _isDrawingPolygon = false;
                        } else {
                          _draftCenter = null;
                        }
                      });
                    },
                    onToggleDrawPolygon: () {
                      setState(() {
                        _isDrawingPolygon = !_isDrawingPolygon;
                      });
                    },
                    onUndoPolygon: () {
                      setState(() {
                        _draftPath.removeLast();
                      });
                    },
                    onClearPolygon: () {
                      setState(() {
                        _draftPath = <LatLng>[];
                      });
                    },
                    onPickCenter: () {
                      setState(() {
                        _isPickingCenter = true;
                      });
                    },
                    onSave: _save,
                  ),
                ),
              ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: SizedBox(
                  height: keyboardOpen ? 220 : 340,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(18),
                    child: FlutterMap(
                      mapController: _mapController,
                      options: MapOptions(
                        initialCenter: initialCenter,
                        initialZoom: _currentZoom,
                        onTap: (TapPosition _, LatLng point) {
                          if (_isPickingCenter) {
                            setState(() {
                              _draftCenter = point;
                              _isPickingCenter = false;
                            });
                            return;
                          }

                          if (_editorType == GeofenceType.polygon &&
                              _isDrawingPolygon) {
                            setState(() {
                              _draftPath.add(point);
                            });
                            return;
                          }
                          // move selected vertex to tapped location
                          if (_editorType == GeofenceType.polygon &&
                              _isMovingVertex &&
                              _selectedVertexIndex != null &&
                              _selectedVertexIndex! >= 0 &&
                              _selectedVertexIndex! < _draftPath.length) {
                            setState(() {
                              _draftPath[_selectedVertexIndex!] = point;
                              _isMovingVertex = false;
                              _selectedVertexIndex = null;
                            });
                            return;
                          }
                        },
                      ),
                      children: <Widget>[
                        TileLayer(
                          urlTemplate:
                              'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                          userAgentPackageName: 'com.ontacoche.app',
                        ),
                        if (initialPosition != null)
                          MarkerLayer(
                            markers: <Marker>[
                              Marker(
                                point: LatLng(
                                  initialPosition.latitude,
                                  initialPosition.longitude,
                                ),
                                width: 40,
                                height: 40,
                                child: const MapCircleMarker(),
                              ),
                            ],
                          ),
                        CircleLayer(circles: circles),
                        if (geofences.isNotEmpty)
                          PolygonLayer(
                            polygons: geofences
                                .where((g) => g.type == GeofenceType.polygon)
                                .map(
                                  (g) => Polygon(
                                    points: g.points
                                        .map(
                                          (p) =>
                                              LatLng(p.latitude, p.longitude),
                                        )
                                        .toList(growable: false),
                                    color: Colors.blue.withValues(
                                      alpha: 0.12,
                                    ),
                                    borderColor: Colors.blue,
                                    borderStrokeWidth: 2,
                                  ),
                                )
                                .toList(growable: false),
                          ),
                        if (_draftPath.isNotEmpty)
                          PolygonLayer(
                            polygons: <Polygon>[
                              Polygon(
                                points: _draftPath,
                                color: Colors.orange.withValues(alpha: 0.16),
                                borderColor: Colors.orange,
                                borderStrokeWidth: 2,
                              ),
                            ],
                          ),
                        // numbered vertex markers for the draft polygon
                        if (_draftPath.isNotEmpty)
                          MarkerLayer(
                            markers: _draftPath.asMap().entries.map((entry) {
                              final int idx = entry.key;
                              final LatLng p = entry.value;
                              return Marker(
                                point: p,
                                width: 28,
                                height: 28,
                                child: GestureDetector(
                                  onTap: () {
                                    setState(() {
                                      _selectedVertexIndex = idx;
                                      _isMovingVertex = true;
                                    });
                                  },
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: _selectedVertexIndex == idx
                                          ? AppColors.brand
                                          : Colors.orange,
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: AppColors.surfaceContainerLow,
                                      ),
                                    ),
                                    alignment: Alignment.center,
                                    child: Text(
                                      '${idx + 1}',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            }).toList(growable: false),
                          ),
                        if (_draftCenter != null)
                          MarkerLayer(
                            markers: <Marker>[
                              Marker(
                                point: _draftCenter!,
                                width: 36,
                                height: 36,
                                child: const Icon(
                                  Icons.place_rounded,
                                  size: 24,
                                  color: Colors.orange,
                                ),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 12)),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              sliver: _showEditor
                  ? const SliverToBoxAdapter(child: SizedBox.shrink())
                  : geofencesState.when(
                      data: (List<Geofence> data) {
                        if (data.isEmpty) {
                          return const SliverToBoxAdapter(
                            child: Padding(
                              padding: EdgeInsets.only(top: 32),
                              child: Text(
                                'No hay geovallas asignadas todavía.',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: AppColors.foreground),
                              ),
                            ),
                          );
                        }

                        return SliverList(
                          delegate: SliverChildBuilderDelegate(
                            (BuildContext context, int index) {
                              if (index.isOdd) return const SizedBox(height: 10);
                              final int itemIndex = index ~/ 2;
                              final Geofence geofence = data[itemIndex];
                              return GeofenceListTile(
                                geofence: geofence,
                                isEditing: _editingGeofenceId == geofence.id,
                                onEdit: () => _loadForEdit(geofence),
                                onDelete: () => _delete(geofence),
                                isDeleting: _deletingIds.contains(geofence.id),
                              );
                            },
                            childCount: (data.length * 2) - 1,
                          ),
                        );
                      },
                      loading: () => const SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.only(top: 24),
                          child: Center(child: ExpressiveIndicator(
                            size: 40,
                            strokeWidth: 10,
                            color: AppColors.foreground,
                          )),
                        ),
                      ),
                      error: (Object error, StackTrace _) => SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.only(top: 24),
                          child: Text(
                            'Error cargando geovallas: $error',
                            style: const TextStyle(color: Colors.redAccent),
                          ),
                        ),
                      ),
                    ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 200)),
          ],
        ),
      ),
    );


    return Stack(
      children: [
        content,
        if (geofencesState.hasError)
          Positioned(
            top: 120,
            left: 16,
            right: 16,
            child: Material(
              color: Colors.transparent,
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline, color: Colors.orange),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text(
                        'No se pudieron cargar las geovallas',
                        style: TextStyle(color: AppColors.foreground),
                      ),
                    ),
                    TextButton(
                      onPressed: () {
                        ref.invalidate(managedGeofencesProvider);
                        ref.invalidate(deviceGeofencesProvider);
                      },
                      child: const Text('Reintentar'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        Positioned(
          bottom: 150,
          right: 16,
          child: !_showEditor
              ? FloatingActionButton(
                  shape: const CircleBorder(),
                  clipBehavior: Clip.hardEdge,
                  onPressed: _startCreateMode,
                  backgroundColor: AppColors.brand,
                  foregroundColor: AppColors.surfaceContainerLow,
                  child: const Icon(Icons.add_rounded, size: 30),
                )
              : FloatingActionButton(
                  shape: const CircleBorder(),
                  clipBehavior: Clip.hardEdge,
                  onPressed: _exitEditor,
                  backgroundColor: AppColors.danger,
                  foregroundColor: AppColors.surfaceContainerLow,
                  child: const Icon(Icons.close_rounded, size: 30,),
                ),
        ),
      ],
    );
  }
}
