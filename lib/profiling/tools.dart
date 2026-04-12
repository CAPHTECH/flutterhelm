import 'dart:async';
import 'dart:typed_data';

import 'package:flutterhelm/artifacts/store.dart';
import 'package:flutterhelm/platform_bridge/support.dart';
import 'package:flutterhelm/runtime/vm_service_support.dart';
import 'package:flutterhelm/server/errors.dart';
import 'package:flutterhelm/sessions/session.dart';
import 'package:flutterhelm/sessions/session_store.dart';
import 'package:vm_service/vm_service.dart' as vm;

class ProfilingToolService {
  ProfilingToolService({
    required this.sessionStore,
    required this.artifactStore,
  });

  final SessionStore sessionStore;
  final ArtifactStore artifactStore;

  Future<Map<String, Object?>> startCpuProfile({
    required String sessionId,
  }) async {
    final context = _requireProfilingContext(sessionId);
    if (context.session.profileActive || context.handle.cpuProfileStartMicros != null) {
      throw FlutterHelmToolError(
        code: 'CPU_PROFILE_ALREADY_ACTIVE',
        category: 'runtime',
        message: 'CPU profiling is already active for this session.',
        retryable: false,
        detailsResource: _healthResource(sessionId),
      );
    }

    final vmSession = await _connectVmSession(sessionId);
    try {
      final timestamp = await vmSession.service.getVMTimelineMicros();
      context.handle.cpuProfileStartMicros = timestamp.timestamp;
      context.handle.cpuProfileStartedAt = DateTime.now().toUtc();
      final updated = sessionStore.setProfileActive(sessionId, true);
      await artifactStore.writeSessionAppState(
        sessionId: sessionId,
        payload: _sessionAppState(updated),
      );
      return <String, Object?>{
        'sessionId': sessionId,
        'profileActive': true,
        'startedAt': context.handle.cpuProfileStartedAt!.toIso8601String(),
        'backend': 'vm_service',
      };
    } on vm.RPCError catch (error) {
      throw _rpcError(
        code: 'CPU_PROFILE_UNAVAILABLE',
        sessionId: sessionId,
        fallbackMessage: 'CPU profiling is unavailable for this session.',
        error: error,
      );
    } finally {
      await vmSession.dispose();
    }
  }

  Future<Map<String, Object?>> stopCpuProfile({
    required String sessionId,
  }) async {
    final context = _requireProfilingContext(sessionId);
    final startMicros = context.handle.cpuProfileStartMicros;
    if (!context.session.profileActive || startMicros == null) {
      throw FlutterHelmToolError(
        code: 'CPU_PROFILE_NOT_ACTIVE',
        category: 'runtime',
        message: 'CPU profiling is not active for this session.',
        retryable: true,
        detailsResource: _healthResource(sessionId),
      );
    }

    final vmSession = await _connectVmSession(sessionId);
    try {
      final endTimestamp = await vmSession.service.getVMTimelineMicros();
      final durationMicros = (endTimestamp.timestamp! - startMicros).clamp(1, 1 << 62);
      final samples = await vmSession.service.getCpuSamples(
        vmSession.isolate.id!,
        startMicros,
        durationMicros,
      );
      final captureId = _captureId('cpu');
      final summary = _cpuSummary(samples);
      final payload = <String, Object?>{
        'sessionId': sessionId,
        'captureId': captureId,
        'capturedAt': DateTime.now().toUtc().toIso8601String(),
        if (context.handle.cpuProfileStartedAt != null)
          'startedAt': context.handle.cpuProfileStartedAt!.toIso8601String(),
        'summary': summary,
        'samples': samples.toJson(),
      };
      await artifactStore.writeSessionCpuProfile(
        sessionId: sessionId,
        captureId: captureId,
        payload: payload,
      );

      context.handle.cpuProfileStartMicros = null;
      context.handle.cpuProfileStartedAt = null;
      final updated = sessionStore.setProfileActive(sessionId, false);
      await artifactStore.writeSessionAppState(
        sessionId: sessionId,
        payload: _sessionAppState(updated),
      );
      return <String, Object?>{
        'sessionId': sessionId,
        'captureId': captureId,
        'profileActive': false,
        'summary': summary,
        'resource': <String, Object?>{
          'uri': artifactStore.sessionCpuProfileUri(sessionId, captureId),
          'mimeType': 'application/json',
          'title': 'CPU profile capture',
        },
      };
    } on vm.RPCError catch (error) {
      throw _rpcError(
        code: 'CPU_PROFILE_UNAVAILABLE',
        sessionId: sessionId,
        fallbackMessage: 'CPU profiling is unavailable for this session.',
        error: error,
      );
    } finally {
      await vmSession.dispose();
    }
  }

