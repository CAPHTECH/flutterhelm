import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutterhelm/artifacts/resources.dart';
import 'package:flutterhelm/config/config.dart';
import 'package:flutterhelm/policies/audit.dart';
import 'package:flutterhelm/policies/risk.dart';
import 'package:flutterhelm/policies/roots.dart';
import 'package:flutterhelm/server/capabilities.dart';
import 'package:flutterhelm/server/errors.dart';
import 'package:flutterhelm/server/registry.dart';
import 'package:flutterhelm/sessions/session.dart';
import 'package:flutterhelm/sessions/session_store.dart';
import 'package:flutterhelm/version.dart';

class FlutterHelmServer {
  FlutterHelmServer._({
    required this.runtimePaths,
    required this.config,
    required this.stateRepository,
    required this.auditLogger,
    required this.rootPolicy,
    required this.toolRegistry,
    required this.resourceCatalog,
    required this.sessionStore,
    required String logLevel,
    required ServerState state,
  }) : _logLevel = logLevel,
       _state = state;

  final RuntimePaths runtimePaths;
  final FlutterHelmConfig config;
  final StateRepository stateRepository;
  final AuditLogger auditLogger;
  final RootPolicy rootPolicy;
  final ToolRegistry toolRegistry;
  final ResourceCatalog resourceCatalog;
  final SessionStore sessionStore;
  final String _logLevel;

  ServerState _state;
  bool _initializeReceived = false;
  bool _clientInitialized = false;
  bool _clientSupportsRoots = false;
  String _protocolVersion = defaultProtocolVersion;
  List<String>? _cachedClientRoots;
  int _nextServerRequestId = 1;
  final Map<String, Completer<Object?>> _pendingResponses =
      <String, Completer<Object?>>{};

  static Future<FlutterHelmServer> create({
    required RuntimePaths runtimePaths,
    required bool allowRootFallbackFlag,
    required String logLevel,
  }) async {
    final configRepository = ConfigRepository(runtimePaths);
    final config = await configRepository.load();
    final stateRepository = StateRepository(runtimePaths);
    final state = await stateRepository.load();
    final allowRootFallback =
        allowRootFallbackFlag || config.fallbacks.allowRootFallback;

    return FlutterHelmServer._(
      runtimePaths: runtimePaths,
      config: config,
      stateRepository: stateRepository,
      auditLogger: AuditLogger(runtimePaths.auditFilePath),
      rootPolicy: RootPolicy(allowRootFallback: allowRootFallback),
      toolRegistry: ToolRegistry(),
      resourceCatalog: const ResourceCatalog(),
      sessionStore: SessionStore(),
      logLevel: logLevel,
      state: state,
    );
  }

  Future<void> run() async {
    final pendingOperations = <Future<void>>{};

    await for (final line
        in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        continue;
      }

      final operation = _dispatchLine(trimmed);
      pendingOperations.add(operation);
      operation.whenComplete(() => pendingOperations.remove(operation));
    }

