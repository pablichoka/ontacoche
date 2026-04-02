import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ontacoche/theme/app_colors.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/tracking_flow.dart';
import '../providers/api_provider.dart';
import '../providers/vehicle_state_provider.dart';
import '../utils/parsers.dart';

class DynamicIsland extends ConsumerStatefulWidget {
  const DynamicIsland({super.key});

  @override
  ConsumerState<DynamicIsland> createState() => _DynamicIslandState();
}

class _DynamicIslandState extends ConsumerState<DynamicIsland>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _animation;
  bool _isExpanded = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _animation = CurvedAnimation(
      parent: _controller,
      curve: Curves.fastOutSlowIn,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _toggleExpanded() {
    setState(() {
      _isExpanded = !_isExpanded;
      if (_isExpanded) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final double screenWidth = MediaQuery.of(context).size.width;
    final double maxWidth = screenWidth - 32;
    const double compactWidth = 220;

    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        final double factor = _animation.value;
        final Widget islandBody = PhysicalModel(
          color: Colors.transparent,
          elevation: _isExpanded ? 18 : 10,
          shadowColor: AppColors.secondary.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(_isExpanded ? 32 : 28),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: _toggleExpanded,
              borderRadius: BorderRadius.circular(_isExpanded ? 32 : 28),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOutCubic,
                width: _isExpanded ? maxWidth : compactWidth,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: AppColors.surfaceContainerLowest.withValues(
                    alpha: 0.90,
                  ),
                  border: Border.all(
                    color: AppColors.foreground.withValues(alpha: 0.12),
                    width: 1,
                  ),
                  borderRadius: BorderRadius.circular(_isExpanded ? 32 : 28),
                ),
                padding: EdgeInsets.symmetric(
                  horizontal: _isExpanded ? 8 : 4,
                  vertical: _isExpanded ? 0 : 4,
                ),
                child: AnimatedSize(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.topCenter,
                  child: DefaultTextStyle(
                    style: const TextStyle(
                      color: AppColors.foreground,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                    child: IconTheme(
                      data: const IconThemeData(color: AppColors.foreground),
                      child: _isExpanded
                          ? Opacity(
                              opacity: factor.clamp(0.0, 1.0),
                              child: ConstrainedBox(
                                constraints: BoxConstraints(
                                  maxHeight:
                                      MediaQuery.of(context).size.height * 0.8,
                                ),
                                child: SingleChildScrollView(
                                  physics: ClampingScrollPhysics(),
                                  child: const _StatusCard(),
                                ),
                              ),
                            )
                          : const Center(
                              child: SizedBox(
                                height: 56,
                                child: _StatusCard(isCompact: true),
                              ),
                            ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );

        return islandBody;
      },
    );
  }
}

class _StatusCard extends ConsumerWidget {
  const _StatusCard({this.isCompact = false});

  final bool isCompact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final initialTrackingState = ref.watch(initialTrackingProvider);
    final realtimeStatus = ref.watch(realtimeTrackingStatusProvider);
    final positionState = ref.watch(positionStreamProvider);
    final historyState = ref.watch(telemetryHistoryProvider);
    final deviceDetailsState = ref.watch(deviceDetailsProvider);

    final rawStatePayload = ref.watch(deviceRawStateProvider);
    final Map<String, dynamic>? rawPayload = rawStatePayload.valueOrNull;
    final Map<String, dynamic>? rawState = (() {
      final dynamic state = rawPayload?['state'];
      if (state is Map) {
        return Map<String, dynamic>.from(state);
      }
      return null;
    })();

    final String deviceName = (() {
      // Prefer device.name from device_last_state: state.device.name
      if (rawPayload != null) {
        final state = rawPayload['state'];
        if (state is Map &&
            state['device'] is Map &&
            state['device']['name'] != null) {
          return state['device']['name'].toString();
        }
      }

      // fallback to previously used details provider
      return deviceDetailsState.maybeWhen(
        data: (d) => (d['name'] ?? 'Tracker').toString(),
        orElse: () => 'Tracker',
      );
    })();

    final position = positionState.valueOrNull ?? initialTrackingState.position;

    if (isCompact) {
      final String batteryText = position?.batteryLevel != null
          ? '${position!.batteryLevel!.toStringAsFixed(0)}%'
          : '--%';

      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            initialTrackingState.hasPosition
                ? Icons.satellite_alt_rounded
                : Icons.travel_explore_rounded,
            color: initialTrackingState.hasPosition
                ? AppColors.brand
                : AppColors.danger,
            size: 18,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              deviceName,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.foreground,
                fontSize: 16,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.2,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Container(width: 1, height: 14, color: AppColors.foreground),
          const SizedBox(width: 12),
          Icon(
            _getBatteryIcon(position?.batteryLevel),
            color: (position?.batteryLevel ?? 100) < 20
                ? Colors.redAccent
                : AppColors.brand,
            size: 18,
          ),
          const SizedBox(width: 4),
          Text(
            batteryText,
            style: const TextStyle(
              color: AppColors.foreground,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      );
    }

    final theme = Theme.of(context);
    final statusText = switch (realtimeStatus) {
      TrackingServiceStatus.ok => 'Información en vivo',
      TrackingServiceStatus.connecting =>
        initialTrackingState.hasPosition
            ? 'Sincronizando en segundo plano'
            : 'Buscando la primera posición',
      TrackingServiceStatus.failure =>
        initialTrackingState.hasPosition
            ? 'Mostrando la última posición disponible'
            : 'Sin conexión con el tracker',
    };

    final String coordinatesText = position == null
        ? 'Esperando la primera posición...'
        : 'Lat ${position.latitude.toStringAsFixed(6)} · Lon ${position.longitude.toStringAsFixed(6)}';

    final String detailText = positionState.maybeWhen(
      data: (current) {
        final bool isMoving = (current.speed ?? 0) > 2;
        final String speed = current.speed == null
            ? 'velocidad desconocida'
            : '${current.speed!.toStringAsFixed(1)} km/h';
        return '${isMoving ? 'En movimiento' : 'Estacionado'} · $speed';
      },
      orElse: () {
        if (position != null) {
          final bool isMoving = (position.speed ?? 0) > 2;
          final String speed = position.speed == null
              ? 'velocidad desconocida'
              : '${position.speed!.toStringAsFixed(1)} km/h';
          return '${isMoving ? 'En movimiento' : 'Estacionado'} · $speed';
        }
        return 'Sin posición recibida todavía';
      },
    );

    final latestStoredRecord = historyState.maybeWhen(
      data: (records) => records.isEmpty ? null : records.first,
      orElse: () => null,
    );

    String lastPositionText = 'Sin posiciones registradas';
    final DateTime? lastTime =
        Parsers.fromUnknown(rawState?['source_ts']) ??
        positionState.valueOrNull?.timestamp ??
        position?.timestamp ??
        latestStoredRecord?.recordedAt;
    if (lastTime != null) {
      lastPositionText = Parsers.formatRelativeTimestamp(lastTime);
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    deviceName,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: AppColors.foreground,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    statusText,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: initialTrackingState.hasPosition
                          ? AppColors.brand
                          : AppColors.danger,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 16),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _getBatteryIcon(position?.batteryLevel),
                    size: 20,
                    color: (position?.batteryLevel ?? 100) < 20
                        ? Colors.redAccent
                        : AppColors.brand,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '${position?.batteryLevel?.toStringAsFixed(0) ?? '--'}%',
                    style: theme.textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w900,
                      color: AppColors.foreground,
                      fontSize: 16,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Divider(height: 1, color: AppColors.muted),
          const SizedBox(height: 8),
          _InfoRow(
            icon: Icons.navigation_rounded,
            label: 'Coordenadas',
            value: coordinatesText,
            onTap: position != null
                ? () {
                    final RenderBox? button =
                        context.findRenderObject() as RenderBox?;
                    final Offset? offset = button?.localToGlobal(Offset.zero);

                    showMenu(
                      context: context,
                      position: RelativeRect.fromLTRB(
                        offset?.dx ?? 100,
                        (offset?.dy ?? 300) + 100,
                        (offset?.dx ?? 100) + 200,
                        0,
                      ),
                      items: [
                        PopupMenuItem(
                          onTap: () {
                            Clipboard.setData(
                              ClipboardData(
                                text:
                                    '${position.latitude}, ${position.longitude}',
                              ),
                            );
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Coordenadas copiadas'),
                              ),
                            );
                          },
                          child: const ListTile(
                            leading: Icon(Icons.copy_rounded),
                            title: Text('Copiar'),
                          ),
                        ),
                        PopupMenuItem(
                          onTap: () async {
                            final url =
                                'google.navigation:q=${position.latitude},${position.longitude}';
                            final fallbackUrl =
                                'https://www.google.com/maps/search/?api=1&query=${position.latitude},${position.longitude}';

                            try {
                              if (await canLaunchUrl(Uri.parse(url))) {
                                await launchUrl(Uri.parse(url));
                              } else {
                                await launchUrl(
                                  Uri.parse(fallbackUrl),
                                  mode: LaunchMode.externalApplication,
                                );
                              }
                            } catch (e) {
                              await launchUrl(
                                Uri.parse(fallbackUrl),
                                mode: LaunchMode.externalApplication,
                              );
                            }
                          },
                          child: const ListTile(
                            leading: Icon(Icons.map_rounded),
                            title: Text('Abrir en Google Maps'),
                          ),
                        ),
                      ],
                    );
                  }
                : null,
          ),
          const SizedBox(height: 12),
          _InfoRow(
            icon: Icons.speed_rounded,
            label: 'Estado actual',
            value: detailText,
          ),
          const SizedBox(height: 12),
          _InfoRow(
            icon: Icons.history_rounded,
            label: 'Última posición',
            value: lastPositionText,
          ),
        ],
      ),
    );
  }

  IconData _getBatteryIcon(double? level) {
    if (level == null) return Icons.battery_unknown_rounded;
    if (level < 15) return Icons.battery_alert_rounded;
    if (level < 30) return Icons.battery_2_bar_rounded;
    if (level < 50) return Icons.battery_3_bar_rounded;
    if (level < 70) return Icons.battery_4_bar_rounded;
    if (level < 90) return Icons.battery_5_bar_rounded;
    return Icons.battery_full_rounded;
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final String value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppColors.surfaceContainerLowest,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 18, color: AppColors.foreground),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        label,
                        style: const TextStyle(
                          color: AppColors.brand,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (onTap != null) ...[
                        const SizedBox(width: 4),
                        const Icon(
                          Icons.arrow_drop_down_rounded,
                          size: 16,
                          color: AppColors.foreground,
                        ),
                      ],
                    ],
                  ),
                  Text(
                    value,
                    style: const TextStyle(
                      color: AppColors.foreground,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
