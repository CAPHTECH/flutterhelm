import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

void main() {
  final provider = _FakeNativeBuildProvider();
  stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(provider.handleLine);
}

class _FakeNativeBuildProvider {
  final Set<String> _activeBuildIds = <String>{};

  void handleLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) {
      return;
    }
    final decoded = jsonDecode(trimmed);
    if (decoded is! Map) {
      return;
    }
    final id = decoded['id'];
    final method = decoded['method'] as String?;
    if (id == null || method == null) {
      return;
    }
    final params = _asMap(decoded['params']);
    switch (method) {
      case 'initialize':
        _sendResult(id, <String, Object?>{
          'adapterProtocolVersion': 'flutterhelm.adapter.v1',
          'providerInfo': <String, Object?>{
            'name': 'fake-native-build-provider',
            'version': '0.1.0',
          },
          'families': <String>['nativeBuild'],
          'operations': <String, Object?>{
            'nativeBuild': <String>['inspect_project', 'build_launch', 'stop'],
          },
        });
        return;
      case 'provider/health':
        _sendResult(id, <String, Object?>{
          'providerInfo': <String, Object?>{
            'name': 'fake-native-build-provider',
            'version': '0.1.0',
          },
          'families': <String, Object?>{
            'nativeBuild': <String, Object?>{
              'healthy': true,
              'operations': <String>['inspect_project', 'build_launch', 'stop'],
              'supportedPlatforms': <String>['ios'],
            },
          },
        });
        return;
      case 'provider/invoke':
        _handleInvoke(id, params);
        return;
      default:
        _sendError(id, 'Unsupported method: $method');
    }
  }

  void _handleInvoke(Object id, Map<String, Object?> params) {
    final family = params['family'] as String?;
    final operation = params['operation'] as String?;
    final input = _asMap(params['input']);
    if (family != 'nativeBuild' || operation == null) {
      _sendError(id, 'Unsupported adapter family.');
      return;
    }
    switch (operation) {
      case 'inspect_project':
        _sendResult(id, _inspectProject(input));
        return;
      case 'build_launch':
        _sendResult(id, _buildLaunch(input));
        return;
      case 'stop':
        _sendResult(id, _stop(input));
        return;
      default:
        _sendError(id, 'Unsupported operation: $operation');
    }
  }

  Map<String, Object?> _inspectProject(Map<String, Object?> input) {
    final workspaceRoot = input['workspaceRoot'] as String? ?? '';
    final platform = input['platform'] as String? ?? 'ios';
    return <String, Object?>{
      'status': 'ready',
      'platform': platform,
      'projectPath': p.join(workspaceRoot, 'ios', 'Runner.xcodeproj'),
      'workspacePath': p.join(workspaceRoot, 'ios', 'Runner.xcworkspace'),
      'schemes': const <String>['Runner'],
      'destinations': const <String>[
        'platform=iOS Simulator,name=iPhone 16',
      ],
      'notes': const <String>[
        'Fake provider for contract tests.',
      ],
    };
  }

  Map<String, Object?> _buildLaunch(Map<String, Object?> input) {
    final workspaceRoot = input['workspaceRoot'] as String? ?? '';
    final buildId = 'build_${DateTime.now().toUtc().microsecondsSinceEpoch}';
    _activeBuildIds.add(buildId);
    return <String, Object?>{
      'buildId': buildId,
      'platform': input['platform'] as String? ?? 'ios',
      'projectPath': p.join(workspaceRoot, 'ios', 'Runner.xcodeproj'),
      'workspacePath': p.join(workspaceRoot, 'ios', 'Runner.xcworkspace'),
      'scheme': input['scheme'] as String? ?? 'Runner',
      'configuration': input['configuration'] as String? ?? 'Debug',
      'destination':
          input['destination'] as String? ??
          'platform=iOS Simulator,name=iPhone 16',
      'launchStatus': 'launched',
      'nativeDebuggerAttached': true,
      'nativeAppId': 'com.example.sampleApp',
      'deviceId': 'fake-ios-simulator',
      'debugUrl': 'ws://127.0.0.1:34567/ws',
      'appId': 'fake-ios-app',
      'buildLogLines': <String>[
        'xcodebuild -scheme Runner -configuration Debug',
        'Build succeeded',
      ],
      'deviceLogLines': <String>[
        'Installing com.example.sampleApp on fake-ios-simulator',
        'Application launched',
      ],
    };
  }

  Map<String, Object?> _stop(Map<String, Object?> input) {
    final buildId = input['buildId'] as String?;
    if (buildId != null) {
      _activeBuildIds.remove(buildId);
    }
    return <String, Object?>{
      'status': 'stopped',
      'buildLogLines': <String>[
        if (buildId != null) 'Stopped build session $buildId',
      ],
      'deviceLogLines': const <String>['Application terminated'],
    };
  }

  void _sendResult(Object id, Map<String, Object?> result) {
    stdout.writeln(
      jsonEncode(<String, Object?>{
        'jsonrpc': '2.0',
        'id': id,
        'result': result,
      }),
    );
  }

  void _sendError(Object id, String message) {
    stdout.writeln(
      jsonEncode(<String, Object?>{
        'jsonrpc': '2.0',
        'id': id,
        'error': <String, Object?>{
          'code': -32601,
          'message': message,
        },
      }),
    );
  }

  Map<String, Object?> _asMap(Object? value) {
    if (value is Map<String, Object?>) {
      return value;
    }
    if (value is Map) {
      return value.map<String, Object?>(
        (Object? key, Object? nested) =>
            MapEntry<String, Object?>(key.toString(), nested),
      );
    }
    return <String, Object?>{};
  }
}
