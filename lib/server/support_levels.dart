import 'package:flutterhelm/config/config.dart';

enum SupportLevel { stable, beta, preview }

const String flutterHelmReleaseChannel = 'stable';
const List<String> flutterHelmStableHarnessTags = <String>[
  'smoke',
  'contracts',
  'hardening',
  'runtime',
  'profiling',
  'bridge',
];
const List<String> flutterHelmBetaHarnessTags = <String>[
  ...flutterHelmStableHarnessTags,
  'ecosystem',
  'interaction',
];

SupportLevel workflowSupportLevel(String workflow) {
  return switch (workflow) {
    'runtime_interaction' => SupportLevel.beta,
    _ => SupportLevel.stable,
  };
}

SupportLevel transportSupportLevel(String transportMode) {
  return switch (transportMode) {
    'http' => SupportLevel.preview,
    _ => SupportLevel.stable,
  };
}

SupportLevel adapterFamilySupportLevel(String family) {
  return switch (family) {
    'runtimeDriver' => SupportLevel.beta,
    _ => SupportLevel.stable,
  };
}

SupportLevel adapterProviderSupportLevel(AdapterProviderConfig provider) {
  if (provider.kind == 'stdio_json') {
    return SupportLevel.beta;
  }
  if (provider.id == 'builtin.runtime_driver.external_process') {
    return SupportLevel.beta;
  }
  return SupportLevel.stable;
}

bool workflowIncludedInStableLane(String workflow) {
  return workflowSupportLevel(workflow) == SupportLevel.stable;
}

bool transportIncludedInStableLane(String transportMode) {
  return transportSupportLevel(transportMode) == SupportLevel.stable;
}

bool adapterProviderIncludedInStableLane(AdapterProviderConfig provider) {
  return adapterProviderSupportLevel(provider) == SupportLevel.stable;
}

bool adapterFamilyIncludedInStableLane(
  String family,
  AdapterProviderConfig? provider,
) {
  return adapterFamilySupportLevel(family) == SupportLevel.stable &&
      provider != null &&
      adapterProviderIncludedInStableLane(provider);
}

Map<String, Object?> supportLevelMetadata({
  required SupportLevel supportLevel,
  required bool includedInStableLane,
  String? rationale,
}) {
  return <String, Object?>{
    'supportLevel': supportLevel.name,
    'includedInStableLane': includedInStableLane,
    if (rationale != null) 'supportRationale': rationale,
  };
}
