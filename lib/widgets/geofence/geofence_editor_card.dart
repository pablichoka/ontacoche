import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:ontacoche/theme/app_colors.dart';
import 'package:ontacoche/widgets/app_text_field.dart';
import 'package:ontacoche/widgets/expressive_indicator.dart';

import '../../models/geofence.dart';

class GeofenceEditorCard extends StatelessWidget {
  final int? editingGeofenceId;
  final GeofenceType editorType;
  final TextEditingController nameController;
  final TextEditingController radiusController;
  final String radiusUnit;
  final ValueChanged<String?> onUnitChanged;
  final bool isDrawingPolygon;
  final bool isPickingCenter;
  final List<LatLng> draftPath;
  final bool isSaving;
  final ValueChanged<int> onToggleEditorType;
  final VoidCallback onToggleDrawPolygon;
  final VoidCallback onUndoPolygon;
  final VoidCallback onClearPolygon;
  final VoidCallback onPickCenter;
  final VoidCallback onSave;

  const GeofenceEditorCard({
    super.key,
    required this.editingGeofenceId,
    required this.editorType,
    required this.nameController,
    required this.radiusController,
    required this.radiusUnit,
    required this.onUnitChanged,
    required this.isDrawingPolygon,
    required this.isPickingCenter,
    required this.draftPath,
    required this.isSaving,
    required this.onToggleEditorType,
    required this.onToggleDrawPolygon,
    required this.onUndoPolygon,
    required this.onClearPolygon,
    required this.onPickCenter,
    required this.onSave,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(18),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.4),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            editingGeofenceId == null
                ? (editorType == GeofenceType.circle
                      ? 'Crear geovalla circular'
                      : 'Crear geovalla poligonal')
                : (editorType == GeofenceType.circle
                      ? 'Editar geovalla circular'
                      : 'Editar geovalla poligonal'),
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: AppColors.foreground,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 16),
          AppTextField(
            controller: nameController,
            hintText: 'Nombre',
            keyboardType: TextInputType.text,
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              if (editorType == GeofenceType.circle) ...[
                Expanded(
                  child: AppTextField(
                    controller: radiusController,
                    hintText: 'Radio',
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  ),
                ),
                const SizedBox(width: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceContainerLowest,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppColors.brandSoft),
                  ),
                  child: DropdownButton<String>(
                    value: radiusUnit,
                    dropdownColor: AppColors.surfaceContainerLow,
                    underline: const SizedBox.shrink(),
                    items: const [
                      DropdownMenuItem(value: 'km', child: Text('km')),
                      DropdownMenuItem(value: 'hm', child: Text('hm')),
                      DropdownMenuItem(value: 'm', child: Text('m')),
                    ],
                    onChanged: onUnitChanged,
                    style: const TextStyle(color: AppColors.foreground),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 16),
          ToggleButtons(
            isSelected: <bool>[
              editorType == GeofenceType.circle,
              editorType == GeofenceType.polygon,
            ],
            onPressed: onToggleEditorType,
            color: AppColors.foreground,
            selectedColor: AppColors.brand,
            fillColor: AppColors.brand.withValues(alpha: 0.1),
            borderColor: AppColors.brand,
            selectedBorderColor: AppColors.brand.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(8),
            children: const <Widget>[
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Icon(Icons.circle_outlined, size: 20),
              ),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Icon(Icons.polyline_rounded, size: 20),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Wrap(
                spacing: 8,
                children: <Widget>[
                  if (editorType == GeofenceType.polygon) ...[
                    IconButton(
                      tooltip: isDrawingPolygon ? 'Detener' : 'Dibujar puntos',
                      onPressed: onToggleDrawPolygon,
                      icon: Icon(
                        Icons.edit_location_rounded,
                        color: isDrawingPolygon
                            ? AppColors.brand
                            : AppColors.foreground,
                      ),
                      style: _iconButtonStyle(),
                    ),
                    IconButton(
                      tooltip: 'Deshacer',
                      onPressed: draftPath.isEmpty ? null : onUndoPolygon,
                      icon: const Icon(
                        Icons.undo_rounded,
                        color: AppColors.foreground,
                      ),
                      style: _iconButtonStyle(),
                    ),
                    IconButton(
                      tooltip: 'Limpiar',
                      onPressed: draftPath.isEmpty ? null : onClearPolygon,
                      icon: const Icon(
                        Icons.clear_rounded,
                        color: AppColors.foreground,
                      ),
                      style: _iconButtonStyle(),
                    ),
                  ],
                  if (editorType == GeofenceType.circle) ...[
                    IconButton(
                      tooltip: isPickingCenter
                          ? 'Toca el mapa...'
                          : 'Seleccionar centro',
                      onPressed: onPickCenter,
                      icon: Icon(
                        Icons.touch_app_rounded,
                        color: isPickingCenter
                            ? AppColors.brand
                            : AppColors.foreground,
                      ),
                      style: _iconButtonStyle(),
                    ),
                  ],
                ],
              ),
              IconButton(
                onPressed: isSaving ? null : onSave,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.brand,
                  foregroundColor: const Color(0xFF131313),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(24),
                  ),
                ),
                icon: isSaving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: ExpressiveIndicator(
                          strokeWidth: 2,
                          color: AppColors.brand,
                        ),
                      )
                    : const Icon(Icons.save_rounded, size: 20),
              ),
            ],
          ),
        ],
      ),
    );
  }

  ButtonStyle _iconButtonStyle() {
    return IconButton.styleFrom(
      backgroundColor: const Color(0xFF1E1E1E), // surface-container-low
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    );
  }
}
