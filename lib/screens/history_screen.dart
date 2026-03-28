import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/trip.dart';
import '../providers/trip_provider.dart';
import '../providers/api_provider.dart';
import '../theme/app_colors.dart';
import '../utils/parsers.dart';
import '../widgets/expressive_indicator.dart';
import 'trip_playback_screen.dart';

class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<Trip>> tripsState = ref.watch(tripsProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text(
          'Historial',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: tripsState.when(
              data: (List<Trip> trips) {
                if (trips.isEmpty) {
                  return const _EmptyTripsState();
                }

                return RefreshIndicator(
                  onRefresh: () async => ref.invalidate(tripsProvider),
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 200),
                    itemCount: trips.length,
                    itemBuilder: (BuildContext context, int index) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _TripCard(trip: trips[index]),
                      );
                    },
                  ),
                );
              },
              loading: () => const Center(child: ExpressiveIndicator(size: 40, strokeWidth: 5,)),
              error: (Object error, StackTrace stackTrace) => Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      const Icon(Icons.route_rounded, size: 48, color: Colors.grey),
                      const SizedBox(height: 12),
                      Text(
                        'No se pudo cargar los trayectos',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: () => ref.invalidate(tripsProvider),
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
                    title: const Text('Borrar trayectos'),
                    content: const Text('¿Eliminar todos los trayectos del servidor? Esta acción es irreversible.'),
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
                  final int deleted = await service.deleteTripsForDevice(deviceId);
                  ref.invalidate(tripsProvider);
                  Navigator.of(context).pop(); // close progress
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Eliminados $deleted trayectos')),
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

class _TripCard extends StatelessWidget {
  const _TripCard({required this.trip});

  final Trip trip;

  @override
  Widget build(BuildContext context) {
    final String start = _formatTime(trip.startTime);
    final String end = _formatTime(trip.endTime);
    final String duration = trip.activeDurationMinutes != null
        ? '${trip.activeDurationMinutes} min'
        : Parsers.formatRelativeTimestamp(trip.startTime);

    return GestureDetector(
      onTap: () {
        if (trip.routePoints.length >= 2) {
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => TripPlaybackScreen(trip: trip),
            ),
          );
        }
      },
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AppColors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(24),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: AppColors.brand.withValues(alpha: 0.04),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Row(
          children: <Widget>[
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: AppColors.brand.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Icon(Icons.route_rounded, color: AppColors.brand),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '$start — $end',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    duration,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: AppColors.muted),
                  ),
                ],
              ),
            ),
            if (trip.routePoints.length >= 2)
              const Icon(
                Icons.play_circle_outline_rounded,
                color: AppColors.brand,
              ),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime dt) {
    final DateTime local = dt.toLocal();
    String twoDigits(int v) => v.toString().padLeft(2, '0');
    return '${twoDigits(local.day)}/${twoDigits(local.month)} '
        '${twoDigits(local.hour)}:${twoDigits(local.minute)}';
  }
}

class _EmptyTripsState extends StatelessWidget {
  const _EmptyTripsState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const Icon(Icons.route_rounded, size: 56, color: Colors.grey),
            const SizedBox(height: 16),
            Text(
              'Todavía no hay trayectos',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            Text(
              'Cuando el tracker registre recorridos, aparecerán aquí.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}
