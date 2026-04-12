import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutterhelm/artifacts/store.dart';
import 'package:flutterhelm/artifacts/resources.dart';
import 'package:flutterhelm/config/config.dart';
import 'package:flutterhelm/launcher/tools.dart';
import 'package:flutterhelm/policies/approvals.dart';
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
  final ApprovalStore approvalStore;
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
    final approvalStore = await ApprovalStore.create(stateDir: runtimePaths.stateDir);
    final sessionStore = await SessionStore.create(stateDir: runtimePaths.stateDir);
    final processRunner = const ProcessRunner();

    return FlutterHelmServer._(
      runtimePaths: runtimePaths,
      config: config,
      stateRepository: stateRepository,
      auditLogger: AuditLogger(runtimePaths.auditFilePath),
      approvalStore: approvalStore,
      rootPolicy: RootPolicy(allowRootFallback: allowRootFallback),
      toolRegistry: ToolRegistry(),
      artifactStore: artifactStore,
      resourceCatalog: ResourceCatalog(artifactStore: artifactStore),
      sessionStore: sessionStore,
      processRunner: processRunner,
      workspaceTools: WorkspaceToolService(
        processRunner: processRunner,
        artifactStore: artifactStore,
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
          _sendResult(id, toolResult.response);
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
        _sendResult(id, _toolErrorResponse(error));
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
          'Phase 2 server: use tools for workspace/package/run/test orchestration and resources for logs, widget trees, runtime errors, reports, and coverage.',
    };
  }

  Future<ToolExecutionResult> _executeTool(
    ToolDefinition definition,
    Map<String, Object?> arguments,
  ) async {
    String? currentWorkspaceRoot;
    String? currentSessionId;
    String? currentApprovalRequestId;

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
          return _toolSuccessExecution(
            definition: definition,
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
          return _toolSuccessExecution(
            definition: definition,
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
          final snapshot = await _currentRootSnapshot();
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
            arguments['workspaceRoot'] as String?,
          );
          final analysis = await workspaceTools.analyzeProject(
            workspaceRoot: currentWorkspaceRoot,
            fatalInfos: arguments['fatalInfos'] as bool? ?? false,
            fatalWarnings: arguments['fatalWarnings'] as bool? ?? true,
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
            arguments['workspaceRoot'] as String?,
          );
          final paths = _asStringList(arguments['paths']);
          final formatResult = await workspaceTools.formatFiles(
            workspaceRoot: currentWorkspaceRoot,
            paths: paths,
            lineLength: arguments['lineLength'] as int?,
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
          final addResult = await workspaceTools.dependencyAdd(
            workspaceRoot: currentWorkspaceRoot,
            package: packageName,
            versionConstraint: arguments['versionConstraint'] as String?,
            devDependency: arguments['devDependency'] as bool? ?? false,
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
          final removeResult = await workspaceTools.dependencyRemove(
            workspaceRoot: currentWorkspaceRoot,
            package: packageName,
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
          final clientRoots = await _getClientRoots();
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
            rootSnapshot: await _currentRootSnapshot(),
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
        case 'device_list':
          final devices = await launcherTools.listDevices();
          return _toolSuccessExecution(
            definition: definition,
            summary: '${devices.length} device(s) available.',
            structuredContent: <String, Object?>{'devices': devices},
          );
        case 'run_app':
          currentWorkspaceRoot = await _resolveWorkspaceRoot(
            arguments['workspaceRoot'] as String?,
          );
          final target = (arguments['target'] as String?) ?? config.defaults.target;
          final flavor = arguments['flavor'] as String?;
          final mode = (arguments['mode'] as String?) ?? config.defaults.mode;
          final platform = _requiredString(arguments['platform'], 'platform');
          final session = await launcherTools.runApp(
            workspaceRoot: currentWorkspaceRoot,
            target: target,
            platform: platform,
            mode: mode,
            flavor: flavor,
            dartDefines: _asStringList(arguments['dartDefines']),
            deviceId: arguments['deviceId'] as String?,
            sessionId: arguments['sessionId'] as String?,
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
          final stopped = await launcherTools.stopApp(sessionId: currentSessionId);
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
        case 'run_unit_tests':
          currentWorkspaceRoot = await _resolveWorkspaceRoot(
            arguments['workspaceRoot'] as String?,
          );
          final unitTests = await testTools.runUnitTests(
            workspaceRoot: currentWorkspaceRoot,
            targets: _asStringList(arguments['targets']),
            coverage: arguments['coverage'] as bool? ?? false,
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
            arguments['workspaceRoot'] as String?,
          );
          final widgetTests = await testTools.runWidgetTests(
            workspaceRoot: currentWorkspaceRoot,
            targets: _asStringList(arguments['targets']),
            coverage: arguments['coverage'] as bool? ?? false,
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
          final integrationTests = await testTools.runIntegrationTests(
            workspaceRoot: currentWorkspaceRoot,
            targets: <String>[target],
            platform: platform,
            deviceId: deviceId,
            flavor: arguments['flavor'] as String?,
            coverage: arguments['coverage'] as bool? ?? false,
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
            message: 'Tool not implemented in Phase 2: ${definition.name}',
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
