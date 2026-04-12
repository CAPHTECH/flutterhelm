import { pathExists, resolveDocsPython, runCommandInherit } from "./support.js";

function preferredPythonCommand(): string {
  return process.env.HARNESS_BOOTSTRAP_PYTHON ?? (process.platform === "win32" ? "python" : "python3");
}

export async function bootstrapHarness(rootDir = process.cwd()): Promise<void> {
  const venvPython = resolveDocsPython(rootDir);
  if (!(await pathExists(venvPython))) {
    await runCommandInherit(preferredPythonCommand(), ["-m", "venv", ".venv-docs"], rootDir);
  }

  await runCommandInherit(venvPython, ["-m", "pip", "install", "--upgrade", "pip"], rootDir);
  await runCommandInherit(venvPython, ["-m", "pip", "install", "-r", "requirements-docs.txt"], rootDir);

  console.log("Harness bootstrap complete.");
}
