import { spawn } from "node:child_process";
import { access, readFile, readdir } from "node:fs/promises";
import { constants } from "node:fs";
import { relative, resolve, sep } from "node:path";

export interface CommandResult {
  exitCode: number;
  stdout: string;
  stderr: string;
}

export interface Citation {
  pattern: string;
  file: string;
  line: number;
  snippet: string;
}

export interface MarkdownTableRow {
  [key: string]: string;
}

export async function pathExists(path: string): Promise<boolean> {
  try {
    await access(path, constants.F_OK);
    return true;
  } catch {
    return false;
  }
}

export function resolveRepoRoot(harnessRoot = process.cwd()): string {
  return resolve(harnessRoot, "..");
}

export function resolveDocsPython(harnessRoot = process.cwd()): string {
  if (process.platform === "win32") {
    return resolve(harnessRoot, ".venv-docs", "Scripts", "python.exe");
  }
  return resolve(harnessRoot, ".venv-docs", "bin", "python");
}

export async function runCommandCapture(
  command: string,
  args: string[],
  cwd: string,
  env: NodeJS.ProcessEnv = process.env,
): Promise<CommandResult> {
  return new Promise((resolveResult, reject) => {
    const child = spawn(command, args, {
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
      resolveResult({
        exitCode: code ?? 1,
        stdout: stdout.trim(),
        stderr: stderr.trim(),
      });
    });
  });
}

export async function runCommandInherit(
  command: string,
  args: string[],
  cwd: string,
  env: NodeJS.ProcessEnv = process.env,
): Promise<void> {
  await new Promise<void>((resolveResult, reject) => {
    const child = spawn(command, args, {
      cwd,
      env,
      stdio: "inherit",
    });

    child.on("error", reject);
    child.on("close", (code) => {
      if ((code ?? 1) !== 0) {
        reject(new Error(`Command failed: ${command} ${args.join(" ")}`));
        return;
      }
      resolveResult();
    });
  });
}

async function walkFiles(rootDir: string): Promise<string[]> {
  const entries = await readdir(rootDir, { withFileTypes: true });
  const nested = await Promise.all(
    entries.map(async (entry) => {
      const entryPath = resolve(rootDir, entry.name);
      if (entry.isDirectory()) {
        return walkFiles(entryPath);
      }
      return [entryPath];
    }),
  );
  return nested.flat();
}

export async function collectSourceFiles(repoRoot: string): Promise<string[]> {
  const docsRoot = resolve(repoRoot, "docs");
  const docFiles = await walkFiles(docsRoot);

  return [
    resolve(repoRoot, "README.md"),
    resolve(repoRoot, "mkdocs.yml"),
    ...docFiles,
  ].sort();
}

function lineNumberForIndex(text: string, index: number): number {
  return text.slice(0, index).split("\n").length;
}

function snippetForIndex(text: string, index: number): string {
  const lines = text.split("\n");
  const lineNumber = lineNumberForIndex(text, index);
  return lines[lineNumber - 1]?.trim() ?? "";
}

export async function findCitation(repoRoot: string, pattern: string): Promise<Citation | undefined> {
  const files = await collectSourceFiles(repoRoot);
  for (const file of files) {
    const text = await readFile(file, "utf8");
    const index = text.indexOf(pattern);
    if (index >= 0) {
      return {
        pattern,
        file: relative(repoRoot, file).split(sep).join("/"),
        line: lineNumberForIndex(text, index),
        snippet: snippetForIndex(text, index),
      };
    }
  }
  return undefined;
}

export async function readRepoText(repoRoot: string, relativePath: string): Promise<string> {
  return readFile(resolve(repoRoot, relativePath), "utf8");
}

