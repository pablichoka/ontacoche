import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../models/geofence.dart';
import '../providers/api_provider.dart';
import '../providers/tracking_provider.dart';

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
    text: '0.20',
  );
  final TextEditingController _priorityController = TextEditingController(
    text: '10',
  );

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

  @override
  void dispose() {
    _mapEventSub?.cancel();
    _nameController.dispose();
    _radiusController.dispose();
    _priorityController.dispose();
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
      _radiusController.text = '0.20';
      _priorityController.text = '10';
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
      _radiusController.text = '0.20';
      _priorityController.text = '10';
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
      _priorityController.text = geofence.priority.toString();
      _isPickingCenter = false;

      if (geofence.type == GeofenceType.circle &&
          geofence.latitude != null &&
          geofence.longitude != null &&
          geofence.radius != null) {
        _editorType = GeofenceType.circle;
        _radiusController.text = geofence.radius!.toStringAsFixed(3);
        _draftCenter = LatLng(geofence.latitude!, geofence.longitude!);
        _draftPath = <LatLng>[];
        _isDrawingPolygon = false;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          try {
            _mapController.move(_draftCenter!, _currentZoom);
            _didRecentreEditor = true;
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
        WidgetsBinding.instance.addPostFrameCallback((_) {
          try {
            _mapController.move(_draftPath.first, _currentZoom);
            _didRecentreEditor = true;
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
    if (_isSaving) {
      return;
    }

    final String name = _nameController.text.trim();
    final int? priority = int.tryParse(_priorityController.text.trim());
    final double? radiusKm = double.tryParse(
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
    if (priority == null) {
      _showError('La prioridad debe ser un numero entero.');
      return;
    }
    if (_editorType == GeofenceType.circle &&
        (radiusKm == null || radiusKm <= 0)) {
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
        if (_editingGeofenceId == null) {
          await service.createCircleGeofence(
            deviceId: deviceId,
            name: name,
            priority: priority,
            latitude: _draftCenter!.latitude,
            longitude: _draftCenter!.longitude,
            radiusKm: radiusKm!,
          );
        } else {
          await service.updateCircleGeofence(
            geofenceId: _editingGeofenceId!,
            name: name,
            priority: priority,
            latitude: _draftCenter!.latitude,
            longitude: _draftCenter!.longitude,
            radiusKm: radiusKm!,
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
            priority: priority,
            path: path,
          );
        } else {
          await service.updatePolygonGeofence(
            geofenceId: _editingGeofenceId!,
            name: name,
            priority: priority,
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

    if (confirmed != true) {
      return;
    }

    try {
      await ref
          .read(vercelConnectorServiceProvider)
          .deleteGeofence(geofence.id);
      ref.invalidate(managedGeofencesProvider);
      ref.invalidate(deviceGeofencesProvider);
      if (mounted) {
        final messenger = ScaffoldMessenger.of(context);
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(
          const SnackBar(
            behavior: SnackBarBehavior.fixed,
            content: Text('Geovalla eliminada.'),
          ),
        );
      }
      if (_editingGeofenceId == geofence.id) {
        _exitEditor();
      }
    } catch (error) {
      _showError('No se pudo eliminar: $error');
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
            radius: geofence.radius! * 1000,
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
      circles.add(
        CircleMarker(
          point: _draftCenter!,
          radius: draftRadius * 1000,
          useRadiusInMeter: true,
          color: Colors.orange.withValues(alpha: 0.20),
          borderColor: Colors.orange,
          borderStrokeWidth: 2,
        ),
      );
    }

    Widget content = ColoredBox(
      color: const Color(0xFFF8FAFC),
      child: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              color: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: const Text(
                'Gestion de geovallas',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 20),
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.only(bottom: media.viewInsets.bottom + 200),
                child: Column(
                  children: <Widget>[
                    if (_showEditor) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                        child: _buildEditorCard(),
                      ),
                    ],
                    Padding(
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
                              // current device marker when editor open
                              if (_showEditor && initialPosition != null)
                                MarkerLayer(
                                  markers: <Marker>[
                                    Marker(
                                      point: LatLng(
                                        initialPosition.latitude,
                                        initialPosition.longitude,
                                      ),
                                      width: 40,
                                      height: 40,
                                      child: const Icon(
                                        Icons.directions_car_rounded,
                                        color: Colors.redAccent,
                                        size: 32,
                                      ),
                                    ),
                                  ],
                                ),
                              CircleLayer(circles: circles),
                              // existing polygon geofences
                              if (geofences.isNotEmpty)
                                PolygonLayer(
                                  polygons: geofences
                                      .where(
                                        (g) => g.type == GeofenceType.polygon,
                                      )
                                      .map(
                                        (g) => Polygon(
                                          points: g.points
                                              .map(
                                                (p) => LatLng(
                                                  p.latitude,
                                                  p.longitude,
                                                ),
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
                              // draft polygon preview
                              if (_draftPath.isNotEmpty)
                                PolygonLayer(
                                  polygons: <Polygon>[
                                    Polygon(
                                      points: _draftPath,
                                      color: Colors.orange.withValues(
                                        alpha: 0.16,
                                      ),
                                      borderColor: Colors.orange,
                                      borderStrokeWidth: 2,
                                    ),
                                  ],
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
                                        size: 34,
                                        color: Colors.orange,
                                      ),
                                    ),
                                  ],
                                ),
                              if (_draftPath.isNotEmpty)
                                MarkerLayer(
                                  markers: _draftPath
                                      .asMap()
                                      .entries
                                      .map((MapEntry<int, LatLng> e) {
                                        final int idx = e.key;
                                        final LatLng p = e.value;
                                        final bool selected =
                                            _selectedVertexIndex == idx;
                                        return Marker(
                                          point: p,
                                          width: 28,
                                          height: 28,
                                          child: GestureDetector(
                                            onTap: () {
                                              setState(() {
                                                _selectedVertexIndex = idx;
                                              });
                                            },
                                            onLongPress: () {
                                              setState(() {
                                                _draftPath.removeAt(idx);
                                                if (_selectedVertexIndex !=
                                                    null) {
                                                  _selectedVertexIndex = null;
                                                }
                                              });
                                            },
                                            child: CircleAvatar(
                                              radius: selected ? 14 : 12,
                                              backgroundColor: selected
                                                  ? Colors.orange
                                                  : Colors.orange.withOpacity(
                                                      0.9,
                                                    ),
                                              child: Text(
                                                '${idx + 1}',
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.w700,
                                                ),
                                              ),
                                            ),
                                          ),
                                        );
                                      })
                                      .toList(growable: false),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                      child: geofencesState.when(
                        data: (List<Geofence> data) {
                          if (data.isEmpty) {
                            return const Padding(
                              padding: EdgeInsets.only(top: 32),
                              child: Text(
                                'No hay geovallas asignadas todavia.',
                              ),
                            );
                          }

                          return ListView.separated(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: data.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 10),
                            itemBuilder: (BuildContext context, int index) {
                              final Geofence geofence = data[index];
                              return _buildGeofenceTile(geofence);
                            },
                          );
                        },
                        loading: () => const Padding(
                          padding: EdgeInsets.only(top: 24),
                          child: CircularProgressIndicator(),
                        ),
                        error: (Object error, StackTrace _) {
                          return Padding(
                            padding: const EdgeInsets.only(top: 24),
                            child: Text('Error cargando geovallas: $error'),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );

    return Stack(
      children: [
        content,
        Positioned(
          bottom: 150,
          right: 16,
          child: !_showEditor
              ? FloatingActionButton.extended(
                  onPressed: _startCreateMode,
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('Nueva geovalla'),
                )
              : FloatingActionButton.extended(
                  onPressed: _exitEditor,
                  icon: const Icon(Icons.close_rounded),
                  label: const Text('Cerrar'),
                ),
        ),
      ],
    );
  }

  Widget _buildEditorCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            _editingGeofenceId == null
                ? (_editorType == GeofenceType.circle
                      ? 'Crear geovalla circular'
                      : 'Crear geovalla poligonal')
                : (_editorType == GeofenceType.circle
                      ? 'Editar geovalla circular'
                      : 'Editar geovalla poligonal'),
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _nameController,
            decoration: const InputDecoration(
              labelText: 'Nombre',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _priorityController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Prioridad (0-100)',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              if (_editorType == GeofenceType.circle)
                Expanded(
                  child: TextField(
                    controller: _radiusController,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'Radio (km)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          ToggleButtons(
            isSelected: <bool>[
              _editorType == GeofenceType.circle,
              _editorType == GeofenceType.polygon,
            ],
            onPressed: (int idx) {
              setState(() {
                _editorType = idx == 0
                    ? GeofenceType.circle
                    : GeofenceType.polygon;
                // reset incompatible draft data
                if (_editorType == GeofenceType.circle) {
                  _draftPath = <LatLng>[];
                  _isDrawingPolygon = false;
                } else {
                  _draftCenter = null;
                }
              });
            },
            children: const <Widget>[
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Text('Círculo'),
              ),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Text('Polígono'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (_editorType == GeofenceType.polygon)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                OutlinedButton.icon(
                  onPressed: () {
                    setState(() {
                      _isDrawingPolygon = !_isDrawingPolygon;
                    });
                  },
                  icon: const Icon(Icons.edit_location_rounded),
                  label: Text(_isDrawingPolygon ? 'Detener' : 'Dibujar puntos'),
                ),
                OutlinedButton.icon(
                  onPressed: _draftPath.isEmpty
                      ? null
                      : () {
                          setState(() {
                            _draftPath.removeLast();
                          });
                        },
                  icon: const Icon(Icons.undo_rounded),
                  label: const Text('Deshacer'),
                ),
                OutlinedButton.icon(
                  onPressed: _draftPath.isEmpty
                      ? null
                      : () {
                          setState(() {
                            _draftPath = <LatLng>[];
                          });
                        },
                  icon: const Icon(Icons.clear_rounded),
                  label: const Text('Limpiar'),
                ),
              ],
            ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              if (_editorType == GeofenceType.circle)
                OutlinedButton.icon(
                  onPressed: () {
                    setState(() {
                      _isPickingCenter = true;
                    });
                  },
                  icon: const Icon(Icons.touch_app_rounded),
                  label: Text(
                    _isPickingCenter ? 'Toca el mapa...' : 'Seleccionar centro',
                  ),
                ),
              FilledButton.icon(
                onPressed: _isSaving ? null : _save,
                icon: _isSaving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_rounded),
                label: Text(
                  _editingGeofenceId == null ? 'Crear' : 'Guardar cambios',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildGeofenceTile(Geofence geofence) {
    final bool isEditing = _editingGeofenceId == geofence.id;
    final String shapeLabel = geofence.type == GeofenceType.circle
        ? 'Circulo'
        : 'Poligono';

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isEditing ? Colors.orange : Colors.transparent,
          width: 1.5,
        ),
      ),
      child: ListTile(
        title: Text(geofence.name),
        subtitle: Text('Prioridad ${geofence.priority} · $shapeLabel'),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            IconButton(
              tooltip: 'Editar',
              onPressed: () => _loadForEdit(geofence),
              icon: const Icon(Icons.edit_rounded),
            ),
            IconButton(
              tooltip: 'Eliminar',
              onPressed: () => _delete(geofence),
              icon: const Icon(Icons.delete_outline_rounded),
            ),
          ],
        ),
      ),
    );
  }
}
