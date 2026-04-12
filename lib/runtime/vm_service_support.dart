import 'dart:async';

import 'package:vm_service/vm_service.dart' as vm;
import 'package:vm_service/vm_service_io.dart';

class VmServiceSession {
  VmServiceSession._({
    required this.service,
    required this.isolate,
  });

  final vm.VmService service;
  final vm.Isolate isolate;

  static Future<VmServiceSession> connect(
    String wsUri, {
    String? requiredExtension,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final service = await vmServiceConnectUri(wsUri);
    try {
      final isolate = await primaryIsolate(
        service,
        requiredExtension: requiredExtension,
        timeout: timeout,
      );
      return VmServiceSession._(service: service, isolate: isolate);
    } catch (_) {
      await service.dispose();
      rethrow;
    }
  }

  Future<void> dispose() => service.dispose();
}

Future<vm.Isolate> primaryIsolate(
  vm.VmService service, {
  String? requiredExtension,
  Duration timeout = const Duration(seconds: 20),
}) async {
  final isolateRef = await _primaryIsolateRef(service);
  final isolate = await service.getIsolate(isolateRef.id!);
  if (requiredExtension == null ||
      isolate.extensionRPCs?.contains(requiredExtension) == true) {
    return isolate;
  }
  await waitForExtension(service, requiredExtension, timeout: timeout);
  return service.getIsolate(isolateRef.id!);
}

Future<vm.IsolateRef> _primaryIsolateRef(vm.VmService service) async {
  final vmInfo = await service.getVM();
  final isolates = vmInfo.isolates ?? const <vm.IsolateRef>[];
  for (final isolate in isolates) {
    if (isolate.isSystemIsolate != true) {
      return isolate;
    }
  }
  if (isolates.isNotEmpty) {
    return isolates.first;
  }
  throw StateError('No isolates are available in the connected VM service.');
}

Future<void> waitForExtension(
  vm.VmService service,
  String extension, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final isolateRef = await _primaryIsolateRef(service);
  final isolate = await service.getIsolate(isolateRef.id!);
  if (isolate.extensionRPCs?.contains(extension) == true) {
    return;
  }

  final completer = Completer<void>();
  try {
    await service.streamListen(vm.EventStreams.kExtension);
  } on vm.RPCError {
    // Already listening.
  }

  late final StreamSubscription<vm.Event> subscription;
  subscription = service.onExtensionEvent.listen((vm.Event event) async {
    final eventExtension = event.extensionData?.data['extensionRPC'];
    if (eventExtension == extension && !completer.isCompleted) {
      completer.complete();
      await subscription.cancel();
    }
  });

  try {
    await completer.future.timeout(timeout);
  } finally {
    await subscription.cancel();
  }
}

Future<Map<String, Object?>> toggleFlutterBoolExtension({
  required vm.VmService service,
  required vm.Isolate isolate,
  required String extensionName,
  required bool enabled,
}) async {
  final response = await service.callServiceExtension(
    extensionName,
    isolateId: isolate.id,
    args: <String, String>{'enabled': enabled ? 'true' : 'false'},
  );
  final raw = response.json;
  if (raw == null) {
    return <String, Object?>{'enabled': enabled};
  }
  return raw.map<String, Object?>(
    (String key, Object? value) => MapEntry<String, Object?>(key, value),
  );
}
