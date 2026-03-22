abstract final class SourceTime {
  static const Duration fixedOffset = Duration(hours: 1);

  static DateTime fromUnixSeconds(num value) {
    return DateTime.fromMillisecondsSinceEpoch(
      (value.toDouble() * 1000).round(),
      isUtc: true,
    ).add(fixedOffset);
  }

  static DateTime? fromUnknown(Object? value) {
    if (value is num) {
      return fromUnixSeconds(value);
    }

    if (value is String && value.isNotEmpty) {
      return DateTime.tryParse(value)?.add(fixedOffset);
    }

    return null;
  }

  static DateTime now() {
    return DateTime.now().toUtc().add(fixedOffset);
  }
}