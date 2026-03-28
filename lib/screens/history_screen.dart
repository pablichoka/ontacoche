import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../models/telemetry_record.dart';
import '../providers/telemetry_provider.dart';
import '../theme/app_colors.dart';
import '../utils/parsers.dart';

class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<TelemetryRecord>> historyState = ref.watch(
      telemetryHistoryProvider,
    );

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text(
          'Historial',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
      body: historyState.when(
        data: (List<TelemetryRecord> records) {
          if (records.length < 2) {
            return const _EmptyHistoryState();
          }

          final List<TelemetryRecord> orderedRecords = records.reversed.toList(
            growable: false,
          );
          final List<LatLng> points = orderedRecords
              .map(
                (TelemetryRecord record) =>
                    LatLng(record.latitude, record.longitude),
              )
              .toList(growable: false);
          final TelemetryRecord latest = records.first;
          final TelemetryRecord earliest = orderedRecords.first;

          return Column(
            children: <Widget>[
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: FlutterMap(
                      options: MapOptions(
                        initialCenter: LatLng(
                          latest.latitude,
                          latest.longitude,
                        ),
                        initialZoom: 14,
                        minZoom: 3,
                        maxZoom: 19,
                      ),
                      children: <Widget>[
                        TileLayer(
                          urlTemplate:
                              'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                          userAgentPackageName: 'com.ontacoche.app',
                        ),
                        PolylineLayer(
                          polylines: <Polyline>[
                            Polyline(
                              points: points,
                              strokeWidth: 4,
                              color: AppColors.brand,
                            ),
                          ],
                        ),
                        MarkerLayer(
                          markers: <Marker>[
                            Marker(
                              point: points.first,
                              width: 42,
                              height: 42,
                              child: const _RouteMarker(
                                icon: Icons.flag_rounded,
                                color: AppColors.brand,
                              ),
                            ),
                            Marker(
                              point: points.last,
                              width: 42,
                              height: 42,
                              child: const _RouteMarker(
                                icon: Icons.directions_car_filled_rounded,
                                color: AppColors.success,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 200),
                child: _HistorySummaryCard(
                  count: points.length,
                  latest: latest,
                  earliest: earliest,
                ),
              ),
            ],
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (Object error, StackTrace stackTrace) => Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                const Icon(Icons.route_rounded, size: 48, color: Colors.grey),
                const SizedBox(height: 16),
                Text(
                  'No se pudo cargar el trayecto',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  error.toString(),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HistorySummaryCard extends StatelessWidget {
  const _HistorySummaryCard({
    required this.count,
    required this.latest,
    required this.earliest,
  });

  final int count;
  final TelemetryRecord latest;
  final TelemetryRecord earliest;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(24),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Trayecto guardado',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 16),
          _SummaryRow(
            icon: Icons.timeline_rounded,
            label: 'Puntos almacenados',
            value: '$count registros',
          ),
          const SizedBox(height: 12),
          _SummaryRow(
            icon: Icons.schedule_rounded,
            label: 'Inicio',
            value: Parsers.formatRelativeTimestamp(earliest.recordedAt),
          ),
          const SizedBox(height: 12),
          _SummaryRow(
            icon: Icons.place_rounded,
            label: 'Última muestra',
            value: Parsers.formatRelativeTimestamp(latest.recordedAt),
          ),
        ],
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: AppColors.brandSoft,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: AppColors.brand),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(label, style: Theme.of(context).textTheme.labelMedium),
              Text(
                value,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _RouteMarker extends StatelessWidget {
  const _RouteMarker({required this.icon, required this.color});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 14,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: DecoratedBox(
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          child: Icon(icon, color: Colors.white, size: 18),
        ),
      ),
    );
  }
}

class _EmptyHistoryState extends StatelessWidget {
  const _EmptyHistoryState();

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
              'Todavía no hay trayecto suficiente',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            Text(
              'Cuando el tracker guarde al menos dos posiciones, aquí verás el recorrido persistido.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}
