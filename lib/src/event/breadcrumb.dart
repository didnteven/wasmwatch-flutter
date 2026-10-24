enum SeverityLevel { debug, info, warning, error, fatal }

class Breadcrumb {
  const Breadcrumb({
    required this.category,
    this.message,
    this.level = SeverityLevel.info,
    this.data = const {},
    this.timestamp,
  });

  final String category;
  final String? message;
  final SeverityLevel level;
  final Map<String, Object?> data;
  final DateTime? timestamp;

  Breadcrumb copyWith({DateTime? timestamp, Map<String, Object?>? data}) =>
      Breadcrumb(
          category: category,
          message: message,
          level: level,
          timestamp: timestamp ?? this.timestamp,
          data: data ?? this.data);

  Map<String, Object?> toJson() => {
        'timestamp': (timestamp ?? DateTime.now()).toUtc().toIso8601String(),
        'category': category,
        if (message != null) 'message': message,
        'level': level.name,
        if (data.isNotEmpty) 'data': data,
      };
}
