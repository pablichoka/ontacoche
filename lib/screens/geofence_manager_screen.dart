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
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _radiusController = TextEditingController(
    text: '0.20',
  );
  final TextEditingController _priorityController = TextEditingController(
    text: '10',
  );

  LatLng? _draftCenter;
  bool _isPickingCenter = false;
  bool _isSaving = false;
  int? _editingGeofenceId;

  @override
  void dispose() {
    _mapController.dispose();
    _nameController.dispose();
    _radiusController.dispose();
    _priorityController.dispose();
    super.dispose();
  }

  void _startCreateMode() {
    setState(() {
      _editingGeofenceId = null;
      _nameController.text = '';
      _radiusController.text = '0.20';
      _priorityController.text = '10';
      _draftCenter = null;
      _isPickingCenter = false;
    });
  }

  void _loadForEdit(Geofence geofence) {
    if (geofence.type != GeofenceType.circle ||
        geofence.latitude == null ||
        geofence.longitude == null ||
        geofence.radius == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'En fase 1 solo se pueden editar geovallas circulares.',
          ),
        ),
      );
      return;
    }

    setState(() {
      _editingGeofenceId = geofence.id;
      _nameController.text = geofence.name;
      _radiusController.text = geofence.radius!.toStringAsFixed(3);
      _priorityController.text = geofence.priority.toString();
      _draftCenter = LatLng(geofence.latitude!, geofence.longitude!);
      _isPickingCenter = false;
    });

    _mapController.move(_draftCenter!, 16);
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
    if (_draftCenter == null) {
      _showError('Selecciona un centro en el mapa.');
      return;
    }
    if (priority == null) {
      _showError('La prioridad debe ser un numero entero.');
      return;
    }
    if (radiusKm == null || radiusKm <= 0) {
      _showError('El radio debe ser un numero mayor que 0.');
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
      if (_editingGeofenceId == null) {
        await service.createCircleGeofence(
          deviceId: deviceId,
          name: name,
          priority: priority,
          latitude: _draftCenter!.latitude,
          longitude: _draftCenter!.longitude,
          radiusKm: radiusKm,
        );
      } else {
        await service.updateCircleGeofence(
          geofenceId: _editingGeofenceId!,
          name: name,
          priority: priority,
          latitude: _draftCenter!.latitude,
          longitude: _draftCenter!.longitude,
          radiusKm: radiusKm,
        );
      }

      ref.invalidate(managedGeofencesProvider);
      ref.invalidate(deviceGeofencesProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Geovalla guardada correctamente.')),
        );
      }
      _startCreateMode();
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Geovalla eliminada.')));
      }
      if (_editingGeofenceId == geofence.id) {
        _startCreateMode();
      }
    } catch (error) {
      _showError('No se pudo eliminar: $error');
    }
  }

  void _showError(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final geofencesState = ref.watch(managedGeofencesProvider);
    final initialPosition = ref.watch(initialTrackingProvider).position;
    final LatLng initialCenter = initialPosition != null
        ? LatLng(initialPosition.latitude, initialPosition.longitude)
        : const LatLng(38.052972, -1.216263);

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
        .toList(growable: false);

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

    return Scaffold(
      appBar: AppBar(title: const Text('Gestion de geovallas')),
      backgroundColor: const Color(0xFFF8FAFC),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _startCreateMode,
        icon: const Icon(Icons.add_rounded),
        label: const Text('Nueva geovalla'),
      ),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: _buildEditorCard(),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SizedBox(
              height: 260,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: initialCenter,
                    initialZoom: 15,
                    onTap: (TapPosition _, LatLng point) {
                      if (!_isPickingCenter) {
                        return;
                      }
                      setState(() {
                        _draftCenter = point;
                        _isPickingCenter = false;
                      });
                    },
                  ),
                  children: <Widget>[
                    TileLayer(
                      urlTemplate:
                          'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'com.ontacoche.app',
                    ),
                    CircleLayer(circles: circles),
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
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: geofencesState.when(
              data: (List<Geofence> data) {
                if (data.isEmpty) {
                  return const Center(
                    child: Text('No hay geovallas asignadas todavia.'),
                  );
                }

                return ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
                  itemCount: data.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (BuildContext context, int index) {
                    final Geofence geofence = data[index];
                    return _buildGeofenceTile(geofence);
                  },
                );
              },
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (Object error, StackTrace _) {
                return Center(child: Text('Error cargando geovallas: $error'));
              },
            ),
          ),
        ],
      ),
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
                ? 'Crear geovalla circular'
                : 'Editar geovalla circular',
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
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
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
