import 'dart:async';
import 'dart:convert';
import 'dart:io';

class ProcessRunResult {
  const ProcessRunResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    required this.duration,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
  final Duration duration;
}

class ProcessRunner {
  const ProcessRunner();

  Future<ProcessRunResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    Duration timeout = const Duration(minutes: 2),
  }) async {
    final startedAt = DateTime.now().toUtc();
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
    );
    final stdoutFuture = process.stdout.transform(utf8.decoder).join();
    final stderrFuture = process.stderr.transform(utf8.decoder).join();
    final exitCode = await process.exitCode.timeout(
      timeout,
      onTimeout: () {
        process.kill();
        return 124;
      },
    );
    return ProcessRunResult(
      exitCode: exitCode,
      stdout: await stdoutFuture,
      stderr: await stderrFuture,
      duration: DateTime.now().toUtc().difference(startedAt),
    );
  }
}
