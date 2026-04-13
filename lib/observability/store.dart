class ObservabilityStore {
  ObservabilityStore() : _startedAt = DateTime.now().toUtc();

  final DateTime _startedAt;
  final Map<String, int> _transportRequests = <String, int>{};
  final Map<String, int> _transportErrors = <String, int>{};
  final Map<String, int> _sessionLifecycle = <String, int>{};
  final Map<String, int> _resourcePublications = <String, int>{};
  final Map<String, int> _resourceReads = <String, int>{};
  final Map<String, _TimingAccumulator> _adapterInvocations =
      <String, _TimingAccumulator>{};
  Map<String, Object?>? _lastRetentionSweep;

  void recordTransportRequest({
    required String transport,
    required String method,
    required bool success,
    String? errorCode,
  }) {
    final key = '$transport:$method';
    _transportRequests.update(key, (int value) => value + 1, ifAbsent: () => 1);
    if (!success) {
      final errorKey = errorCode == null ? key : '$key:$errorCode';
      _transportErrors.update(
        errorKey,
        (int value) => value + 1,
        ifAbsent: () => 1,
      );
    }
  }

  void recordSessionLifecycle(String event) {
    _sessionLifecycle.update(event, (int value) => value + 1, ifAbsent: () => 1);
  }

  void recordResourcePublished(String uri) {
    final kind = _resourceKind(uri);
    _resourcePublications.update(
      kind,
      (int value) => value + 1,
      ifAbsent: () => 1,
    );
  }

  void recordResourceRead(String uri) {
    final kind = _resourceKind(uri);
    _resourceReads.update(kind, (int value) => value + 1, ifAbsent: () => 1);
  }

  void recordAdapterInvocation({
    required String providerId,
    required String family,
    required String operation,
    required Duration duration,
    required bool success,
  }) {
    final key = '$providerId:$family:$operation';
    final accumulator = _adapterInvocations.putIfAbsent(
      key,
      () => _TimingAccumulator(
        providerId: providerId,
        family: family,
        operation: operation,
      ),
    );
    accumulator.record(duration, success: success);
  }

  void recordRetentionSweep(Map<String, Object?> summary) {
    _lastRetentionSweep = Map<String, Object?>.from(summary);
  }

  Map<String, Object?> snapshot() {
    final adapterTimings = _adapterInvocations.values.toList()
      ..sort(
        (_TimingAccumulator left, _TimingAccumulator right) =>
            left.key.compareTo(right.key),
      );
    return <String, Object?>{
      'startedAt': _startedAt.toIso8601String(),
      'transport': <String, Object?>{
        'requests': _sortedMap(_transportRequests),
        'errors': _sortedMap(_transportErrors),
        'totalRequests': _countTotal(_transportRequests),
        'totalErrors': _countTotal(_transportErrors),
      },
      'sessions': <String, Object?>{
        'lifecycle': _sortedMap(_sessionLifecycle),
        'totalEvents': _countTotal(_sessionLifecycle),
      },
      'resources': <String, Object?>{
        'published': _sortedMap(_resourcePublications),
        'reads': _sortedMap(_resourceReads),
        'totalPublished': _countTotal(_resourcePublications),
        'totalReads': _countTotal(_resourceReads),
      },
      'adapters': <String, Object?>{
        'timings': adapterTimings
            .map((_TimingAccumulator accumulator) => accumulator.toJson())
            .toList(),
      },
      'retention': <String, Object?>{
        if (_lastRetentionSweep != null) 'lastSweep': _lastRetentionSweep,
      },
    };
  }

  String _resourceKind(String uri) {
    final separator = uri.indexOf('://');
    if (separator <= 0) {
      return uri;
    }
    return uri.substring(0, separator);
  }

  Map<String, int> _sortedMap(Map<String, int> source) {
    final entries = source.entries.toList()
      ..sort((MapEntry<String, int> left, MapEntry<String, int> right) {
        return left.key.compareTo(right.key);
      });
    return <String, int>{for (final entry in entries) entry.key: entry.value};
  }

  int _countTotal(Map<String, int> source) {
    return source.values.fold<int>(0, (int total, int value) => total + value);
  }
}

class _TimingAccumulator {
  _TimingAccumulator({
    required this.providerId,
    required this.family,
    required this.operation,
  });

  final String providerId;
  final String family;
  final String operation;
  int count = 0;
  int successCount = 0;
  int failureCount = 0;
  int totalDurationMs = 0;
  int maxDurationMs = 0;
  int? minDurationMs;

  String get key => '$providerId:$family:$operation';

  void record(Duration duration, {required bool success}) {
    final durationMs = duration.inMilliseconds;
    count += 1;
    totalDurationMs += durationMs;
    if (success) {
      successCount += 1;
    } else {
      failureCount += 1;
    }
    if (durationMs > maxDurationMs) {
      maxDurationMs = durationMs;
    }
    if (minDurationMs == null || durationMs < minDurationMs!) {
      minDurationMs = durationMs;
    }
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'providerId': providerId,
      'family': family,
      'operation': operation,
      'count': count,
      'successCount': successCount,
      'failureCount': failureCount,
      'totalDurationMs': totalDurationMs,
      'averageDurationMs': count == 0 ? 0 : (totalDurationMs / count).round(),
      'maxDurationMs': maxDurationMs,
      if (minDurationMs != null) 'minDurationMs': minDurationMs,
    };
  }
}
