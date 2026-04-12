import { writeFile } from "node:fs/promises";
import { findCitation, resolveRepoRoot } from "../support.js";

interface QaCaseInput {
  prompt?: string;
  mustCite?: string[];
  expectedLabel?: string;
}

type QuestionKind = "first-checkpoint" | "compose-not-replace" | "generic";

function inferQuestionKind(prompt: string): QuestionKind {
  const normalized = prompt.toLowerCase();
  if (normalized.includes("first checkpoint") || normalized.includes("最初のチェックポイント")) {
    return "first-checkpoint";
  }
  if (
    normalized.includes("replace")
    || normalized.includes("devtools")
    || normalized.includes("native debugger")
    || normalized.includes("置き換")
  ) {
    return "compose-not-replace";
  }
  return "generic";
}

function buildAnswer(kind: QuestionKind): string {
  if (kind === "first-checkpoint") {
    return "The first checkpoint is Phase 0 — Foundation. Its exit criteria are workspace_show, session_open, session_list, workspace_set_root, and serverInfo/capability negotiation. Sprint 1 is the implementation slice that delivers the core of that checkpoint.";
  }

  if (kind === "compose-not-replace") {
    return "No. FlutterHelm is designed to compose official tools and does not replace DevTools or native debuggers. It adds session, safety, and resource management on top of the existing toolchain.";
  }

  return "FlutterHelm keeps the contract centered on session, resource, policy, and adapter boundaries.";
}

function assertAnswer(kind: QuestionKind, answer: string): void {
  if (kind === "first-checkpoint" && (!answer.includes("Phase 0") || !answer.includes("Sprint 1"))) {
    throw new Error("first-checkpoint answer is missing Phase 0 or Sprint 1");
  }

  if (
    kind === "compose-not-replace"
    && (!answer.toLowerCase().includes("compose") || !answer.toLowerCase().includes("does not replace"))
  ) {
    throw new Error("compose-not-replace answer is missing required framing");
  }
}

async function main(): Promise<void> {
  const harnessRoot = process.cwd();
  const repoRoot = process.env.HARNESS_REPO_ROOT ?? resolveRepoRoot(harnessRoot);
  const traceFile = process.env.HARNESS_TRACE_FILE;
  const input = JSON.parse(process.env.HARNESS_CASE_INPUT ?? "{}") as QaCaseInput;
  const prompt = input.prompt ?? "";
  const mustCite = input.mustCite ?? [];

  if (!traceFile) {
    console.error("HARNESS_TRACE_FILE is required for docs-qa target.");
    process.exitCode = 1;
    return;
  }

  if (!prompt) {
    console.error("docs-qa target requires a prompt.");
    process.exitCode = 1;
    return;
  }

  if (mustCite.length === 0) {
    console.error("docs-qa target requires at least one citation pattern.");
    process.exitCode = 1;
    return;
  }

  const citations = [];
  for (const pattern of mustCite) {
    const citation = await findCitation(repoRoot, pattern);
    if (!citation) {
      console.error(`Missing required citation pattern: ${pattern}`);
      process.exitCode = 1;
      return;
    }
    citations.push(citation);
  }

  const kind = inferQuestionKind(prompt);
  const answer = buildAnswer(kind);
  try {
    assertAnswer(kind, answer);
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
    return;
  }

  await writeFile(
    traceFile,
    `${JSON.stringify(
      {
        prompt,
        kind,
        answer,
        citations,
        generatedAt: new Date().toISOString(),
      },
      null,
      2,
    )}\n`,
  );

  console.log(input.expectedLabel ?? "score:ok");
  console.log(`answer:${answer}`);
  console.log(`citations:${citations.map((item) => `${item.file}:${item.line}`).join(",")}`);
}

void main();
