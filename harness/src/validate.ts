import { access } from "node:fs/promises";
import { constants } from "node:fs";
import { resolve } from "node:path";
import { HarnessCase, HarnessConfig, discoverCases, loadConfig, resolveHarnessPath } from "./config.js";
import { resolveRepoRoot } from "./support.js";

const ALLOWED_TAGS = new Set(["smoke", "regression", "runtime", "profiling", "edge", "adversarial"]);

async function ensurePath(path: string, label: string, errors: string[]): Promise<void> {
  try {
    await access(path, constants.F_OK);
  } catch {
    errors.push(`Missing ${label}: ${path}`);
  }
}

function validateConfig(config: HarnessConfig, errors: string[]): void {
  if (!["hybrid", "software", "agent-eval"].includes(config.profile)) {
    errors.push(`Unsupported profile: ${config.profile}`);
  }

  if (!config.targets.software && config.profile !== "agent-eval") {
    errors.push("software target is required for hybrid/software profiles");
  }

  if (!config.targets.agentEval && config.profile !== "software") {
    errors.push("agentEval target is required for hybrid/agent-eval profiles");
  }

  if (!config.artifacts.reportsDir || !config.artifacts.tracesDir) {
    errors.push("artifacts.reportsDir and artifacts.tracesDir are required");
  }
}

function validateCase(caseItem: HarnessCase, config: HarnessConfig, seenIds: Set<string>, errors: string[]): void {
  if (!caseItem.id) {
    errors.push(`Case without id: ${caseItem.sourceFile ?? "<unknown>"}`);
    return;
  }

  if (seenIds.has(caseItem.id)) {
    errors.push(`Duplicate case id: ${caseItem.id}`);
  }
  seenIds.add(caseItem.id);

  if (!["software", "agent-eval"].includes(caseItem.mode)) {
    errors.push(`Unsupported mode for ${caseItem.id}: ${caseItem.mode}`);
  }

  if (config.profile === "software" && caseItem.mode !== "software") {
    errors.push(`software profile cannot contain ${caseItem.mode} case: ${caseItem.id}`);
  }

  if (config.profile === "agent-eval" && caseItem.mode !== "agent-eval") {
    errors.push(`agent-eval profile cannot contain ${caseItem.mode} case: ${caseItem.id}`);
  }

  if (!Array.isArray(caseItem.tags) || caseItem.tags.length === 0) {
    errors.push(`Case must have at least one tag: ${caseItem.id}`);
  } else {
    for (const tag of caseItem.tags) {
      if (!ALLOWED_TAGS.has(tag)) {
        errors.push(`Unsupported tag "${tag}" in ${caseItem.id}`);
      }
    }
  }

  if (caseItem.expect.exitCode !== undefined && typeof caseItem.expect.exitCode !== "number") {
    errors.push(`expect.exitCode must be a number in ${caseItem.id}`);
  }

  if (
    caseItem.expect.stdoutIncludes !== undefined
    && (
      !Array.isArray(caseItem.expect.stdoutIncludes)
      || caseItem.expect.stdoutIncludes.some((item) => typeof item !== "string")
    )
  ) {
    errors.push(`expect.stdoutIncludes must be a string array in ${caseItem.id}`);
  }

  if (caseItem.expect.writesTrace !== undefined && typeof caseItem.expect.writesTrace !== "boolean") {
    errors.push(`expect.writesTrace must be a boolean in ${caseItem.id}`);
  }

  const input = caseItem.input ?? {};
  if (caseItem.mode === "software") {
    const checks = input.checks;
    if (!Array.isArray(checks) || checks.length === 0 || checks.some((item) => typeof item !== "string")) {
      errors.push(`software case must define input.checks as a string array: ${caseItem.id}`);
    }
  }

  if (caseItem.mode === "agent-eval") {
    if (typeof input.prompt !== "string" || input.prompt.trim() === "") {
      errors.push(`agent-eval case must define input.prompt: ${caseItem.id}`);
    }
    if (
      !Array.isArray(input.mustCite)
      || input.mustCite.length === 0
      || input.mustCite.some((item) => typeof item !== "string")
    ) {
      errors.push(`agent-eval case must define input.mustCite as a string array: ${caseItem.id}`);
    }
  }
}

export async function validateHarness(rootDir = process.cwd()): Promise<string[]> {
  const errors: string[] = [];
  const repoRoot = resolveRepoRoot(rootDir);
  await ensurePath(resolveHarnessPath(rootDir, "package.json"), "package.json", errors);
  await ensurePath(resolveHarnessPath(rootDir, "pnpm-lock.yaml"), "pnpm-lock.yaml", errors);
  await ensurePath(resolveHarnessPath(rootDir, "tsconfig.json"), "tsconfig.json", errors);
  await ensurePath(resolveHarnessPath(rootDir, "harness.config.json"), "harness.config.json", errors);
  await ensurePath(resolveHarnessPath(rootDir, "README.md"), "README.md", errors);
  await ensurePath(resolveHarnessPath(rootDir, "requirements-docs.txt"), "requirements-docs.txt", errors);
  await ensurePath(resolveHarnessPath(rootDir, ".gitignore"), ".gitignore", errors);
  await ensurePath(resolveHarnessPath(rootDir, "cases"), "cases directory", errors);
  await ensurePath(resolveHarnessPath(rootDir, "fixtures"), "fixtures directory", errors);
  await ensurePath(resolveHarnessPath(rootDir, "reports", ".gitignore"), "reports/.gitignore", errors);
  await ensurePath(resolveHarnessPath(rootDir, "traces", ".gitignore"), "traces/.gitignore", errors);
  await ensurePath(resolveHarnessPath(rootDir, "src", "bootstrap.ts"), "src/bootstrap.ts", errors);
  await ensurePath(resolveHarnessPath(rootDir, "src", "targets", "docs-contract.ts"), "src/targets/docs-contract.ts", errors);
  await ensurePath(resolveHarnessPath(rootDir, "src", "targets", "docs-qa.ts"), "src/targets/docs-qa.ts", errors);
  await ensurePath(resolve(repoRoot, "README.md"), "repo README.md", errors);
  await ensurePath(resolve(repoRoot, "mkdocs.yml"), "repo mkdocs.yml", errors);
  await ensurePath(resolve(repoRoot, "mise.toml"), "repo mise.toml", errors);
  await ensurePath(resolve(repoRoot, "pubspec.yaml"), "repo pubspec.yaml", errors);
  await ensurePath(resolve(repoRoot, "bin", "flutterhelm.dart"), "bin/flutterhelm.dart", errors);
  await ensurePath(resolve(repoRoot, ".github", "workflows", "harness.yml"), ".github/workflows/harness.yml", errors);
  await ensurePath(
    resolve(repoRoot, ".devcontainer", "harness", "devcontainer.json"),
    ".devcontainer/harness/devcontainer.json",
    errors,
  );
  await ensurePath(resolve(repoRoot, "docs", "07-roadmap.md"), "docs/07-roadmap.md", errors);
  await ensurePath(resolve(repoRoot, "docs", "09-implementation-plan.md"), "docs/09-implementation-plan.md", errors);

  if (errors.length > 0) {
    return errors;
  }

  const config = await loadConfig(rootDir);
  validateConfig(config, errors);
  const seenIds = new Set<string>();
  const cases = await discoverCases(rootDir);
  for (const caseItem of cases) {
    validateCase(caseItem, config, seenIds, errors);
  }
  return errors;
}