    if (pendingOperations.isNotEmpty) {
      await Future.wait(pendingOperations);
    }
  }

  Future<void> _dispatchLine(String line) async {
    try {
      final decoded = jsonDecode(line);
      await _handleIncoming(decoded);
    } on FormatException catch (error) {
      _sendProtocolError(
        null,
        -32700,
        'Parse error',
        data: <String, Object?>{'details': error.message},
      );
    } catch (error, stackTrace) {
      _log('Unhandled dispatch error: $error');
      if (_logLevel == 'debug') {
        _log(stackTrace.toString());
      }
      _sendProtocolError(null, -32603, 'Internal error');
    }
  }

  Future<void> _handleIncoming(Object? payload) async {
    if (payload is List<Object?>) {
      for (final item in payload) {
        unawaited(_handleIncoming(item));
      }
      return;
    }

    if (payload is! Map<String, Object?>) {
      throw const FormatException('Expected a JSON object.');
    }

    final method = payload['method'];
    final id = payload['id'];
    if (method is String) {
      if (id == null) {
        await _handleNotification(method, _asMap(payload['params']));
        return;
      }
      await _handleRequest(id, method, _asMap(payload['params']));
      return;
    }

    if (payload.containsKey('id')) {
      _handleResponse(id, payload['result'], payload['error']);
      return;
    }

    throw const FormatException('Unsupported JSON-RPC envelope.');
  }

  Future<void> _handleNotification(
    String method,
    Map<String, Object?> params,
  ) async {
    switch (method) {
      case 'notifications/initialized':
        _clientInitialized = true;
        return;
      case 'notifications/roots/list_changed':
        _cachedClientRoots = null;
        return;
      default:
        return;
    }
  }

  Future<void> _handleRequest(
    Object id,
    String method,
    Map<String, Object?> params,
  ) async {
    final startedAt = DateTime.now().toUtc();

    try {
      switch (method) {
        case 'initialize':
          final result = _handleInitialize(params);
          _sendResult(id, result);
          await _recordAudit(
            method: method,
            riskClass: RiskClass.readOnly,
            result: 'success',
            startedAt: startedAt,
          );
          return;
        case 'ping':
          _sendResult(id, <String, Object?>{});
          await _recordAudit(
            method: method,
            riskClass: RiskClass.readOnly,
            result: 'success',
            startedAt: startedAt,
          );
          return;
        case 'logging/setLevel':
          _ensureInitialized();
          _sendResult(id, <String, Object?>{});
          await _recordAudit(
            method: method,
            riskClass: RiskClass.readOnly,
            result: 'success',
            startedAt: startedAt,
          );
          return;
        case 'tools/list':
          _ensureInitialized();
          _sendResult(id, <String, Object?>{
            'tools': toolRegistry
                .publicDefinitions(config)
                .map((ToolDefinition tool) => tool.toMcpTool())
                .toList(),
          });
          await _recordAudit(
            method: method,
            riskClass: RiskClass.readOnly,
            result: 'success',
            startedAt: startedAt,
          );
          return;
        case 'tools/call':
          _ensureInitialized();
          final toolName = _requiredString(params['name'], 'name');
          final arguments = _asMap(params['arguments']);
          final definition = toolRegistry.byName(toolName);
          if (definition == null) {
            throw FlutterHelmProtocolError(-32602, 'Unknown tool: $toolName');
          }
          final toolResult = await _executeTool(definition, arguments);
          _sendResult(id, toolResult);
          await _recordAudit(
            method: method,
            riskClass: definition.risk,
            result: toolResult['isError'] == true ? 'failure' : 'success',
            startedAt: startedAt,
            workspaceRoot: _extractWorkspaceRoot(
              toolResult['structuredContent'],
            ),
            sessionId: _extractSessionId(toolResult['structuredContent']),
            tool: toolName,
            errorCode: _extractErrorCode(toolResult['structuredContent']),
          );
          return;
        case 'resources/list':
          _ensureInitialized();
          final rootsSnapshot = await _currentRootSnapshot();
          final resources = resourceCatalog
              .listResources(
                config: config,
                state: _state,
                rootSnapshot: rootsSnapshot,
                sessions: sessionStore.listActiveSessions(),
              )
              .map((ResourceDescriptor resource) => resource.toJson())
              .toList();
          _sendResult(id, <String, Object?>{'resources': resources});
          await _recordAudit(
            method: method,
            riskClass: RiskClass.readOnly,
            result: 'success',
            startedAt: startedAt,
          );
          return;
        case 'resources/read':
          _ensureInitialized();
          final uri = _requiredString(params['uri'], 'uri');
          final rootsSnapshot = await _currentRootSnapshot();
          final sessionId = _sessionIdFromUri(uri);
          final session = sessionId == null
              ? null
              : sessionStore.getById(sessionId);
          final resource = resourceCatalog.readResource(
            uri: uri,
            config: config,
            state: _state,
            rootSnapshot: rootsSnapshot,
            session: session,
          );
          _sendResult(id, resource.toJson());
          await _recordAudit(
            method: method,
            riskClass: RiskClass.readOnly,
            result: 'success',
            startedAt: startedAt,
            sessionId: sessionId,
            workspaceRoot: _state.activeRoot,
          );
          return;
        default:
          throw FlutterHelmProtocolError(-32601, 'Method not found: $method');
      }
    } on FlutterHelmProtocolError catch (error) {
      _sendProtocolError(id, error.code, error.message, data: error.data);
      await _recordAudit(
        method: method,
        riskClass: RiskClass.readOnly,
        result: 'failure',
        startedAt: startedAt,
        errorCode: error.message,
      );
    } catch (error, stackTrace) {
      if (error is FlutterHelmToolError) {
        _sendResult(id, _toolErrorResult(error));
        await _recordAudit(
          method: method,
          riskClass: RiskClass.readOnly,
          result: 'failure',
          startedAt: startedAt,
          errorCode: error.code,
        );
        return;
      }

      _log('Unhandled request error: $error');
      if (_logLevel == 'debug') {
        _log(stackTrace.toString());
      }
      _sendProtocolError(id, -32603, 'Internal error');
      await _recordAudit(
        method: method,
        riskClass: RiskClass.readOnly,
        result: 'failure',
        startedAt: startedAt,
        errorCode: 'INTERNAL_ERROR',
      );
    }
  }

  Map<String, Object?> _handleInitialize(Map<String, Object?> params) {
    final clientVersion = _requiredString(
      params['protocolVersion'],
      'protocolVersion',
    );
    _clientSupportsRoots = _asMap(params['capabilities'])['roots'] is Map;
    _protocolVersion = supportedProtocolVersions.contains(clientVersion)
        ? clientVersion
        : defaultProtocolVersion;
    _initializeReceived = true;

    return <String, Object?>{
      'protocolVersion': _protocolVersion,
      'capabilities': buildServerCapabilities(
        toolRegistry: toolRegistry,
        config: config,
      ),
      'serverInfo': <String, Object?>{
        'name': flutterHelmName,
        'title': flutterHelmTitle,
        'version': flutterHelmVersion,
      },
      'instructions':
          'Phase 0 server: workspace/session contract only. Use resources for config:// and session:// payloads.',
    };
  }

  Future<Map<String, Object?>> _executeTool(
    ToolDefinition definition,
    Map<String, Object?> arguments,
  ) async {
    try {
      switch (definition.name) {
        case 'workspace_show':
          final snapshot = await _currentRootSnapshot();
          final resources = resourceCatalog.listResources(
            config: config,
            state: _state,
            rootSnapshot: snapshot,
            sessions: sessionStore.listActiveSessions(),
          );
          final structuredContent = <String, Object?>{
            'rootsMode': snapshot.mode.wireName,
            'clientRoots': snapshot.clientRoots,
            'configuredRoots': snapshot.configuredRoots,
            'activeRoot': _state.activeRoot,
            'defaults': config.defaults.toJson(),
            'configuredWorkflows': config.enabledWorkflows,
            'implementedWorkflows': <String>['workspace', 'session'],
            'resources': resources
                .where(
                  (ResourceDescriptor resource) =>
                      resource.uri == 'config://workspace/current' ||
                      resource.uri == 'config://workspace/defaults',
                )
                .map((ResourceDescriptor resource) => resource.toJson())
                .toList(),
          };
          final summary = _state.activeRoot == null
              ? 'No active root configured.'
              : 'Active root: ${_state.activeRoot}';
          return _toolSuccessResult(
            summary: summary,
            structuredContent: structuredContent,
            resourceLinks: resources
                .where(
                  (ResourceDescriptor resource) =>
                      resource.uri == 'config://workspace/current' ||
                      resource.uri == 'config://workspace/defaults',
                )
                .map((ResourceDescriptor resource) => resource.toResourceLink())
                .toList(),
          );
        case 'workspace_set_root':
          final clientRoots = await _getClientRoots();
          final requestedRoot = _requiredString(
            arguments['workspaceRoot'],
            'workspaceRoot',
          );
          final canonicalRoot = await rootPolicy.validateWorkspaceRoot(
            requestedRoot: requestedRoot,
            clientRoots: clientRoots,
          );
          _state = await stateRepository.save(
            _state.copyWith(
              activeRoot: canonicalRoot,
              updatedAt: DateTime.now().toUtc(),
            ),
          );
          final snapshot = await _currentRootSnapshot();
          return _toolSuccessResult(
            summary: 'Active root set to $canonicalRoot',
            structuredContent: <String, Object?>{
              'workspaceRoot': canonicalRoot,
              'rootsMode': snapshot.mode.wireName,
              'clientRoots': snapshot.clientRoots,
              'configuredRoots': snapshot.configuredRoots,
              'activeRoot': _state.activeRoot,
            },
            resourceLinks: <Map<String, Object?>>[
              resourceCatalog
                  .listResources(
                    config: config,
                    state: _state,
                    rootSnapshot: snapshot,
                    sessions: sessionStore.listActiveSessions(),
                  )
                  .firstWhere(
                    (ResourceDescriptor resource) =>
                        resource.uri == 'config://workspace/current',
                  )
                  .toResourceLink(),
            ],
          );
        case 'session_open':
          final clientRoots = await _getClientRoots();
          final workspaceRootArgument = arguments['workspaceRoot'] as String?;
          final workspaceRoot = workspaceRootArgument != null
              ? await rootPolicy.validateWorkspaceRoot(
                  requestedRoot: workspaceRootArgument,
                  clientRoots: clientRoots,
                )
              : _requireActiveRoot();
          final target =
              (arguments['target'] as String?) ?? config.defaults.target;
          final flavor = arguments['flavor'] as String?;
          final mode = (arguments['mode'] as String?) ?? config.defaults.mode;
          if (!const <String>{'debug', 'profile', 'release'}.contains(mode)) {
            throw FlutterHelmToolError(
              code: 'INVALID_MODE',
              category: 'validation',
              message: 'mode must be debug, profile, or release.',
              retryable: true,
            );
          }
          final session = sessionStore.createContextSession(
            workspaceRoot: workspaceRoot,
            target: target,
            mode: mode,
            flavor: flavor,
          );
          final descriptor = resourceCatalog
              .listResources(
                config: config,
                state: _state,
                rootSnapshot: await _currentRootSnapshot(),
                sessions: sessionStore.listActiveSessions(),
              )
              .firstWhere(
                (ResourceDescriptor resource) =>
                    resource.uri == 'session://${session.sessionId}/summary',
              );
          return _toolSuccessResult(
            summary: 'Opened session ${session.sessionId}.',
            structuredContent: session.toJson(),
            resourceLinks: <Map<String, Object?>>[descriptor.toResourceLink()],
          );
        case 'session_list':
          final sessions = sessionStore.listActiveSessions();
          return _toolSuccessResult(
            summary: '${sessions.length} active session(s).',
            structuredContent: <String, Object?>{
              'sessions': sessions
                  .map((SessionRecord session) => session.toSummaryJson())
                  .toList(),
            },
          );
        default:
          throw FlutterHelmToolError(
            code: 'TOOL_NOT_IMPLEMENTED',
            category: 'internal',
            message: 'Tool not implemented in Phase 0: ${definition.name}',
            retryable: false,
          );
      }
    } on FlutterHelmToolError catch (error) {
      return _toolErrorResult(error);
    }
  }

  Future<RootSnapshot> _currentRootSnapshot() async {
    final clientRoots = await _getClientRoots();
    return rootPolicy.buildSnapshot(
      clientRoots: clientRoots,
      configuredRoots: config.workspace.roots,
      activeRoot: _state.activeRoot,
    );
  }

  Future<List<String>> _getClientRoots() async {
    if (!_clientSupportsRoots) {
      return const <String>[];
    }
    if (_cachedClientRoots != null) {
      return _cachedClientRoots!;
    }
    if (!_clientInitialized) {
      return const <String>[];
    }

    final requestId = 'server-${_nextServerRequestId++}';
    final completer = Completer<Object?>();
    _pendingResponses[requestId] = completer;
    _send(<String, Object?>{
      'jsonrpc': '2.0',
      'id': requestId,
      'method': 'roots/list',
    });

    try {
      final rawResult = await completer.future.timeout(
        const Duration(seconds: 5),
      );
      final result = _asMap(rawResult);
      final roots = _asList(result['roots'])
          .map(_asMap)
          .map((Map<String, Object?> root) => root['uri'])
          .whereType<String>()
          .map((String uri) => Uri.parse(uri).toFilePath())
          .toList();
      _cachedClientRoots = roots;
      return roots;
    } on TimeoutException {
      throw FlutterHelmToolError(
        code: 'ROOTS_LIST_TIMEOUT',
        category: 'roots',
        message: 'Timed out while requesting client roots.',
        retryable: true,
      );
    } finally {
      _pendingResponses.remove(requestId);
    }
  }

  void _handleResponse(Object? id, Object? result, Object? error) {
    final key = id?.toString();
    if (key == null) {
      return;
    }
    final completer = _pendingResponses[key];
    if (completer == null || completer.isCompleted) {
      return;
    }

    if (error is Map<String, Object?>) {
      completer.completeError(
        FlutterHelmToolError(
          code: 'CLIENT_REQUEST_FAILED',
          category: 'roots',
          message:
              error['message'] as String? ??
              'Client rejected the server request.',
          retryable: true,
        ),
      );
      return;
    }
    completer.complete(result);
  }

  String _requireActiveRoot() {
    final activeRoot = _state.activeRoot;
    if (activeRoot == null || activeRoot.isEmpty) {
      throw FlutterHelmToolError(
        code: 'WORKSPACE_ROOT_REQUIRED',
        category: 'workspace',
        message:
            'No active root is configured. Call workspace_set_root first or pass workspaceRoot.',
        retryable: true,
      );
    }
    return activeRoot;
  }

  void _ensureInitialized() {
    if (!_initializeReceived) {
      throw FlutterHelmProtocolError(-32002, 'Server not initialized.');
    }
  }

  Future<void> _recordAudit({
    required String method,
    required RiskClass riskClass,
    required String result,
    required DateTime startedAt,
    String? workspaceRoot,
    String? sessionId,
    String? tool,
    String? errorCode,
  }) async {
    await auditLogger.log(
      AuditEvent(
        timestamp: DateTime.now().toUtc(),
        actor: 'mcp-client',
        method: method,
        riskClass: riskClass.wireName,
        workspaceRoot: workspaceRoot,
        sessionId: sessionId,
        tool: tool,
        approved: result == 'success',
        result: result,
        durationMs: DateTime.now().toUtc().difference(startedAt).inMilliseconds,
        errorCode: errorCode,
      ),
    );
  }

  Map<String, Object?> _toolSuccessResult({
    required String summary,
    required Map<String, Object?> structuredContent,
    List<Map<String, Object?>> resourceLinks = const <Map<String, Object?>>[],
  }) {
    return <String, Object?>{
      'content': <Map<String, Object?>>[
        <String, Object?>{'type': 'text', 'text': summary},
        ...resourceLinks,
      ],
      'structuredContent': structuredContent,
      'isError': false,
    };
  }

  Map<String, Object?> _toolErrorResult(FlutterHelmToolError error) {
    return <String, Object?>{
      'content': <Map<String, Object?>>[
        <String, Object?>{'type': 'text', 'text': error.message},
      ],
      'structuredContent': <String, Object?>{'error': error.toJson()},
      'isError': true,
    };
  }

  void _sendResult(Object id, Map<String, Object?> result) {
    _send(<String, Object?>{'jsonrpc': '2.0', 'id': id, 'result': result});
  }

  void _sendProtocolError(
    Object? id,
    int code,
    String message, {
    Map<String, Object?>? data,
  }) {
    _send(<String, Object?>{
      'jsonrpc': '2.0',
      'id': id,
      'error': <String, Object?>{
        'code': code,
        'message': message,
        if (data != null) 'data': data,
      },
    });
  }

  void _send(Map<String, Object?> message) {
    stdout.writeln(jsonEncode(message));
  }

  void _log(String message) {
    stderr.writeln(message);
  }
}

