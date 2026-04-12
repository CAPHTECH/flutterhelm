import { readFile } from "node:fs/promises";
import { bootstrapHarness } from "./bootstrap.js";
import { resolveHarnessPath } from "./config.js";
import { runHarness } from "./run.js";
import { validateHarness } from "./validate.js";

function parseTag(argv: string[]): string | undefined {
  const index = argv.indexOf("--tag");
  if (index >= 0) {
    return argv[index + 1];
  }
  return undefined;
}

async function main(): Promise<void> {
  const [command = "run", ...rest] = process.argv.slice(2);

  if (command === "validate") {
    const errors = await validateHarness(process.cwd());
    if (errors.length > 0) {
      console.error(errors.map((entry) => `- ${entry}`).join("\n"));
      process.exitCode = 1;
      return;
    }
    console.log("Harness validation passed.");
    return;
  }

  if (command === "bootstrap") {
    await bootstrapHarness(process.cwd());
    return;
  }

  if (command === "run") {
    const report = await runHarness(process.cwd(), parseTag(rest));
    console.log(`Harness run complete: ${report.summary.passed}/${report.summary.total} passed`);
    if (report.summary.failed > 0) {
      process.exitCode = 1;
    }
    return;
  }

  if (command === "report") {
    const report = await readFile(resolveHarnessPath(process.cwd(), "reports", "latest.md"), "utf8");
    process.stdout.write(report);
    return;
  }

  console.error(`Unknown command: ${command}`);
  process.exitCode = 1;
}

void main();