  Future<Map<String, Object?>> captureTimeline({
    required String sessionId,
    required int durationMs,
    required List<String> streams,
  }) async {
    if (durationMs <= 0) {
      throw FlutterHelmToolError(
        code: 'INVALID_DURATION',
        category: 'validation',
        message: 'durationMs must be greater than zero.',
        retryable: true,
      );
    }
    if (streams.isEmpty) {
      throw FlutterHelmToolError(
        code: 'INVALID_TIMELINE_STREAMS',
        category: 'validation',
        message: 'At least one timeline stream is required.',
        retryable: true,
      );
    }

    _requireProfilingContext(sessionId);
    final vmSession = await _connectVmSession(sessionId);
    vm.TimelineFlags? originalFlags;
    try {
      originalFlags = await vmSession.service.getVMTimelineFlags();
      await vmSession.service.setVMTimelineFlags(streams);
      await vmSession.service.clearVMTimeline();
      final start = await vmSession.service.getVMTimelineMicros();
      await Future<void>.delayed(Duration(milliseconds: durationMs));
      final end = await vmSession.service.getVMTimelineMicros();
      final extent = (end.timestamp! - start.timestamp!).clamp(1, 1 << 62);
      final timeline = await vmSession.service.getVMTimeline(
        timeOriginMicros: start.timestamp,
        timeExtentMicros: extent,
      );
      final captureId = _captureId('timeline');
      final summary = _timelineSummary(timeline, streams);
      final payload = <String, Object?>{
        'sessionId': sessionId,
        'captureId': captureId,
        'capturedAt': DateTime.now().toUtc().toIso8601String(),
        'summary': summary,
        'timeline': timeline.toJson(),
      };
      await artifactStore.writeSessionTimeline(
        sessionId: sessionId,
        captureId: captureId,
        payload: payload,
      );
      return <String, Object?>{
        'sessionId': sessionId,
        'captureId': captureId,
        'summary': summary,
        'resource': <String, Object?>{
          'uri': artifactStore.sessionTimelineUri(sessionId, captureId),
          'mimeType': 'application/json',
          'title': 'Timeline capture',
        },
      };
    } on vm.RPCError catch (error) {
      throw _rpcError(
        code: 'TIMELINE_CAPTURE_UNAVAILABLE',
        sessionId: sessionId,
        fallbackMessage: 'Timeline capture is unavailable for this session.',
        error: error,
      );
    } finally {
      if (originalFlags?.recordedStreams case final recordedStreams?) {
        try {
          await vmSession.service.setVMTimelineFlags(recordedStreams);
        } on vm.RPCError {
          // Preserve the capture result even if restoring streams fails.
        }
      }
      await vmSession.dispose();
    }
  }