Map<String, Object?> _asMap(Object? value) {
  if (value is Map<String, Object?>) {
    return value;
  }
  if (value is Map) {
    return value.map<String, Object?>(
      (Object? key, Object? nestedValue) =>
          MapEntry<String, Object?>(key.toString(), nestedValue),
    );
  }
  return <String, Object?>{};
}

List<Object?> _asList(Object? value) {
  if (value is List<Object?>) {
    return value;
  }
  if (value is List) {
    return value.cast<Object?>();
  }
  return const <Object?>[];
}

String _requiredString(Object? value, String fieldName) {
  if (value is String && value.isNotEmpty) {
    return value;
  }
  throw FlutterHelmProtocolError(-32602, 'Missing required field: $fieldName');
}

String? _extractWorkspaceRoot(Object? structuredContent) {
  final content = _asMap(structuredContent);
  return content['workspaceRoot'] as String? ??
      content['activeRoot'] as String?;
}

String? _extractSessionId(Object? structuredContent) {
  final content = _asMap(structuredContent);
  return content['sessionId'] as String?;
}

String? _extractErrorCode(Object? structuredContent) {
  final content = _asMap(structuredContent);
  return _asMap(content['error'])['code'] as String?;
}

String? _sessionIdFromUri(String uri) {
  final match = RegExp(r'^session://([^/]+)/summary$').firstMatch(uri);
  return match?.group(1);
}
