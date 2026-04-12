import 'package:flutterhelm/config/config.dart';
import 'package:flutterhelm/policies/risk.dart';

class ToolDefinition {
  const ToolDefinition({
    required this.name,
    required this.title,
    required this.description,
    required this.workflow,
    required this.risk,
    required this.implemented,
    this.inputSchema = const <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{},
    },
  });

  final String name;
  final String title;
  final String description;
  final String workflow;
  final RiskClass risk;
  final bool implemented;
  final Map<String, Object?> inputSchema;

  Map<String, Object?> toMcpTool() {
    return <String, Object?>{
      'name': name,
      'title': title,
      'description': description,
      'inputSchema': inputSchema,
    };
  }
}

class ToolRegistry {
  ToolRegistry() : _definitions = _buildDefinitions();

  final List<ToolDefinition> _definitions;

  List<ToolDefinition> get allDefinitions =>
      List<ToolDefinition>.unmodifiable(_definitions);

  ToolDefinition? byName(String name) {
    for (final definition in _definitions) {
      if (definition.name == name) {
        return definition;
      }
    }
    return null;
  }

  List<ToolDefinition> publicDefinitions(FlutterHelmConfig config) {
    final enabledWorkflows = config.enabledWorkflows.toSet();
    return _definitions
        .where(
          (ToolDefinition definition) =>
              definition.implemented &&
              enabledWorkflows.contains(definition.workflow),
        )
        .toList()
      ..sort((left, right) => left.name.compareTo(right.name));
  }

  Map<String, Object?> workflowStatus(FlutterHelmConfig config) {
    final enabledWorkflows = config.enabledWorkflows.toSet();
    final workflows = <String>{
      for (final definition in _definitions) definition.workflow,
    }.toList()..sort();

    final status = <String, Object?>{};
    for (final workflow in workflows) {
      status[workflow] = <String, Object?>{
        'configured': enabledWorkflows.contains(workflow),
        'implemented': _definitions.any(
          (ToolDefinition definition) =>
              definition.workflow == workflow && definition.implemented,
        ),
      };
    }
    return status;
  }
}

