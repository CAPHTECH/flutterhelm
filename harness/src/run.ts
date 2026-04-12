import { mkdir, readFile, writeFile } from "node:fs/promises";
import { spawn } from "node:child_process";
import { basename } from "node:path";
import { HarnessCase, discoverCases, loadConfig, resolveHarnessPath } from "./config.js";
import { validateHarness } from "./validate.js";

interface CaseResult {
  id: string;
  mode: HarnessCase["mode"];
  tags: string[];
  ok: boolean;
  exitCode: number;
  durationMs: number;
  stdout: string;
  stderr: string;
  traceFile?: string;
  failures: string[];
}

interface RunReport {
  profile: string;
  generatedAt: string;
  selectedTag?: string;
  summary: {
    total: number;
    passed: number;
    failed: number;
  };
  results: CaseResult[];
}

function resolveTargetCommand(mode: HarnessCase["mode"], config: Awaited<ReturnType<typeof loadConfig>>): string {
  if (mode === "software") {
    return config.targets.software?.command ?? "";
  }
  return config.targets.agentEval?.command ?? "";
}

function safeCaseFileName(caseId: string): string {
  return caseId.replace(/[^a-zA-Z0-9._-]+/g, "_");
}

function checkExpectations(caseItem: HarnessCase, stdout: string, exitCode: number, traceFile: string): string[] {
  const failures: string[] = [];

  if (caseItem.expect.exitCode !== undefined && caseItem.expect.exitCode !== exitCode) {
    failures.push(`expected exitCode ${caseItem.expect.exitCode}, got ${exitCode}`);
  }

  for (const expected of caseItem.expect.stdoutIncludes ?? []) {
    if (!stdout.includes(expected)) {
      failures.push(`stdout missing "${expected}"`);
    }
  }

  if (caseItem.expect.writesTrace) {
    return failures;
  }

  return failures;
}

async function runCommand(command: string, env: NodeJS.ProcessEnv, cwd: string): Promise<{ exitCode: number; stdout: string; stderr: string; durationMs: number }> {
  const startedAt = Date.now();

  return new Promise((resolve, reject) => {
    const child = spawn("sh", ["-lc", command], {
      cwd,
      env,
      stdio: ["ignore", "pipe", "pipe"],
    });

    let stdout = "";
    let stderr = "";

    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", reject);
    child.on("close", (code) => {
      resolve({
        exitCode: code ?? 1,
        stdout: stdout.trim(),
        stderr: stderr.trim(),
        durationMs: Date.now() - startedAt,
      });
    });
  });
}

function renderMarkdown(report: RunReport): string {
  const lines = [
    "# Harness Report",
    "",
    `- profile: ${report.profile}`,
    `- generated_at: ${report.generatedAt}`,
    `- selected_tag: ${report.selectedTag ?? "all"}`,
    `- passed: ${report.summary.passed}/${report.summary.total}`,
    "",
    "| Case | Mode | Result | Duration (ms) | Artifacts |",
    "| --- | --- | --- | ---: | --- |",
  ];

  for (const item of report.results) {
    const result = item.ok ? "PASS" : "FAIL";
    const artifact = item.traceFile ? basename(item.traceFile) : "-";
    lines.push(`| ${item.id} | ${item.mode} | ${result} | ${item.durationMs} | ${artifact} |`);
    if (item.failures.length > 0) {
      lines.push(`| ${item.id} details | - | ${item.failures.join("; ")} | - | - |`);
    }
  }

  return `${lines.join("\n")}\n`;
}

export async function runHarness(rootDir = process.cwd(), selectedTag?: string): Promise<RunReport> {
  const validationErrors = await validateHarness(rootDir);
  if (validationErrors.length > 0) {
    throw new Error(`Harness validation failed:\n- ${validationErrors.join("\n- ")}`);
  }

  const config = await loadConfig(rootDir);
  const cases = (await discoverCases(rootDir)).filter((caseItem) => {
    return selectedTag ? caseItem.tags.includes(selectedTag) : true;
  });
  const repoRoot = resolveHarnessPath(rootDir, "..");

  if (cases.length === 0) {
    throw new Error(`No harness cases matched tag: ${selectedTag ?? "all"}`);
  }

  const reportsDir = resolveHarnessPath(rootDir, config.artifacts.reportsDir);
  const tracesDir = resolveHarnessPath(rootDir, config.artifacts.tracesDir);
  await mkdir(reportsDir, { recursive: true });
  await mkdir(tracesDir, { recursive: true });

  const results: CaseResult[] = [];

  for (const caseItem of cases) {
    const command = resolveTargetCommand(caseItem.mode, config);
    const traceFile = resolveHarnessPath(tracesDir, `${safeCaseFileName(caseItem.id)}.json`);
    const env = {
      ...process.env,
      HARNESS_CASE_ID: caseItem.id,
      HARNESS_CASE_FILE: caseItem.sourceFile ?? "",
      HARNESS_CASE_INPUT: JSON.stringify(caseItem.input ?? {}),
      HARNESS_TRACE_FILE: traceFile,
      HARNESS_REPORTS_DIR: reportsDir,
      HARNESS_TRACES_DIR: tracesDir,
      HARNESS_REPO_ROOT: repoRoot,
    };

    const execution = await runCommand(command, env, rootDir);
    const failures = checkExpectations(caseItem, execution.stdout, execution.exitCode, traceFile);

    if (caseItem.expect.writesTrace) {
      try {
        await readFile(traceFile, "utf8");
      } catch {
        failures.push(`trace file not written: ${traceFile}`);
      }
    }

    results.push({
      id: caseItem.id,
      mode: caseItem.mode,
      tags: caseItem.tags,
      ok: failures.length === 0,
      exitCode: execution.exitCode,
      durationMs: execution.durationMs,
      stdout: execution.stdout,
      stderr: execution.stderr,
      traceFile: caseItem.expect.writesTrace ? traceFile : undefined,
      failures,
    });
  }

  const report: RunReport = {
    profile: config.profile,
    generatedAt: new Date().toISOString(),
    selectedTag,
    summary: {
      total: results.length,
      passed: results.filter((item) => item.ok).length,
      failed: results.filter((item) => !item.ok).length,
    },
    results,
  };

  await writeFile(resolveHarnessPath(reportsDir, "latest.json"), JSON.stringify(report, null, 2));
  await writeFile(resolveHarnessPath(reportsDir, "latest.md"), renderMarkdown(report));

  return report;
}
