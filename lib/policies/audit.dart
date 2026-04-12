import 'dart:convert';
import 'dart:io';

class AuditEvent {
  const AuditEvent({
    required this.timestamp,
    required this.actor,
    required this.method,
    required this.riskClass,
    required this.approved,
    required this.result,
    this.workspaceRoot,
    this.sessionId,
    this.tool,
    this.durationMs,
    this.errorCode,
    this.approvalRequestId,
  });

  final DateTime timestamp;
  final String actor;
  final String method;
  final String riskClass;
  final bool approved;
  final String result;
  final String? workspaceRoot;
  final String? sessionId;
  final String? tool;
  final int? durationMs;
  final String? errorCode;
  final String? approvalRequestId;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'timestamp': timestamp.toUtc().toIso8601String(),
      'actor': actor,
      'method': method,
      'riskClass': riskClass,
      'workspaceRoot': workspaceRoot,
      'sessionId': sessionId,
      'tool': tool,
      'approved': approved,
      'result': result,
      'durationMs': durationMs,
      'errorCode': errorCode,
      'approvalRequestId': approvalRequestId,
    };
  }
}

class AuditLogger {
  AuditLogger(this.auditFilePath);

  final String auditFilePath;

  Future<void> log(AuditEvent event) async {
    final file = File(auditFilePath);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      '${jsonEncode(event.toJson())}\n',
      mode: FileMode.append,
    );
  }
}
