import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutterhelm/artifacts/store.dart';
import 'package:flutterhelm/artifacts/resources.dart';
import 'package:flutterhelm/config/config.dart';
import 'package:flutterhelm/launcher/tools.dart';
import 'package:flutterhelm/policies/audit.dart';
import 'package:flutterhelm/policies/risk.dart';
import 'package:flutterhelm/policies/roots.dart';
import 'package:flutterhelm/runtime/tools.dart';
import 'package:flutterhelm/server/capabilities.dart';
import 'package:flutterhelm/server/errors.dart';
import 'package:flutterhelm/server/registry.dart';
import 'package:flutterhelm/sessions/session.dart';
import 'package:flutterhelm/sessions/session_store.dart';
import 'package:flutterhelm/tests/tools.dart';
import 'package:flutterhelm/utils/process_runner.dart';
import 'package:flutterhelm/version.dart';
import 'package:flutterhelm/workspace/tools.dart';

class FlutterHelmServer {
  FlutterHelmServer._({
    required this.runtimePaths,
    required this.config,
    required this.stateRepository,
    required this.auditLogger,
    required this.rootPolicy,
    required this.toolRegistry,
    required this.artifactStore,
    required this.resourceCatalog,
    required this.sessionStore,
    required this.processRunner,
    required this.workspaceTools,
    required this.launcherTools,
    required this.runtimeTools,
    required this.testTools,
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
  final ArtifactStore artifactStore;
  final ResourceCatalog resourceCatalog;
  final SessionStore sessionStore;
  final ProcessRunner processRunner;
  final WorkspaceToolService workspaceTools;
  final LauncherToolService launcherTools;
  final RuntimeToolService runtimeTools;
  final TestToolService testTools;
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
    final artifactStore = ArtifactStore(stateDir: runtimePaths.stateDir);
    final sessionStore = await SessionStore.create(stateDir: runtimePaths.stateDir);
    final processRunner = const ProcessRunner();

    return FlutterHelmServer._(
      runtimePaths: runtimePaths,
      config: config,
      stateRepository: stateRepository,
      auditLogger: AuditLogger(runtimePaths.auditFilePath),
      rootPolicy: RootPolicy(allowRootFallback: allowRootFallback),
      toolRegistry: ToolRegistry(),
      artifactStore: artifactStore,
      resourceCatalog: ResourceCatalog(artifactStore: artifactStore),
      sessionStore: sessionStore,
      processRunner: processRunner,
      workspaceTools: WorkspaceToolService(
        processRunner: processRunner,
        flutterExecutable: config.adapters.flutterExecutable,
      ),
      launcherTools: LauncherToolService(
        processRunner: processRunner,
        sessionStore: sessionStore,
        artifactStore: artifactStore,
        flutterExecutable: config.adapters.flutterExecutable,
      ),
      runtimeTools: RuntimeToolService(
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
          final listedResources = await resourceCatalog.listResources(
            config: config,
            state: _state,
            rootSnapshot: rootsSnapshot,
            sessions: sessionStore.listActiveSessions(),
          );
          final resources = listedResources
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
          final resource = await resourceCatalog.readResource(
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
          'Phase 1 server: use tools for workspace/run/test orchestration and resources for logs, widget trees, runtime errors, and reports.',
    };
  }

  Future<Map<String, Object?>> _executeTool(
    ToolDefinition definition,
    Map<String, Object?> arguments,
  ) async {
    try {
      switch (definition.name) {
        case 'workspace_discover':
          final snapshot = await _currentRootSnapshot();
          final roots = <String>{
            ...snapshot.clientRoots,
            ...snapshot.configuredRoots,
            if (snapshot.activeRoot != null) snapshot.activeRoot!,
          }.toList()
            ..sort();
          final workspaces = await workspaceTools.discoverWorkspaces(roots: roots);
          return _toolSuccessResult(
            summary: '${workspaces.length} workspace(s) discovered.',
            structuredContent: <String, Object?>{'workspaces': workspaces},
          );
        case 'workspace_show':
          final snapshot = await _currentRootSnapshot();
          final resources = await resourceCatalog.listResources(
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
            'implementedWorkflows': _implementedWorkflows(),
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
          final resources = await resourceCatalog.listResources(
            config: config,
            state: _state,
            rootSnapshot: snapshot,
            sessions: sessionStore.listActiveSessions(),
          );
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
              resources
                  .firstWhere(
                    (ResourceDescriptor resource) =>
                        resource.uri == 'config://workspace/current',
                  )
                  .toResourceLink(),
            ],
          );
        case 'analyze_project':
          final workspaceRoot = await _resolveWorkspaceRoot(
            arguments['workspaceRoot'] as String?,
          );
          final analysis = await workspaceTools.analyzeProject(
            workspaceRoot: workspaceRoot,
            fatalInfos: arguments['fatalInfos'] as bool? ?? false,
            fatalWarnings: arguments['fatalWarnings'] as bool? ?? true,
          );
          return _toolSuccessResult(
            summary: 'Static analysis completed with ${analysis['issueCount']} issue(s).',
            structuredContent: analysis,
          );
        case 'resolve_symbol':
          final workspaceRoot = await _resolveWorkspaceRoot(
            arguments['workspaceRoot'] as String?,
          );
          final symbol = _requiredString(arguments['symbol'], 'symbol');
          final resolution = await workspaceTools.resolveSymbol(
            workspaceRoot: workspaceRoot,
            symbol: symbol,
          );
          final matches = _asList(resolution['matches']);
          return _toolSuccessResult(
            summary: matches.isEmpty
                ? 'No symbol match found for $symbol.'
                : '${matches.length} symbol match(es) found for $symbol.',
            structuredContent: resolution,
          );
        case 'format_files':
          final workspaceRoot = await _resolveWorkspaceRoot(
            arguments['workspaceRoot'] as String?,
          );
          final paths = _asStringList(arguments['paths']);
          final formatResult = await workspaceTools.formatFiles(
            workspaceRoot: workspaceRoot,
            paths: paths,
            lineLength: arguments['lineLength'] as int?,
          );
          return _toolSuccessResult(
            summary: 'Formatting completed for ${paths.length} path(s).',
            structuredContent: formatResult,
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
          final resources = await resourceCatalog
              .listResources(
                config: config,
                state: _state,
                rootSnapshot: await _currentRootSnapshot(),
                sessions: sessionStore.listActiveSessions(),
              );
          final descriptor = resources
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
        case 'device_list':
          final devices = await launcherTools.listDevices();
          return _toolSuccessResult(
            summary: '${devices.length} device(s) available.',
            structuredContent: <String, Object?>{'devices': devices},
          );
        case 'run_app':
          final workspaceRoot = await _resolveWorkspaceRoot(
            arguments['workspaceRoot'] as String?,
          );
          final target = (arguments['target'] as String?) ?? config.defaults.target;
          final flavor = arguments['flavor'] as String?;
          final mode = (arguments['mode'] as String?) ?? config.defaults.mode;
          final platform = _requiredString(arguments['platform'], 'platform');
          final session = await launcherTools.runApp(
            workspaceRoot: workspaceRoot,
            target: target,
            platform: platform,
            mode: mode,
            flavor: flavor,
            dartDefines: _asStringList(arguments['dartDefines']),
            deviceId: arguments['deviceId'] as String?,
            sessionId: arguments['sessionId'] as String?,
          );
          return _toolSuccessResult(
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
          final workspaceRoot = await _resolveWorkspaceRoot(
            arguments['workspaceRoot'] as String?,
          );
          final attached = await launcherTools.attachApp(
            workspaceRoot: workspaceRoot,
            platform: _requiredString(arguments['platform'], 'platform'),
            target: (arguments['target'] as String?) ?? config.defaults.target,
            mode: (arguments['mode'] as String?) ?? config.defaults.mode,
            flavor: arguments['flavor'] as String?,
            deviceId: arguments['deviceId'] as String?,
            sessionId: arguments['sessionId'] as String?,
            debugUrl: arguments['debugUrl'] as String?,
            appId: arguments['appId'] as String?,
          );
          return _toolSuccessResult(
            summary: 'Attached session ${attached.sessionId} is ready.',
            structuredContent: attached.toJson(),
            resourceLinks: <Map<String, Object?>>[
              _resourceLink(
                uri: 'session://${attached.sessionId}/summary',
                mimeType: 'application/json',
                title: 'Session summary',
              ),
            ],
          );
        case 'stop_app':
          final stopped = await launcherTools.stopApp(
            sessionId: _requiredString(arguments['sessionId'], 'sessionId'),
          );
          return _toolSuccessResult(
            summary: 'Session ${stopped.sessionId} is ${stopped.state.wireName}.',
            structuredContent: stopped.toJson(),
            resourceLinks: <Map<String, Object?>>[
              _resourceLink(
                uri: 'session://${stopped.sessionId}/summary',
                mimeType: 'application/json',
                title: 'Session summary',
              ),
            ],
          );
        case 'get_logs':
          final result = await runtimeTools.getLogs(
            sessionId: _requiredString(arguments['sessionId'], 'sessionId'),
            stream: (arguments['stream'] as String?) ?? 'both',
            tailLines: arguments['tailLines'] as int? ?? 200,
          );
          return _toolSuccessResult(
            summary: 'Retrieved ${result['stream']} logs.',
            structuredContent: result,
            resourceLinks: _resourceLinksFromPayload(result['resources']),
          );
        case 'get_runtime_errors':
          final result = await runtimeTools.getRuntimeErrors(
            sessionId: _requiredString(arguments['sessionId'], 'sessionId'),
          );
          return _toolSuccessResult(
            summary: '${result['count']} runtime error(s) found.',
            structuredContent: result,
            resourceLinks: _resourceLinksFromPayload(<Object?>[result['resource']]),
          );
        case 'get_widget_tree':
          final depth = arguments['depth'] as int? ?? 3;
          final result = await runtimeTools.getWidgetTree(
            sessionId: _requiredString(arguments['sessionId'], 'sessionId'),
            depth: depth,
            includeProperties: arguments['includeProperties'] as bool? ?? false,
          );
          return _toolSuccessResult(
            summary: 'Captured widget tree for session ${result['sessionId']}.',
            structuredContent: result,
            resourceLinks: _resourceLinksFromPayload(<Object?>[result['resource']]),
          );
        case 'get_app_state_summary':
          final result = await runtimeTools.getAppStateSummary(
            sessionId: _requiredString(arguments['sessionId'], 'sessionId'),
          );
          return _toolSuccessResult(
            summary: 'App state summary retrieved.',
            structuredContent: result,
            resourceLinks: _resourceLinksFromPayload(<Object?>[result['resource']]),
          );
        case 'run_unit_tests':
          final workspaceRoot = await _resolveWorkspaceRoot(
            arguments['workspaceRoot'] as String?,
          );
          final result = await testTools.runUnitTests(
            workspaceRoot: workspaceRoot,
            targets: _asStringList(arguments['targets']),
            coverage: arguments['coverage'] as bool? ?? false,
          );
          return _toolSuccessResult(
            summary: 'Unit tests ${result['status']}.',
            structuredContent: result,
            resourceLinks: _resourceLinksFromPayload(result['resources']),
          );
        case 'run_widget_tests':
          final workspaceRoot = await _resolveWorkspaceRoot(
            arguments['workspaceRoot'] as String?,
          );
          final result = await testTools.runWidgetTests(
            workspaceRoot: workspaceRoot,
            targets: _asStringList(arguments['targets']),
            coverage: arguments['coverage'] as bool? ?? false,
          );
          return _toolSuccessResult(
            summary: 'Widget tests ${result['status']}.',
            structuredContent: result,
            resourceLinks: _resourceLinksFromPayload(result['resources']),
          );
        default:
          throw FlutterHelmToolError(
            code: 'TOOL_NOT_IMPLEMENTED',
            category: 'internal',
            message: 'Tool not implemented in Phase 1: ${definition.name}',
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

  Future<String> _resolveWorkspaceRoot(String? workspaceRootArgument) async {
    if (workspaceRootArgument == null || workspaceRootArgument.isEmpty) {
      return _requireActiveRoot();
    }
    return rootPolicy.validateWorkspaceRoot(
      requestedRoot: workspaceRootArgument,
      clientRoots: await _getClientRoots(),
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
