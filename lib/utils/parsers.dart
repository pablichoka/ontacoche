import 'package:cloud_firestore/cloud_firestore.dart';

abstract final class Parsers {
  static DateTime fromUnixSeconds(num value) {
    return DateTime.fromMillisecondsSinceEpoch(
      (value.toDouble() * 1000).round(),
      isUtc: true,
    ).toLocal();
  }

  static DateTime? fromUnknown(Object? value) {
    if (value is Timestamp) {
      return value.toDate().toLocal();
    }

    if (value is num) {
      // firestored numeric timestamps may come as unix seconds or milliseconds
      if (value.abs() >= 100000000000) {
        return DateTime.fromMillisecondsSinceEpoch(
          value.toInt(),
          isUtc: true,
        ).toLocal();
      }
      return fromUnixSeconds(value);
    }

    if (value is String && value.isNotEmpty) {
      final DateTime? parsed = DateTime.tryParse(value);
      return parsed?.toLocal();
    }

    return null;
  }

  static DateTime now() {
    return DateTime.now();
  }

  static String formatRelativeTimestamp(DateTime timestamp) {
    final DateTime current = Parsers.now();
    final Duration difference = current.difference(timestamp);

    if (difference.inMinutes < 60 && difference.inMinutes >= 0) {
      return 'hace ${difference.inMinutes} min';
    }

    if (difference.inHours < 24 && timestamp.day == current.day) {
      String twoDigits(int value) => value.toString().padLeft(2, '0');
      return 'a las ${twoDigits(timestamp.hour)}:${twoDigits(timestamp.minute)}';
    }

    String twoDigits(int value) => value.toString().padLeft(2, '0');
    return '${twoDigits(timestamp.day)}/${twoDigits(timestamp.month)} '
        '${twoDigits(timestamp.hour)}:${twoDigits(timestamp.minute)}';
  }
}
