import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

class ArtifactPinRecord {
  const ArtifactPinRecord({
    required this.uri,
    required this.kind,
    required this.pinnedAt,
    required this.updatedAt,
    this.label,
  });

  final String uri;
  final String kind;
  final DateTime pinnedAt;
  final DateTime updatedAt;
  final String? label;

  ArtifactPinRecord copyWith({
    String? label,
    DateTime? updatedAt,
  }) {
    return ArtifactPinRecord(
      uri: uri,
      kind: kind,
      pinnedAt: pinnedAt,
      updatedAt: updatedAt ?? this.updatedAt,
      label: label ?? this.label,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'uri': uri,
      'kind': kind,
      'pinnedAt': pinnedAt.toUtc().toIso8601String(),
      'updatedAt': updatedAt.toUtc().toIso8601String(),
      if (label != null) 'label': label,
    };
  }

  factory ArtifactPinRecord.fromJson(Map<String, Object?> json) {
    return ArtifactPinRecord(
      uri: json['uri'] as String,
      kind: json['kind'] as String,
      pinnedAt: DateTime.parse(json['pinnedAt'] as String).toUtc(),
      updatedAt: DateTime.parse(json['updatedAt'] as String).toUtc(),
      label: json['label'] as String?,
    );
  }
}

class ArtifactPinStore {
  ArtifactPinStore._(this._filePath);

  final String _filePath;
  final Map<String, ArtifactPinRecord> _records = <String, ArtifactPinRecord>{};

  static Future<ArtifactPinStore> create({required String stateDir}) async {
    final store = ArtifactPinStore._(p.join(stateDir, 'artifacts', 'pins.json'));
    await store._load();
    return store;
  }

  List<ArtifactPinRecord> listPins() {
    final records = _records.values.toList()
      ..sort((left, right) => left.uri.compareTo(right.uri));
    return records;
  }

  ArtifactPinRecord? getByUri(String uri) => _records[uri];

  Set<String> get pinnedUris => _records.keys.toSet();

  Future<ArtifactPinRecord> pin({
    required String uri,
    required String kind,
    String? label,
  }) async {
    final now = DateTime.now().toUtc();
    final existing = _records[uri];
    final record = existing == null
        ? ArtifactPinRecord(
            uri: uri,
            kind: kind,
            pinnedAt: now,
            updatedAt: now,
            label: label,
          )
        : existing.copyWith(
            label: label ?? existing.label,
            updatedAt: now,
          );
    _records[uri] = record;
    await _persist();
    return record;
  }

  Future<ArtifactPinRecord?> unpin(String uri) async {
    final removed = _records.remove(uri);
    if (removed != null) {
      await _persist();
    }
    return removed;
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
    final records = decoded['pins'];
    if (records is! List) {
      return;
    }
    for (final rawRecord in records) {
      if (rawRecord is! Map) {
        continue;
      }
      final record = ArtifactPinRecord.fromJson(
        rawRecord.map<String, Object?>(
          (Object? key, Object? value) =>
              MapEntry<String, Object?>(key.toString(), value),
        ),
      );
      _records[record.uri] = record;
    }
  }

  Future<void> _persist() async {
    final file = File(_filePath);
    await file.parent.create(recursive: true);
    final records = listPins();
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'pins': records.map((ArtifactPinRecord record) => record.toJson()).toList(),
      }),
    );
  }
}
