import { readdir, readFile } from "node:fs/promises";
import { resolve } from "node:path";

export type HarnessProfile = "hybrid" | "software" | "agent-eval";
export type CaseMode = "software" | "agent-eval";

export interface HarnessCase {
  id: string;
  mode: CaseMode;
  tags: string[];
  input: Record<string, unknown>;
  expect: {
    exitCode?: number;
    stdoutIncludes?: string[];
    writesTrace?: boolean;
  };
  sourceFile?: string;
}

export interface HarnessConfig {
  profile: HarnessProfile;
  targets: {
    software?: { command: string };
    agentEval?: { command: string };
  };
  artifacts: {
    reportsDir: string;
    tracesDir: string;
  };
  matrix: {
    os: string[];
    node: string[];
  };
}

async function walkJsonFiles(dir: string): Promise<string[]> {
  const entries = await readdir(dir, { withFileTypes: true });
  const files = await Promise.all(
    entries.map(async (entry) => {
      const entryPath = resolve(dir, entry.name);
      if (entry.isDirectory()) {
        return walkJsonFiles(entryPath);
      }
      return entry.name.endsWith(".json") ? [entryPath] : [];
    }),
  );
  return files.flat();
}

export function resolveHarnessPath(rootDir: string, ...parts: string[]): string {
  return resolve(rootDir, ...parts);
}

export async function loadConfig(rootDir = process.cwd()): Promise<HarnessConfig> {
  const configPath = resolveHarnessPath(rootDir, "harness.config.json");
  return JSON.parse(await readFile(configPath, "utf8")) as HarnessConfig;
}

export async function discoverCases(rootDir = process.cwd()): Promise<HarnessCase[]> {
  const casesDir = resolveHarnessPath(rootDir, "cases");
  const files = await walkJsonFiles(casesDir);
  const parsed = await Promise.all(
    files.map(async (filePath) => {
      const value = JSON.parse(await readFile(filePath, "utf8")) as HarnessCase;
      value.sourceFile = filePath;
      return value;
    }),
  );
  return parsed.sort((left, right) => left.id.localeCompare(right.id));
}
