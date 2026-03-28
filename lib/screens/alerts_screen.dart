import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/vehicle_state_provider.dart';
import '../models/device_alert.dart';
import '../providers/api_provider.dart';
import '../theme/app_colors.dart';

class AlertsScreen extends ConsumerWidget {
  const AlertsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<DeviceAlert>> alertsState = ref.watch(
      alertsHistoryProvider,
    );

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text(
          'Alertas',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        backgroundColor: AppColors.surface,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: alertsState.when(
              data: (List<DeviceAlert> alerts) {
                if (alerts.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(
                          Icons.notifications_off_rounded,
                          size: 48,
                          color: AppColors.muted,
                        ),
                        const SizedBox(height: 16),
                        const Text('No hay alertas recientes'),
                      ],
                    ),
                  );
                }

                final List<_AlertGroup> groups = _groupAlertsByDay(alerts);

                return ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 200),
                  itemCount: groups.length,
                  itemBuilder: (BuildContext context, int index) {
                    final _AlertGroup group = groups[index];
                    return Padding(
                      padding: EdgeInsets.only(
                        bottom: index == groups.length - 1 ? 0 : 20,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Padding(
                            padding: const EdgeInsets.only(left: 4, bottom: 10),
                            child: Text(
                              group.label,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.6,
                                color: AppColors.muted,
                              ),
                            ),
                          ),
                          ...group.alerts.map(
                            (DeviceAlert alert) => Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: _AlertCard(alert: alert),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (err, stack) => Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      const Icon(
                        Icons.notifications_off_rounded,
                        size: 48,
                        color: AppColors.muted,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'No se pudieron cargar las alertas',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: () => ref.invalidate(alertsHistoryProvider),
                        child: const Text('Reintentar'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          Positioned(
            right: 16,
            bottom: 150,
            child: FloatingActionButton(
              backgroundColor: Colors.redAccent,
              onPressed: () async {
                final bool? confirmed = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Borrar alertas'),
                    content: const Text('¿Eliminar todas las alertas del servidor? Esta acción es irreversible.'),
                    actions: [
                      TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancelar')),
                      TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Eliminar')),
                    ],
                  ),
                );

                if (confirmed != true) return;

                showDialog<void>(
                  context: context,
                  barrierDismissible: false,
                  builder: (_) => const Center(child: CircularProgressIndicator()),
                );

                try {
                  final service = ref.read(vercelConnectorServiceProvider);
                  final String deviceId = ref.read(deviceIdentProvider).trim();
                  final int deleted = await service.deleteDeviceAlertsForDevice(deviceId);
                  ref.invalidate(alertsHistoryProvider);
                  Navigator.of(context).pop();
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Eliminadas $deleted alertas')),
                  );
                } catch (e) {
                  Navigator.of(context).pop();
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Error al eliminar: $e')),
                  );
                }
              },
              child: const Icon(Icons.delete_rounded),
            ),
          ),
        ],
      ),
    );
  }
}

List<_AlertGroup> _groupAlertsByDay(List<DeviceAlert> alerts) {
  final Map<String, List<DeviceAlert>> grouped = <String, List<DeviceAlert>>{};

  for (final DeviceAlert alert in alerts) {
    final DateTime local = alert.timestamp;
    final String key =
        '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
    grouped.putIfAbsent(key, () => <DeviceAlert>[]).add(alert);
  }

  final List<String> keys = grouped.keys.toList()
    ..sort((a, b) => b.compareTo(a));
  return keys
      .map((String key) {
        final List<DeviceAlert> groupAlerts = grouped[key]!
          ..sort(
            (DeviceAlert a, DeviceAlert b) =>
                b.timestamp.compareTo(a.timestamp),
          );
        return _AlertGroup(
          label: _formatGroupLabel(groupAlerts.first.timestamp),
          alerts: groupAlerts,
        );
      })
      .toList(growable: false);
}

String _formatGroupLabel(DateTime timestamp) {
  final DateTime local = timestamp;
  final DateTime now = DateTime.now();
  final DateTime today = DateTime(now.year, now.month, now.day);
  final DateTime day = DateTime(local.year, local.month, local.day);

  if (today.year == day.year &&
      today.month == day.month &&
      today.day == day.day) {
    return 'HOY';
  }
  final DateTime yesterday = today.subtract(const Duration(days: 1));
  if (yesterday.year == day.year &&
      yesterday.month == day.month &&
      yesterday.day == day.day) {
    return 'AYER';
  }

  const List<String> months = <String>[
    'enero',
    'febrero',
    'marzo',
    'abril',
    'mayo',
    'junio',
    'julio',
    'agosto',
    'septiembre',
    'octubre',
    'noviembre',
    'diciembre',
  ];
  return '${local.day} ${months[local.month - 1]} ${local.year}'.toUpperCase();
}

class _AlertGroup {
  const _AlertGroup({required this.label, required this.alerts});

  final String label;
  final List<DeviceAlert> alerts;
}

class _AlertCard extends StatelessWidget {
  const _AlertCard({required this.alert});

  final DeviceAlert alert;

  @override
  Widget build(BuildContext context) {
    final bool isGeofence = alert.type == DeviceAlertType.geofence;
    final Color color = isGeofence ? Colors.blue : Colors.orange;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.16),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(
              isGeofence ? Icons.near_me_rounded : Icons.vibration_rounded,
              color: color,
              size: 24,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _getNameFromType(alert.type),
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    Text(
                      _formatTime(alert.timestamp),
                      style: const TextStyle(
                        color: AppColors.muted,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  alert.message,
                  style: const TextStyle(color: Colors.white70, fontSize: 14),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _getNameFromType(DeviceAlertType type) {
    switch (type) {
      case DeviceAlertType.geofence:
        return 'Geovalla';
      case DeviceAlertType.vibration:
        return 'Vibración';
      case DeviceAlertType.unknown:
        return 'Alerta';
      case DeviceAlertType.lowBattery:
        return 'Batería baja';
      case DeviceAlertType.movement:
        return 'Movimiento';
    }
  }

  String _formatTime(DateTime time) {
    return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }
}