  Future<Map<String, Object?>> captureMemorySnapshot({
    required String sessionId,
    required bool gc,
  }) async {
    _requireProfilingContext(sessionId);
    final vmSession = await _connectVmSession(sessionId);
    try {
      final allocationProfile = await vmSession.service.getAllocationProfile(
        vmSession.isolate.id!,
        gc: gc,
      );
      final snapshot = await vm.HeapSnapshotGraph.getSnapshot(
        vmSession.service,
        vmSession.isolate,
        calculateReferrers: false,
        decodeObjectData: false,
        decodeExternalProperties: false,
        decodeIdentityHashCodes: false,
      ).timeout(const Duration(minutes: 2));
      final snapshotId = _captureId('memory');
      final chunks = snapshot.toChunks();
      await artifactStore.writeSessionHeapSnapshotSidecar(
        sessionId: sessionId,
        snapshotId: snapshotId,
        chunks: <List<int>>[
          for (final chunk in chunks)
            chunk.buffer.asUint8List(chunk.offsetInBytes, chunk.lengthInBytes),
        ],
      );
      final summary = _memorySummary(allocationProfile, snapshot, chunks);
      final payload = <String, Object?>{
        'sessionId': sessionId,
        'snapshotId': snapshotId,
        'capturedAt': DateTime.now().toUtc().toIso8601String(),
        'summary': summary,
        'allocationProfile': allocationProfile.toJson(),
        'heapSnapshot': <String, Object?>{
          'chunkCount': chunks.length,
          'path': 'memory-$snapshotId.heap',
        },
      };
      await artifactStore.writeSessionMemorySnapshot(
        sessionId: sessionId,
        snapshotId: snapshotId,
        payload: payload,
      );
      return <String, Object?>{
        'sessionId': sessionId,
        'snapshotId': snapshotId,
        'summary': summary,
        'resource': <String, Object?>{
          'uri': artifactStore.sessionMemoryUri(sessionId, snapshotId),
          'mimeType': 'application/json',
          'title': 'Memory snapshot',
        },
      };
    } on TimeoutException {
      throw FlutterHelmToolError(
        code: 'MEMORY_SNAPSHOT_UNAVAILABLE',
        category: 'runtime',
        message: 'Timed out while capturing the heap snapshot.',
        retryable: true,
        detailsResource: _healthResource(sessionId),
      );
    } on vm.RPCError catch (error) {
      throw _rpcError(
        code: 'MEMORY_SNAPSHOT_UNAVAILABLE',
        sessionId: sessionId,
        fallbackMessage: 'Memory snapshot capture is unavailable for this session.',
        error: error,
      );
    } finally {
      await vmSession.dispose();
    }
  }

  Future<Map<String, Object?>> togglePerformanceOverlay({
    required String sessionId,
    required bool enabled,
  }) async {
    _requireProfilingContext(sessionId);
    final vmSession = await _connectVmSession(
      sessionId,
      requiredExtension: 'ext.flutter.showPerformanceOverlay',
    );
    try {
      final state = await toggleFlutterBoolExtension(
        service: vmSession.service,
        isolate: vmSession.isolate,
        extensionName: 'ext.flutter.showPerformanceOverlay',
        enabled: enabled,
      );
      final session = sessionStore.requireById(sessionId, touch: false);
      await artifactStore.writeSessionAppState(
        sessionId: sessionId,
        payload: <String, Object?>{
          ..._sessionAppState(session),
          'performanceOverlay': <String, Object?>{
            'enabled': state['enabled'] == true || state['enabled'] == 'true',
          },
        },
      );
      return <String, Object?>{
        'sessionId': sessionId,
        'enabled': state['enabled'] == true || state['enabled'] == 'true',
        'resource': <String, Object?>{
          'uri': artifactStore.sessionAppStateUri(sessionId),
          'mimeType': 'application/json',
          'title': 'App state summary',
        },
      };
    } on StateError {
      throw FlutterHelmToolError(
        code: 'PERFORMANCE_OVERLAY_UNAVAILABLE',
        category: 'runtime',
        message: 'Performance overlay is unavailable for this session.',
        retryable: true,
        detailsResource: _healthResource(sessionId),
      );
    } on vm.RPCError catch (error) {
      throw _rpcError(
        code: 'PERFORMANCE_OVERLAY_UNAVAILABLE',
        sessionId: sessionId,
        fallbackMessage: 'Performance overlay is unavailable for this session.',
        error: error,
      );
    } finally {
      await vmSession.dispose();
    }
  }

