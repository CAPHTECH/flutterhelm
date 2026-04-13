import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutterhelm/adapters/registry.dart';
import 'package:flutterhelm/artifacts/store.dart';
import 'package:flutterhelm/artifacts/pins.dart';
import 'package:flutterhelm/artifacts/resources.dart';
import 'package:flutterhelm/config/config.dart';
import 'package:flutterhelm/hardening/operation_coordinator.dart';
import 'package:flutterhelm/hardening/tools.dart';
import 'package:flutterhelm/launcher/tools.dart';
import 'package:flutterhelm/platform_bridge/tools.dart';
import 'package:flutterhelm/policies/approvals.dart';
import 'package:flutterhelm/policies/audit.dart';
import 'package:flutterhelm/policies/risk.dart';
import 'package:flutterhelm/policies/roots.dart';
import 'package:flutterhelm/profiling/tools.dart';
import 'package:flutterhelm/runtime/tools.dart';
import 'package:flutterhelm/runtime_interaction/tools.dart';
import 'package:flutterhelm/server/capabilities.dart';
import 'package:flutterhelm/server/errors.dart';
import 'package:flutterhelm/server/registry.dart';
import 'package:flutterhelm/sessions/session.dart';
import 'package:flutterhelm/sessions/session_store.dart';
import 'package:flutterhelm/tests/tools.dart';
import 'package:flutterhelm/utils/process_runner.dart';
import 'package:flutterhelm/version.dart';
import 'package:flutterhelm/workspace/tools.dart';

class ToolAuditEntry {
  const ToolAuditEntry({
    required this.result,
    required this.riskClass,
    this.workspaceRoot,
    this.sessionId,
    this.tool,
    this.errorCode,
    this.approvalRequestId,
    this.approved,
  });

  final String result;
  final RiskClass riskClass;
  final String? workspaceRoot;
  final String? sessionId;
  final String? tool;
  final String? errorCode;
  final String? approvalRequestId;
  final bool? approved;
}

class ToolExecutionResult {
  const ToolExecutionResult({
    required this.response,
    required this.audits,
  });

  final Map<String, Object?> response;
  final List<ToolAuditEntry> audits;
}

class ApprovalCheckResult {
  const ApprovalCheckResult({
    this.shortCircuit,
    this.approvalRequestId,
  });

  final ToolExecutionResult? shortCircuit;
  final String? approvalRequestId;
}

enum TransportMode { stdio, http }

extension on TransportMode {
  String get wireName => switch (this) {
    TransportMode.stdio => 'stdio',
    TransportMode.http => 'http',
  };
}

const Duration _httpPreviewSweepInterval = Duration(minutes: 5);
const Duration _httpPreviewExpiredSessionRetention = Duration(hours: 1);
const String _httpPreviewExpiryOverrideEnv =
    'FLUTTERHELM_HTTP_PREVIEW_SESSION_EXPIRY_MINUTES_OVERRIDE';

typedef ServerEmitter = void Function(Map<String, Object?> message);

class ClientSessionContext {
  ClientSessionContext({
    required this.transportMode,
    this.httpSessionId,
    DateTime? lastSeenAt,
  }) : lastSeenAt = lastSeenAt ?? DateTime.now().toUtc();

  final TransportMode transportMode;
  final String? httpSessionId;
  DateTime lastSeenAt;

  bool initializeReceived = false;
  bool clientInitialized = false;
  bool clientSupportsRoots = false;
  String protocolVersion = defaultProtocolVersion;
  List<String>? cachedClientRoots;
  int nextServerRequestId = 1;
  final Map<String, Completer<Object?>> pendingResponses =
      <String, Completer<Object?>>{};

  bool get rootsTransportSupported => transportMode == TransportMode.stdio;

  void touch(DateTime now) {
    lastSeenAt = now;
  }
}

class FlutterHelmServer {
  FlutterHelmServer._({
    required this.runtimePaths,
    required this.config,
    required this.stateRepository,
    required this.auditLogger,
    required this.approvalStore,
    required this.rootPolicy,
    required this.toolRegistry,
    required this.artifactStore,
    required this.resourceCatalog,
    required this.sessionStore,
    required this.processRunner,
    required this.adapterRegistry,
    required this.workspaceTools,
    required this.hardeningTools,
    required this.operationCoordinator,
    required this.runtimeInteractionTools,
    required this.launcherTools,
    required this.runtimeTools,
    required this.profilingTools,
    required this.nativeBridgeTools,
    required this.testTools,
    required String logLevel,
    required ServerState state,
  }) : _logLevel = logLevel,
       _state = state;

  final RuntimePaths runtimePaths;
  final FlutterHelmConfig config;
  final StateRepository stateRepository;
  final AuditLogger auditLogger;
  final ApprovalStore approvalStore;
  final RootPolicy rootPolicy;
  final ToolRegistry toolRegistry;
  final ArtifactStore artifactStore;
  final ResourceCatalog resourceCatalog;
  final SessionStore sessionStore;
  final ProcessRunner processRunner;
  final AdapterRegistry adapterRegistry;
  final WorkspaceToolService workspaceTools;
  final HardeningToolService hardeningTools;
  final OperationCoordinator operationCoordinator;
  final RuntimeInteractionToolService runtimeInteractionTools;
  final LauncherToolService launcherTools;
  final RuntimeToolService runtimeTools;
  final ProfilingToolService profilingTools;
  final NativeBridgeToolService nativeBridgeTools;
  final TestToolService testTools;
  final String _logLevel;

  ServerState _state;
  final ClientSessionContext _stdioContext = ClientSessionContext(
    transportMode: TransportMode.stdio,
  );
  final Map<String, ClientSessionContext> _httpSessions =
      <String, ClientSessionContext>{};
  final Map<String, DateTime> _expiredHttpSessions =
      <String, DateTime>{};

  static Future<FlutterHelmServer> create({
    required RuntimePaths runtimePaths,
    required bool allowRootFallbackFlag,
    required String logLevel,
    String? selectedProfile,
  }) async {
    final configRepository = ConfigRepository(runtimePaths);
    final config = await configRepository.load(selectedProfile: selectedProfile);
    final stateRepository = StateRepository(runtimePaths);
    final state = await stateRepository.load();
    final allowRootFallback =
        allowRootFallbackFlag || config.fallbacks.allowRootFallback;
    final artifactStore = ArtifactStore(stateDir: runtimePaths.stateDir);
    final artifactPinStore = await ArtifactPinStore.create(
      stateDir: runtimePaths.stateDir,
    );
    await artifactStore.sweepRetention(
      retention: config.retention,
      pinnedUris: artifactPinStore.pinnedUris,
    );
    final approvalStore = await ApprovalStore.create(stateDir: runtimePaths.stateDir);
    final sessionStore = await SessionStore.create(stateDir: runtimePaths.stateDir);
    final processRunner = const ProcessRunner();
    final adapterRegistry = AdapterRegistry(
      config: config,
      processRunner: processRunner,
    );
    final hardeningTools = HardeningToolService(
      artifactStore: artifactStore,
      pinStore: artifactPinStore,
      processRunner: processRunner,
      configRepository: configRepository,
    );
    final runtimeInteractionTools = RuntimeInteractionToolService(
      sessionStore: sessionStore,
      artifactStore: artifactStore,
      workflowEnabled: config.enabledWorkflows.contains('runtime_interaction'),
      driverEnabled:
          config.adapters.providerForFamily('runtimeDriver') != null &&
          (config.adapters.providerForFamily('runtimeDriver')!.kind ==
                  'stdio_json' ||
              config.adapters.runtimeDriverEnabled),
      driverConfigured: config.adapters.providerForFamily('runtimeDriver') != null,
      driverBackend:
          config.adapters.providerForFamily('runtimeDriver')?.kind ??
          'builtin',
      driverAdapter: await adapterRegistry.runtimeDriverAdapter(),
    );

    return FlutterHelmServer._(
      runtimePaths: runtimePaths,
      config: config,
      stateRepository: stateRepository,
      auditLogger: AuditLogger(runtimePaths.auditFilePath),
      approvalStore: approvalStore,
      rootPolicy: RootPolicy(allowRootFallback: allowRootFallback),
      toolRegistry: ToolRegistry(),
      artifactStore: artifactStore,
      resourceCatalog: ResourceCatalog(
        artifactStore: artifactStore,
        sessionHealthBuilder: runtimeInteractionTools.healthForSession,
        sessionAppStateBuilder: runtimeInteractionTools.appStateForSession,
        pinsIndexBuilder: hardeningTools.pinsIndex,
        compatibilityBuilder: (
          FlutterHelmConfig config,
          ServerState state,
          String transportMode,
        ) => hardeningTools.compatibilityCheck(
          config: config,
          activeRoot: state.activeRoot,
          transportMode: transportMode,
        ),
        adaptersBuilder: adapterRegistry.currentResource,
      ),
      sessionStore: sessionStore,
      processRunner: processRunner,
      adapterRegistry: adapterRegistry,
      workspaceTools: WorkspaceToolService(
        processRunner: processRunner,
        artifactStore: artifactStore,
        flutterExecutable: config.adapters.flutterExecutable,
      ),
      hardeningTools: hardeningTools,
      operationCoordinator: OperationCoordinator(),
      runtimeInteractionTools: runtimeInteractionTools,
      launcherTools: LauncherToolService(
        processRunner: processRunner,
        sessionStore: sessionStore,
        artifactStore: artifactStore,
        flutterExecutable: config.adapters.flutterExecutable,
        appStateBuilder: runtimeInteractionTools.appStateForSession,
      ),
      runtimeTools: RuntimeToolService(
        sessionStore: sessionStore,
        artifactStore: artifactStore,
        appStateBuilder: runtimeInteractionTools.appStateForSession,
      ),
      profilingTools: ProfilingToolService(
        sessionStore: sessionStore,
        artifactStore: artifactStore,
      ),
      nativeBridgeTools: NativeBridgeToolService(
        sessionStore: sessionStore,
        artifactStore: artifactStore,
      ),
      testTools: TestToolService(
        processRunner: processRunner,
        artifactStore: artifactStore,
        flutterExecutable: config.adapters.flutterExecutable,
      ),
      logLevel: logLevel,
      state: state,
    );
  }