List<ToolDefinition> _buildDefinitions() {
  return const <ToolDefinition>[
    ToolDefinition(
      name: 'workspace_discover',
      title: 'Workspace Discover',
      description: 'List Flutter workspace candidates.',
      workflow: 'workspace',
      risk: RiskClass.readOnly,
      implemented: true,
    ),
    ToolDefinition(
      name: 'workspace_set_root',
      title: 'Workspace Set Root',
      description: 'Set the active workspace root.',
      workflow: 'workspace',
      risk: RiskClass.boundedMutation,
      implemented: true,
      inputSchema: <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'workspaceRoot': <String, Object?>{'type': 'string'},
          'approvalToken': <String, Object?>{'type': 'string'},
        },
        'required': <String>['workspaceRoot'],
        'additionalProperties': false,
      },
    ),
    ToolDefinition(
      name: 'workspace_show',
      title: 'Workspace Show',
      description: 'Show the current root, defaults, and workflow state.',
      workflow: 'workspace',
      risk: RiskClass.readOnly,
      implemented: true,
    ),
    ToolDefinition(
      name: 'analyze_project',
      title: 'Analyze Project',
      description: 'Run static analysis.',
      workflow: 'workspace',
      risk: RiskClass.readOnly,
      implemented: true,
      inputSchema: <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'workspaceRoot': <String, Object?>{'type': 'string'},
          'fatalInfos': <String, Object?>{'type': 'boolean'},
          'fatalWarnings': <String, Object?>{'type': 'boolean'},
        },
        'additionalProperties': false,
      },
    ),
    ToolDefinition(
      name: 'resolve_symbol',
      title: 'Resolve Symbol',
      description: 'Resolve symbol metadata.',
      workflow: 'workspace',
      risk: RiskClass.readOnly,
      implemented: true,
      inputSchema: <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'workspaceRoot': <String, Object?>{'type': 'string'},
          'symbol': <String, Object?>{'type': 'string'},
        },
        'required': <String>['symbol'],
        'additionalProperties': false,
      },
    ),
    ToolDefinition(
      name: 'format_files',
      title: 'Format Files',
      description: 'Format workspace files.',
      workflow: 'workspace',
      risk: RiskClass.projectMutation,
      implemented: true,
      inputSchema: <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'workspaceRoot': <String, Object?>{'type': 'string'},
          'paths': <String, Object?>{
            'type': 'array',
            'items': <String, Object?>{'type': 'string'},
          },
          'lineLength': <String, Object?>{'type': 'integer', 'minimum': 40},
        },
        'required': <String>['paths'],
        'additionalProperties': false,
      },
    ),
    ToolDefinition(
      name: 'pub_search',
      title: 'Pub Search',
      description: 'Search packages on pub.dev.',
      workflow: 'workspace',
      risk: RiskClass.readOnlyNetwork,
      implemented: true,
      inputSchema: <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'query': <String, Object?>{'type': 'string'},
          'limit': <String, Object?>{'type': 'integer', 'minimum': 1, 'maximum': 20},
        },
        'required': <String>['query'],
        'additionalProperties': false,
      },
    ),
    ToolDefinition(
      name: 'dependency_add',
      title: 'Dependency Add',
      description: 'Add a dependency to pubspec.yaml.',
      workflow: 'workspace',
      risk: RiskClass.projectMutation,
      implemented: true,
      inputSchema: <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'workspaceRoot': <String, Object?>{'type': 'string'},
          'package': <String, Object?>{'type': 'string'},
          'versionConstraint': <String, Object?>{'type': 'string'},
          'devDependency': <String, Object?>{'type': 'boolean'},
          'approvalToken': <String, Object?>{'type': 'string'},
        },
        'required': <String>['package'],
        'additionalProperties': false,
      },
    ),
    ToolDefinition(
      name: 'dependency_remove',
      title: 'Dependency Remove',
      description: 'Remove a dependency from pubspec.yaml.',
      workflow: 'workspace',
      risk: RiskClass.projectMutation,
      implemented: true,
      inputSchema: <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'workspaceRoot': <String, Object?>{'type': 'string'},
          'package': <String, Object?>{'type': 'string'},
          'approvalToken': <String, Object?>{'type': 'string'},
        },
        'required': <String>['package'],
        'additionalProperties': false,
      },
    ),
    ToolDefinition(
      name: 'session_open',
      title: 'Session Open',
      description: 'Open a reusable workspace context session.',
      workflow: 'session',
      risk: RiskClass.boundedMutation,
      implemented: true,
      inputSchema: <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'workspaceRoot': <String, Object?>{'type': 'string'},
          'target': <String, Object?>{'type': 'string'},
          'flavor': <String, Object?>{'type': 'string'},
          'mode': <String, Object?>{
            'type': 'string',
            'enum': <String>['debug', 'profile', 'release'],
          },
        },
        'additionalProperties': false,
      },
    ),
    ToolDefinition(
      name: 'session_show',
      title: 'Session Show',
      description: 'Show session details.',
      workflow: 'session',
      risk: RiskClass.readOnly,
      implemented: false,
    ),
    ToolDefinition(
      name: 'session_list',
      title: 'Session List',
      description: 'List active sessions.',
      workflow: 'session',
      risk: RiskClass.readOnly,
      implemented: true,
    ),
    ToolDefinition(
      name: 'session_close',
      title: 'Session Close',
      description: 'Close a session.',
      workflow: 'session',
      risk: RiskClass.boundedMutation,
      implemented: false,
    ),
    ToolDefinition(
      name: 'device_list',
      title: 'Device List',
      description: 'List connected devices.',
      workflow: 'launcher',
      risk: RiskClass.readOnly,
      implemented: true,
    ),
    ToolDefinition(
      name: 'run_app',
      title: 'Run App',
      description: 'Launch an app.',
      workflow: 'launcher',
      risk: RiskClass.runtimeControl,
      implemented: true,
      inputSchema: <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'sessionId': <String, Object?>{'type': 'string'},
          'workspaceRoot': <String, Object?>{'type': 'string'},
          'target': <String, Object?>{'type': 'string', 'default': 'lib/main.dart'},
          'platform': <String, Object?>{
            'type': 'string',
            'enum': <String>['ios', 'android', 'macos', 'linux', 'windows', 'web'],
          },
          'deviceId': <String, Object?>{'type': 'string'},
          'flavor': <String, Object?>{'type': 'string'},
          'mode': <String, Object?>{
            'type': 'string',
            'enum': <String>['debug', 'profile', 'release'],
            'default': 'debug',
          },
          'dartDefines': <String, Object?>{
            'type': 'array',
            'items': <String, Object?>{'type': 'string'},
          },
        },
        'required': <String>['platform'],
        'additionalProperties': false,
      },
    ),
    ToolDefinition(
      name: 'attach_app',
      title: 'Attach App',
      description: 'Attach to an existing app.',
      workflow: 'launcher',
      risk: RiskClass.runtimeControl,
      implemented: true,
      inputSchema: <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'sessionId': <String, Object?>{'type': 'string'},
          'workspaceRoot': <String, Object?>{'type': 'string'},
          'platform': <String, Object?>{
            'type': 'string',
            'enum': <String>['ios', 'android', 'macos', 'linux', 'windows', 'web'],
          },
          'deviceId': <String, Object?>{'type': 'string'},
          'target': <String, Object?>{'type': 'string', 'default': 'lib/main.dart'},
          'flavor': <String, Object?>{'type': 'string'},
          'mode': <String, Object?>{
            'type': 'string',
            'enum': <String>['debug', 'profile'],
            'default': 'debug',
          },
          'debugUrl': <String, Object?>{'type': 'string'},
          'appId': <String, Object?>{'type': 'string'},
        },
        'required': <String>['platform'],
        'additionalProperties': false,
      },
    ),
    ToolDefinition(
      name: 'stop_app',
      title: 'Stop App',
      description: 'Stop a managed app process.',
      workflow: 'launcher',
      risk: RiskClass.runtimeControl,
      implemented: true,
      inputSchema: <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'sessionId': <String, Object?>{'type': 'string'},
        },
        'required': <String>['sessionId'],
        'additionalProperties': false,
      },
    ),
    ToolDefinition(
      name: 'build_app',
      title: 'Build App',
      description: 'Build an app artifact.',
      workflow: 'launcher',
      risk: RiskClass.buildControl,
      implemented: false,
    ),
    ToolDefinition(
      name: 'get_runtime_errors',
      title: 'Get Runtime Errors',
      description: 'Read runtime errors.',
      workflow: 'runtime_readonly',
      risk: RiskClass.readOnly,
      implemented: true,
      inputSchema: <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'sessionId': <String, Object?>{'type': 'string'},
        },
        'required': <String>['sessionId'],
        'additionalProperties': false,
      },
    ),
    ToolDefinition(
      name: 'get_widget_tree',
      title: 'Get Widget Tree',
      description: 'Read the current widget tree snapshot.',
      workflow: 'runtime_readonly',
      risk: RiskClass.readOnly,
      implemented: true,
      inputSchema: <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'sessionId': <String, Object?>{'type': 'string'},
          'depth': <String, Object?>{
            'type': 'integer',
            'minimum': 1,
            'maximum': 12,
            'default': 3,
          },
          'includeProperties': <String, Object?>{'type': 'boolean', 'default': false},
        },
        'required': <String>['sessionId'],
        'additionalProperties': false,
      },
    ),
    ToolDefinition(
      name: 'get_logs',
      title: 'Get Logs',
      description: 'Read session logs.',
      workflow: 'runtime_readonly',
      risk: RiskClass.readOnly,
      implemented: true,
      inputSchema: <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'sessionId': <String, Object?>{'type': 'string'},
          'stream': <String, Object?>{
            'type': 'string',
            'enum': <String>['stdout', 'stderr', 'both'],
            'default': 'both',
          },
          'tailLines': <String, Object?>{
            'type': 'integer',
            'minimum': 1,
            'maximum': 2000,
            'default': 200,
          },
        },
        'required': <String>['sessionId'],
        'additionalProperties': false,
      },
    ),
    ToolDefinition(
      name: 'get_app_state_summary',
      title: 'Get App State Summary',
      description: 'Read a high-level app summary.',
      workflow: 'runtime_readonly',
      risk: RiskClass.readOnly,
      implemented: true,
      inputSchema: <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'sessionId': <String, Object?>{'type': 'string'},
        },
        'required': <String>['sessionId'],
        'additionalProperties': false,
      },
    ),
    ToolDefinition(
      name: 'capture_screenshot',
      title: 'Capture Screenshot',
      description: 'Capture a screenshot as a resource.',
      workflow: 'runtime_readonly',
      risk: RiskClass.boundedMutation,
      implemented: false,
    ),
    ToolDefinition(
      name: 'run_unit_tests',
      title: 'Run Unit Tests',
      description: 'Run unit tests.',
      workflow: 'tests',
      risk: RiskClass.testExecution,
      implemented: true,
      inputSchema: <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'workspaceRoot': <String, Object?>{'type': 'string'},
          'targets': <String, Object?>{
            'type': 'array',
            'items': <String, Object?>{'type': 'string'},
          },
          'coverage': <String, Object?>{'type': 'boolean', 'default': false},
        },
        'additionalProperties': false,
      },
    ),
    ToolDefinition(
      name: 'run_widget_tests',
      title: 'Run Widget Tests',
      description: 'Run widget tests.',
      workflow: 'tests',
      risk: RiskClass.testExecution,
      implemented: true,
      inputSchema: <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'workspaceRoot': <String, Object?>{'type': 'string'},
          'targets': <String, Object?>{
            'type': 'array',
            'items': <String, Object?>{'type': 'string'},
          },
          'coverage': <String, Object?>{'type': 'boolean', 'default': false},
        },
        'additionalProperties': false,
      },
    ),
    ToolDefinition(
      name: 'run_integration_tests',
      title: 'Run Integration Tests',
      description: 'Run integration tests.',
      workflow: 'tests',
      risk: RiskClass.testExecution,
      implemented: true,
      inputSchema: <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'workspaceRoot': <String, Object?>{'type': 'string'},
          'platform': <String, Object?>{'type': 'string'},
          'deviceId': <String, Object?>{'type': 'string'},
          'target': <String, Object?>{'type': 'string'},
          'flavor': <String, Object?>{'type': 'string'},
          'coverage': <String, Object?>{'type': 'boolean', 'default': false},
        },
        'required': <String>['platform', 'target'],
        'additionalProperties': false,
      },
    ),
    ToolDefinition(
      name: 'get_test_results',
      title: 'Get Test Results',
      description: 'Read test results.',
      workflow: 'tests',
      risk: RiskClass.readOnly,
      implemented: true,
      inputSchema: <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'runId': <String, Object?>{'type': 'string'},
        },
        'required': <String>['runId'],
        'additionalProperties': false,
      },
    ),
    ToolDefinition(
      name: 'collect_coverage',
      title: 'Collect Coverage',
      description: 'Collect coverage artifacts.',
      workflow: 'tests',
      risk: RiskClass.readOnly,
      implemented: true,
      inputSchema: <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'runId': <String, Object?>{'type': 'string'},
        },
        'required': <String>['runId'],
        'additionalProperties': false,
      },
    ),
    ToolDefinition(
      name: 'tap_widget',
      title: 'Tap Widget',
      description: 'Tap a widget via a runtime driver.',
      workflow: 'runtime_interaction',
      risk: RiskClass.runtimeControl,
      implemented: false,
    ),
    ToolDefinition(
      name: 'enter_text',
      title: 'Enter Text',
      description: 'Enter text via a runtime driver.',
      workflow: 'runtime_interaction',
      risk: RiskClass.runtimeControl,
      implemented: false,
    ),
    ToolDefinition(
      name: 'scroll_until_visible',
      title: 'Scroll Until Visible',
      description: 'Scroll until a widget is visible.',
      workflow: 'runtime_interaction',
      risk: RiskClass.runtimeControl,
      implemented: false,
    ),
    ToolDefinition(
      name: 'hot_reload',
      title: 'Hot Reload',
      description: 'Trigger a hot reload.',
      workflow: 'runtime_interaction',
      risk: RiskClass.runtimeControl,
      implemented: false,
    ),
    ToolDefinition(
      name: 'hot_restart',
      title: 'Hot Restart',
      description: 'Trigger a hot restart.',
      workflow: 'runtime_interaction',
      risk: RiskClass.stateDestructive,
      implemented: false,
    ),
    ToolDefinition(
      name: 'start_cpu_profile',
      title: 'Start CPU Profile',
      description: 'Start CPU profiling.',
      workflow: 'profiling',
      risk: RiskClass.runtimeControl,
      implemented: false,
    ),
    ToolDefinition(
      name: 'stop_cpu_profile',
      title: 'Stop CPU Profile',
      description: 'Stop CPU profiling.',
      workflow: 'profiling',
      risk: RiskClass.runtimeControl,
      implemented: false,
    ),
    ToolDefinition(
      name: 'capture_memory_snapshot',
      title: 'Capture Memory Snapshot',
      description: 'Capture a memory snapshot.',
      workflow: 'profiling',
      risk: RiskClass.runtimeControl,
      implemented: false,
    ),
    ToolDefinition(
      name: 'capture_timeline',
      title: 'Capture Timeline',
      description: 'Capture a performance timeline.',
      workflow: 'profiling',
      risk: RiskClass.runtimeControl,
      implemented: false,
    ),
    ToolDefinition(
      name: 'toggle_performance_overlay',
      title: 'Toggle Performance Overlay',
      description: 'Toggle the performance overlay.',
      workflow: 'profiling',
      risk: RiskClass.runtimeControl,
      implemented: false,
    ),
    ToolDefinition(
      name: 'ios_debug_context',
      title: 'iOS Debug Context',
      description: 'Create an iOS handoff bundle.',
      workflow: 'platform_bridge',
      risk: RiskClass.readOnly,
      implemented: false,
    ),
    ToolDefinition(
      name: 'android_debug_context',
      title: 'Android Debug Context',
      description: 'Create an Android handoff bundle.',
      workflow: 'platform_bridge',
      risk: RiskClass.readOnly,
      implemented: false,
    ),
    ToolDefinition(
      name: 'native_handoff_summary',
      title: 'Native Handoff Summary',
      description: 'Summarize native debugging context.',
      workflow: 'platform_bridge',
      risk: RiskClass.readOnly,
      implemented: false,
    ),
  ];
}
