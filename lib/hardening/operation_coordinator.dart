import 'package:flutterhelm/server/errors.dart';

class ActiveOperation {
  const ActiveOperation({
    required this.scope,
    required this.key,
    required this.toolName,
    required this.startedAt,
    this.sessionId,
    this.workspaceRoot,
  });

  final String scope;
  final String key;
  final String toolName;
  final DateTime startedAt;
  final String? sessionId;
  final String? workspaceRoot;
}

class OperationCoordinator {
  final Map<String, ActiveOperation> _workspaceLocks =
      <String, ActiveOperation>{};
  final Map<String, ActiveOperation> _sessionLocks = <String, ActiveOperation>{};

  Future<T> runLocked<T>({
    required String toolName,
    String? workspaceRoot,
    String? sessionId,
    required Future<T> Function() action,
  }) async {
    ActiveOperation? workspaceOperation;
    ActiveOperation? sessionOperation;

    if (workspaceRoot != null && workspaceRoot.isNotEmpty) {
      final existing = _workspaceLocks[workspaceRoot];
      if (existing != null) {
        throw _busyError(
          code: 'WORKSPACE_BUSY',
          category: 'workspace',
          scope: 'workspace',
          key: workspaceRoot,
          existing: existing,
        );
      }
      workspaceOperation = ActiveOperation(
        scope: 'workspace',
        key: workspaceRoot,
        toolName: toolName,
        startedAt: DateTime.now().toUtc(),
        sessionId: sessionId,
        workspaceRoot: workspaceRoot,
      );
      _workspaceLocks[workspaceRoot] = workspaceOperation;
    }

    if (sessionId != null && sessionId.isNotEmpty) {
      final existing = _sessionLocks[sessionId];
      if (existing != null) {
        if (workspaceRoot != null &&
            workspaceOperation != null &&
            identical(_workspaceLocks[workspaceRoot], workspaceOperation)) {
          _workspaceLocks.remove(workspaceRoot);
        }
        throw _busyError(
          code: 'SESSION_BUSY',
          category: 'runtime',
          scope: 'session',
          key: sessionId,
          existing: existing,
        );
      }
      sessionOperation = ActiveOperation(
        scope: 'session',
        key: sessionId,
        toolName: toolName,
        startedAt: DateTime.now().toUtc(),
        sessionId: sessionId,
        workspaceRoot: workspaceRoot,
      );
      _sessionLocks[sessionId] = sessionOperation;
    }

    try {
      return await action();
    } finally {
      if (sessionId != null &&
          sessionOperation != null &&
          identical(_sessionLocks[sessionId], sessionOperation)) {
        _sessionLocks.remove(sessionId);
      }
      if (workspaceRoot != null &&
          workspaceOperation != null &&
          identical(_workspaceLocks[workspaceRoot], workspaceOperation)) {
        _workspaceLocks.remove(workspaceRoot);
      }
    }
  }

  FlutterHelmToolError _busyError({
    required String code,
    required String category,
    required String scope,
    required String key,
    required ActiveOperation existing,
  }) {
    return FlutterHelmToolError(
      code: code,
      category: category,
      message:
          'Another ${scope == 'session' ? 'session' : 'workspace'} operation is already running: ${existing.toolName}.',
      retryable: true,
      details: <String, Object?>{
        'busyScope': scope,
        'busyKey': key,
        'activeTool': existing.toolName,
        if (existing.sessionId != null) 'heldBySessionId': existing.sessionId,
        if (existing.workspaceRoot != null) 'workspaceRoot': existing.workspaceRoot,
        'startedAt': existing.startedAt.toUtc().toIso8601String(),
      },
    );
  }
}
