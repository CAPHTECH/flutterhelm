import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

enum ApprovalConsumeStatus { approved, expired, rejected }

class ApprovalRequestRecord {
  const ApprovalRequestRecord({
    required this.approvalRequestId,
    required this.tool,
    required this.argumentsHash,
    required this.workspaceRoot,
    required this.riskClass,
    required this.createdAt,
    required this.expiresAt,
    required this.used,
    required this.revoked,
  });

  final String approvalRequestId;
  final String tool;
  final String argumentsHash;
  final String workspaceRoot;
  final String riskClass;
  final DateTime createdAt;
  final DateTime expiresAt;
  final bool used;
  final bool revoked;

  bool get isExpired => DateTime.now().toUtc().isAfter(expiresAt);

  ApprovalRequestRecord copyWith({
    bool? used,
    bool? revoked,
  }) {
    return ApprovalRequestRecord(
      approvalRequestId: approvalRequestId,
      tool: tool,
      argumentsHash: argumentsHash,
      workspaceRoot: workspaceRoot,
      riskClass: riskClass,
      createdAt: createdAt,
      expiresAt: expiresAt,
      used: used ?? this.used,
      revoked: revoked ?? this.revoked,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'approvalRequestId': approvalRequestId,
      'tool': tool,
      'argumentsHash': argumentsHash,
      'workspaceRoot': workspaceRoot,
      'riskClass': riskClass,
      'createdAt': createdAt.toUtc().toIso8601String(),
      'expiresAt': expiresAt.toUtc().toIso8601String(),
      'used': used,
      'revoked': revoked,
    };
  }

  factory ApprovalRequestRecord.fromJson(Map<String, Object?> json) {
    return ApprovalRequestRecord(
      approvalRequestId: json['approvalRequestId'] as String,
      tool: json['tool'] as String,
      argumentsHash: json['argumentsHash'] as String,
      workspaceRoot: json['workspaceRoot'] as String,
      riskClass: json['riskClass'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String).toUtc(),
      expiresAt: DateTime.parse(json['expiresAt'] as String).toUtc(),
      used: json['used'] as bool? ?? false,
      revoked: json['revoked'] as bool? ?? false,
    );
  }
}

class ApprovalConsumeResult {
  const ApprovalConsumeResult({
    required this.status,
    this.record,
  });

  final ApprovalConsumeStatus status;
  final ApprovalRequestRecord? record;
}

class ApprovalStore {
  ApprovalStore._(this._filePath);

  final String _filePath;
  final Map<String, ApprovalRequestRecord> _records =
      <String, ApprovalRequestRecord>{};
  int _counter = 0;

  static const Duration defaultTtl = Duration(minutes: 10);

  static Future<ApprovalStore> create({required String stateDir}) async {
    final store = ApprovalStore._(p.join(stateDir, 'approvals.json'));
    await store._load();
    return store;
  }

  Future<ApprovalRequestRecord> createRequest({
    required String tool,
    required String argumentsHash,
    required String workspaceRoot,
    required String riskClass,
    Duration ttl = defaultTtl,
  }) async {
    final now = DateTime.now().toUtc();
    final request = ApprovalRequestRecord(
      approvalRequestId:
          'apr_${now.microsecondsSinceEpoch.toRadixString(36)}_${(_counter++).toRadixString(36)}',
      tool: tool,
      argumentsHash: argumentsHash,
      workspaceRoot: workspaceRoot,
      riskClass: riskClass,
      createdAt: now,
      expiresAt: now.add(ttl),
      used: false,
      revoked: false,
    );
    _records[request.approvalRequestId] = request;
    await _persist();
    return request;
  }

  Future<ApprovalConsumeResult> consume({
    required String approvalToken,
    required String tool,
    required String argumentsHash,
    required String workspaceRoot,
  }) async {
    final record = _records[approvalToken];
    if (record == null) {
      return const ApprovalConsumeResult(status: ApprovalConsumeStatus.rejected);
    }
    if (record.used ||
        record.revoked ||
        record.tool != tool ||
        record.argumentsHash != argumentsHash ||
        record.workspaceRoot != workspaceRoot) {
      return ApprovalConsumeResult(
        status: ApprovalConsumeStatus.rejected,
        record: record,
      );
    }
    if (record.isExpired) {
      _records[approvalToken] = record.copyWith(revoked: true);
      await _persist();
      return ApprovalConsumeResult(
        status: ApprovalConsumeStatus.expired,
        record: _records[approvalToken],
      );
    }
    _records[approvalToken] = record.copyWith(used: true);
    await _persist();
    return ApprovalConsumeResult(
      status: ApprovalConsumeStatus.approved,
      record: _records[approvalToken],
    );
  }

  Future<void> _load() async {
    final file = File(_filePath);
    if (!await file.exists()) {
      return;
    }
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map<String, Object?>) {
      return;
    }
    final records = decoded['records'];
    if (records is! List) {
      return;
    }
    for (final rawRecord in records) {
      if (rawRecord is! Map) {
        continue;
      }
      final record = ApprovalRequestRecord.fromJson(
        rawRecord.map<String, Object?>(
          (Object? key, Object? value) =>
              MapEntry<String, Object?>(key.toString(), value),
        ),
      );
      _records[record.approvalRequestId] = record;
    }
  }

  Future<void> _persist() async {
    final file = File(_filePath);
    await file.parent.create(recursive: true);
    final sorted = _records.values.toList()
      ..sort((left, right) => left.createdAt.compareTo(right.createdAt));
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'records': sorted
            .map((ApprovalRequestRecord record) => record.toJson())
            .toList(),
      }),
    );
  }
}

String stableApprovalArgumentsHash(Map<String, Object?> arguments) {
  final normalized = _normalize(arguments);
  return _fnv1a64(jsonEncode(normalized));
}

Object? _normalize(Object? value) {
  if (value is Map) {
    final entries = value.entries
        .map((MapEntry<dynamic, dynamic> entry) {
          return MapEntry<String, Object?>(
            entry.key.toString(),
            _normalize(entry.value),
          );
        })
        .toList()
      ..sort((left, right) => left.key.compareTo(right.key));
    return <String, Object?>{
      for (final entry in entries) entry.key: entry.value,
    };
  }
  if (value is List) {
    return value.map<Object?>((Object? item) => _normalize(item)).toList();
  }
  return value;
}

String _fnv1a64(String input) {
  var hash = 0xcbf29ce484222325;
  const prime = 0x100000001b3;
  for (final codeUnit in utf8.encode(input)) {
    hash ^= codeUnit;
    hash = (hash * prime) & 0xffffffffffffffff;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}