  Future<void> run() async {
    await runStdio();
  }

  Future<void> runStdio() async {
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
      await _handleIncoming(decoded, _stdioContext, _emitToStdout);
    } on FormatException catch (error) {
      _sendProtocolError(
        _emitToStdout,
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
      _sendProtocolError(_emitToStdout, null, -32603, 'Internal error');
    }
  }

  Future<void> runHttpPreview({
    required String host,
    required int port,
    required String path,
  }) async {
    if (!_isLocalBindHost(host)) {
      throw ConfigException(
        'HTTP preview is localhost-only. Use 127.0.0.1, localhost, or ::1.',
      );
    }
    final server = await HttpServer.bind(host, port);
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    stderr.writeln(
      'HTTP preview listening on http://${server.address.host}:${server.port}$normalizedPath',
    );
    final sweepTimer = Timer.periodic(
      _httpPreviewSweepInterval,
      (_) => _sweepHttpSessions(),
    );
    try {
      await for (final request in server) {
        unawaited(_handleHttpRequest(request, normalizedPath));
      }
    } finally {
      sweepTimer.cancel();
    }
  }

  Future<void> _handleHttpRequest(HttpRequest request, String path) async {
    if (request.uri.path != path) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    final origin = request.headers.value('Origin');
    if (origin != null && !_isLocalOrigin(origin)) {
      await _writeHttpError(
        request,
        statusCode: HttpStatus.forbidden,
        code: 'HTTP_PREVIEW_INVALID_ORIGIN',
        message: 'HTTP preview only accepts localhost origins.',
      );
      return;
    }

    final now = DateTime.now().toUtc();
    _sweepHttpSessions(now: now);

    switch (request.method.toUpperCase()) {
      case 'POST':
        await _handleHttpPost(request, now);
        return;
      case 'DELETE':
        await _handleHttpDelete(request, now);
        return;
      case 'GET':
        request.response.statusCode = HttpStatus.methodNotAllowed;
        request.response.headers.set(HttpHeaders.allowHeader, 'POST, DELETE');
        await request.response.close();
        return;
      default:
        request.response.statusCode = HttpStatus.methodNotAllowed;
        request.response.headers.set(HttpHeaders.allowHeader, 'POST, DELETE');
        await request.response.close();
        return;
    }
  }

  Future<void> _handleHttpPost(HttpRequest request, DateTime now) async {
    final body = await utf8.decoder.bind(request).join();
    late final Object? payload;
    try {
      payload = body.trim().isEmpty ? null : jsonDecode(body);
    } on FormatException catch (error) {
      await _writeHttpError(
        request,
        statusCode: HttpStatus.badRequest,
        code: 'PARSE_ERROR',
        message: error.message,
      );
      return;
    }

    final sessionId = request.headers.value('MCP-Session-Id');
    ClientSessionContext? context;
    var createdSession = false;
    if (sessionId != null && sessionId.isNotEmpty) {
      context = _httpSessions[sessionId];
      if (context == null) {
        if (_expiredHttpSessions.containsKey(sessionId)) {
          await _writeHttpError(
            request,
            statusCode: HttpStatus.notFound,
            code: 'HTTP_PREVIEW_SESSION_EXPIRED',
            message: 'HTTP preview session expired: $sessionId',
          );
          return;
        }
        await _writeHttpError(
          request,
          statusCode: HttpStatus.notFound,
          code: 'HTTP_PREVIEW_SESSION_REQUIRED',
          message: 'Unknown HTTP preview session: $sessionId',
        );
        return;
      }
      if (_isHttpSessionExpired(context, now)) {
        _expireHttpSession(sessionId, now);
        await _writeHttpError(
          request,
          statusCode: HttpStatus.notFound,
          code: 'HTTP_PREVIEW_SESSION_EXPIRED',
          message: 'HTTP preview session expired: $sessionId',
        );
        return;
      }
      final protocolHeader = request.headers.value('MCP-Protocol-Version');
      if (!context.initializeReceived ||
          protocolHeader == null ||
          !supportedProtocolVersions.contains(protocolHeader)) {
        await _writeHttpError(
          request,
          statusCode: HttpStatus.badRequest,
          code: 'HTTP_PREVIEW_INVALID_PROTOCOL',
          message:
              'Initialized HTTP preview requests require a supported MCP-Protocol-Version.',
        );
        return;
      }
      context.touch(now);
    } else {
      if (!_payloadContainsMethod(payload, 'initialize')) {
        await _writeHttpError(
          request,
          statusCode: HttpStatus.badRequest,
          code: 'HTTP_PREVIEW_SESSION_REQUIRED',
          message: 'HTTP preview requires initialize before other requests.',
        );
        return;
      }
      final newSessionId = _generateHttpSessionId();
      context = ClientSessionContext(
        transportMode: TransportMode.http,
        httpSessionId: newSessionId,
        lastSeenAt: now,
      );
      _httpSessions[newSessionId] = context;
      createdSession = true;
    }

    final responses = <Map<String, Object?>>[];
    try {
      context.touch(now);
      await _handleIncoming(
        payload,
        context,
        (Map<String, Object?> message) => responses.add(message),
      );
    } catch (error) {
      if (createdSession && context.httpSessionId != null) {
        _httpSessions.remove(context.httpSessionId);
      }
      await _writeHttpError(
        request,
        statusCode: HttpStatus.internalServerError,
        code: 'INTERNAL_ERROR',
        message: error.toString(),
      );
      return;
    }

    if (context.httpSessionId != null) {
      request.response.headers.set('MCP-Session-Id', context.httpSessionId!);
    }
    request.response.headers.contentType = ContentType.json;
    if (responses.isEmpty) {
      request.response.statusCode = HttpStatus.accepted;
      await request.response.close();
      return;
    }
    final envelope = responses.length == 1 ? responses.single : responses;
    request.response.statusCode = HttpStatus.ok;
    request.response.write(jsonEncode(envelope));
    await request.response.close();
  }

  Future<void> _handleHttpDelete(HttpRequest request, DateTime now) async {
    final sessionId = request.headers.value('MCP-Session-Id');
    if (sessionId == null || sessionId.isEmpty) {
      await _writeHttpError(
        request,
        statusCode: HttpStatus.badRequest,
        code: 'HTTP_PREVIEW_SESSION_REQUIRED',
        message: 'DELETE requires MCP-Session-Id.',
      );
      return;
    }
    _sweepHttpSessions(now: now);
    final removed = _httpSessions.remove(sessionId);
    if (removed == null) {
      if (_expiredHttpSessions.containsKey(sessionId)) {
        await _writeHttpError(
          request,
          statusCode: HttpStatus.notFound,
          code: 'HTTP_PREVIEW_SESSION_EXPIRED',
          message: 'HTTP preview session expired: $sessionId',
        );
        return;
      }
      await _writeHttpError(
        request,
        statusCode: HttpStatus.notFound,
        code: 'HTTP_PREVIEW_SESSION_REQUIRED',
        message: 'Unknown HTTP preview session: $sessionId',
      );
      return;
    }
    request.response.statusCode = HttpStatus.noContent;
    await request.response.close();
  }

  Duration get _httpPreviewSessionExpiry {
    final override = Platform.environment[_httpPreviewExpiryOverrideEnv];
    final minutes = override == null ? 30.0 : double.tryParse(override);
    final effectiveMinutes = minutes == null || minutes <= 0 ? 30.0 : minutes;
    return Duration(
      milliseconds: (effectiveMinutes * Duration.millisecondsPerMinute).round(),
    );
  }

  void _sweepHttpSessions({DateTime? now}) {
    final effectiveNow = now ?? DateTime.now().toUtc();
    final expiry = _httpPreviewSessionExpiry;
    final expiredIds = <String>[];
    for (final entry in _httpSessions.entries) {
      if (effectiveNow.difference(entry.value.lastSeenAt) >= expiry) {
        expiredIds.add(entry.key);
      }
    }
    for (final sessionId in expiredIds) {
      final removed = _httpSessions.remove(sessionId);
      if (removed != null) {
        _expiredHttpSessions[sessionId] = effectiveNow;
      }
    }
    _expiredHttpSessions.removeWhere(
      (_, expiredAt) =>
          effectiveNow.difference(expiredAt) >=
          _httpPreviewExpiredSessionRetention,
    );
  }

  bool _isHttpSessionExpired(ClientSessionContext context, DateTime now) {
    return now.difference(context.lastSeenAt) >= _httpPreviewSessionExpiry;
  }

  void _expireHttpSession(String sessionId, DateTime now) {
    _httpSessions.remove(sessionId);
    _expiredHttpSessions[sessionId] = now;
  }

  Future<void> _writeHttpError(
    HttpRequest request, {
    required int statusCode,
    required String code,
    required String message,
  }) async {
    request.response.statusCode = statusCode;
    request.response.headers.contentType = ContentType.json;
    request.response.write(
      jsonEncode(<String, Object?>{
        'error': <String, Object?>{
          'code': code,
          'message': message,
        },
      }),
    );
    await request.response.close();
  }

  bool _payloadContainsMethod(Object? payload, String method) {
    if (payload is List) {
      for (final item in payload) {
        if (_payloadContainsMethod(item, method)) {
          return true;
        }
      }
      return false;
    }
    final map = _asMap(payload);
    return map['method'] == method;
  }

  bool _isLocalOrigin(String origin) {
    final uri = Uri.tryParse(origin);
    final host = uri?.host ?? origin;
    return host == 'localhost' || host == '127.0.0.1' || host == '::1';
  }

  bool _isLocalBindHost(String host) {
    return host == 'localhost' || host == '127.0.0.1' || host == '::1';
  }

