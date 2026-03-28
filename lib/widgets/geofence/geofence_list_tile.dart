import 'package:flutter/material.dart';
import '../../models/geofence.dart';

class GeofenceListTile extends StatelessWidget {
  final Geofence geofence;
  final bool isEditing;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const GeofenceListTile({
    super.key,
    required this.geofence,
    required this.isEditing,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final String shapeLabel = geofence.type == GeofenceType.circle
        ? 'Círculo'
        : 'Polígono';

    return Container(
      decoration: BoxDecoration(
        color: isEditing
            ? const Color(0xFF1E1E1E)
            : const Color(0xFF0E0E0E), // surface-container-low or lowest
        borderRadius: BorderRadius.circular(16),
      ),
      child: ListTile(
        title: Text(
          geofence.name,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: Text(
          'Prioridad ${geofence.priority} · $shapeLabel',
          style: const TextStyle(color: Colors.white54),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            IconButton(
              tooltip: 'Editar',
              onPressed: onEdit,
              icon: Icon(
                Icons.edit_rounded,
                color: isEditing ? const Color(0xFF5ADCB3) : Colors.white70,
              ),
            ),
            IconButton(
              tooltip: 'Eliminar',
              onPressed: onDelete,
              icon: const Icon(
                Icons.delete_outline_rounded,
                color: Colors.redAccent,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