  _ProfilingContext _requireProfilingContext(String sessionId) {
    final session = sessionStore.requireById(sessionId);
    if (session.stale) {
      throw FlutterHelmToolError(
        code: 'SESSION_STALE',
        category: 'runtime',
        message: 'The target session is stale and cannot be profiled.',
        retryable: true,
        detailsResource: _healthResource(sessionId),
      );
    }
    if (session.ownership != SessionOwnership.owned) {
      throw FlutterHelmToolError(
        code: 'PROFILE_OWNERSHIP_REQUIRED',
        category: 'runtime',
        message: 'Profiling is only allowed for owned sessions.',
        retryable: true,
        detailsResource: _healthResource(sessionId),
      );
    }
    if (session.state != SessionState.running) {
      throw FlutterHelmToolError(
        code: 'SESSION_NOT_RUNNING',
        category: 'runtime',
        message: 'The target session is not running.',
        retryable: true,
        detailsResource: _healthResource(sessionId),
      );
    }
    if (session.mode == 'release') {
      throw FlutterHelmToolError(
        code: 'PROFILE_MODE_REQUIRED',
        category: 'runtime',
        message: 'Profiling is unavailable for release sessions. Start the app in debug or profile mode.',
        retryable: true,
        detailsResource: _healthResource(sessionId),
      );
    }
    final handle = sessionStore.liveHandle(sessionId);
    if (handle == null || handle.vmServiceUri == null || handle.vmServiceUri!.isEmpty) {
      throw FlutterHelmToolError(
        code: 'PROFILE_VM_SERVICE_REQUIRED',
        category: 'runtime',
        message: 'Profiling requires a live VM service connection.',
        retryable: true,
        detailsResource: _healthResource(sessionId),
      );
    }
    return _ProfilingContext(session: session, handle: handle);
  }

  Future<VmServiceSession> _connectVmSession(
    String sessionId, {
    String? requiredExtension,
  }) async {
    final context = _requireProfilingContext(sessionId);
    try {
      return await VmServiceSession.connect(
        context.handle.vmServiceUri!,
        requiredExtension: requiredExtension,
      );
    } on StateError {
      throw FlutterHelmToolError(
        code: requiredExtension == null
            ? 'PROFILE_VM_SERVICE_REQUIRED'
            : 'PERFORMANCE_OVERLAY_UNAVAILABLE',
        category: 'runtime',
        message: requiredExtension == null
            ? 'Profiling requires a live VM service connection.'
            : 'The required Flutter extension is unavailable for this session.',
        retryable: true,
        detailsResource: _healthResource(sessionId),
      );
    }
  }

  FlutterHelmToolError _rpcError({
    required String code,
    required String sessionId,
    required String fallbackMessage,
    required vm.RPCError error,
  }) {
    return FlutterHelmToolError(
      code: code,
      category: 'runtime',
      message: error.message.isNotEmpty ? error.message : fallbackMessage,
      retryable: true,
      detailsResource: _healthResource(sessionId),
    );
  }

  Map<String, Object?> _healthResource(String sessionId) {
    return <String, Object?>{
      'uri': artifactStore.sessionHealthUri(sessionId),
      'mimeType': 'application/json',
    };
  }

  String _captureId(String prefix) {
    final now = DateTime.now().toUtc();
    return '${prefix}_${now.microsecondsSinceEpoch.toRadixString(36)}';
  }

  Map<String, Object?> _sessionAppState(SessionRecord session) {
    return <String, Object?>{
      'sessionId': session.sessionId,
      'ownership': session.ownership.wireName,
      'state': session.state.wireName,
      'stale': session.stale,
      'platform': session.platform,
      'deviceId': session.deviceId,
      'target': session.target,
      'mode': session.mode,
      'pid': session.pid,
      'profileActive': session.profileActive,
      'nativeBridgeAvailablePlatforms': detectNativeBridgePlatformsSync(
        session.workspaceRoot,
      ),
      'vmService': <String, Object?>{
        'available': session.vmServiceAvailable,
        'maskedUri': session.vmServiceMaskedUri,
      },
      'dtd': <String, Object?>{
        'available': session.dtdAvailable,
        'maskedUri': session.dtdMaskedUri,
      },
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
    };
  }

