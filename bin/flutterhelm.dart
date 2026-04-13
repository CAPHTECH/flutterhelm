import 'dart:io';

import 'package:args/args.dart';
import 'package:flutterhelm/flutterhelm.dart';

ArgParser buildParser() {
  final serve = ArgParser()
    ..addOption('config', help: 'Override the config.yaml path.')
    ..addOption('state-dir', help: 'Override the mutable state directory.')
    ..addOption('profile', help: 'Select a named config profile overlay.')
    ..addOption(
      'transport',
      help: 'Select the server transport.',
      allowed: <String>['stdio', 'http'],
      defaultsTo: 'stdio',
    )
    ..addOption('http-host', help: 'Bind host for HTTP preview.', defaultsTo: '127.0.0.1')
    ..addOption('http-port', help: 'Bind port for HTTP preview.', defaultsTo: '0')
    ..addOption('http-path', help: 'Request path for HTTP preview.', defaultsTo: '/mcp')
    ..addFlag(
      'allow-root-fallback',
      help: 'Allow workspace_set_root without client roots support.',
      negatable: false,
    )
    ..addOption(
      'log-level',
      help: 'Server log level.',
      allowed: <String>['info', 'debug'],
      defaultsTo: 'info',
    )
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show this help.');

  return ArgParser()
    ..addCommand('serve', serve)
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show this help.');
}

Never printUsage(ArgParser parser, {int exitCode = 64}) {
  stderr
    ..writeln('Usage: flutterhelm serve [options]')
    ..writeln(parser.usage);
  exit(exitCode);
}

Future<void> main(List<String> arguments) async {
  final parser = buildParser();
  late final ArgResults results;

  try {
    results = parser.parse(arguments);
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    printUsage(parser);
  }

  if (results['help'] == true || results.command?.name == null) {
    printUsage(parser, exitCode: 0);
  }

  final command = results.command!;
  if (command['help'] == true) {
    printUsage(parser, exitCode: 0);
  }

  if (command.name != 'serve') {
    stderr.writeln('Unknown command: ${command.name}');
    printUsage(parser);
  }

  final runtimePaths = RuntimePaths.fromEnvironment(
    configPathOverride: command['config'] as String?,
    stateDirOverride: command['state-dir'] as String?,
  );

  try {
    final selectedProfile =
        (command['profile'] as String?) ??
        Platform.environment[RuntimePaths.profileEnvVar];
    final server = await FlutterHelmServer.create(
      runtimePaths: runtimePaths,
      allowRootFallbackFlag: command['allow-root-fallback'] as bool,
      logLevel: command['log-level'] as String,
      selectedProfile: selectedProfile,
    );
    final transport = command['transport'] as String;
    if (transport == 'http') {
      await server.runHttpPreview(
        host: command['http-host'] as String,
        port: int.tryParse(command['http-port'] as String? ?? '0') ?? 0,
        path: command['http-path'] as String? ?? '/mcp',
      );
    } else {
      await server.runStdio();
    }
  } on ConfigException catch (error) {
    stderr.writeln(error.message);
    exitCode = 78;
  } catch (error, stackTrace) {
    stderr
      ..writeln('flutterhelm failed: $error')
      ..writeln(stackTrace);
    exitCode = 1;
  }
}
