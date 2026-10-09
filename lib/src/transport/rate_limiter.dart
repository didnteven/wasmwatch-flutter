class RateLimiter {
  RateLimiter({this.maximumPerMinute = 60});
  final int maximumPerMinute;
  final List<DateTime> _timestamps = [];

  bool allow([DateTime? now]) {
    final instant = now ?? DateTime.now();
    _timestamps.removeWhere((time) => instant.difference(time) >= const Duration(minutes: 1));
    if (_timestamps.length >= maximumPerMinute) return false;
    _timestamps.add(instant);
    return true;
  }
}