  Map<String, Object?> _cpuSummary(vm.CpuSamples samples) {
    final functions = samples.functions ?? const <vm.ProfileFunction>[];
    final topFunctions = [...functions]
      ..sort((left, right) => (right.exclusiveTicks ?? 0).compareTo(left.exclusiveTicks ?? 0));
    return <String, Object?>{
      'sampleCount': samples.sampleCount ?? 0,
      'samplePeriodMicros': samples.samplePeriod ?? 0,
      'maxStackDepth': samples.maxStackDepth ?? 0,
      'timeOriginMicros': samples.timeOriginMicros ?? 0,
      'timeExtentMicros': samples.timeExtentMicros ?? 0,
      'topFunctions': <Map<String, Object?>>[
        for (final function in topFunctions.take(5))
          <String, Object?>{
            'name': _profileFunctionName(function),
            'inclusiveTicks': function.inclusiveTicks ?? 0,
            'exclusiveTicks': function.exclusiveTicks ?? 0,
            'resolvedUrl': function.resolvedUrl,
          },
      ],
    };
  }

  Map<String, Object?> _timelineSummary(vm.Timeline timeline, List<String> streams) {
    final events = timeline.traceEvents ?? const <vm.TimelineEvent>[];
    final counts = <String, int>{};
    var gcEventCount = 0;
    var frameEventCount = 0;
    for (final event in events) {
      final json = event.json ?? const <String, Object?>{};
      final name = json['name']?.toString() ?? 'unknown';
      counts[name] = (counts[name] ?? 0) + 1;
      if (name.contains('GC')) {
        gcEventCount += 1;
      }
      if (name.contains('Frame')) {
        frameEventCount += 1;
      }
    }
    final topEvents = counts.entries.toList()
      ..sort((left, right) => right.value.compareTo(left.value));
    return <String, Object?>{
      'eventCount': events.length,
      'gcEventCount': gcEventCount,
      'frameEventCount': frameEventCount,
      'timeOriginMicros': timeline.timeOriginMicros ?? 0,
      'timeExtentMicros': timeline.timeExtentMicros ?? 0,
      'streams': streams,
      'topEvents': <Map<String, Object?>>[
        for (final entry in topEvents.take(10))
          <String, Object?>{'name': entry.key, 'count': entry.value},
      ],
    };
  }

  Map<String, Object?> _memorySummary(
    vm.AllocationProfile allocationProfile,
    vm.HeapSnapshotGraph snapshot,
    List<ByteData> chunks,
  ) {
    final members = allocationProfile.members ?? const <vm.ClassHeapStats>[];
    final topClasses = [...members]
      ..sort((left, right) => (right.bytesCurrent ?? 0).compareTo(left.bytesCurrent ?? 0));
    final totalBytes = chunks.fold<int>(0, (sum, chunk) => sum + chunk.lengthInBytes);
    return <String, Object?>{
      'memoryUsage': allocationProfile.memoryUsage?.toJson() ?? const <String, Object?>{},
      'heapSnapshotBytes': totalBytes,
      'heapSnapshotChunks': chunks.length,
      'classCount': snapshot.classes.length,
      'objectCount': snapshot.objects.length,
      'topClasses': <Map<String, Object?>>[
        for (final member in topClasses.take(10))
          <String, Object?>{
            'name': member.classRef?.name ?? 'unknown',
            'bytesCurrent': member.bytesCurrent ?? 0,
            'instancesCurrent': member.instancesCurrent ?? 0,
            'accumulatedSize': member.accumulatedSize ?? 0,
          },
      ],
    };
  }

  String _profileFunctionName(vm.ProfileFunction function) {
    final dynamic innerFunction = function.function;
    final dynamic name = innerFunction?.name;
    if (name is String && name.isNotEmpty) {
      return name;
    }
    if (function.resolvedUrl case final resolvedUrl?) {
      return resolvedUrl;
    }
    return 'unknown';
  }
}

class _ProfilingContext {
  const _ProfilingContext({
    required this.session,
    required this.handle,
  });

  final SessionRecord session;
  final LiveSessionHandle handle;
}