function headingLevel(line: string): number | undefined {
  const match = /^(#+)\s+/.exec(line.trim());
  if (!match) {
    return undefined;
  }
  return match[1].length;
}

function splitMarkdownRow(line: string): string[] {
  return line
    .trim()
    .replace(/^\|/, "")
    .replace(/\|$/, "")
    .split("|")
    .map((cell) => cell.trim());
}

function isTableSeparator(line: string): boolean {
  if (!line.trim().startsWith("|")) {
    return false;
  }
  const cells = splitMarkdownRow(line);
  return cells.length > 0 && cells.every((cell) => /^:?-{3,}:?$/.test(cell));
}

function extractFirstFencedCodeBlock(section: string, language?: string): string {
  const lines = section.split("\n");
  let inBlock = false;
  let matchesLanguage = false;
  const block: string[] = [];

  for (const line of lines) {
    if (!inBlock && line.trim().startsWith("```")) {
      inBlock = true;
      matchesLanguage = language ? line.trim() === `\`\`\`${language}` : true;
      continue;
    }

    if (inBlock && line.trim() === "```") {
      if (matchesLanguage) {
        return block.join("\n").trim();
      }
      inBlock = false;
      matchesLanguage = false;
      block.length = 0;
      continue;
    }

    if (inBlock && matchesLanguage) {
      block.push(line);
    }
  }

  throw new Error(`No fenced code block found${language ? ` for language ${language}` : ""}`);
}

export function normalizeMarkdownValue(value: string): string {
  return value.replace(/`/g, "").trim();
}

export function extractSection(markdown: string, heading: string): string {
  const lines = markdown.split("\n");
  let startIndex = -1;
  let sectionLevel: number | undefined;

  for (let index = 0; index < lines.length; index += 1) {
    if (lines[index].trim() === heading.trim()) {
      startIndex = index + 1;
      sectionLevel = headingLevel(lines[index]);
      break;
    }
  }

  if (startIndex < 0 || sectionLevel === undefined) {
    throw new Error(`Heading not found: ${heading}`);
  }

  let endIndex = lines.length;
  for (let index = startIndex; index < lines.length; index += 1) {
    const nextLevel = headingLevel(lines[index]);
    if (nextLevel !== undefined && nextLevel <= sectionLevel) {
      endIndex = index;
      break;
    }
  }

  return lines.slice(startIndex, endIndex).join("\n").trim();
}

export function extractSectionBetweenHeadings(markdown: string, startHeading: string, endHeading: string): string {
  const lines = markdown.split("\n");
  let startIndex = -1;
  let endIndex = -1;

  for (let index = 0; index < lines.length; index += 1) {
    if (startIndex < 0 && lines[index].trim() === startHeading.trim()) {
      startIndex = index + 1;
      continue;
    }

    if (startIndex >= 0 && lines[index].trim() === endHeading.trim()) {
      endIndex = index;
      break;
    }
  }

  if (startIndex < 0) {
    throw new Error(`Heading not found: ${startHeading}`);
  }
  if (endIndex < 0) {
    throw new Error(`Heading not found: ${endHeading}`);
  }

  return lines.slice(startIndex, endIndex).join("\n").trim();
}

export function extractMarkdownTable(markdown: string, heading: string): MarkdownTableRow[] {
  const section = extractSection(markdown, heading);
  const lines = section.split("\n");
  const startIndex = lines.findIndex((line, index) => {
    return line.trim().startsWith("|") && index + 1 < lines.length && isTableSeparator(lines[index + 1]);
  });

  if (startIndex < 0) {
    throw new Error(`Markdown table not found under heading: ${heading}`);
  }

  const headers = splitMarkdownRow(lines[startIndex]);
  const rows: MarkdownTableRow[] = [];
  for (let index = startIndex + 2; index < lines.length; index += 1) {
    const line = lines[index].trim();
    if (!line.startsWith("|")) {
      break;
    }

    const cells = splitMarkdownRow(lines[index]);
    if (cells.length !== headers.length) {
      throw new Error(`Unexpected markdown table shape under heading: ${heading}`);
    }

    const row: MarkdownTableRow = {};
    for (let cellIndex = 0; cellIndex < headers.length; cellIndex += 1) {
      row[headers[cellIndex]] = cells[cellIndex];
    }
    rows.push(row);
  }

  return rows;
}

export function extractBulletItems(markdown: string, heading: string): string[] {
  const section = extractSection(markdown, heading);
  return section
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line.startsWith("- "))
    .map((line) => line.slice(2).trim());
}

export function extractInlineCodeTokens(markdown: string, heading: string): string[] {
  const section = extractSection(markdown, heading);
  const matches = [...section.matchAll(/`([^`]+)`/g)];
  return matches.map((match) => match[1]);
}

export function extractJsonCodeBlock<T>(markdown: string, heading: string): T {
  const section = extractSection(markdown, heading);
  const codeBlock = extractFirstFencedCodeBlock(section, "json");
  return JSON.parse(codeBlock) as T;
}
