import 'package:flutter/material.dart';
import 'package:ontacoche/theme/app_colors.dart';
import 'package:ontacoche/widgets/expressive_indicator.dart';
import '../../models/geofence.dart';

class GeofenceListTile extends StatelessWidget {
  final Geofence geofence;
  final bool isEditing;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final bool isDeleting;

  const GeofenceListTile({
    super.key,
    required this.geofence,
    required this.isEditing,
    required this.onEdit,
    required this.onDelete,
    required this.isDeleting,
  });

  @override
  Widget build(BuildContext context) {
    final String shapeLabel = geofence.type == GeofenceType.circle
        ? 'Círculo'
        : 'Polígono';

    return Container(
      decoration: BoxDecoration(
        color: isEditing
            ? AppColors.surface
            : AppColors.surfaceContainerLow, // surface-container-low or lowest
        borderRadius: BorderRadius.circular(16),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: AppColors.secondary.withValues(alpha: 0.04),
            blurRadius: 24,
          ),
        ],
      ),

      child: ListTile(
        title: Text(
          geofence.name,
          style: const TextStyle(
            color: AppColors.foreground,
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: Text(
          'Prioridad ${geofence.priority} · $shapeLabel',
          style: const TextStyle(color: AppColors.foreground),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            IconButton(
              tooltip: 'Editar',
              onPressed: onEdit,
              icon: Icon(Icons.edit_rounded, color: AppColors.brand),
            ),
            isDeleting
                ? SizedBox(
                    width: 40,
                    height: 40,
                    child: Center(
                      child: ExpressiveIndicator(size: 20, strokeWidth: 3),
                    ),
                  )
                : IconButton(
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
