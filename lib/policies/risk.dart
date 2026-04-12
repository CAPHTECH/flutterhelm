enum RiskClass {
  readOnly,
  readOnlyNetwork,
  boundedMutation,
  runtimeControl,
  projectMutation,
  stateDestructive,
  buildControl,
  publishLike,
  testExecution,
}

extension RiskClassWireName on RiskClass {
  String get wireName {
    switch (this) {
      case RiskClass.readOnly:
        return 'read_only';
      case RiskClass.readOnlyNetwork:
        return 'read_only_network';
      case RiskClass.boundedMutation:
        return 'bounded_mutation';
      case RiskClass.runtimeControl:
        return 'runtime_control';
      case RiskClass.projectMutation:
        return 'project_mutation';
      case RiskClass.stateDestructive:
        return 'state_destructive';
      case RiskClass.buildControl:
        return 'build_control';
      case RiskClass.publishLike:
        return 'publish_like';
      case RiskClass.testExecution:
        return 'test_execution';
    }
  }
}
