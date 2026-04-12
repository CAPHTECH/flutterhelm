import 'dart:io';

import 'package:flutterhelm/policies/approvals.dart';
import 'package:test/test.dart';

void main() {
  group('ApprovalStore', () {
    test('consumes matching replay token exactly once', () async {
      final sandbox = await Directory.systemTemp.createTemp('approval-store');
      addTearDown(() => sandbox.delete(recursive: true));

      final store = await ApprovalStore.create(stateDir: sandbox.path);
      final request = await store.createRequest(
        tool: 'dependency_add',
        argumentsHash: 'abc',
        workspaceRoot: '/tmp/workspace',
        riskClass: 'project_mutation',
      );

      final approved = await store.consume(
        approvalToken: request.approvalRequestId,
        tool: 'dependency_add',
        argumentsHash: 'abc',
        workspaceRoot: '/tmp/workspace',
      );
      expect(approved.status, ApprovalConsumeStatus.approved);

      final rejected = await store.consume(
        approvalToken: request.approvalRequestId,
        tool: 'dependency_add',
        argumentsHash: 'abc',
        workspaceRoot: '/tmp/workspace',
      );
      expect(rejected.status, ApprovalConsumeStatus.rejected);
    });

    test('rejects mismatched arguments and expires old tokens', () async {
      final sandbox = await Directory.systemTemp.createTemp('approval-store');
      addTearDown(() => sandbox.delete(recursive: true));

      final store = await ApprovalStore.create(stateDir: sandbox.path);
      final mismatch = await store.createRequest(
        tool: 'dependency_remove',
        argumentsHash: 'hash-a',
        workspaceRoot: '/tmp/workspace',
        riskClass: 'project_mutation',
      );

      final rejected = await store.consume(
        approvalToken: mismatch.approvalRequestId,
        tool: 'dependency_remove',
        argumentsHash: 'hash-b',
        workspaceRoot: '/tmp/workspace',
      );
      expect(rejected.status, ApprovalConsumeStatus.rejected);

      final expired = await store.createRequest(
        tool: 'workspace_set_root',
        argumentsHash: 'hash-root',
        workspaceRoot: '/tmp/workspace',
        riskClass: 'bounded_mutation',
        ttl: const Duration(milliseconds: 1),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final expiredResult = await store.consume(
        approvalToken: expired.approvalRequestId,
        tool: 'workspace_set_root',
        argumentsHash: 'hash-root',
        workspaceRoot: '/tmp/workspace',
      );
      expect(expiredResult.status, ApprovalConsumeStatus.expired);
    });
  });
}