  String _generateHttpSessionId() {
    final micros = DateTime.now().toUtc().microsecondsSinceEpoch;
    return 'http_${micros.toRadixString(36)}';
  }

  Future<void> _handleIncoming(
    Object? payload,
    ClientSessionContext context,
    ServerEmitter emit,
  ) async {
    if (payload is List<Object?>) {
      for (final item in payload) {
        await _handleIncoming(item, context, emit);
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
        await _handleNotification(context, method, _asMap(payload['params']));
        return;
      }
      await _handleRequest(context, emit, id, method, _asMap(payload['params']));
      return;
    }

    if (payload.containsKey('id')) {
      _handleResponse(context, id, payload['result'], payload['error']);
      return;
    }

    throw const FormatException('Unsupported JSON-RPC envelope.');
  }

  Future<void> _handleNotification(
    ClientSessionContext context,
    String method,
    Map<String, Object?> params,
  ) async {
    switch (method) {
      case 'notifications/initialized':
        context.clientInitialized = true;
        return;
      case 'notifications/roots/list_changed':
        context.cachedClientRoots = null;
        return;
      default:
        return;
    }
  }

  Future<void> _handleRequest(
    ClientSessionContext context,
    ServerEmitter emit,
    Object id,
    String method,
    Map<String, Object?> params,
  ) async {
    final startedAt = DateTime.now().toUtc();

    try {
      switch (method) {
        case 'initialize':
          final result = _handleInitialize(context, params);
          _sendResult(emit, id, result);
          await _recordAudit(
            method: method,
            riskClass: RiskClass.readOnly,
            result: 'success',
            startedAt: startedAt,
          );
          return;
        case 'ping':
          _sendResult(emit, id, <String, Object?>{});
          await _recordAudit(
            method: method,
            riskClass: RiskClass.readOnly,
            result: 'success',
            startedAt: startedAt,
          );
          return;
        case 'logging/setLevel':
          _ensureInitialized(context);
          _sendResult(emit, id, <String, Object?>{});
          await _recordAudit(
            method: method,
            riskClass: RiskClass.readOnly,
            result: 'success',
            startedAt: startedAt,
          );
          return;
        case 'tools/list':
          _ensureInitialized(context);
          _sendResult(emit, id, <String, Object?>{
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
          _ensureInitialized(context);
          final toolName = _requiredString(params['name'], 'name');
          final arguments = _asMap(params['arguments']);
          final definition = toolRegistry.byName(toolName);
          if (definition == null) {
            throw FlutterHelmProtocolError(-32602, 'Unknown tool: $toolName');
          }
          final toolResult = await _executeTool(
            context,
            emit,
            definition,
            arguments,
          );
          _sendResult(emit, id, toolResult.response);
          for (final audit in toolResult.audits) {
            await _recordAudit(
              method: method,
              riskClass: audit.riskClass,
              result: audit.result,
              startedAt: startedAt,
              workspaceRoot: audit.workspaceRoot,
              sessionId: audit.sessionId,
              tool: audit.tool ?? toolName,
              errorCode: audit.errorCode,
              approvalRequestId: audit.approvalRequestId,
              approved: audit.approved,
            );
          }
          return;
        case 'resources/list':
          _ensureInitialized(context);
          final rootsSnapshot = await _currentRootSnapshot(context, emit);
          final listedResources = await resourceCatalog.listResources(
            config: config,
            state: _state,
            rootSnapshot: rootsSnapshot,
            sessions: sessionStore.listActiveSessions(),
          );
          final resources = listedResources
              .map((ResourceDescriptor resource) => resource.toJson())
              .toList();
          _sendResult(emit, id, <String, Object?>{'resources': resources});
          await _recordAudit(
            method: method,
            riskClass: RiskClass.readOnly,
            result: 'success',
            startedAt: startedAt,
          );
          return;
        case 'resources/read':
          _ensureInitialized(context);
          final uri = _requiredString(params['uri'], 'uri');
          final rootsSnapshot = await _currentRootSnapshot(context, emit);
          final sessionId = _sessionIdFromUri(uri);
          final session = sessionId == null
              ? null
              : sessionStore.getById(sessionId);
          final resource = await resourceCatalog.readResource(
            uri: uri,
            config: config,
            state: _state,
            rootSnapshot: rootsSnapshot,
            session: session,
            transportMode: context.transportMode.wireName,
            rootsTransportSupported: context.rootsTransportSupported,
          );
          _sendResult(emit, id, resource.toJson());
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
      _sendProtocolError(emit, id, error.code, error.message, data: error.data);
      await _recordAudit(
        method: method,
        riskClass: RiskClass.readOnly,
        result: 'failure',
        startedAt: startedAt,
        errorCode: error.message,
      );
    } catch (error, stackTrace) {
      if (error is FlutterHelmToolError) {
        _sendResult(emit, id, _toolErrorResponse(error));
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
      _sendProtocolError(emit, id, -32603, 'Internal error');
      await _recordAudit(
        method: method,
        riskClass: RiskClass.readOnly,
        result: 'failure',
        startedAt: startedAt,
        errorCode: 'INTERNAL_ERROR',
      );
    }
  }

  Map<String, Object?> _handleInitialize(
    ClientSessionContext context,
    Map<String, Object?> params,
  ) {
    final clientVersion = _requiredString(
      params['protocolVersion'],
      'protocolVersion',
    );
    context.clientSupportsRoots =
        context.rootsTransportSupported &&
        _asMap(params['capabilities'])['roots'] is Map;
    context.protocolVersion = supportedProtocolVersions.contains(clientVersion)
        ? clientVersion
        : defaultProtocolVersion;
    context.initializeReceived = true;

    return <String, Object?>{
      'protocolVersion': context.protocolVersion,
      'capabilities': buildServerCapabilities(
        toolRegistry: toolRegistry,
        config: config,
        transportMode: context.transportMode.wireName,
      ),
      'serverInfo': <String, Object?>{
        'name': flutterHelmName,
        'title': flutterHelmTitle,
        'version': flutterHelmVersion,
      },
      'instructions':
          'Phase 6 hardening server: use tools for workspace/package/run/test orchestration, vm_service-backed profiling, handoff-only native bridge generation, screenshot capture, opt-in runtime interaction, explicit artifact pinning, and compatibility preflight; use resources for logs, widget trees, runtime errors, reports, coverage, session health, profiling captures, screenshots, native handoff bundles, pinned artifact index, and compatibility state.',
    };
  }

  Future<ToolExecutionResult> _executeTool(
    ClientSessionContext context,
    ServerEmitter emit,
    ToolDefinition definition,
    Map<String, Object?> arguments,
  ) async {
    String? currentWorkspaceRoot;
    String? currentSessionId;
    String? currentApprovalRequestId;

    try {
      switch (definition.name) {
        case 'workspace_discover':
          final snapshot = await _currentRootSnapshot(context, emit);
          final roots = <String>{
            ...snapshot.clientRoots,
            ...snapshot.configuredRoots,
            if (snapshot.activeRoot != null) snapshot.activeRoot!,
          }.toList()
            ..sort();
          final workspaces = await workspaceTools.discoverWorkspaces(roots: roots);
          return _toolSuccessExecution(
            definition: definition,
            summary: '${workspaces.length} workspace(s) discovered.',
            structuredContent: <String, Object?>{'workspaces': workspaces},
          );
        case 'workspace_show':
          final snapshot = await _currentRootSnapshot(context, emit);
          final resources = await resourceCatalog.listResources(
            config: config,
            state: _state,
            rootSnapshot: snapshot,
            sessions: sessionStore.listActiveSessions(),
          );
          final activeAdapters = await adapterRegistry.activeAdaptersSummary();
          final structuredContent = <String, Object?>{
            'rootsMode': snapshot.mode.wireName,
            'clientRoots': snapshot.clientRoots,
            'configuredRoots': snapshot.configuredRoots,
            'activeRoot': _state.activeRoot,
            'transportMode': context.transportMode.wireName,
            'httpPreview': context.transportMode == TransportMode.http,
            'rootsTransportSupport': context.rootsTransportSupported
                ? 'supported'
                : 'unsupported',
            'activeProfile': config.activeProfile,
            'availableProfiles': config.availableProfiles,
            'defaults': config.defaults.toJson(),
            'configuredWorkflows': config.enabledWorkflows,
            'implementedWorkflows': _implementedWorkflows(),
            'activeAdapters': activeAdapters,
            'profilingBackend': 'vm_service',
            'profilingOwnershipPolicy': 'owned_only',
            'platformBridgeMode': 'handoff_only',
            'platformBridgeSupportedPlatforms': const <String>['ios', 'android'],
            'runtimeInteractionBackend':
                config.adapters.providerForFamily('runtimeDriver')?.kind ??
                'builtin',
            'runtimeInteractionDefaultEnabled': false,
            'screenshotWorkflow': 'runtime_readonly',
            'hotOpsOwnershipPolicy': 'owned_only',
            'adaptersResource': 'config://adapters/current',
            'compatibilityResource': 'config://compatibility/current',
            'resources': resources
                .where(
                  (ResourceDescriptor resource) =>
                      resource.uri == 'config://workspace/current' ||
                      resource.uri == 'config://workspace/defaults' ||
                      resource.uri == 'config://adapters/current' ||
                      resource.uri == 'config://compatibility/current',
                )
                .map((ResourceDescriptor resource) => resource.toJson())
                .toList(),
          };
          final summary = _state.activeRoot == null
              ? 'No active root configured.'
              : 'Active root: ${_state.activeRoot}';
          return _toolSuccessExecution(
            definition: definition,
            summary: summary,
            structuredContent: structuredContent,
            resourceLinks: resources
                .where(
                  (ResourceDescriptor resource) =>
                      resource.uri == 'config://workspace/current' ||
                      resource.uri == 'config://workspace/defaults' ||
                      resource.uri == 'config://adapters/current' ||
                      resource.uri == 'config://compatibility/current',
                )
                .map((ResourceDescriptor resource) => resource.toResourceLink())
                .toList(),
          );
        case 'compatibility_check':
          final requestedProfile = arguments['profile'] as String?;
          final compatibility = await hardeningTools.compatibilityCheck(
            profile: requestedProfile,
            config: requestedProfile == null ? config : null,
            activeRoot: _state.activeRoot,
            transportMode: context.transportMode.wireName,
          );
          return _toolSuccessExecution(
            definition: definition,
            summary: 'Compatibility matrix resolved.',
            structuredContent: compatibility,
            workspaceRoot: _state.activeRoot,
            resourceLinks: requestedProfile == null
                ? <Map<String, Object?>>[
                    _resourceLink(
                      uri: 'config://compatibility/current',
                      mimeType: 'application/json',
                      title: 'Current compatibility matrix',
                    ),
                  ]
                : const <Map<String, Object?>>[],
          );
        case 'adapter_list':
          final family = arguments['family'] as String?;
          final adapters = await adapterRegistry.list(family: family);
          return _toolSuccessExecution(
            definition: definition,
            summary: family == null
                ? '${adapters.length} adapter family entries resolved.'
                : 'Adapter family $family resolved.',
            structuredContent: <String, Object?>{
              'adapters': adapters,
              'deprecations': config.adapters.deprecations,
              'resource': 'config://adapters/current',
            },
            resourceLinks: <Map<String, Object?>>[
              _resourceLink(
                uri: 'config://adapters/current',
                mimeType: 'application/json',
                title: 'Current adapter registry state',
              ),
            ],
          );
        case 'workspace_set_root':
          final clientRoots = await _getClientRoots(context, emit);
          final requestedRoot = _requiredString(
            arguments['workspaceRoot'],
            'workspaceRoot',
          );
          final canonicalRoot = await rootPolicy.validateWorkspaceRoot(
            requestedRoot: requestedRoot,
            clientRoots: clientRoots,
          );
          currentWorkspaceRoot = canonicalRoot;
          final snapshotBeforeSet = await rootPolicy.buildSnapshot(
            clientRoots: clientRoots,
            configuredRoots: config.workspace.roots,
            activeRoot: _state.activeRoot,
          );
          if (snapshotBeforeSet.mode == RootsMode.fallback) {
            final approval = await _checkApproval(
              definition: definition,
              arguments: arguments,
              workspaceRoot: canonicalRoot,
              reason:
                  'Setting the workspace root in fallback mode expands the writable boundary.',
            );
            if (approval.shortCircuit != null) {
              return approval.shortCircuit!;
            }
            currentApprovalRequestId = approval.approvalRequestId;
          }
          _state = await stateRepository.save(
            _state.copyWith(
              activeRoot: canonicalRoot,
              updatedAt: DateTime.now().toUtc(),
            ),
          );
          final snapshot = await _currentRootSnapshot(context, emit);
          final resources = await resourceCatalog.listResources(
            config: config,
            state: _state,
            rootSnapshot: snapshot,
            sessions: sessionStore.listActiveSessions(),
          );
          return _toolSuccessExecution(
            definition: definition,
            summary: 'Active root set to $canonicalRoot',
            structuredContent: <String, Object?>{
              'workspaceRoot': canonicalRoot,
              'rootsMode': snapshot.mode.wireName,
              'clientRoots': snapshot.clientRoots,
              'configuredRoots': snapshot.configuredRoots,
              'activeRoot': _state.activeRoot,
            },
            workspaceRoot: canonicalRoot,
            approvalRequestId: currentApprovalRequestId,
            resourceLinks: <Map<String, Object?>>[
              resources
                  .firstWhere(
                    (ResourceDescriptor resource) =>
                        resource.uri == 'config://workspace/current',
                  )
                  .toResourceLink(),
            ],
          );
        case 'analyze_project':
          currentWorkspaceRoot = await _resolveWorkspaceRoot(
            context,
            emit,
            arguments['workspaceRoot'] as String?,
          );
          final analysis = await _withWorkspaceLock(
            toolName: definition.name,
            workspaceRoot: currentWorkspaceRoot,
            action: () => workspaceTools.analyzeProject(
              workspaceRoot: currentWorkspaceRoot!,
              fatalInfos: arguments['fatalInfos'] as bool? ?? false,
              fatalWarnings: arguments['fatalWarnings'] as bool? ?? true,
            ),
          );
          return _toolSuccessExecution(
            definition: definition,
            summary:
                'Static analysis completed with ${analysis['issueCount']} issue(s).',
            structuredContent: analysis,
            workspaceRoot: currentWorkspaceRoot,
          );
        case 'resolve_symbol':
          currentWorkspaceRoot = await _resolveWorkspaceRoot(
            context,
            emit,
            arguments['workspaceRoot'] as String?,
          );
          final symbol = _requiredString(arguments['symbol'], 'symbol');
          final resolution = await workspaceTools.resolveSymbol(
            workspaceRoot: currentWorkspaceRoot,
            symbol: symbol,
          );
          final matches = _asList(resolution['matches']);
          return _toolSuccessExecution(
            definition: definition,
            summary: matches.isEmpty
                ? 'No symbol match found for $symbol.'
                : '${matches.length} symbol match(es) found for $symbol.',
            structuredContent: resolution,
            workspaceRoot: currentWorkspaceRoot,
          );
        case 'format_files':
          currentWorkspaceRoot = await _resolveWorkspaceRoot(
            context,
            emit,
            arguments['workspaceRoot'] as String?,
          );
          final paths = _asStringList(arguments['paths']);
          final formatResult = await _withWorkspaceLock(
            toolName: definition.name,
            workspaceRoot: currentWorkspaceRoot,
            action: () => workspaceTools.formatFiles(
              workspaceRoot: currentWorkspaceRoot!,
              paths: paths,
              lineLength: arguments['lineLength'] as int?,
            ),
          );
          return _toolSuccessExecution(
            definition: definition,
            summary: 'Formatting completed for ${paths.length} path(s).',
            structuredContent: formatResult,
            workspaceRoot: currentWorkspaceRoot,
          );
        case 'pub_search':
          final result = await workspaceTools.pubSearch(
            query: _requiredString(arguments['query'], 'query'),
            limit: arguments['limit'] as int? ?? 10,
          );
          return _toolSuccessExecution(
            definition: definition,
            summary: '${_asList(result['packages']).length} package candidate(s) found.',
            structuredContent: result,
          );
        case 'dependency_add':
          currentWorkspaceRoot = await _resolveWorkspaceRoot(
            context,
            emit,
            arguments['workspaceRoot'] as String?,
          );
          final addApproval = await _checkApproval(
            definition: definition,
            arguments: arguments,
            workspaceRoot: currentWorkspaceRoot,
            reason:
                'dependency_add modifies pubspec.yaml and runs package resolution.',
          );
          if (addApproval.shortCircuit != null) {
            return addApproval.shortCircuit!;
          }
          currentApprovalRequestId = addApproval.approvalRequestId;
          final packageName = _requiredString(arguments['package'], 'package');
          final addResult = await _withWorkspaceLock(
            toolName: definition.name,
            workspaceRoot: currentWorkspaceRoot,
            action: () => workspaceTools.dependencyAdd(
              workspaceRoot: currentWorkspaceRoot!,
              package: packageName,
              versionConstraint: arguments['versionConstraint'] as String?,
              devDependency: arguments['devDependency'] as bool? ?? false,
            ),
          );
          return _toolSuccessExecution(
            definition: definition,
            summary: 'Dependency $packageName added.',
            structuredContent: addResult,
            workspaceRoot: currentWorkspaceRoot,
            approvalRequestId: currentApprovalRequestId,
            resourceLinks: <Map<String, Object?>>[
              _resourceLink(
                uri: 'config://workspace/current',
                mimeType: 'application/json',
                title: 'Current workspace configuration',
              ),
              ..._resourceLinksFromPayload(addResult['resources']),
            ],
          );
        case 'dependency_remove':
          currentWorkspaceRoot = await _resolveWorkspaceRoot(
            context,
            emit,
            arguments['workspaceRoot'] as String?,
          );
          final removeApproval = await _checkApproval(
            definition: definition,
            arguments: arguments,
            workspaceRoot: currentWorkspaceRoot,
            reason:
                'dependency_remove modifies pubspec.yaml and runs package resolution.',
          );
          if (removeApproval.shortCircuit != null) {
            return removeApproval.shortCircuit!;
          }
          currentApprovalRequestId = removeApproval.approvalRequestId;
          final packageName = _requiredString(arguments['package'], 'package');
          final removeResult = await _withWorkspaceLock(
            toolName: definition.name,
            workspaceRoot: currentWorkspaceRoot,
            action: () => workspaceTools.dependencyRemove(
              workspaceRoot: currentWorkspaceRoot!,
              package: packageName,
            ),
          );
          return _toolSuccessExecution(
            definition: definition,
            summary: 'Dependency $packageName removed.',
            structuredContent: removeResult,
            workspaceRoot: currentWorkspaceRoot,
            approvalRequestId: currentApprovalRequestId,
            resourceLinks: <Map<String, Object?>>[
              _resourceLink(
                uri: 'config://workspace/current',
                mimeType: 'application/json',
                title: 'Current workspace configuration',
              ),
              ..._resourceLinksFromPayload(removeResult['resources']),
            ],
          );
        case 'session_open':
          final clientRoots = await _getClientRoots(context, emit);
          final workspaceRootArgument = arguments['workspaceRoot'] as String?;
          currentWorkspaceRoot = workspaceRootArgument != null
              ? await rootPolicy.validateWorkspaceRoot(
                  requestedRoot: workspaceRootArgument,
                  clientRoots: clientRoots,
                )
              : _requireActiveRoot();
          final target = (arguments['target'] as String?) ?? config.defaults.target;
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
            workspaceRoot: currentWorkspaceRoot,
            target: target,
            mode: mode,
            flavor: flavor,
          );
          currentSessionId = session.sessionId;
          final resources = await resourceCatalog.listResources(
            config: config,
            state: _state,
            rootSnapshot: await _currentRootSnapshot(context, emit),
            sessions: sessionStore.listActiveSessions(),
          );
          final descriptor = resources.firstWhere(
            (ResourceDescriptor resource) =>
                resource.uri == 'session://${session.sessionId}/summary',
          );
          return _toolSuccessExecution(
            definition: definition,
            summary: 'Opened session ${session.sessionId}.',
            structuredContent: session.toJson(),
            workspaceRoot: currentWorkspaceRoot,
            sessionId: session.sessionId,
            resourceLinks: <Map<String, Object?>>[descriptor.toResourceLink()],
          );
        case 'session_list':
          final sessions = sessionStore.listActiveSessions();
          return _toolSuccessExecution(
            definition: definition,
            summary: '${sessions.length} active session(s).',
            structuredContent: <String, Object?>{
              'sessions': sessions
                  .map((SessionRecord session) => session.toSummaryJson())
                  .toList(),
            },
          );
        case 'artifact_pin':
          final pinResult = await hardeningTools.artifactPin(
            uri: _requiredString(arguments['uri'], 'uri'),
            label: arguments['label'] as String?,
          );
          currentSessionId = _sessionIdFromUri(pinResult['uri'] as String);
          currentWorkspaceRoot = currentSessionId == null
              ? null
              : sessionStore.getById(currentSessionId, touch: false)?.workspaceRoot;
          return _toolSuccessExecution(
            definition: definition,
            summary: 'Artifact pinned.',
            structuredContent: pinResult,
            workspaceRoot: currentWorkspaceRoot,
            sessionId: currentSessionId,
            resourceLinks: <Map<String, Object?>>[
              _resourceLink(
                uri: 'config://artifacts/pins',
                mimeType: 'application/json',
                title: 'Pinned artifacts index',
              ),
            ],
          );
        case 'artifact_unpin':
          final removedUri = _requiredString(arguments['uri'], 'uri');
          currentSessionId = _sessionIdFromUri(removedUri);
          currentWorkspaceRoot = currentSessionId == null
              ? null
              : sessionStore.getById(currentSessionId, touch: false)?.workspaceRoot;
          final unpinResult = await hardeningTools.artifactUnpin(uri: removedUri);
          return _toolSuccessExecution(
            definition: definition,
            summary: 'Artifact unpinned.',
            structuredContent: unpinResult,
            workspaceRoot: currentWorkspaceRoot,
            sessionId: currentSessionId,
            resourceLinks: <Map<String, Object?>>[
              _resourceLink(
                uri: 'config://artifacts/pins',
                mimeType: 'application/json',
                title: 'Pinned artifacts index',
              ),
            ],
          );
        case 'artifact_pin_list':
          currentSessionId = arguments['sessionId'] as String?;
          currentWorkspaceRoot = currentSessionId == null
              ? null
              : sessionStore.getById(currentSessionId, touch: false)?.workspaceRoot;
          final pinList = await hardeningTools.artifactPinList(
            sessionId: currentSessionId,
            kind: arguments['kind'] as String?,
          );
          return _toolSuccessExecution(
            definition: definition,
            summary: '${pinList['count']} pinned artifact(s).',
            structuredContent: pinList,
            workspaceRoot: currentWorkspaceRoot,
            sessionId: currentSessionId,
            resourceLinks: <Map<String, Object?>>[
              _resourceLink(
                uri: 'config://artifacts/pins',
                mimeType: 'application/json',
                title: 'Pinned artifacts index',
              ),
            ],
          );
        case 'device_list':
          final devices = await launcherTools.listDevices();
          return _toolSuccessExecution(
            definition: definition,
            summary: '${devices.length} device(s) available.',
            structuredContent: <String, Object?>{'devices': devices},
          );
        case 'run_app':
          currentWorkspaceRoot = await _resolveWorkspaceRoot(
            context,
            emit,
            arguments['workspaceRoot'] as String?,
          );
          final target = (arguments['target'] as String?) ?? config.defaults.target;
          final flavor = arguments['flavor'] as String?;
          final mode = (arguments['mode'] as String?) ?? config.defaults.mode;
          final platform = _requiredString(arguments['platform'], 'platform');
          final session = await _withWorkspaceLock(
            toolName: definition.name,
            workspaceRoot: currentWorkspaceRoot,
            action: () => launcherTools.runApp(
              workspaceRoot: currentWorkspaceRoot!,
              target: target,
              platform: platform,
              mode: mode,
              flavor: flavor,
              dartDefines: _asStringList(arguments['dartDefines']),
              deviceId: arguments['deviceId'] as String?,
              sessionId: arguments['sessionId'] as String?,
            ),
          );
          currentSessionId = session.sessionId;
          return _toolSuccessExecution(
            definition: definition,
            summary: 'App session ${session.sessionId} is ${session.state.wireName}.',
            structuredContent: <String, Object?>{
              ...session.toJson(),
              'resources': <Map<String, Object?>>[
                <String, Object?>{
                  'uri': 'session://${session.sessionId}/summary',
                  'mimeType': 'application/json',
                  'title': 'Session summary',
                },
                <String, Object?>{
                  'uri': artifactStore.sessionLogUri(session.sessionId, 'stdout'),
                  'mimeType': 'text/plain',
                  'title': 'Startup logs',
                },
              ],
            },
            workspaceRoot: currentWorkspaceRoot,
            sessionId: session.sessionId,
            resourceLinks: <Map<String, Object?>>[
              _resourceLink(
                uri: 'session://${session.sessionId}/summary',
                mimeType: 'application/json',
                title: 'Session summary',
              ),
              _resourceLink(
                uri: artifactStore.sessionLogUri(session.sessionId, 'stdout'),
                mimeType: 'text/plain',
                title: 'Startup logs',
              ),
            ],
          );
        case 'attach_app':
          currentWorkspaceRoot = await _resolveWorkspaceRoot(
            context,
            emit,
            arguments['workspaceRoot'] as String?,
          );
          final attached = await launcherTools.attachApp(
            workspaceRoot: currentWorkspaceRoot,
            platform: _requiredString(arguments['platform'], 'platform'),
            target: (arguments['target'] as String?) ?? config.defaults.target,
            mode: (arguments['mode'] as String?) ?? config.defaults.mode,
            flavor: arguments['flavor'] as String?,
            deviceId: arguments['deviceId'] as String?,
            sessionId: arguments['sessionId'] as String?,
            debugUrl: arguments['debugUrl'] as String?,
            appId: arguments['appId'] as String?,
          );
          currentSessionId = attached.sessionId;
          return _toolSuccessExecution(
            definition: definition,
            summary: 'Attached session ${attached.sessionId} is ready.',
            structuredContent: attached.toJson(),
            workspaceRoot: currentWorkspaceRoot,
            sessionId: attached.sessionId,
            resourceLinks: <Map<String, Object?>>[
              _resourceLink(
                uri: 'session://${attached.sessionId}/summary',
                mimeType: 'application/json',
                title: 'Session summary',
              ),
            ],
          );
        case 'stop_app':
          currentSessionId = _requiredString(arguments['sessionId'], 'sessionId');
          final stopped = await _withSessionLock(
            toolName: definition.name,
            sessionId: currentSessionId,
            action: () => launcherTools.stopApp(sessionId: currentSessionId!),
          );
          currentWorkspaceRoot = stopped.workspaceRoot;
          return _toolSuccessExecution(
            definition: definition,
            summary: 'Session ${stopped.sessionId} is ${stopped.state.wireName}.',
            structuredContent: stopped.toJson(),
            workspaceRoot: currentWorkspaceRoot,
            sessionId: stopped.sessionId,
            resourceLinks: <Map<String, Object?>>[
              _resourceLink(
                uri: 'session://${stopped.sessionId}/summary',
                mimeType: 'application/json',
                title: 'Session summary',
              ),
            ],
          );
        case 'get_logs':
          currentSessionId = _requiredString(arguments['sessionId'], 'sessionId');
          final logs = await runtimeTools.getLogs(
            sessionId: currentSessionId,
            stream: (arguments['stream'] as String?) ?? 'both',
            tailLines: arguments['tailLines'] as int? ?? 200,
          );
          currentWorkspaceRoot = sessionStore.getById(currentSessionId, touch: false)?.workspaceRoot;
          return _toolSuccessExecution(
            definition: definition,
            summary: 'Retrieved ${logs['stream']} logs.',
            structuredContent: logs,
            workspaceRoot: currentWorkspaceRoot,
            sessionId: currentSessionId,
            resourceLinks: _resourceLinksFromPayload(logs['resources']),
          );
        case 'get_runtime_errors':
          currentSessionId = _requiredString(arguments['sessionId'], 'sessionId');
          final runtimeErrors = await runtimeTools.getRuntimeErrors(
            sessionId: currentSessionId,
          );
          currentWorkspaceRoot = sessionStore.getById(currentSessionId, touch: false)?.workspaceRoot;
          return _toolSuccessExecution(
            definition: definition,
            summary: '${runtimeErrors['count']} runtime error(s) found.',
            structuredContent: runtimeErrors,
            workspaceRoot: currentWorkspaceRoot,
            sessionId: currentSessionId,
            resourceLinks: _resourceLinksFromPayload(<Object?>[runtimeErrors['resource']]),
          );
        case 'get_widget_tree':
          currentSessionId = _requiredString(arguments['sessionId'], 'sessionId');
          final depth = arguments['depth'] as int? ?? 3;
          final widgetTree = await runtimeTools.getWidgetTree(
            sessionId: currentSessionId,
            depth: depth,
            includeProperties: arguments['includeProperties'] as bool? ?? false,
          );
          currentWorkspaceRoot = sessionStore.getById(currentSessionId, touch: false)?.workspaceRoot;
          return _toolSuccessExecution(
            definition: definition,
            summary: 'Captured widget tree for session ${widgetTree['sessionId']}.',
            structuredContent: widgetTree,
            workspaceRoot: currentWorkspaceRoot,
            sessionId: currentSessionId,
            resourceLinks: _resourceLinksFromPayload(<Object?>[widgetTree['resource']]),
          );
        case 'get_app_state_summary':
          currentSessionId = _requiredString(arguments['sessionId'], 'sessionId');
          final appState = await runtimeTools.getAppStateSummary(
            sessionId: currentSessionId,
          );
          currentWorkspaceRoot = sessionStore.getById(currentSessionId, touch: false)?.workspaceRoot;
          return _toolSuccessExecution(
            definition: definition,
            summary: 'App state summary retrieved.',
            structuredContent: appState,
            workspaceRoot: currentWorkspaceRoot,
            sessionId: currentSessionId,
            resourceLinks: _resourceLinksFromPayload(<Object?>[appState['resource']]),
          );
        case 'capture_screenshot':
          currentSessionId = _requiredString(arguments['sessionId'], 'sessionId');
          currentWorkspaceRoot =
              sessionStore.getById(currentSessionId, touch: false)?.workspaceRoot;
          final screenshot = await _withSessionLock(
            toolName: definition.name,
            sessionId: currentSessionId,
            action: () => runtimeInteractionTools.captureScreenshot(
              sessionId: currentSessionId!,
              format: (arguments['format'] as String?) ?? 'png',
            ),
          );
          return _toolSuccessExecution(
            definition: definition,
            summary: 'Screenshot captured for session $currentSessionId.',
            structuredContent: screenshot,
            workspaceRoot: currentWorkspaceRoot,
            sessionId: currentSessionId,
            resourceLinks: _resourceLinksFromPayload(<Object?>[screenshot['resource']]),
          );
        case 'tap_widget':
          currentSessionId = _requiredString(arguments['sessionId'], 'sessionId');
          currentWorkspaceRoot =
              sessionStore.getById(currentSessionId, touch: false)?.workspaceRoot;
          final tapped = await _withSessionLock(
            toolName: definition.name,
            sessionId: currentSessionId,
            action: () => runtimeInteractionTools.tapWidget(
              sessionId: currentSessionId!,
              locator: _asMap(arguments['locator']),
              timeoutMs: arguments['timeoutMs'] as int? ?? 3000,
            ),
          );
          return _toolSuccessExecution(
            definition: definition,
            summary: 'Widget tap completed for session $currentSessionId.',
            structuredContent: tapped,
            workspaceRoot: currentWorkspaceRoot,
            sessionId: currentSessionId,
          );
        case 'enter_text':
          currentSessionId = _requiredString(arguments['sessionId'], 'sessionId');
          currentWorkspaceRoot =
              sessionStore.getById(currentSessionId, touch: false)?.workspaceRoot;
          final entered = await _withSessionLock(
            toolName: definition.name,
            sessionId: currentSessionId,
            action: () => runtimeInteractionTools.enterText(
              sessionId: currentSessionId!,
              locator: _asMap(arguments['locator']),
              text: _requiredString(arguments['text'], 'text'),
              replaceExisting: arguments['replaceExisting'] as bool? ?? true,
              submit: arguments['submit'] as bool? ?? false,
              timeoutMs: arguments['timeoutMs'] as int? ?? 3000,
            ),
          );
          return _toolSuccessExecution(
            definition: definition,
            summary: 'Text input completed for session $currentSessionId.',
            structuredContent: entered,
            workspaceRoot: currentWorkspaceRoot,
            sessionId: currentSessionId,
          );
        case 'scroll_until_visible':
          currentSessionId = _requiredString(arguments['sessionId'], 'sessionId');
          currentWorkspaceRoot =
              sessionStore.getById(currentSessionId, touch: false)?.workspaceRoot;
          final scrolled = await _withSessionLock(
            toolName: definition.name,
            sessionId: currentSessionId,
            action: () => runtimeInteractionTools.scrollUntilVisible(
              sessionId: currentSessionId!,
              locator: _asMap(arguments['locator']),
              direction: (arguments['direction'] as String?) ?? 'down',
              maxScrolls: arguments['maxScrolls'] as int? ?? 8,
              stepPixels: arguments['stepPixels'] as int?,
              timeoutMs: arguments['timeoutMs'] as int? ?? 3000,
            ),
          );
          return _toolSuccessExecution(
            definition: definition,
            summary:
                'Scroll completed for session $currentSessionId after ${scrolled['scrollsUsed']} scroll(s).',
            structuredContent: scrolled,
            workspaceRoot: currentWorkspaceRoot,
            sessionId: currentSessionId,
          );
        case 'hot_reload':
          currentSessionId = _requiredString(arguments['sessionId'], 'sessionId');
          currentWorkspaceRoot =
              sessionStore.getById(currentSessionId, touch: false)?.workspaceRoot;
          final reloaded = await _withSessionLock(
            toolName: definition.name,
            sessionId: currentSessionId,
            action: () => launcherTools.hotReload(sessionId: currentSessionId!),
          );
          return _toolSuccessExecution(
            definition: definition,
            summary: 'Hot reload completed for session $currentSessionId.',
            structuredContent: reloaded,
            workspaceRoot: currentWorkspaceRoot,
            sessionId: currentSessionId,
            resourceLinks: _resourceLinksFromPayload(<Object?>[reloaded['resource']]),
          );
        case 'hot_restart':
          currentSessionId = _requiredString(arguments['sessionId'], 'sessionId');
          currentWorkspaceRoot =
              sessionStore.getById(currentSessionId, touch: false)?.workspaceRoot;
          launcherTools.ensureHotRestartAvailable(sessionId: currentSessionId);
          final restartApproval = await _checkApproval(
            definition: definition,
            arguments: arguments,
            workspaceRoot: currentWorkspaceRoot ?? _requireActiveRoot(),
            reason: 'hot_restart is destructive to in-memory runtime state.',
          );
          if (restartApproval.shortCircuit != null) {
            return restartApproval.shortCircuit!;
          }
          currentApprovalRequestId = restartApproval.approvalRequestId;
          final restarted = await _withSessionLock(
            toolName: definition.name,
            sessionId: currentSessionId,
            action: () => launcherTools.hotRestart(sessionId: currentSessionId!),
          );
          return _toolSuccessExecution(
            definition: definition,
            summary: 'Hot restart completed for session $currentSessionId.',
            structuredContent: restarted,
            workspaceRoot: currentWorkspaceRoot,
            sessionId: currentSessionId,
            approvalRequestId: currentApprovalRequestId,
            resourceLinks: _resourceLinksFromPayload(<Object?>[restarted['resource']]),
          );
        case 'start_cpu_profile':
          currentSessionId = _requiredString(arguments['sessionId'], 'sessionId');
          currentWorkspaceRoot = sessionStore.getById(currentSessionId, touch: false)?.workspaceRoot;
          final started = await _withSessionLock(
            toolName: definition.name,
            sessionId: currentSessionId,
            action: () => profilingTools.startCpuProfile(sessionId: currentSessionId!),
          );
          return _toolSuccessExecution(
            definition: definition,
            summary: 'CPU profiling started for session $currentSessionId.',
            structuredContent: started,
            workspaceRoot: currentWorkspaceRoot,
            sessionId: currentSessionId,
          );
        case 'stop_cpu_profile':
          currentSessionId = _requiredString(arguments['sessionId'], 'sessionId');
          currentWorkspaceRoot = sessionStore.getById(currentSessionId, touch: false)?.workspaceRoot;
          final stopped = await _withSessionLock(
            toolName: definition.name,
            sessionId: currentSessionId,
            action: () => profilingTools.stopCpuProfile(sessionId: currentSessionId!),
          );
          return _toolSuccessExecution(
            definition: definition,
            summary: 'CPU profiling capture completed for session $currentSessionId.',
            structuredContent: stopped,
            workspaceRoot: currentWorkspaceRoot,
            sessionId: currentSessionId,
            resourceLinks: _resourceLinksFromPayload(<Object?>[stopped['resource']]),
          );
        case 'capture_timeline':
          currentSessionId = _requiredString(arguments['sessionId'], 'sessionId');
          currentWorkspaceRoot = sessionStore.getById(currentSessionId, touch: false)?.workspaceRoot;
          final timeline = await _withSessionLock(
            toolName: definition.name,
            sessionId: currentSessionId,
            action: () => profilingTools.captureTimeline(
              sessionId: currentSessionId!,
              durationMs: arguments['durationMs'] as int? ?? 3000,
              streams: _asStringList(arguments['streams']).isEmpty
                  ? const <String>['all']
                  : _asStringList(arguments['streams']),
            ),
          );
          return _toolSuccessExecution(
            definition: definition,
            summary: 'Timeline capture completed for session $currentSessionId.',
            structuredContent: timeline,
            workspaceRoot: currentWorkspaceRoot,
            sessionId: currentSessionId,
            resourceLinks: _resourceLinksFromPayload(<Object?>[timeline['resource']]),
          );
        case 'capture_memory_snapshot':
          currentSessionId = _requiredString(arguments['sessionId'], 'sessionId');
          currentWorkspaceRoot = sessionStore.getById(currentSessionId, touch: false)?.workspaceRoot;
          final memory = await _withSessionLock(
            toolName: definition.name,
            sessionId: currentSessionId,
            action: () => profilingTools.captureMemorySnapshot(
              sessionId: currentSessionId!,
              gc: arguments['gc'] as bool? ?? true,
            ),
          );
          return _toolSuccessExecution(
            definition: definition,
            summary: 'Memory snapshot completed for session $currentSessionId.',
            structuredContent: memory,
            workspaceRoot: currentWorkspaceRoot,
            sessionId: currentSessionId,
            resourceLinks: _resourceLinksFromPayload(<Object?>[memory['resource']]),
          );
        case 'toggle_performance_overlay':
          currentSessionId = _requiredString(arguments['sessionId'], 'sessionId');
          currentWorkspaceRoot = sessionStore.getById(currentSessionId, touch: false)?.workspaceRoot;
          final overlay = await _withSessionLock(
            toolName: definition.name,
            sessionId: currentSessionId,
            action: () => profilingTools.togglePerformanceOverlay(
              sessionId: currentSessionId!,
              enabled: arguments['enabled'] as bool? ?? false,
            ),
          );
          return _toolSuccessExecution(
            definition: definition,
            summary: 'Performance overlay updated for session $currentSessionId.',
            structuredContent: overlay,
            workspaceRoot: currentWorkspaceRoot,
            sessionId: currentSessionId,
            resourceLinks: _resourceLinksFromPayload(<Object?>[overlay['resource']]),
          );
        case 'ios_debug_context':
          currentSessionId = _requiredString(arguments['sessionId'], 'sessionId');
          currentWorkspaceRoot = sessionStore.getById(currentSessionId, touch: false)?.workspaceRoot;
          final iosTailLines = arguments['tailLines'] as int? ?? 200;
          final iosContext = await nativeBridgeTools.iosDebugContext(
            sessionId: currentSessionId,
            tailLines: iosTailLines < 1 ? 1 : (iosTailLines > 500 ? 500 : iosTailLines),
          );
          return _toolSuccessExecution(
            definition: definition,
            summary: 'iOS native handoff bundle prepared for session $currentSessionId.',
            structuredContent: iosContext,
            workspaceRoot: currentWorkspaceRoot,
            sessionId: currentSessionId,
            resourceLinks: _resourceLinksFromPayload(<Object?>[iosContext['resource']]),
          );
        case 'android_debug_context':
          currentSessionId = _requiredString(arguments['sessionId'], 'sessionId');
          currentWorkspaceRoot = sessionStore.getById(currentSessionId, touch: false)?.workspaceRoot;
          final androidTailLines = arguments['tailLines'] as int? ?? 200;
          final androidContext = await nativeBridgeTools.androidDebugContext(
            sessionId: currentSessionId,
            tailLines: androidTailLines < 1
                ? 1
                : (androidTailLines > 500 ? 500 : androidTailLines),
          );
          return _toolSuccessExecution(
            definition: definition,
            summary: 'Android native handoff bundle prepared for session $currentSessionId.',
            structuredContent: androidContext,
            workspaceRoot: currentWorkspaceRoot,
            sessionId: currentSessionId,
            resourceLinks: _resourceLinksFromPayload(<Object?>[androidContext['resource']]),
          );
        case 'native_handoff_summary':
          currentSessionId = _requiredString(arguments['sessionId'], 'sessionId');
          currentWorkspaceRoot = sessionStore.getById(currentSessionId, touch: false)?.workspaceRoot;
          final handoffSummary = await nativeBridgeTools.nativeHandoffSummary(
            sessionId: currentSessionId,
            platform: arguments['platform'] as String?,
          );
          return _toolSuccessExecution(
            definition: definition,
            summary: 'Native handoff summary prepared for session $currentSessionId.',
            structuredContent: handoffSummary,
            workspaceRoot: currentWorkspaceRoot,
            sessionId: currentSessionId,
            resourceLinks: _resourceLinksFromPayload(handoffSummary['resources']),
          );
        case 'run_unit_tests':
          currentWorkspaceRoot = await _resolveWorkspaceRoot(
            context,
            emit,
            arguments['workspaceRoot'] as String?,
          );
          final unitTests = await _withWorkspaceLock(
            toolName: definition.name,
            workspaceRoot: currentWorkspaceRoot,
            action: () => testTools.runUnitTests(
              workspaceRoot: currentWorkspaceRoot!,
              targets: _asStringList(arguments['targets']),
              coverage: arguments['coverage'] as bool? ?? false,
            ),
          );
          return _toolSuccessExecution(
            definition: definition,
            summary: 'Unit tests ${unitTests['status']}.',
            structuredContent: unitTests,
            workspaceRoot: currentWorkspaceRoot,
            resourceLinks: _resourceLinksFromPayload(unitTests['resources']),
          );
        case 'run_widget_tests':
          currentWorkspaceRoot = await _resolveWorkspaceRoot(
            context,
            emit,
            arguments['workspaceRoot'] as String?,
          );
          final widgetTests = await _withWorkspaceLock(
            toolName: definition.name,
            workspaceRoot: currentWorkspaceRoot,
            action: () => testTools.runWidgetTests(
              workspaceRoot: currentWorkspaceRoot!,
              targets: _asStringList(arguments['targets']),
              coverage: arguments['coverage'] as bool? ?? false,
            ),
          );
          return _toolSuccessExecution(
            definition: definition,
            summary: 'Widget tests ${widgetTests['status']}.',
            structuredContent: widgetTests,
            workspaceRoot: currentWorkspaceRoot,
            resourceLinks: _resourceLinksFromPayload(widgetTests['resources']),
          );
        case 'run_integration_tests':
          currentWorkspaceRoot = await _resolveWorkspaceRoot(
            context,
            emit,
            arguments['workspaceRoot'] as String?,
          );
          final platform = _requiredString(arguments['platform'], 'platform');
          final target = _requiredString(arguments['target'], 'target');
          final deviceId = await launcherTools.resolveLaunchDeviceId(
            platform: platform,
            deviceId: arguments['deviceId'] as String?,
          );
          if (platform == 'ios') {
            await launcherTools.ensureIosSimulatorBooted(deviceId);
          }
          final integrationTests = await _withWorkspaceLock(
            toolName: definition.name,
            workspaceRoot: currentWorkspaceRoot,
            action: () => testTools.runIntegrationTests(
              workspaceRoot: currentWorkspaceRoot!,
              targets: <String>[target],
              platform: platform,
              deviceId: deviceId,
              flavor: arguments['flavor'] as String?,
              coverage: arguments['coverage'] as bool? ?? false,
            ),
          );
          return _toolSuccessExecution(
            definition: definition,
            summary: 'Integration tests ${integrationTests['status']}.',
            structuredContent: integrationTests,
            workspaceRoot: currentWorkspaceRoot,
            resourceLinks: _resourceLinksFromPayload(integrationTests['resources']),
          );
        case 'get_test_results':
          final testResults = await testTools.getTestResults(
            runId: _requiredString(arguments['runId'], 'runId'),
          );
          return _toolSuccessExecution(
            definition: definition,
            summary: 'Test results loaded for ${testResults['runId']}.',
            structuredContent: testResults,
            resourceLinks: _resourceLinksFromPayload(testResults['resources']),
          );
        case 'collect_coverage':
          final coverage = await testTools.collectCoverage(
            runId: _requiredString(arguments['runId'], 'runId'),
          );
          return _toolSuccessExecution(
            definition: definition,
            summary: 'Coverage artifacts loaded for ${coverage['runId']}.',
            structuredContent: coverage,
            resourceLinks: _resourceLinksFromPayload(coverage['resources']),
          );
        default:
          throw FlutterHelmToolError(
            code: 'TOOL_NOT_IMPLEMENTED',
            category: 'internal',
            message: 'Tool not implemented in Phase 6: ${definition.name}',
            retryable: false,
          );
      }
    } on FlutterHelmToolError catch (error) {
      return _toolErrorExecution(
        definition: definition,
        error: error,
        workspaceRoot: currentWorkspaceRoot,
        sessionId: currentSessionId,
        approvalRequestId: currentApprovalRequestId,
      );
    }
  }

  Future<T> _withWorkspaceLock<T>({
    required String toolName,
    required String workspaceRoot,
    required Future<T> Function() action,
  }) {
    return operationCoordinator.runLocked(
      toolName: toolName,
      workspaceRoot: workspaceRoot,
      action: action,
    );
  }

  Future<T> _withSessionLock<T>({
    required String toolName,
    required String sessionId,
    required Future<T> Function() action,
  }) {
    return operationCoordinator.runLocked(
      toolName: toolName,
      sessionId: sessionId,
      action: action,
    );
  }

  Future<RootSnapshot> _currentRootSnapshot(
    ClientSessionContext context,
    ServerEmitter emit,
  ) async {
    final clientRoots = await _getClientRoots(context, emit);
    return rootPolicy.buildSnapshot(
      clientRoots: clientRoots,
      configuredRoots: config.workspace.roots,
      activeRoot: _state.activeRoot,
    );
  }

  Future<List<String>> _getClientRoots(
    ClientSessionContext context,
    ServerEmitter emit,
  ) async {
    if (!context.clientSupportsRoots || !context.rootsTransportSupported) {
      return const <String>[];
    }
    if (context.cachedClientRoots != null) {
      return context.cachedClientRoots!;
    }
    if (!context.clientInitialized) {
      return const <String>[];
    }

    final requestId = 'server-${context.nextServerRequestId++}';
    final completer = Completer<Object?>();
    context.pendingResponses[requestId] = completer;
    emit(<String, Object?>{
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
      context.cachedClientRoots = roots;
      return roots;
    } on TimeoutException {
      throw FlutterHelmToolError(
        code: 'ROOTS_LIST_TIMEOUT',
        category: 'roots',
        message: 'Timed out while requesting client roots.',
        retryable: true,
      );
    } finally {
      context.pendingResponses.remove(requestId);
    }
  }

  void _handleResponse(
    ClientSessionContext context,
    Object? id,
    Object? result,
    Object? error,
  ) {
    final key = id?.toString();
    if (key == null) {
      return;
    }
    final completer = context.pendingResponses[key];
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

  Future<String> _resolveWorkspaceRoot(
    ClientSessionContext context,
    ServerEmitter emit,
    String? workspaceRootArgument,
  ) async {
    if (workspaceRootArgument == null || workspaceRootArgument.isEmpty) {
      return _requireActiveRoot();
    }
    return rootPolicy.validateWorkspaceRoot(
      requestedRoot: workspaceRootArgument,
      clientRoots: await _getClientRoots(context, emit),
    );
  }

  List<String> _implementedWorkflows() {
    final workflows = <String>{
      for (final definition in toolRegistry.allDefinitions)
        if (definition.implemented) definition.workflow,
    }.toList()
      ..sort();
    return workflows;
  }

  List<Map<String, Object?>> _resourceLinksFromPayload(Object? payload) {
    return _asList(payload).map((Object? item) {
      final resource = _asMap(item);
      return _resourceLink(
        uri: _requiredString(resource['uri'], 'uri'),
        mimeType: resource['mimeType'] as String? ?? 'application/json',
        title: resource['title'] as String? ?? resource['uri'] as String? ?? 'resource',
      );
    }).toList();
  }

  Map<String, Object?> _resourceLink({
    required String uri,
    required String mimeType,
    required String title,
  }) {
    return <String, Object?>{
      'type': 'resource_link',
      'uri': uri,
      'name': title,
      'description': title,
      'mimeType': mimeType,
      'annotations': <String, Object?>{
        'audience': const <String>['assistant'],
        'priority': 0.8,
      },
    };
  }

  List<String> _asStringList(Object? value) {
    return _asList(value).whereType<String>().toList();
  }

  void _ensureInitialized(ClientSessionContext context) {
    if (!context.initializeReceived) {
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
    String? approvalRequestId,
    bool? approved,
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
        approved: approved ?? result == 'success',
        result: result,
        durationMs: DateTime.now().toUtc().difference(startedAt).inMilliseconds,
        errorCode: errorCode,
        approvalRequestId: approvalRequestId,
      ),
    );
  }

  ToolExecutionResult _toolSuccessExecution({
    required ToolDefinition definition,
    required String summary,
    required Map<String, Object?> structuredContent,
    String? workspaceRoot,
    String? sessionId,
    String? approvalRequestId,
    List<Map<String, Object?>> resourceLinks = const <Map<String, Object?>>[],
  }) {
    return ToolExecutionResult(
      response: <String, Object?>{
        'content': <Map<String, Object?>>[
          <String, Object?>{'type': 'text', 'text': summary},
          ...resourceLinks,
        ],
        'structuredContent': structuredContent,
        'isError': false,
      },
      audits: <ToolAuditEntry>[
        if (approvalRequestId != null)
          ToolAuditEntry(
            result: 'approved',
            riskClass: definition.risk,
            workspaceRoot: workspaceRoot,
            sessionId: sessionId,
            tool: definition.name,
            approvalRequestId: approvalRequestId,
            approved: true,
          ),
        ToolAuditEntry(
          result: 'success',
          riskClass: definition.risk,
          workspaceRoot: workspaceRoot,
          sessionId: sessionId,
          tool: definition.name,
          approvalRequestId: approvalRequestId,
          approved: approvalRequestId != null,
        ),
      ],
    );
  }

  ToolExecutionResult _toolErrorExecution({
    required ToolDefinition definition,
    required FlutterHelmToolError error,
    String? workspaceRoot,
    String? sessionId,
    String? approvalRequestId,
  }) {
    return ToolExecutionResult(
      response: <String, Object?>{
        'content': <Map<String, Object?>>[
          <String, Object?>{'type': 'text', 'text': error.message},
        ],
        'structuredContent': <String, Object?>{'error': error.toJson()},
        'isError': true,
      },
      audits: <ToolAuditEntry>[
        if (approvalRequestId != null)
          ToolAuditEntry(
            result: 'approved',
            riskClass: definition.risk,
            workspaceRoot: workspaceRoot,
            sessionId: sessionId,
            tool: definition.name,
            approvalRequestId: approvalRequestId,
            approved: true,
          ),
        ToolAuditEntry(
          result: 'failure',
          riskClass: definition.risk,
          workspaceRoot: workspaceRoot,
          sessionId: sessionId,
          tool: definition.name,
          errorCode: error.code,
          approvalRequestId: approvalRequestId,
          approved: approvalRequestId != null,
        ),
      ],
    );
  }

  Future<ApprovalCheckResult> _checkApproval({
    required ToolDefinition definition,
    required Map<String, Object?> arguments,
    required String workspaceRoot,
    required String reason,
  }) async {
    final normalizedArguments = _normalizedApprovalArguments(
      arguments,
      workspaceRoot: workspaceRoot,
    );
    final argumentsHash = stableApprovalArgumentsHash(normalizedArguments);
    final approvalToken = arguments['approvalToken'] as String?;
    if (approvalToken == null || approvalToken.isEmpty) {
      final request = await approvalStore.createRequest(
        tool: definition.name,
        argumentsHash: argumentsHash,
        workspaceRoot: workspaceRoot,
        riskClass: definition.risk.wireName,
      );
      return ApprovalCheckResult(
        shortCircuit: _approvalRequiredExecution(
          definition: definition,
          workspaceRoot: workspaceRoot,
          reason: reason,
          approvalRequestId: request.approvalRequestId,
        ),
      );
    }

    final consumeResult = await approvalStore.consume(
      approvalToken: approvalToken,
      tool: definition.name,
      argumentsHash: argumentsHash,
      workspaceRoot: workspaceRoot,
    );
    switch (consumeResult.status) {
      case ApprovalConsumeStatus.approved:
        return ApprovalCheckResult(approvalRequestId: approvalToken);
      case ApprovalConsumeStatus.expired:
        return ApprovalCheckResult(
          shortCircuit: ToolExecutionResult(
            response: _toolErrorResponse(
              FlutterHelmToolError(
                code: 'APPROVAL_TOKEN_EXPIRED',
                category: 'approval',
                message: 'The approval token has expired. Retry the tool to request a new token.',
                retryable: true,
              ),
            ),
            audits: <ToolAuditEntry>[
              ToolAuditEntry(
                result: 'expired',
                riskClass: definition.risk,
                workspaceRoot: workspaceRoot,
                tool: definition.name,
                errorCode: 'APPROVAL_TOKEN_EXPIRED',
                approvalRequestId: approvalToken,
                approved: false,
              ),
            ],
          ),
        );
      case ApprovalConsumeStatus.rejected:
        return ApprovalCheckResult(
          shortCircuit: ToolExecutionResult(
            response: _toolErrorResponse(
              FlutterHelmToolError(
                code: 'APPROVAL_TOKEN_REJECTED',
                category: 'approval',
                message:
                    'The approval token is invalid for this tool or argument set.',
                retryable: true,
              ),
            ),
            audits: <ToolAuditEntry>[
              ToolAuditEntry(
                result: 'rejected_token',
                riskClass: definition.risk,
                workspaceRoot: workspaceRoot,
                tool: definition.name,
                errorCode: 'APPROVAL_TOKEN_REJECTED',
                approvalRequestId: approvalToken,
                approved: false,
              ),
            ],
          ),
        );
    }
  }

  ToolExecutionResult _approvalRequiredExecution({
    required ToolDefinition definition,
    required String workspaceRoot,
    required String reason,
    required String approvalRequestId,
  }) {
    return ToolExecutionResult(
      response: <String, Object?>{
        'content': <Map<String, Object?>>[
          <String, Object?>{'type': 'text', 'text': reason},
        ],
        'structuredContent': <String, Object?>{
          'status': 'approval_required',
          'risk': definition.risk.wireName,
          'reason': reason,
          'approvalRequestId': approvalRequestId,
        },
        'isError': false,
      },
      audits: <ToolAuditEntry>[
        ToolAuditEntry(
          result: 'approval_required',
          riskClass: definition.risk,
          workspaceRoot: workspaceRoot,
          tool: definition.name,
          approvalRequestId: approvalRequestId,
          approved: false,
        ),
      ],
    );
  }

  Map<String, Object?> _toolErrorResponse(FlutterHelmToolError error) {
    return <String, Object?>{
      'content': <Map<String, Object?>>[
        <String, Object?>{'type': 'text', 'text': error.message},
      ],
      'structuredContent': <String, Object?>{'error': error.toJson()},
      'isError': true,
    };
  }

  Map<String, Object?> _normalizedApprovalArguments(
    Map<String, Object?> arguments, {
    required String workspaceRoot,
  }) {
    final normalized = <String, Object?>{};
    for (final entry in arguments.entries) {
      if (entry.key == 'approvalToken') {
        continue;
      }
      normalized[entry.key] = entry.value;
    }
    normalized['workspaceRoot'] = workspaceRoot;
    return normalized;
  }

  void _sendResult(
    ServerEmitter emit,
    Object id,
    Map<String, Object?> result,
  ) {
    emit(<String, Object?>{'jsonrpc': '2.0', 'id': id, 'result': result});
  }

  void _sendProtocolError(
    ServerEmitter emit,
    Object? id,
    int code,
    String message, {
    Map<String, Object?>? data,
  }) {
    emit(<String, Object?>{
      'jsonrpc': '2.0',
      'id': id,
      'error': <String, Object?>{
        'code': code,
        'message': message,
        if (data != null) 'data': data,
      },
    });
  }

  void _emitToStdout(Map<String, Object?> message) {
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

String? _sessionIdFromUri(String uri) {
  for (final pattern in <RegExp>[
    RegExp(r'^session://([^/]+)/(?:summary|health)$'),
    RegExp(r'^log://([^/]+)/(?:stdout|stderr)$'),
    RegExp(r'^runtime-errors://([^/]+)/current$'),
    RegExp(r'^widget-tree://([^/]+)/current(?:\?.*)?$'),
    RegExp(r'^app-state://([^/]+)/summary$'),
    RegExp(r'^timeline://([^/]+)/[^/]+$'),
    RegExp(r'^memory://([^/]+)/[^/]+$'),
    RegExp(r'^cpu://([^/]+)/[^/]+$'),
    RegExp(r'^screenshot://([^/]+)/[^/]+$'),
    RegExp(r'^native-handoff://([^/]+)/(?:ios|android)$'),
  ]) {
    final match = pattern.firstMatch(uri);
    if (match != null) {
      return match.group(1);
    }
  }
  return null;
}
