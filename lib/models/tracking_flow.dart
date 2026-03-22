import 'package:flutter/material.dart';

import 'device_position.dart';

enum TrackingServiceStatus {
  connecting,
  ok,
  failure,
}

enum InitialTrackingSource {
  fallback,
  persisted,
  remote,
}

enum TrackingIndicatorKind {
  initial,
  realtime,
}

class TrackingIndicatorData {
  const TrackingIndicatorData({
    required this.kind,
    required this.status,
    required this.tooltip,
  });

  final TrackingIndicatorKind kind;
  final TrackingServiceStatus status;
  final String tooltip;

  IconData get icon {
    switch ((kind, status)) {
      case (TrackingIndicatorKind.initial, TrackingServiceStatus.connecting):
        return Icons.travel_explore_rounded;
      case (TrackingIndicatorKind.initial, TrackingServiceStatus.ok):
        return Icons.directions_car_filled_rounded;
      case (TrackingIndicatorKind.initial, TrackingServiceStatus.failure):
        return Icons.sentiment_dissatisfied_rounded;
      case (TrackingIndicatorKind.realtime, TrackingServiceStatus.connecting):
        return Icons.wifi_tethering_rounded;
      case (TrackingIndicatorKind.realtime, TrackingServiceStatus.ok):
        return Icons.rss_feed; // antenna-like icon for live tracking
      case (TrackingIndicatorKind.realtime, TrackingServiceStatus.failure):
        return Icons.wifi_off_rounded;
    }
  }

  Color get iconColor {
    switch (status) {
      case TrackingServiceStatus.connecting:
        return const Color(0xFFF8FAFC);
      case TrackingServiceStatus.ok:
        return const Color(0xFF86EFAC);
      case TrackingServiceStatus.failure:
        return const Color(0xFFFDA4AF);
    }
  }
}

class InitialTrackingState {
  const InitialTrackingState({
    required this.status,
    required this.source,
    this.position,
    this.resolvedAt,
    this.errorMessage,
  });

  const InitialTrackingState.connecting()
      : status = TrackingServiceStatus.connecting,
        source = InitialTrackingSource.fallback,
        position = null,
        resolvedAt = null,
        errorMessage = null;

  final TrackingServiceStatus status;
  final InitialTrackingSource source;
  final DevicePosition? position;
  final DateTime? resolvedAt;
  final String? errorMessage;

  bool get hasPosition => position != null;

  InitialTrackingState copyWith({
    TrackingServiceStatus? status,
    InitialTrackingSource? source,
    DevicePosition? position,
    DateTime? resolvedAt,
    String? errorMessage,
    bool clearPosition = false,
    bool clearResolvedAt = false,
    bool clearErrorMessage = false,
  }) {
    return InitialTrackingState(
      status: status ?? this.status,
      source: source ?? this.source,
      position: clearPosition ? null : (position ?? this.position),
      resolvedAt: clearResolvedAt ? null : (resolvedAt ?? this.resolvedAt),
      errorMessage: clearErrorMessage ? null : (errorMessage ?? this.errorMessage),
    );
  }
}