import { spawn } from "node:child_process";
import { cp, mkdtemp, mkdir, readFile, realpath, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { createInterface } from "node:readline";
import { pathToFileURL } from "node:url";
import {
  extractBulletItems,
  extractJsonCodeBlock,
  extractMarkdownTable,
  extractSection,
  extractSectionBetweenHeadings,
  normalizeMarkdownValue,
  pathExists,
  readRepoText,
  resolveDocsPython,
  resolveRepoRoot,
  runCommandCapture,
} from "../support.js";

type CheckName =
  | "mkdocs-build"
  | "readme-nav-links"
  | "phase0-foundation"
  | "sprint1-minimum"
  | "core-principles"
  | "workflow-groups"
  | "tool-risk-catalog"
  | "approval-contract"
  | "safety-root-fallback"
  | "session-contract"
  | "resource-uri-contract"
  | "resource-metadata-retention"
  | "phase0-server-smoke"
  | "phase0-tool-exposure"
  | "phase0-root-session-flow"
  | "phase0-audit-log"
  | "phase1-tool-exposure"
  | "phase1-sample-app-flow"
  | "phase1-runtime-overflow-flow"
  | "phase3-profiling-flow"
  | "phase4-platform-bridge-flow"
  | "phase5-runtime-interaction-flow"
  | "phase6-hardening-docs"
  | "phase6-hardening-flow"
  | "phase6-ecosystem-docs"
  | "phase6-ecosystem-flow";

interface ContractCaseInput {
  checks?: CheckName[];
}

interface Phase0Fixture {
  sandboxDir: string;
  stateDir: string;
  workspaceRoot: string;
}

class Phase0HarnessClient {
  private readonly pending = new Map<string, { resolve: (value: Record<string, unknown>) => void; reject: (reason: unknown) => void }>();
  private readonly rootsEnabled: boolean;
  private nextRequestId = 1;
  private stderr = "";
  private closed = false;

  private constructor(
    private readonly child: ReturnType<typeof spawn>,
    private readonly clientRoots: string[],
  ) {
    this.rootsEnabled = clientRoots.length > 0;
    const lineReader = createInterface({ input: child.stdout! });
    lineReader.on("line", (line) => {
      void this.handleLine(line);
    });
    child.stderr?.on("data", (chunk) => {
      this.stderr += chunk.toString();
    });
    child.on("close", (code) => {
      this.closed = true;
      if (this.pending.size > 0) {
        const message = this.stderr.trim() || `FlutterHelm server exited with code ${code ?? 1}`;
        for (const entry of this.pending.values()) {
          entry.reject(new Error(message));
        }
        this.pending.clear();
      }
    });
  }

  static async start(
    repoRoot: string,
    stateDir: string,
    clientRoots: string[],
    options: { allowRootFallback?: boolean; configPath?: string; profile?: string } = {},
  ): Promise<Phase0HarnessClient> {
    const child = spawn(
      "mise",
      [
        "exec",
        "--",
        "dart",
        "run",
        "bin/flutterhelm.dart",
        "serve",
        "--state-dir",
        stateDir,
        ...(options.configPath ? ["--config", options.configPath] : []),
        ...(options.profile ? ["--profile", options.profile] : []),
        ...(options.allowRootFallback ? ["--allow-root-fallback"] : []),
      ],
      {
        cwd: repoRoot,
        env: process.env,
        stdio: ["pipe", "pipe", "pipe"],
      },
    );
    return new Phase0HarnessClient(child, clientRoots);
  }

  get stderrOutput(): string {
    return this.stderr.trim();
  }

  async initialize(): Promise<Record<string, unknown>> {
    const result = await this.request("initialize", {
      protocolVersion: "2025-06-18",
      capabilities: this.rootsEnabled ? { roots: { listChanged: true } } : {},
      clientInfo: {
        name: "flutterhelm-harness",
        version: "0.1.0",
      },
    });
    this.notify("notifications/initialized");
    return result;
  }

  async callTool(name: string, args: Record<string, unknown> = {}): Promise<Record<string, unknown>> {
    return this.request("tools/call", {
      name,
      arguments: args,
    });
  }

  async request(method: string, params: Record<string, unknown> = {}): Promise<Record<string, unknown>> {
    const id = `client-${this.nextRequestId++}`;
    const promise = new Promise<Record<string, unknown>>((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
    });
    this.send({
      jsonrpc: "2.0",
      id,
      method,
      params,
    });
    return promise;
  }

  notify(method: string, params: Record<string, unknown> = {}): void {
    this.send({
      jsonrpc: "2.0",
      method,
      ...(Object.keys(params).length > 0 ? { params } : {}),
    });
  }

  async close(): Promise<void> {
    if (this.closed) {
      return;
    }
    this.child.stdin?.end();
    await new Promise<void>((resolveClose) => {
      this.child.once("close", () => resolveClose());
      setTimeout(() => {
        if (!this.closed) {
          this.child.kill("SIGTERM");
        }
      }, 3000);
    });
  }

  private async handleLine(line: string): Promise<void> {
    const message = JSON.parse(line) as Record<string, unknown>;
    if (typeof message.method === "string") {
      if (message.method === "roots/list") {
        const id = String(message.id);
        this.send({
          jsonrpc: "2.0",
          id,
          result: {
            roots: this.clientRoots.map((root, index) => ({
              uri: pathToFileURL(root).toString(),
              name: index === 0 ? "workspace" : `workspace-${index}`,
            })),
          },
        });
      }
      return;
    }

    if (message.id === undefined) {
      return;
    }

    const id = String(message.id);
    const pending = this.pending.get(id);
    if (!pending) {
      return;
    }
    this.pending.delete(id);

    if (message.error) {
      pending.reject(new Error(JSON.stringify(message.error)));
      return;
    }

    pending.resolve((message.result ?? {}) as Record<string, unknown>);
  }

  private send(payload: Record<string, unknown>): void {
    this.child.stdin?.write(`${JSON.stringify(payload)}\n`);
  }
}

interface RawHttpHarnessResponse {
  statusCode: number;
  body: string;
  headers: Record<string, string>;
}

class HttpPreviewHarnessClient {
  private sessionId: string | null = null;
  private protocolVersion: string | null = null;
  private nextRequestId = 1;
  private closed = false;

  private constructor(
    private readonly child: ReturnType<typeof spawn>,
    private readonly endpoint: string,
  ) {}

  static async start(
    repoRoot: string,
    stateDir: string,
    options: { allowRootFallback?: boolean; configPath?: string; profile?: string } = {},
  ): Promise<HttpPreviewHarnessClient> {
    const child = spawn(
      "mise",
      [
        "exec",
        "--",
        "dart",
        "run",
        "bin/flutterhelm.dart",
        "serve",
        "--transport",
        "http",
        "--http-host",
        "127.0.0.1",
        "--http-port",
        "0",
        "--http-path",
        "/mcp",
        "--state-dir",
        stateDir,
        ...(options.configPath ? ["--config", options.configPath] : []),
        ...(options.profile ? ["--profile", options.profile] : []),
        ...(options.allowRootFallback ? ["--allow-root-fallback"] : []),
      ],
      {
        cwd: repoRoot,
        env: process.env,
        stdio: ["ignore", "ignore", "pipe"],
      },
    );

    let stderrLog = "";
    const endpoint = await new Promise<string>((resolveEndpoint, rejectEndpoint) => {
      const timeout = setTimeout(() => {
        rejectEndpoint(new Error(stderrLog.trim() || "Timed out waiting for HTTP preview endpoint."));
      }, 20000);
      const reader = createInterface({ input: child.stderr! });
      reader.on("line", (line) => {
        stderrLog += `${line}\n`;
        const marker = "HTTP preview listening on ";
        const index = line.indexOf(marker);
        if (index < 0) {
          return;
        }
        clearTimeout(timeout);
        resolveEndpoint(line.slice(index + marker.length).trim());
      });
      child.once("close", (code) => {
        clearTimeout(timeout);
        rejectEndpoint(
          new Error(stderrLog.trim() || `FlutterHelm HTTP preview exited with code ${code ?? 1}`),
        );
      });
    });

    return new HttpPreviewHarnessClient(child, endpoint);
  }

  async initialize(): Promise<Record<string, unknown>> {
    return this.request("initialize", {
      protocolVersion: "2025-06-18",
      capabilities: {},
      clientInfo: {
        name: "flutterhelm-harness-http",
        version: "0.1.0",
      },
    });
  }

  async request(method: string, params: Record<string, unknown> = {}): Promise<Record<string, unknown>> {
    const id = `http-${this.nextRequestId++}`;
    const raw = await this.rawRequest(method, params, { id });
    if (raw.statusCode !== 200) {
      throw new Error(`HTTP request failed with status ${raw.statusCode}: ${raw.body}`);
    }
    const decoded = JSON.parse(raw.body) as Record<string, unknown>;
    if (decoded.error) {
      throw new Error(JSON.stringify(decoded.error));
    }
    return requireObject(decoded.result, `${method}.result`);
  }

  async rawRequest(
    method: string,
    params: Record<string, unknown> = {},
    options: { id?: string } = {},
  ): Promise<RawHttpHarnessResponse> {
    const payload: Record<string, unknown> = {
      jsonrpc: "2.0",
      method,
      params,
    };
    if (options.id) {
      payload.id = options.id;
    }
    return this.send(payload);
  }

  async getStatusCode(): Promise<number> {
    const response = await fetch(this.endpoint, { method: "GET" });
    await response.text();
    return response.status;
  }

  async deleteSession(): Promise<number> {
    const headers: Record<string, string> = {};
    if (this.sessionId) {
      headers["MCP-Session-Id"] = this.sessionId;
    }
    const response = await fetch(this.endpoint, {
      method: "DELETE",
      headers,
    });
    await response.text();
    return response.status;
  }

  async close(): Promise<void> {
    if (this.closed) {
      return;
    }
    this.closed = true;
    this.child.kill("SIGTERM");
    await new Promise<void>((resolveClose) => {
      this.child.once("close", () => resolveClose());
      setTimeout(() => {
        if (!this.child.killed) {
          this.child.kill("SIGKILL");
        }
      }, 3000);
    });
  }

  private async send(payload: Record<string, unknown>): Promise<RawHttpHarnessResponse> {
    const headers: Record<string, string> = {
      "content-type": "application/json",
    };
    if (this.sessionId) {
      headers["MCP-Session-Id"] = this.sessionId;
    }
    if (this.protocolVersion) {
      headers["MCP-Protocol-Version"] = this.protocolVersion;
    }

    const response = await fetch(this.endpoint, {
      method: "POST",
      headers,
      body: JSON.stringify(payload),
    });
    const body = await response.text();
    const nextSessionId = response.headers.get("MCP-Session-Id");
    if (nextSessionId) {
      this.sessionId = nextSessionId;
    }
    if (payload.method === "initialize") {
      const params = requireObject(payload.params, "initialize.params");
      this.protocolVersion = requireString(params.protocolVersion, "initialize.params.protocolVersion");
    }
    const responseHeaders: Record<string, string> = {};
    response.headers.forEach((value, key) => {
      responseHeaders[key] = value;
    });
    return {
      statusCode: response.status,
      body,
      headers: responseHeaders,
    };
  }
}

async function createPhase0Fixture(): Promise<Phase0Fixture> {
  const sandboxDir = await mkdtemp(resolve(tmpdir(), "flutterhelm-phase0-"));
  const workspaceRoot = resolve(sandboxDir, "workspace");
  const stateDir = resolve(sandboxDir, "state");
  await mkdir(workspaceRoot, { recursive: true });
  await mkdir(stateDir, { recursive: true });
  await writeFile(
    resolve(workspaceRoot, "pubspec.yaml"),
    "name: sample_workspace\npublish_to: none\n",
  );
  return {
    sandboxDir,
    stateDir,
    workspaceRoot: await realpath(workspaceRoot),
  };
}

async function createSampleAppFixture(repoRoot: string): Promise<Phase0Fixture> {
  const sandboxDir = await mkdtemp(resolve(tmpdir(), "flutterhelm-phase1-"));
  const workspaceRoot = resolve(sandboxDir, "sample_app");
  const stateDir = resolve(sandboxDir, "state");
  const sourceRoot = resolve(repoRoot, "fixtures", "sample_app");

  await cp(sourceRoot, workspaceRoot, { recursive: true });
  await rm(resolve(workspaceRoot, ".dart_tool"), { recursive: true, force: true });
  await rm(resolve(workspaceRoot, "build"), { recursive: true, force: true });
  await mkdir(stateDir, { recursive: true });

  return {
    sandboxDir,
    stateDir,
    workspaceRoot: await realpath(workspaceRoot),
  };
}

function requireObject(value: unknown, label: string): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`Expected ${label} to be an object`);
  }
  return value as Record<string, unknown>;
}

function requireArray(value: unknown, label: string): unknown[] {
  if (!Array.isArray(value)) {
    throw new Error(`Expected ${label} to be an array`);
  }
  return value;
}

function requireString(value: unknown, label: string): string {
  if (typeof value !== "string" || value.length === 0) {
    throw new Error(`Expected ${label} to be a non-empty string`);
  }
  return value;
}

async function withPhase0Client<T>(
  repoRoot: string,
  clientRootsFactory: (fixture: Phase0Fixture) => string[],
  callback: (fixture: Phase0Fixture, client: Phase0HarnessClient) => Promise<T>,
): Promise<T> {
  const fixture = await createPhase0Fixture();
  const client = await Phase0HarnessClient.start(
    repoRoot,
    fixture.stateDir,
    clientRootsFactory(fixture),
  );
  try {
    return await callback(fixture, client);
  } finally {
    await client.close();
    await rm(fixture.sandboxDir, { recursive: true, force: true });
  }
}

async function withSampleAppClient<T>(
  repoRoot: string,
  callback: (fixture: Phase0Fixture, client: Phase0HarnessClient) => Promise<T>,
  options: { configText?: string; profile?: string } = {},
): Promise<T> {
  const fixture = await createSampleAppFixture(repoRoot);
  const pubGet = await runCommandCapture(
    "flutter",
    ["pub", "get"],
    fixture.workspaceRoot,
  );
  if (pubGet.exitCode !== 0) {
    await rm(fixture.sandboxDir, { recursive: true, force: true });
    throw new Error(pubGet.stderr || pubGet.stdout || "flutter pub get failed for sample app fixture");
  }

  let configPath: string | undefined;
  if (options.configText) {
    configPath = resolve(fixture.sandboxDir, "config.yaml");
    await writeFile(configPath, options.configText);
  }

  const client = await Phase0HarnessClient.start(
    repoRoot,
    fixture.stateDir,
    [fixture.workspaceRoot],
    { configPath, profile: options.profile },
  );
  try {
    return await callback(fixture, client);
  } finally {
    await client.close();
    await rm(fixture.sandboxDir, { recursive: true, force: true });
  }
}

function buildSampleAppConfig(
  fixture: Phase0Fixture,
  options: {
    enableRuntimeInteraction?: boolean;
    runtimeDriverEnabled?: boolean;
    runtimeDriverStartupTimeoutMs?: number;
  } = {},
): string {
  const workflows = [
    "workspace",
    "session",
    "launcher",
    "runtime_readonly",
    "tests",
    "profiling",
    "platform_bridge",
    ...(options.enableRuntimeInteraction ? ["runtime_interaction"] : []),
  ];
  const runtimeDriverEnabled = options.runtimeDriverEnabled ?? false;
  const runtimeDriverStartupTimeoutMs = options.runtimeDriverStartupTimeoutMs ?? 5000;
  return `version: 1
workspace:
  roots:
    - ${JSON.stringify(fixture.workspaceRoot)}
defaults:
  target: lib/main.dart
  mode: debug
enabledWorkflows:
${workflows.map((workflow) => `  - ${workflow}`).join("\n")}
fallbacks:
  allowRootFallback: false
retention:
  heavyArtifactsDays: 7
  metadataDays: 30
safety:
  confirmBefore:
    - dependency_add
    - dependency_remove
    - hot_restart
    - build_app:release
adapters:
  runtimeDriver:
    enabled: ${runtimeDriverEnabled ? "true" : "false"}
    startupTimeoutMs: ${runtimeDriverStartupTimeoutMs}
`;
}

async function checkPhase0ServerSmoke(repoRoot: string): Promise<void> {
  await withPhase0Client(repoRoot, () => [], async (_fixture, client) => {
    const initialize = await client.initialize();
    const serverInfo = requireObject(initialize.serverInfo, "initialize.serverInfo");
    const capabilities = requireObject(initialize.capabilities, "initialize.capabilities");

    if (initialize.protocolVersion !== "2025-06-18") {
      throw new Error(`Expected protocolVersion 2025-06-18, got ${String(initialize.protocolVersion)}`);
    }
    if (serverInfo.name !== "flutterhelm") {
      throw new Error(`Expected serverInfo.name to be flutterhelm, got ${String(serverInfo.name)}`);
    }
    if (!("tools" in capabilities) || !("resources" in capabilities)) {
      throw new Error("Initialize capabilities must include tools and resources");
    }

    const ping = await client.request("ping");
    if (Object.keys(ping).length > 0) {
      throw new Error(`Expected empty ping result, got ${JSON.stringify(ping)}`);
    }
  });
}

async function checkPhase0ToolExposure(repoRoot: string): Promise<void> {
  await withPhase0Client(repoRoot, () => [repoRoot], async (_fixture, client) => {
    const initialize = await client.initialize();
    const capabilities = requireObject(initialize.capabilities, "initialize.capabilities");
    const experimental = requireObject(capabilities.experimental, "capabilities.experimental");
    const workflowStatus = requireObject(experimental.workflowStatus, "workflowStatus");
    for (const [workflow, implemented] of [
      ["workspace", true],
      ["session", true],
      ["launcher", false],
      ["runtime_readonly", false],
      ["tests", false],
    ] as const) {
      const status = requireObject(workflowStatus[workflow], `workflowStatus.${workflow}`);
      if (status.implemented !== implemented) {
        throw new Error(`workflow ${workflow} implemented=${implemented} expected, got ${String(status.implemented)}`);
      }
    }

    const toolsList = await client.request("tools/list");
    const tools = requireArray(toolsList.tools, "tools/list.tools")
      .map((tool) => requireObject(tool, "tool"))
      .map((tool) => requireString(tool.name, "tool.name"))
      .sort();
    const expectedTools = [
      "adapter_list",
      "artifact_pin",
      "artifact_pin_list",
      "artifact_unpin",
      "compatibility_check",
      "session_list",
      "session_open",
      "workspace_set_root",
      "workspace_show",
    ];
    if (JSON.stringify(tools) !== JSON.stringify(expectedTools)) {
      throw new Error(`Unexpected Phase 0 tools exposure: ${JSON.stringify(tools)}`);
    }

    const resourcesList = await client.request("resources/list");
    const resources = requireArray(resourcesList.resources, "resources/list.resources")
      .map((resource) => requireObject(resource, "resource"))
      .map((resource) => requireString(resource.uri, "resource.uri"));
    for (const expected of [
      "config://workspace/current",
      "config://workspace/defaults",
      "config://artifacts/pins",
      "config://adapters/current",
      "config://compatibility/current",
    ]) {
      if (!resources.includes(expected)) {
        throw new Error(`resources/list is missing ${expected}`);
      }
    }
  });
}

async function checkPhase0RootSessionFlow(repoRoot: string): Promise<void> {
  await withPhase0Client(repoRoot, (fixture) => [fixture.workspaceRoot], async (fixture, client) => {
    await client.initialize();

    const workspaceShow = await client.callTool("workspace_show");
    const workspaceStructured = requireObject(workspaceShow.structuredContent, "workspace_show.structuredContent");
    if (workspaceStructured.rootsMode !== "roots-aware") {
      throw new Error(`Expected workspace_show rootsMode=roots-aware, got ${String(workspaceStructured.rootsMode)}`);
    }

    const rootResult = await client.callTool("workspace_set_root", {
      workspaceRoot: fixture.workspaceRoot,
    });
    const rootStructured = requireObject(rootResult.structuredContent, "workspace_set_root.structuredContent");
    const activeRoot = await realpath(requireString(rootStructured.activeRoot, "workspace_set_root.activeRoot"));
    if (activeRoot !== fixture.workspaceRoot) {
      throw new Error(`workspace_set_root returned unexpected activeRoot ${String(rootStructured.activeRoot)}`);
    }

    const opened = await client.callTool("session_open");
    const session = requireObject(opened.structuredContent, "session_open.structuredContent");
    const sessionId = requireString(session.sessionId, "session.sessionId");
    if (session.state !== "created") {
      throw new Error(`session_open returned unexpected state ${String(session.state)}`);
    }

    const listed = await client.callTool("session_list");
    const listedStructured = requireObject(listed.structuredContent, "session_list.structuredContent");
    const sessions = requireArray(listedStructured.sessions, "session_list.sessions")
      .map((value) => requireObject(value, "session summary"));
    if (!sessions.some((value) => value.sessionId === sessionId)) {
      throw new Error(`session_list did not include ${sessionId}`);
    }

    const resource = await client.request("resources/read", {
      uri: `session://${sessionId}/summary`,
    });
    const contents = requireArray(resource.contents, "resources/read.contents");
    const firstContent = requireObject(contents[0], "resources/read.contents[0]");
    const decoded = JSON.parse(requireString(firstContent.text, "resources/read text")) as Record<string, unknown>;
    if (decoded.sessionId !== sessionId) {
      throw new Error(`session summary resource returned ${String(decoded.sessionId)} instead of ${sessionId}`);
    }
    const sessionWorkspaceRoot = await realpath(requireString(decoded.workspaceRoot, "session.workspaceRoot"));
    if (sessionWorkspaceRoot !== fixture.workspaceRoot) {
      throw new Error(`session summary resource returned unexpected workspaceRoot ${String(decoded.workspaceRoot)}`);
    }
  });

  await withPhase0Client(repoRoot, () => [], async (fixture, client) => {
    await client.initialize();
    const result = await client.callTool("workspace_set_root", {
      workspaceRoot: fixture.workspaceRoot,
    });
    if (result.isError !== true) {
      throw new Error("workspace_set_root without roots support should return a tool error");
    }
    const error = requireObject(requireObject(result.structuredContent, "error result").error, "structured error");
    if (error.code !== "WORKSPACE_ROOT_REQUIRED") {
      throw new Error(`Expected WORKSPACE_ROOT_REQUIRED, got ${String(error.code)}`);
    }
  });

  const fallbackFixture = await createPhase0Fixture();
  const fallbackClient = await Phase0HarnessClient.start(
    repoRoot,
    fallbackFixture.stateDir,
    [],
    { allowRootFallback: true },
  );
  try {
    await fallbackClient.initialize();
    const approvalRequired = await fallbackClient.callTool("workspace_set_root", {
      workspaceRoot: fallbackFixture.workspaceRoot,
    });
    const structured = requireObject(
      approvalRequired.structuredContent,
      "workspace_set_root fallback structuredContent",
    );
    if (structured.status !== "approval_required") {
      throw new Error(`Expected approval_required in fallback mode, got ${String(structured.status)}`);
    }
    const approvalToken = requireString(
      structured.approvalRequestId,
      "workspace_set_root.approvalRequestId",
    );
    const approved = await fallbackClient.callTool("workspace_set_root", {
      workspaceRoot: fallbackFixture.workspaceRoot,
      approvalToken,
    });
    const approvedStructured = requireObject(
      approved.structuredContent,
      "workspace_set_root approved structuredContent",
    );
    if (await realpath(requireString(approvedStructured.activeRoot, "approved activeRoot")) !== fallbackFixture.workspaceRoot) {
      throw new Error("workspace_set_root with approval token did not set the active root");
    }
  } finally {
    await fallbackClient.close();
    await rm(fallbackFixture.sandboxDir, { recursive: true, force: true });
  }
}

async function checkPhase0AuditLog(repoRoot: string): Promise<void> {
  await withPhase0Client(repoRoot, (fixture) => [fixture.workspaceRoot], async (fixture, client) => {
    await client.initialize();
    await client.callTool("workspace_show");
    await client.callTool("workspace_set_root", {
      workspaceRoot: fixture.workspaceRoot,
    });
    const opened = await client.callTool("session_open");
    const session = requireObject(opened.structuredContent, "session_open.structuredContent");
    const sessionId = requireString(session.sessionId, "session.sessionId");
    await client.request("resources/read", {
      uri: `session://${sessionId}/summary`,
    });

    await client.close();
    const auditPath = resolve(fixture.stateDir, "audit.jsonl");
    const lines = (await readFile(auditPath, "utf8")).trim().split("\n").filter(Boolean);
    if (lines.length < 4) {
      throw new Error(`Expected audit log entries, found ${lines.length}`);
    }

    const events = lines.map((line) => JSON.parse(line) as Record<string, unknown>);
    const methods = events.map((event) => event.method);
    for (const method of ["initialize", "tools/call", "resources/read"]) {
      if (!methods.includes(method)) {
        throw new Error(`Audit log is missing method ${method}`);
      }
    }

    if (!events.some((event) => event.tool === "workspace_set_root" && event.riskClass === "bounded_mutation")) {
      throw new Error("Audit log is missing workspace_set_root bounded_mutation event");
    }
    if (!events.some((event) => event.tool === "session_open" && event.result === "success")) {
      throw new Error("Audit log is missing successful session_open event");
    }
  });
}

async function checkPhase1ToolExposure(repoRoot: string): Promise<void> {
  await withSampleAppClient(repoRoot, async (_fixture, client) => {
    const initialize = await client.initialize();
    const capabilities = requireObject(initialize.capabilities, "initialize.capabilities");
    const experimental = requireObject(capabilities.experimental, "capabilities.experimental");
    const workflowStatus = requireObject(experimental.workflowStatus, "workflowStatus");

    for (const [workflow, implemented] of [
      ["workspace", true],
      ["session", true],
      ["launcher", true],
      ["runtime_readonly", true],
      ["tests", true],
      ["runtime_interaction", true],
      ["profiling", true],
      ["platform_bridge", true],
    ] as const) {
      const status = requireObject(workflowStatus[workflow], `workflowStatus.${workflow}`);
      if (status.implemented !== implemented) {
        throw new Error(`workflow ${workflow} implemented=${implemented} expected, got ${String(status.implemented)}`);
      }
    }
    const profiling = requireObject(experimental.profiling, "capabilities.experimental.profiling");
    if (profiling.backend !== "vm_service" || profiling.ownershipPolicy !== "owned_only") {
      throw new Error(`Unexpected profiling capability metadata: ${JSON.stringify(profiling)}`);
    }
    const platformBridge = requireObject(experimental.platformBridge, "capabilities.experimental.platformBridge");
    if (
      platformBridge.mode !== "handoff_only"
      || platformBridge.ideAutomation !== false
      || platformBridge.defaultEnabled !== true
    ) {
      throw new Error(`Unexpected platform bridge capability metadata: ${JSON.stringify(platformBridge)}`);
    }
    const supportedPlatforms = requireArray(platformBridge.supportedPlatforms, "platformBridge.supportedPlatforms");
    for (const platform of ["ios", "android"]) {
      if (!supportedPlatforms.includes(platform)) {
        throw new Error(`platformBridge.supportedPlatforms is missing ${platform}`);
      }
    }
    const runtimeInteraction = requireObject(
      experimental.runtimeInteraction,
      "capabilities.experimental.runtimeInteraction",
    );
    if (
      runtimeInteraction.defaultEnabled !== false
      || runtimeInteraction.uiBackend !== "external_adapter"
      || runtimeInteraction.hotOpBackend !== "flutter_daemon"
      || runtimeInteraction.screenshotWorkflow !== "runtime_readonly"
      || runtimeInteraction.hotOpsOwnershipPolicy !== "owned_only"
    ) {
      throw new Error(`Unexpected runtime interaction capability metadata: ${JSON.stringify(runtimeInteraction)}`);
    }
    const hardening = requireObject(
      experimental.hardening,
      "capabilities.experimental.hardening",
    );
    if (
      hardening.busyPolicy !== "fail_fast"
      || hardening.pinnedArtifacts !== true
      || hardening.configProfiles !== true
      || hardening.compatibilityResource !== "config://compatibility/current"
    ) {
      throw new Error(`Unexpected hardening capability metadata: ${JSON.stringify(hardening)}`);
    }
    const httpPreview = requireObject(
      experimental.httpPreview,
      "capabilities.experimental.httpPreview",
    );
    if (
      httpPreview.mode !== "preview"
      || httpPreview.localhostOnly !== true
      || httpPreview.rootsSupport !== "unsupported"
      || httpPreview.sse !== false
      || httpPreview.resumability !== false
      || httpPreview.activeTransport !== "stdio"
    ) {
      throw new Error(`Unexpected HTTP preview capability metadata: ${JSON.stringify(httpPreview)}`);
    }
    const adapterRegistry = requireObject(
      experimental.adapterRegistry,
      "capabilities.experimental.adapterRegistry",
    );
    const adapterFamilies = requireArray(
      adapterRegistry.families,
      "capabilities.experimental.adapterRegistry.families",
    );
    for (const family of ["delegate", "flutterCli", "profiling", "runtimeDriver", "platformBridge"]) {
      if (!adapterFamilies.includes(family)) {
        throw new Error(`adapterRegistry.families is missing ${family}`);
      }
    }
    const customProviderKinds = requireArray(
      adapterRegistry.customProviderKinds,
      "capabilities.experimental.adapterRegistry.customProviderKinds",
    );
    if (!customProviderKinds.includes("stdio_json") || adapterRegistry.legacyConfigShim !== true) {
      throw new Error(`Unexpected adapter registry capability metadata: ${JSON.stringify(adapterRegistry)}`);
    }

    const toolsList = await client.request("tools/list");
    const tools = requireArray(toolsList.tools, "tools/list.tools")
      .map((tool) => requireObject(tool, "tool"))
      .map((tool) => requireString(tool.name, "tool.name"))
      .sort();
    const expectedTools = [
      "analyze_project",
      "attach_app",
      "adapter_list",
      "artifact_pin",
      "artifact_pin_list",
      "artifact_unpin",
      "capture_screenshot",
      "capture_memory_snapshot",
      "capture_timeline",
      "collect_coverage",
      "compatibility_check",
      "dependency_add",
      "dependency_remove",
      "device_list",
      "android_debug_context",
      "format_files",
      "get_app_state_summary",
      "get_logs",
      "get_runtime_errors",
      "get_test_results",
      "get_widget_tree",
      "ios_debug_context",
      "native_handoff_summary",
      "pub_search",
      "resolve_symbol",
      "run_app",
      "run_integration_tests",
      "run_unit_tests",
      "run_widget_tests",
      "session_list",
      "session_open",
      "start_cpu_profile",
      "stop_app",
      "stop_cpu_profile",
      "toggle_performance_overlay",
      "workspace_discover",
      "workspace_set_root",
      "workspace_show",
    ].sort();
    if (JSON.stringify(tools) !== JSON.stringify(expectedTools)) {
      throw new Error(`Unexpected Phase 1 tools exposure: ${JSON.stringify(tools)}`);
    }
  });
}

async function checkPhase1SampleAppFlow(repoRoot: string): Promise<void> {
  await withSampleAppClient(repoRoot, async (fixture, client) => {
    await client.initialize();

    const discovered = await client.callTool("workspace_discover");
    const discoveredStructured = requireObject(discovered.structuredContent, "workspace_discover.structuredContent");
    const workspaces = requireArray(discoveredStructured.workspaces, "workspace_discover.workspaces")
      .map((value) => requireObject(value, "workspace entry"));
    if (!workspaces.some((workspace) => requireString(workspace.workspaceRoot, "workspace.workspaceRoot") === fixture.workspaceRoot)) {
      throw new Error("workspace_discover did not return the sample app fixture");
    }

    await client.callTool("workspace_set_root", {
      workspaceRoot: fixture.workspaceRoot,
    });

    const analysis = await client.callTool("analyze_project");
    const analysisStructured = requireObject(analysis.structuredContent, "analyze_project.structuredContent");
    if (analysisStructured.exitCode !== 0) {
      throw new Error(`analyze_project failed: ${String(analysisStructured.stderr || analysisStructured.stdout || analysisStructured.exitCode)}`);
    }

    const resolution = await client.callTool("resolve_symbol", { symbol: "SampleApp" });
    const resolutionStructured = requireObject(resolution.structuredContent, "resolve_symbol.structuredContent");
    const matches = requireArray(resolutionStructured.matches, "resolve_symbol.matches")
      .map((value) => requireObject(value, "resolve_symbol match"));
    if (!matches.some((match) => requireString(match.path, "resolve_symbol.path").endsWith("/lib/app.dart"))) {
      throw new Error("resolve_symbol did not resolve SampleApp in lib/app.dart");
    }

    const formatTarget = resolve(fixture.workspaceRoot, "lib", "format_me.dart");
    await writeFile(formatTarget, "void main( ){print('x');}\n");
    const formatted = await client.callTool("format_files", {
      paths: ["lib/format_me.dart"],
    });
    const formattedStructured = requireObject(formatted.structuredContent, "format_files.structuredContent");
    if (formattedStructured.exitCode !== 0) {
      throw new Error(`format_files failed: ${String(formattedStructured.stderr || formattedStructured.stdout || formattedStructured.exitCode)}`);
    }
    const formattedText = await readFile(formatTarget, "utf8");
    if (!formattedText.includes("void main() {\n  print('x');\n}\n")) {
      throw new Error(`format_files did not rewrite lib/format_me.dart as expected: ${formattedText}`);
    }

    const pubSearch = await client.callTool("pub_search", {
      query: "async",
      limit: 3,
    });
    const pubStructured = requireObject(pubSearch.structuredContent, "pub_search.structuredContent");
    const packages = requireArray(pubStructured.packages, "pub_search.packages");
    if (packages.length === 0) {
      throw new Error("pub_search did not return any package candidates");
    }

    const addApproval = await client.callTool("dependency_add", {
      package: "async",
    });
    const addApprovalStructured = requireObject(addApproval.structuredContent, "dependency_add approval structuredContent");
    if (addApprovalStructured.status !== "approval_required") {
      throw new Error(`dependency_add should require approval, got ${JSON.stringify(addApprovalStructured)}`);
    }
    const addApproved = await client.callTool("dependency_add", {
      package: "async",
      approvalToken: requireString(addApprovalStructured.approvalRequestId, "dependency_add.approvalRequestId"),
    });
    const addStructured = requireObject(addApproved.structuredContent, "dependency_add.structuredContent");
    if (addStructured.status !== "completed") {
      throw new Error(`dependency_add failed: ${JSON.stringify(addStructured)}`);
    }

    const removeApproval = await client.callTool("dependency_remove", {
      package: "async",
    });
    const removeApprovalStructured = requireObject(removeApproval.structuredContent, "dependency_remove approval structuredContent");
    if (removeApprovalStructured.status !== "approval_required") {
      throw new Error(`dependency_remove should require approval, got ${JSON.stringify(removeApprovalStructured)}`);
    }
    const removeApproved = await client.callTool("dependency_remove", {
      package: "async",
      approvalToken: requireString(removeApprovalStructured.approvalRequestId, "dependency_remove.approvalRequestId"),
    });
    const removeStructured = requireObject(removeApproved.structuredContent, "dependency_remove.structuredContent");
    if (removeStructured.status !== "completed") {
      throw new Error(`dependency_remove failed: ${JSON.stringify(removeStructured)}`);
    }

    const unitTests = await client.callTool("run_unit_tests", {
      coverage: true,
    });
    const unitStructured = requireObject(unitTests.structuredContent, "run_unit_tests.structuredContent");
    const unitRunId = requireString(unitStructured.runId, "run_unit_tests.runId");
    const unitSummary = requireObject(unitStructured.summary, "run_unit_tests.summary");
    if (unitSummary.failed !== 0) {
      throw new Error(`run_unit_tests reported failures: ${JSON.stringify(unitSummary)}`);
    }

    const widgetTests = await client.callTool("run_widget_tests", {
      coverage: true,
    });
    const widgetStructured = requireObject(widgetTests.structuredContent, "run_widget_tests.structuredContent");
    const widgetRunId = requireString(widgetStructured.runId, "run_widget_tests.runId");
    const widgetSummary = requireObject(widgetStructured.summary, "run_widget_tests.summary");
    if (widgetSummary.failed !== 0) {
      throw new Error(`run_widget_tests reported failures: ${JSON.stringify(widgetSummary)}`);
    }

    const testResults = await client.callTool("get_test_results", {
      runId: unitRunId,
    });
    const testResultsStructured = requireObject(testResults.structuredContent, "get_test_results.structuredContent");
    if (testResultsStructured.runId !== unitRunId) {
      throw new Error(`get_test_results returned ${String(testResultsStructured.runId)} instead of ${unitRunId}`);
    }

    const coverage = await client.callTool("collect_coverage", {
      runId: unitRunId,
    });
    const coverageStructured = requireObject(coverage.structuredContent, "collect_coverage.structuredContent");
    const coverageSummary = requireObject(coverageStructured.summary, "collect_coverage.summary");
    if (typeof coverageSummary.lineCoveragePercent !== "number") {
      throw new Error(`collect_coverage returned malformed summary: ${JSON.stringify(coverageSummary)}`);
    }

    const resources = await client.request("resources/list");
    const uris = requireArray(resources.resources, "resources/list.resources")
      .map((value) => requireObject(value, "resource"))
      .map((value) => requireString(value.uri, "resource.uri"));
    for (const expected of [
      `test-report://${unitRunId}/summary`,
      `test-report://${unitRunId}/details`,
      `coverage://${unitRunId}/summary`,
      `coverage://${unitRunId}/lcov`,
      `test-report://${widgetRunId}/summary`,
      `test-report://${widgetRunId}/details`,
      `coverage://${widgetRunId}/summary`,
      `coverage://${widgetRunId}/lcov`,
    ]) {
      if (!uris.includes(expected)) {
        throw new Error(`resources/list is missing ${expected}`);
      }
    }

    const summaryResource = await client.request("resources/read", {
      uri: `test-report://${unitRunId}/summary`,
    });
    const summaryContents = requireArray(summaryResource.contents, "unit summary contents");
    const summaryBody = requireObject(summaryContents[0], "unit summary content");
    const decoded = JSON.parse(requireString(summaryBody.text, "unit summary text")) as Record<string, unknown>;
    if (decoded.runId !== unitRunId) {
      throw new Error(`unit test summary returned ${String(decoded.runId)} instead of ${unitRunId}`);
    }

    const coverageResource = await client.request("resources/read", {
      uri: `coverage://${unitRunId}/summary`,
    });
    const coverageContents = requireArray(coverageResource.contents, "coverage summary contents");
    const coverageBody = requireObject(coverageContents[0], "coverage summary content");
    const coverageDecoded = JSON.parse(requireString(coverageBody.text, "coverage summary text")) as Record<string, unknown>;
    if (coverageDecoded.runId !== unitRunId) {
      throw new Error(`coverage summary returned ${String(coverageDecoded.runId)} instead of ${unitRunId}`);
    }

    const auditPath = resolve(fixture.stateDir, "audit.jsonl");
    const auditLines = (await readFile(auditPath, "utf8")).trim().split("\n").filter(Boolean);
    const approvalEvents = auditLines
      .map((line) => JSON.parse(line) as Record<string, unknown>)
      .filter((event) => event.tool === "dependency_add" || event.tool === "dependency_remove");
    if (!approvalEvents.some((event) => event.result === "approval_required")) {
      throw new Error("audit log is missing dependency approval_required events");
    }
    if (!approvalEvents.some((event) => event.result === "approved")) {
      throw new Error("audit log is missing dependency approved events");
    }
  });
}

async function checkPhase1RuntimeOverflowFlow(repoRoot: string): Promise<void> {
  await withSampleAppClient(repoRoot, async (fixture, client) => {
    await client.initialize();
    await client.callTool("workspace_set_root", {
      workspaceRoot: fixture.workspaceRoot,
    });

    const devicesResult = await client.callTool("device_list");
    const devicesStructured = requireObject(devicesResult.structuredContent, "device_list.structuredContent");
    const devices = requireArray(devicesStructured.devices, "device_list.devices")
      .map((value) => requireObject(value, "device entry"));
    const iosDevice = devices.find((device) => device.platform === "ios" && device.availability === "available");
    if (!iosDevice) {
      throw new Error("device_list did not return an available iOS simulator/device");
    }

    const contextSession = await client.callTool("session_open", {
      target: "lib/main.dart",
      mode: "debug",
    });
    const contextStructured = requireObject(contextSession.structuredContent, "session_open.structuredContent");
    const contextSessionId = requireString(contextStructured.sessionId, "session_open.sessionId");

    let ownedSessionId: string | null = null;
    try {
      const running = await client.callTool("run_app", {
        sessionId: contextSessionId,
        platform: "ios",
        dartDefines: ["FLUTTERHELM_SCENARIO=overflow"],
      });
      if (running.isError === true) {
        const error = requireObject(requireObject(running.structuredContent, "run_app error").error, "run_app structured error");
        throw new Error(`run_app failed: ${String(error.code)}: ${String(error.message)}`);
      }
      const runningStructured = requireObject(running.structuredContent, "run_app.structuredContent");
      ownedSessionId = requireString(runningStructured.sessionId, "run_app.sessionId");
      if (runningStructured.state !== "running") {
        throw new Error(`run_app returned unexpected state ${String(runningStructured.state)}`);
      }

      let runtimeErrors: Record<string, unknown> | null = null;
      for (let attempt = 0; attempt < 15; attempt += 1) {
        runtimeErrors = await client.callTool("get_runtime_errors", {
          sessionId: ownedSessionId,
        });
        const structured = requireObject(runtimeErrors.structuredContent, "get_runtime_errors.structuredContent");
        if ((structured.count as number) > 0) {
          const errors = requireArray(structured.errors, "get_runtime_errors.errors")
            .map((value) => requireObject(value, "runtime error"));
          if (!errors.some((error) => requireString(error.summary, "runtime error summary").includes("RenderFlex overflowed"))) {
            throw new Error(`get_runtime_errors found errors, but not the expected overflow: ${JSON.stringify(errors)}`);
          }
          break;
        }
        await new Promise((resolveDelay) => setTimeout(resolveDelay, 1000));
      }
      if (runtimeErrors == null) {
        throw new Error("get_runtime_errors did not produce a result");
      }
      const runtimeStructured = requireObject(runtimeErrors.structuredContent, "get_runtime_errors.structuredContent");
      if ((runtimeStructured.count as number) <= 0) {
        throw new Error("Expected overflow scenario to produce at least one runtime error");
      }

      const widgetTree = await client.callTool("get_widget_tree", {
        sessionId: ownedSessionId,
        depth: 2,
      });
      const widgetStructured = requireObject(widgetTree.structuredContent, "get_widget_tree.structuredContent");
      const widgetResource = requireObject(widgetStructured.resource, "get_widget_tree.resource");
      const widgetUri = requireString(widgetResource.uri, "get_widget_tree.resource.uri");
      const widgetResourceResult = await client.request("resources/read", {
        uri: widgetUri,
      });
      const widgetContents = requireArray(widgetResourceResult.contents, "widget tree contents");
      const widgetBody = requireObject(widgetContents[0], "widget tree content");
      const widgetPayload = JSON.parse(requireString(widgetBody.text, "widget tree text")) as Record<string, unknown>;
      if (widgetPayload.sessionId !== ownedSessionId) {
        throw new Error(`widget tree resource returned ${String(widgetPayload.sessionId)} instead of ${ownedSessionId}`);
      }

      const attached = await client.callTool("attach_app", {
        sessionId: ownedSessionId,
        platform: "ios",
      });
      const attachedStructured = requireObject(attached.structuredContent, "attach_app.structuredContent");
      const attachedSessionId = requireString(attachedStructured.sessionId, "attach_app.sessionId");
      if (attachedStructured.ownership !== "attached") {
        throw new Error(`attach_app returned unexpected ownership ${String(attachedStructured.ownership)}`);
      }

      const attachedStop = await client.callTool("stop_app", {
        sessionId: attachedSessionId,
      });
      if (attachedStop.isError !== true) {
        throw new Error("stop_app should reject attached sessions");
      }
      const attachedError = requireObject(requireObject(attachedStop.structuredContent, "attached stop error").error, "attached stop structured error");
      if (attachedError.code !== "ATTACHED_SESSION_STOP_FORBIDDEN") {
        throw new Error(`Expected ATTACHED_SESSION_STOP_FORBIDDEN, got ${String(attachedError.code)}`);
      }
    } finally {
      if (ownedSessionId != null) {
        await client.callTool("stop_app", {
          sessionId: ownedSessionId,
        });
      }
    }

    const integration = await client.callTool("run_integration_tests", {
      platform: "ios",
      target: "integration_test/app_test.dart",
    });
    const integrationStructured = requireObject(
      integration.structuredContent,
      "run_integration_tests.structuredContent",
    );
    const integrationRunId = requireString(
      integrationStructured.runId,
      "run_integration_tests.runId",
    );
    if (integrationStructured.status !== "completed") {
      throw new Error(`run_integration_tests failed: ${JSON.stringify(integrationStructured)}`);
    }

    const integrationResults = await client.callTool("get_test_results", {
      runId: integrationRunId,
    });
    const integrationResultsStructured = requireObject(
      integrationResults.structuredContent,
      "get_test_results integration structuredContent",
    );
    if (integrationResultsStructured.runId !== integrationRunId) {
      throw new Error(`get_test_results returned ${String(integrationResultsStructured.runId)} instead of ${integrationRunId}`);
    }

    const resources = await client.request("resources/list");
    const uris = requireArray(resources.resources, "resources/list.resources")
      .map((value) => requireObject(value, "resource"))
      .map((value) => requireString(value.uri, "resource.uri"));
    if (!uris.includes(`test-report://${integrationRunId}/summary`)) {
      throw new Error(`resources/list is missing integration test summary for ${integrationRunId}`);
    }
  });
}

async function checkPhase3ProfilingFlow(repoRoot: string): Promise<void> {
  await withSampleAppClient(repoRoot, async (fixture, client) => {
    await client.initialize();
    await client.callTool("workspace_set_root", {
      workspaceRoot: fixture.workspaceRoot,
    });

    const running = await client.callTool("run_app", {
      platform: "ios",
      mode: "debug",
      dartDefines: ["FLUTTERHELM_SCENARIO=profile_demo"],
    });
    if (running.isError === true) {
      const error = requireObject(requireObject(running.structuredContent, "run_app error").error, "run_app structured error");
      throw new Error(`run_app failed: ${String(error.code)}: ${String(error.message)}`);
    }
    const runningStructured = requireObject(running.structuredContent, "run_app.structuredContent");
    const sessionId = requireString(runningStructured.sessionId, "run_app.sessionId");
    if (runningStructured.mode !== "debug") {
      throw new Error(`Expected debug mode session for local iOS profiling, got ${String(runningStructured.mode)}`);
    }

    try {
      const healthResource = await client.request("resources/read", {
        uri: `session://${sessionId}/health`,
      });
      const healthContents = requireArray(healthResource.contents, "session health contents");
      const healthBody = requireObject(healthContents[0], "session health content");
      const health = JSON.parse(requireString(healthBody.text, "session health text")) as Record<string, unknown>;
      if (health.ready !== true) {
        throw new Error(`session health should be ready for profiling session: ${JSON.stringify(health)}`);
      }
      if (health.recommendedMode !== "profile") {
        throw new Error(`session health should recommend profile mode, got ${JSON.stringify(health)}`);
      }

      const startCpu = await client.callTool("start_cpu_profile", {
        sessionId,
      });
      if (startCpu.isError === true) {
        throw new Error(`start_cpu_profile failed: ${JSON.stringify(startCpu.structuredContent)}`);
      }
      await new Promise((resolveDelay) => setTimeout(resolveDelay, 2000));

      const stopCpu = await client.callTool("stop_cpu_profile", {
        sessionId,
      });
      const stopCpuStructured = requireObject(stopCpu.structuredContent, "stop_cpu_profile.structuredContent");
      const cpuResource = requireObject(stopCpuStructured.resource, "stop_cpu_profile.resource");
      const cpuUri = requireString(cpuResource.uri, "stop_cpu_profile.resource.uri");
      const cpuResult = await client.request("resources/read", { uri: cpuUri });
      const cpuContents = requireArray(cpuResult.contents, "cpu resource contents");
      const cpuBody = requireObject(cpuContents[0], "cpu resource content");
      const cpuPayload = JSON.parse(requireString(cpuBody.text, "cpu resource text")) as Record<string, unknown>;
      const cpuSummary = requireObject(cpuPayload.summary, "cpu summary");
      if (Number(cpuSummary.sampleCount ?? 0) <= 0) {
        throw new Error(`CPU profile should contain samples: ${JSON.stringify(cpuSummary)}`);
      }

      const timeline = await client.callTool("capture_timeline", {
        sessionId,
        durationMs: 1000,
      });
      const timelineStructured = requireObject(timeline.structuredContent, "capture_timeline.structuredContent");
      const timelineResource = requireObject(timelineStructured.resource, "capture_timeline.resource");
      const timelineUri = requireString(timelineResource.uri, "capture_timeline.resource.uri");
      const timelineResult = await client.request("resources/read", { uri: timelineUri });
      const timelineContents = requireArray(timelineResult.contents, "timeline resource contents");
      const timelineBody = requireObject(timelineContents[0], "timeline resource content");
      const timelinePayload = JSON.parse(requireString(timelineBody.text, "timeline resource text")) as Record<string, unknown>;
      const timelineSummary = requireObject(timelinePayload.summary, "timeline summary");
      if (Number(timelineSummary.eventCount ?? 0) <= 0) {
        throw new Error(`Timeline capture should contain events: ${JSON.stringify(timelineSummary)}`);
      }

      const memory = await client.callTool("capture_memory_snapshot", {
        sessionId,
        gc: true,
      });
      const memoryStructured = requireObject(memory.structuredContent, "capture_memory_snapshot.structuredContent");
      const memoryResource = requireObject(memoryStructured.resource, "capture_memory_snapshot.resource");
      const memoryUri = requireString(memoryResource.uri, "capture_memory_snapshot.resource.uri");
      const memoryResult = await client.request("resources/read", { uri: memoryUri });
      const memoryContents = requireArray(memoryResult.contents, "memory resource contents");
      const memoryBody = requireObject(memoryContents[0], "memory resource content");
      const memoryPayload = JSON.parse(requireString(memoryBody.text, "memory resource text")) as Record<string, unknown>;
      const memorySummary = requireObject(memoryPayload.summary, "memory summary");
      if (Number(memorySummary.heapSnapshotBytes ?? 0) <= 0) {
        throw new Error(`Memory snapshot should contain heap data: ${JSON.stringify(memorySummary)}`);
      }

      const overlay = await client.callTool("toggle_performance_overlay", {
        sessionId,
        enabled: true,
      });
      if (overlay.isError === true) {
        throw new Error(`toggle_performance_overlay failed: ${JSON.stringify(overlay.structuredContent)}`);
      }

      const attached = await client.callTool("attach_app", {
        sessionId,
        platform: "ios",
        mode: "debug",
      });
      const attachedStructured = requireObject(attached.structuredContent, "attach_app.structuredContent");
      const attachedSessionId = requireString(attachedStructured.sessionId, "attach_app.sessionId");
      const attachedTimeline = await client.callTool("capture_timeline", {
        sessionId: attachedSessionId,
        durationMs: 250,
      });
      if (attachedTimeline.isError !== true) {
        throw new Error("capture_timeline should reject attached sessions");
      }
      const attachedError = requireObject(
        requireObject(attachedTimeline.structuredContent, "attached profiling error").error,
        "attached profiling structured error",
      );
      if (attachedError.code !== "PROFILE_OWNERSHIP_REQUIRED") {
        throw new Error(`Expected PROFILE_OWNERSHIP_REQUIRED, got ${String(attachedError.code)}`);
      }
      const detailsResource = requireObject(attachedError.detailsResource, "attached profiling detailsResource");
      if (detailsResource.uri !== `session://${attachedSessionId}/health`) {
        throw new Error(`attached profiling failure should point to session health, got ${String(detailsResource.uri)}`);
      }
    } finally {
      await client.callTool("stop_app", {
        sessionId,
      });
    }
  });
}

async function checkPhase4PlatformBridgeFlow(repoRoot: string): Promise<void> {
  await withSampleAppClient(repoRoot, async (fixture, client) => {
    await client.initialize();
    await client.callTool("workspace_set_root", {
      workspaceRoot: fixture.workspaceRoot,
    });

    const running = await client.callTool("run_app", {
      platform: "ios",
      mode: "debug",
    });
    if (running.isError === true) {
      const error = requireObject(requireObject(running.structuredContent, "run_app error").error, "run_app structured error");
      throw new Error(`run_app failed: ${String(error.code)}: ${String(error.message)}`);
    }

    const runningStructured = requireObject(running.structuredContent, "run_app.structuredContent");
    const sessionId = requireString(runningStructured.sessionId, "run_app.sessionId");

    try {
      const iosContext = await client.callTool("ios_debug_context", {
        sessionId,
        tailLines: 120,
      });
      if (iosContext.isError === true) {
        throw new Error(`ios_debug_context failed: ${JSON.stringify(iosContext.structuredContent)}`);
      }
      const iosStructured = requireObject(iosContext.structuredContent, "ios_debug_context.structuredContent");
      if (iosStructured.status !== "ready") {
        throw new Error(`ios_debug_context returned unexpected status: ${JSON.stringify(iosStructured)}`);
      }

      const bundleResource = requireObject(iosStructured.resource, "ios_debug_context.resource");
      const bundleUri = requireString(bundleResource.uri, "ios_debug_context.resource.uri");
      if (bundleUri !== `native-handoff://${sessionId}/ios`) {
        throw new Error(`ios_debug_context returned unexpected resource uri ${bundleUri}`);
      }

      const bundleRead = await client.request("resources/read", { uri: bundleUri });
      const bundleContents = requireArray(bundleRead.contents, "native handoff contents");
      const bundleBody = requireObject(bundleContents[0], "native handoff content");
      const bundle = JSON.parse(requireString(bundleBody.text, "native handoff text")) as Record<string, unknown>;
      if (bundle.status !== "ready") {
        throw new Error(`iOS native handoff bundle should be ready: ${JSON.stringify(bundle)}`);
      }
      const openPaths = requireArray(bundle.openPaths, "bundle.openPaths")
        .map((value) => requireObject(value, "bundle open path"));
      if (!openPaths.some((value) => requireString(value.path, "open path").endsWith("/ios/Runner.xcworkspace"))) {
        throw new Error(`iOS native handoff bundle is missing Runner.xcworkspace: ${JSON.stringify(openPaths)}`);
      }
      const evidenceResources = requireArray(bundle.evidenceResources, "bundle.evidenceResources")
        .map((value) => requireObject(value, "bundle evidence"));
      const evidenceUris = evidenceResources.map((value) => requireString(value.uri, "bundle evidence uri"));
      for (const expected of [`session://${sessionId}/summary`, `session://${sessionId}/health`]) {
        if (!evidenceUris.includes(expected)) {
          throw new Error(`iOS native handoff bundle is missing evidence resource ${expected}`);
        }
      }
      const limitations = requireArray(bundle.limitations, "bundle.limitations")
        .map((value) => requireString(value, "bundle limitation"));
      if (!limitations.some((value) => value.includes("not a native debugger replacement"))) {
        throw new Error(`iOS native handoff bundle is missing the native debugger limitation: ${JSON.stringify(limitations)}`);
      }

      const handoffSummary = await client.callTool("native_handoff_summary", {
        sessionId,
      });
      if (handoffSummary.isError === true) {
        throw new Error(`native_handoff_summary failed: ${JSON.stringify(handoffSummary.structuredContent)}`);
      }
      const summaryStructured = requireObject(
        handoffSummary.structuredContent,
        "native_handoff_summary.structuredContent",
      );
      const platforms = requireArray(summaryStructured.platforms, "native_handoff_summary.platforms")
        .map((value) => requireObject(value, "native handoff platform summary"));
      if (!platforms.some((value) => value.platform === "ios")) {
        throw new Error(`native_handoff_summary did not include ios: ${JSON.stringify(platforms)}`);
      }
      const summaryResources = requireArray(summaryStructured.resources, "native_handoff_summary.resources")
        .map((value) => requireObject(value, "native handoff resource"))
        .map((value) => requireString(value.uri, "native handoff summary resource uri"));
      if (!summaryResources.includes(`native-handoff://${sessionId}/ios`)) {
        throw new Error(`native_handoff_summary did not include the iOS bundle resource: ${JSON.stringify(summaryResources)}`);
      }
    } finally {
      await client.callTool("stop_app", {
        sessionId,
      });
    }

    const postmortem = await client.callTool("ios_debug_context", {
      sessionId,
      tailLines: 60,
    });
    if (postmortem.isError === true) {
      throw new Error(`ios_debug_context should work postmortem: ${JSON.stringify(postmortem.structuredContent)}`);
    }
    const postmortemStructured = requireObject(postmortem.structuredContent, "postmortem ios_debug_context");
    if (!["ready", "partial"].includes(requireString(postmortemStructured.status, "postmortem status"))) {
      throw new Error(`postmortem ios_debug_context returned unexpected status: ${JSON.stringify(postmortemStructured)}`);
    }
  });

  const androidFixture = await createPhase0Fixture();
  const androidClient = await Phase0HarnessClient.start(
    repoRoot,
    androidFixture.stateDir,
    [androidFixture.workspaceRoot],
  );
  try {
    await mkdir(resolve(androidFixture.workspaceRoot, "android", "app", "src", "main"), { recursive: true });
    await writeFile(
      resolve(androidFixture.workspaceRoot, "android", "app", "src", "main", "AndroidManifest.xml"),
      "<manifest package=\"dev.flutterhelm.synthetic\"></manifest>\n",
    );
    await writeFile(resolve(androidFixture.workspaceRoot, "android", "app", "build.gradle"), "plugins {}\n");
    await writeFile(resolve(androidFixture.workspaceRoot, "android", "settings.gradle"), "include(':app')\n");
    await writeFile(resolve(androidFixture.workspaceRoot, "android", "gradle.properties"), "org.gradle.jvmargs=-Xmx1536m\n");

    await androidClient.initialize();
    await androidClient.callTool("workspace_set_root", {
      workspaceRoot: androidFixture.workspaceRoot,
    });
    const opened = await androidClient.callTool("session_open", {
      workspaceRoot: androidFixture.workspaceRoot,
    });
    const openedStructured = requireObject(opened.structuredContent, "android session_open.structuredContent");
    const sessionId = requireString(openedStructured.sessionId, "android session_open.sessionId");

    const androidContext = await androidClient.callTool("android_debug_context", {
      sessionId,
    });
    if (androidContext.isError === true) {
      throw new Error(`android_debug_context failed: ${JSON.stringify(androidContext.structuredContent)}`);
    }
    const androidStructured = requireObject(androidContext.structuredContent, "android_debug_context.structuredContent");
    if (androidStructured.status !== "ready") {
      throw new Error(`android_debug_context should be ready for synthetic workspace: ${JSON.stringify(androidStructured)}`);
    }

    const bundleRead = await androidClient.request("resources/read", {
      uri: `native-handoff://${sessionId}/android`,
    });
    const bundleContents = requireArray(bundleRead.contents, "android native handoff contents");
    const bundleBody = requireObject(bundleContents[0], "android native handoff content");
    const bundle = JSON.parse(requireString(bundleBody.text, "android native handoff text")) as Record<string, unknown>;
    if (bundle.status !== "ready") {
      throw new Error(`android native handoff bundle should be ready: ${JSON.stringify(bundle)}`);
    }

    const handoffSummary = await androidClient.callTool("native_handoff_summary", {
      sessionId,
      platform: "android",
    });
    if (handoffSummary.isError === true) {
      throw new Error(`native_handoff_summary(android) failed: ${JSON.stringify(handoffSummary.structuredContent)}`);
    }
    const summaryStructured = requireObject(
      handoffSummary.structuredContent,
      "native_handoff_summary(android).structuredContent",
    );
    const resources = requireArray(summaryStructured.resources, "native_handoff_summary(android).resources")
      .map((value) => requireObject(value, "android native handoff summary resource"))
      .map((value) => requireString(value.uri, "android native handoff summary resource uri"));
    if (!resources.includes(`native-handoff://${sessionId}/android`)) {
      throw new Error(`native_handoff_summary(android) did not include the bundle resource: ${JSON.stringify(resources)}`);
    }
  } finally {
    await androidClient.close();
    await rm(androidFixture.sandboxDir, { recursive: true, force: true });
  }

  const missingAndroidFixture = await createPhase0Fixture();
  const missingAndroidClient = await Phase0HarnessClient.start(
    repoRoot,
    missingAndroidFixture.stateDir,
    [missingAndroidFixture.workspaceRoot],
  );
  try {
    await missingAndroidClient.initialize();
    await missingAndroidClient.callTool("workspace_set_root", {
      workspaceRoot: missingAndroidFixture.workspaceRoot,
    });
    const opened = await missingAndroidClient.callTool("session_open", {
      workspaceRoot: missingAndroidFixture.workspaceRoot,
    });
    const openedStructured = requireObject(opened.structuredContent, "missing android session_open.structuredContent");
    const sessionId = requireString(openedStructured.sessionId, "missing android session_open.sessionId");
    const androidContext = await missingAndroidClient.callTool("android_debug_context", {
      sessionId,
    });
    if (androidContext.isError === true) {
      throw new Error(`android_debug_context should return an unavailable bundle instead of failing: ${JSON.stringify(androidContext.structuredContent)}`);
    }
    const androidStructured = requireObject(androidContext.structuredContent, "missing android android_debug_context.structuredContent");
    if (androidStructured.status !== "unavailable") {
      throw new Error(`android_debug_context should return unavailable when android/ is missing: ${JSON.stringify(androidStructured)}`);
    }
  } finally {
    await missingAndroidClient.close();
    await rm(missingAndroidFixture.sandboxDir, { recursive: true, force: true });
  }
}

async function checkPhase5RuntimeInteractionFlow(repoRoot: string): Promise<void> {
  const fixture = await createSampleAppFixture(repoRoot);
  const pubGet = await runCommandCapture(
    "flutter",
    ["pub", "get"],
    fixture.workspaceRoot,
  );
  if (pubGet.exitCode !== 0) {
    await rm(fixture.sandboxDir, { recursive: true, force: true });
    throw new Error(pubGet.stderr || pubGet.stdout || "flutter pub get failed for sample app fixture");
  }

  const configPath = resolve(fixture.sandboxDir, "config.yaml");
  await writeFile(
    configPath,
    buildSampleAppConfig(fixture, {
      enableRuntimeInteraction: true,
      runtimeDriverEnabled: true,
      runtimeDriverStartupTimeoutMs: 15000,
    }),
  );
  const client = await Phase0HarnessClient.start(
    repoRoot,
    fixture.stateDir,
    [fixture.workspaceRoot],
    { configPath },
  );

  try {
    const initialize = await client.initialize();
    const capabilities = requireObject(initialize.capabilities, "initialize.capabilities");
    const experimental = requireObject(capabilities.experimental, "capabilities.experimental");
    const runtimeInteraction = requireObject(
      experimental.runtimeInteraction,
      "capabilities.experimental.runtimeInteraction",
    );
    if (runtimeInteraction.defaultEnabled !== false) {
      throw new Error(`runtimeInteraction.defaultEnabled should remain false, got ${JSON.stringify(runtimeInteraction)}`);
    }

    await client.callTool("workspace_set_root", {
      workspaceRoot: fixture.workspaceRoot,
    });

    const toolsList = await client.request("tools/list");
    const toolNames = requireArray(toolsList.tools, "tools/list.tools")
      .map((tool) => requireObject(tool, "tool"))
      .map((tool) => requireString(tool.name, "tool.name"));
    for (const expected of [
      "tap_widget",
      "enter_text",
      "scroll_until_visible",
      "hot_reload",
      "hot_restart",
      "capture_screenshot",
    ]) {
      if (!toolNames.includes(expected)) {
        throw new Error(`tools/list is missing runtime interaction tool ${expected}`);
      }
    }

    const running = await client.callTool("run_app", {
      platform: "ios",
      mode: "debug",
      dartDefines: ["FLUTTERHELM_SCENARIO=interaction_demo"],
    });
    if (running.isError === true) {
      const error = requireObject(requireObject(running.structuredContent, "run_app error").error, "run_app structured error");
      throw new Error(`run_app failed: ${String(error.code)}: ${String(error.message)}`);
    }
    const runningStructured = requireObject(running.structuredContent, "run_app.structuredContent");
    const sessionId = requireString(runningStructured.sessionId, "run_app.sessionId");

    try {
      const healthResource = await client.request("resources/read", {
        uri: `session://${sessionId}/health`,
      });
      const healthContents = requireArray(healthResource.contents, "session health contents");
      const healthBody = requireObject(healthContents[0], "session health content");
      const health = JSON.parse(requireString(healthBody.text, "session health text")) as Record<string, unknown>;
      if (health.driverConfigured !== true || health.driverConnected !== true) {
        throw new Error(`runtime interaction health should report a connected driver: ${JSON.stringify(health)}`);
      }
      const locatorFields = requireArray(health.supportedLocatorFields, "session health supportedLocatorFields");
      if (!locatorFields.includes("text") || !locatorFields.includes("label")) {
        throw new Error(`runtime interaction health is missing basic locator fields: ${JSON.stringify(locatorFields)}`);
      }

      const screenshot = await client.callTool("capture_screenshot", {
        sessionId,
      });
      if (screenshot.isError === true) {
        throw new Error(`capture_screenshot failed: ${JSON.stringify(screenshot.structuredContent)}`);
      }
      const screenshotStructured = requireObject(screenshot.structuredContent, "capture_screenshot.structuredContent");
      const screenshotResource = requireObject(screenshotStructured.resource, "capture_screenshot.resource");
      const screenshotUri = requireString(screenshotResource.uri, "capture_screenshot.resource.uri");
      const screenshotResult = await client.request("resources/read", {
        uri: screenshotUri,
      });
      const screenshotContentsValue = screenshotResult.contents;
      if (!Array.isArray(screenshotContentsValue)) {
        throw new Error(`Expected screenshot contents to be an array: ${JSON.stringify(screenshotResult)}`);
      }
      const screenshotContents = screenshotContentsValue;
      const screenshotBody = requireObject(screenshotContents[0], "screenshot body");
      requireString(screenshotBody.blob, "screenshot blob");
      if ("text" in screenshotBody && screenshotBody.text != null) {
        throw new Error("Screenshot resource should be binary-only");
      }

      const interactionSteps: Array<{ toolName: string; argumentsPayload: Record<string, unknown> }> = [
        { toolName: "tap_widget", argumentsPayload: { sessionId, locator: { text: "Tap primary" } } },
        {
          toolName: "enter_text",
          argumentsPayload: {
            sessionId,
            locator: { textContains: "Name input" },
            text: "Codex",
            submit: true,
          },
        },
        {
          toolName: "scroll_until_visible",
          argumentsPayload: {
            sessionId,
            locator: { text: "Deep action" },
            direction: "down",
            maxScrolls: 10,
          },
        },
        { toolName: "tap_widget", argumentsPayload: { sessionId, locator: { text: "Deep action" } } },
      ];

      for (const step of interactionSteps) {
        const result = await client.callTool(step.toolName, step.argumentsPayload);
        if (result.isError === true) {
          throw new Error(`${step.toolName} failed: ${JSON.stringify(result.structuredContent)}`);
        }
      }

      let preview = "";
      for (let attempt = 0; attempt < 10; attempt += 1) {
        const logs = await client.callTool("get_logs", {
          sessionId,
          stream: "stdout",
          tailLines: 200,
        });
        const logsStructured = requireObject(logs.structuredContent, "get_logs.structuredContent");
        preview =
          (requireObject(logsStructured.preview, "get_logs.preview").stdout as string | undefined) ??
          "";
        if (preview.includes("interaction: deep action tapped")) {
          break;
        }
        await new Promise((resolveDelay) => setTimeout(resolveDelay, 1000));
      }
      for (const expected of [
        "interaction: primary tapped",
        "interaction: text submitted=Codex",
        "interaction: deep action tapped",
      ]) {
        if (!preview.includes(expected)) {
          throw new Error(`get_logs preview is missing ${expected}: ${preview}`);
        }
      }

      const hotReload = await client.callTool("hot_reload", {
        sessionId,
      });
      if (hotReload.isError === true) {
        throw new Error(`hot_reload failed: ${JSON.stringify(hotReload.structuredContent)}`);
      }

      const hotRestartAttempt = await client.callTool("hot_restart", {
        sessionId,
      });
      const hotRestartAttemptStructured = requireObject(
        hotRestartAttempt.structuredContent,
        "hot_restart approval structuredContent",
      );
      if (hotRestartAttemptStructured.status !== "approval_required") {
        throw new Error(`hot_restart should require approval, got ${JSON.stringify(hotRestartAttemptStructured)}`);
      }
      const hotRestartApproved = await client.callTool("hot_restart", {
        sessionId,
        approvalToken: requireString(
          hotRestartAttemptStructured.approvalRequestId,
          "hot_restart.approvalRequestId",
        ),
      });
      if (hotRestartApproved.isError === true) {
        throw new Error(`hot_restart approved replay failed: ${JSON.stringify(hotRestartApproved.structuredContent)}`);
      }

      const attached = await client.callTool("attach_app", {
        sessionId,
        platform: "ios",
        mode: "debug",
      });
      const attachedStructured = requireObject(attached.structuredContent, "attach_app.structuredContent");
      const attachedSessionId = requireString(attachedStructured.sessionId, "attach_app.sessionId");

      for (const toolName of ["hot_reload", "hot_restart"]) {
        const result = await client.callTool(toolName, {
          sessionId: attachedSessionId,
        });
        if (result.isError !== true) {
          throw new Error(`${toolName} should reject attached sessions`);
        }
      }
    } finally {
      await client.callTool("stop_app", {
        sessionId,
      });
    }
  } finally {
    await client.close();
    await rm(fixture.sandboxDir, { recursive: true, force: true });
  }
}

async function checkPhase6HardeningDocs(repoRoot: string): Promise<void> {
  await checkRequiredStrings(
    repoRoot,
    "README.md",
    [
      "`compatibility_check`",
      "`artifact_pin`",
      "`artifact_unpin`",
      "`artifact_pin_list`",
      "`config://compatibility/current`",
      "`config://artifacts/pins`",
      "`--profile`",
      "`FLUTTERHELM_PROFILE`",
    ],
    "README hardening core",
  );
  await checkRequiredStrings(
    repoRoot,
    "docs/07-roadmap.md",
    [
      "concurrency handling",
      "pinned artifacts",
      "config profiles",
      "compatibility matrix",
      "Sprint 8",
    ],
    "Roadmap Phase 6",
  );
  await checkRequiredStrings(
    repoRoot,
    "docs/09-implementation-plan.md",
    [
      "### Sprint 8",
      "session/workspace fail-fast lock",
      "`artifact_pin`",
      "`artifact_unpin`",
      "`artifact_pin_list`",
      "`compatibility_check`",
      "config profile overlay",
    ],
    "Implementation plan Sprint 8",
  );
}

async function checkPhase6HardeningFlow(repoRoot: string): Promise<void> {
  await withSampleAppClient(
    repoRoot,
    async (fixture, client) => {
      await client.initialize();

      await client.callTool("workspace_set_root", {
        workspaceRoot: fixture.workspaceRoot,
      });

      const resourcesList = await client.request("resources/list");
      const resourceUris = requireArray(resourcesList.resources, "resources/list.resources")
        .map((value) => requireObject(value, "resource"))
        .map((value) => requireString(value.uri, "resource.uri"));
      for (const expected of [
        "config://workspace/current",
        "config://workspace/defaults",
        "config://artifacts/pins",
        "config://adapters/current",
        "config://compatibility/current",
      ]) {
        if (!resourceUris.includes(expected)) {
          throw new Error(`resources/list is missing ${expected}`);
        }
      }

      const workspaceShow = await client.callTool("workspace_show");
      const workspaceStructured = requireObject(workspaceShow.structuredContent, "workspace_show.structuredContent");
      if (workspaceStructured.activeProfile !== "interactive") {
        throw new Error(`workspace_show.activeProfile should be interactive, got ${String(workspaceStructured.activeProfile)}`);
      }
      const availableProfiles = requireArray(
        workspaceStructured.availableProfiles,
        "workspace_show.availableProfiles",
      );
      if (!availableProfiles.includes("interactive")) {
        throw new Error(`workspace_show.availableProfiles is missing interactive: ${JSON.stringify(availableProfiles)}`);
      }

      const workspaceCurrent = await client.request("resources/read", {
        uri: "config://workspace/current",
      });
      const workspaceContents = requireArray(workspaceCurrent.contents, "config://workspace/current contents");
      const workspaceBody = requireObject(workspaceContents[0], "config://workspace/current body");
      const workspaceDecoded = JSON.parse(
        requireString(workspaceBody.text, "config://workspace/current text"),
      ) as Record<string, unknown>;
      if (workspaceDecoded.activeProfile !== "interactive") {
        throw new Error(`config://workspace/current activeProfile mismatch: ${JSON.stringify(workspaceDecoded)}`);
      }
      if (workspaceDecoded.adaptersResource !== "config://adapters/current") {
        throw new Error(`config://workspace/current adaptersResource mismatch: ${JSON.stringify(workspaceDecoded)}`);
      }

      const compatibility = await client.callTool("compatibility_check");
      const compatibilityStructured = requireObject(
        compatibility.structuredContent,
        "compatibility_check.structuredContent",
      );
      if (compatibilityStructured.profile !== "interactive") {
        throw new Error(`compatibility_check profile mismatch: ${JSON.stringify(compatibilityStructured)}`);
      }
      const compatibilityWorkflows = requireObject(
        compatibilityStructured.workflows,
        "compatibility_check.workflows",
      );
      const runtimeInteraction = requireObject(
        compatibilityWorkflows.runtime_interaction,
        "compatibility_check.workflows.runtime_interaction",
      );
      if (runtimeInteraction.configured !== true) {
        throw new Error(`runtime_interaction compatibility mismatch: ${JSON.stringify(runtimeInteraction)}`);
      }

      const compatibilityResource = await client.request("resources/read", {
        uri: "config://compatibility/current",
      });
      const compatibilityContents = requireArray(
        compatibilityResource.contents,
        "config://compatibility/current contents",
      );
      const compatibilityBody = requireObject(
        compatibilityContents[0],
        "config://compatibility/current body",
      );
      const compatibilityDecoded = JSON.parse(
        requireString(compatibilityBody.text, "config://compatibility/current text"),
      ) as Record<string, unknown>;
      if (compatibilityDecoded.profile !== "interactive") {
        throw new Error(`config://compatibility/current profile mismatch: ${JSON.stringify(compatibilityDecoded)}`);
      }

      const unitTests = await client.callTool("run_unit_tests", {
        coverage: true,
      });
      if (unitTests.isError === true) {
        throw new Error(`run_unit_tests failed: ${JSON.stringify(unitTests.structuredContent)}`);
      }
      const unitStructured = requireObject(unitTests.structuredContent, "run_unit_tests.structuredContent");
      const runId = requireString(unitStructured.runId, "run_unit_tests.runId");
      const testReportUri = `test-report://${runId}/summary`;

      const pin = await client.callTool("artifact_pin", {
        uri: testReportUri,
        label: "keep-for-debug",
      });
      if (pin.isError === true) {
        throw new Error(`artifact_pin failed: ${JSON.stringify(pin.structuredContent)}`);
      }

      const pinList = await client.callTool("artifact_pin_list", {
        kind: "test-report",
      });
      const pinListStructured = requireObject(pinList.structuredContent, "artifact_pin_list.structuredContent");
      const pins = requireArray(pinListStructured.pins, "artifact_pin_list.pins")
        .map((value) => requireObject(value, "pin"));
      const reportPin = pins.find((entry) => entry.uri === testReportUri);
      if (!reportPin || reportPin.status !== "present") {
        throw new Error(`Pinned test report is missing or not present: ${JSON.stringify(pins)}`);
      }

      const pinsResource = await client.request("resources/read", {
        uri: "config://artifacts/pins",
      });
      const pinsContents = requireArray(pinsResource.contents, "config://artifacts/pins contents");
      const pinsBody = requireObject(pinsContents[0], "config://artifacts/pins body");
      const pinsDecoded = JSON.parse(
        requireString(pinsBody.text, "config://artifacts/pins text"),
      ) as Record<string, unknown>;
      const pinnedResources = requireArray(pinsDecoded.pins, "config://artifacts/pins pins");
      if (!pinnedResources.some((value) => requireObject(value, "pin").uri === testReportUri)) {
        throw new Error(`config://artifacts/pins is missing ${testReportUri}`);
      }

      const widgetTestsPromise = client.callTool("run_widget_tests");
      await new Promise((resolveDelay) => setTimeout(resolveDelay, 300));
      const busyUnitTests = await client.callTool("run_unit_tests");
      if (busyUnitTests.isError !== true) {
        throw new Error("run_unit_tests should fail with WORKSPACE_BUSY while run_widget_tests is active");
      }
      const busyStructured = requireObject(
        busyUnitTests.structuredContent,
        "WORKSPACE_BUSY structuredContent",
      );
      const busyError = "error" in busyStructured
        ? requireObject(busyStructured.error, "WORKSPACE_BUSY error")
        : busyStructured;
      if (busyError.code !== "WORKSPACE_BUSY") {
        throw new Error(`Expected WORKSPACE_BUSY, got ${JSON.stringify(busyError)}`);
      }
      const busyDetails = requireObject(busyError.details, "WORKSPACE_BUSY details");
      if (busyDetails.busyScope !== "workspace" || busyDetails.activeTool !== "run_widget_tests") {
        throw new Error(`Unexpected WORKSPACE_BUSY details: ${JSON.stringify(busyDetails)}`);
      }
      const widgetTests = await widgetTestsPromise;
      if (widgetTests.isError === true) {
        throw new Error(`run_widget_tests failed: ${JSON.stringify(widgetTests.structuredContent)}`);
      }

      const unpin = await client.callTool("artifact_unpin", {
        uri: testReportUri,
      });
      if (unpin.isError === true) {
        throw new Error(`artifact_unpin failed: ${JSON.stringify(unpin.structuredContent)}`);
      }
      const afterUnpin = await client.callTool("artifact_pin_list", {
        kind: "test-report",
      });
      const afterUnpinStructured = requireObject(
        afterUnpin.structuredContent,
        "artifact_pin_list after unpin.structuredContent",
      );
      const afterPins = requireArray(afterUnpinStructured.pins, "artifact_pin_list after unpin pins");
      if (afterPins.some((value) => requireObject(value, "pin").uri === testReportUri)) {
        throw new Error(`artifact_unpin did not remove ${testReportUri}`);
      }
    },
    {
      configText: `version: 1
enabledWorkflows:
  - workspace
  - session
  - launcher
  - runtime_readonly
  - tests
  - profiling
  - platform_bridge
profiles:
  interactive:
    enabledWorkflows:
      - workspace
      - session
      - launcher
      - runtime_readonly
      - tests
      - profiling
      - platform_bridge
      - runtime_interaction
`,
      profile: "interactive",
    },
  );
}

async function checkPhase6EcosystemDocs(repoRoot: string): Promise<void> {
  await checkRequiredStrings(
    repoRoot,
    "README.md",
    [
      "`adapter_list`",
      "`config://adapters/current`",
      "`--transport http`",
      "`--http-host`",
      "`--http-port`",
      "`--http-path`",
      "localhost-only",
      "`stdio_json`",
    ],
    "README ecosystem preview",
  );
  await checkRequiredStrings(
    repoRoot,
    "docs/04-mcp-contract.md",
    [
      "adapter registry",
      "custom provider kind は `stdio_json`",
      "localhost-only の Streamable HTTP preview",
      "`adapter_list`",
      "`experimental.httpPreview.mode = preview`",
      "`experimental.adapterRegistry.customProviderKinds = [\"stdio_json\"]`",
    ],
    "MCP contract ecosystem preview",
  );
  await checkRequiredStrings(
    repoRoot,
    "docs/07-roadmap.md",
    [
      "Sprint 9",
      "Streamable HTTP preview",
      "extension / plugin point for custom adapters",
      "adapter registry / custom `stdio_json` provider / `adapter_list` / `config://adapters/current`",
    ],
    "Roadmap Sprint 9",
  );
  await checkRequiredStrings(
    repoRoot,
    "docs/09-implementation-plan.md",
    [
      "### Sprint 9",
      "transport-agnostic core",
      "`config://adapters/current`",
      "`adapter_list`",
      "`stdio_json`",
      "`--transport http`",
      "localhost-only Streamable HTTP preview",
    ],
    "Implementation plan Sprint 9",
  );
  await checkRequiredStrings(
    repoRoot,
    "docs/adrs/ADR-002-transport-roots.md",
    [
      "Sprint 9 update",
      "primary transport は引き続き `stdio`",
      "HTTP preview では Roots transport を扱わず",
    ],
    "ADR-002 Sprint 9 update",
  );
}

async function checkPhase6EcosystemFlow(repoRoot: string): Promise<void> {
  const sampleFixture = await createSampleAppFixture(repoRoot);
  const pubGet = await runCommandCapture(
    "flutter",
    ["pub", "get"],
    sampleFixture.workspaceRoot,
  );
  if (pubGet.exitCode !== 0) {
    await rm(sampleFixture.sandboxDir, { recursive: true, force: true });
    throw new Error(pubGet.stderr || pubGet.stdout || "flutter pub get failed for ecosystem fixture");
  }
  const configPath = resolve(sampleFixture.sandboxDir, "ecosystem-config.yaml");
  await writeFile(
    configPath,
    `version: 1
workspace:
  roots:
    - ${JSON.stringify(sampleFixture.workspaceRoot)}
defaults:
  target: lib/main.dart
  mode: debug
enabledWorkflows:
  - workspace
  - session
  - launcher
  - runtime_readonly
  - tests
  - profiling
  - platform_bridge
  - runtime_interaction
fallbacks:
  allowRootFallback: false
retention:
  heavyArtifactsDays: 7
  metadataDays: 30
adapters:
  active:
    runtimeDriver: test.runtimeDriver.fake
  providers:
    test.runtimeDriver.fake:
      kind: stdio_json
      families:
        - runtimeDriver
      command: dart
      args:
        - run
        - tool/fake_stdio_adapter_provider.dart
      startupTimeoutMs: 5000
`,
  );
  const sampleClient = await Phase0HarnessClient.start(
    repoRoot,
    sampleFixture.stateDir,
    [sampleFixture.workspaceRoot],
    { configPath },
  );
  try {
    await sampleClient.initialize();
    await sampleClient.callTool("workspace_set_root", {
      workspaceRoot: sampleFixture.workspaceRoot,
    });

    const adaptersList = await sampleClient.callTool("adapter_list", {
      family: "runtimeDriver",
    });
    const adaptersStructured = requireObject(
      adaptersList.structuredContent,
      "adapter_list.structuredContent",
    );
    const adapters = requireArray(adaptersStructured.adapters, "adapter_list.adapters")
      .map((value) => requireObject(value, "adapter family"));
    if (adapters.length !== 1) {
      throw new Error(`adapter_list(family=runtimeDriver) returned ${adapters.length} entries`);
    }
    const runtimeDriver = adapters[0];
    if (
      runtimeDriver.family !== "runtimeDriver"
      || runtimeDriver.activeProviderId !== "test.runtimeDriver.fake"
      || runtimeDriver.kind !== "stdio_json"
      || runtimeDriver.healthy !== true
    ) {
      throw new Error(`Unexpected runtimeDriver adapter entry: ${JSON.stringify(runtimeDriver)}`);
    }
    const operations = requireArray(runtimeDriver.operations, "runtimeDriver.operations");
    for (const operation of ["list_elements", "tap", "enter_text", "scroll_until_visible", "capture_screenshot"]) {
      if (!operations.includes(operation)) {
        throw new Error(`runtimeDriver.operations is missing ${operation}`);
      }
    }

    const adaptersResource = await sampleClient.request("resources/read", {
      uri: "config://adapters/current",
    });
    const adaptersContents = requireArray(
      adaptersResource.contents,
      "config://adapters/current contents",
    );
    const adaptersBody = requireObject(
      adaptersContents[0],
      "config://adapters/current body",
    );
    const adaptersDecoded = JSON.parse(
      requireString(adaptersBody.text, "config://adapters/current text"),
    ) as Record<string, unknown>;
    const active = requireObject(adaptersDecoded.active, "config://adapters/current active");
    if (active.runtimeDriver !== "test.runtimeDriver.fake") {
      throw new Error(`config://adapters/current runtimeDriver mismatch: ${JSON.stringify(adaptersDecoded)}`);
    }
    const providers = requireObject(adaptersDecoded.providers, "config://adapters/current providers");
    if (!("test.runtimeDriver.fake" in providers)) {
      throw new Error("config://adapters/current is missing test.runtimeDriver.fake");
    }
  } finally {
    await sampleClient.close();
    await rm(sampleFixture.sandboxDir, { recursive: true, force: true });
  }

  const fixture = await createPhase0Fixture();
  const client = await HttpPreviewHarnessClient.start(
    repoRoot,
    fixture.stateDir,
    { allowRootFallback: true },
  );
  try {
    const initialize = await client.initialize();
    const serverInfo = requireObject(initialize.serverInfo, "http initialize.serverInfo");
    if (serverInfo.name !== "flutterhelm") {
      throw new Error(`HTTP initialize returned unexpected serverInfo: ${JSON.stringify(serverInfo)}`);
    }

    const tools = await client.request("tools/list");
    const toolNames = requireArray(tools.tools, "http tools/list.tools")
      .map((value) => requireObject(value, "tool"))
      .map((value) => requireString(value.name, "tool.name"));
    if (!toolNames.includes("adapter_list")) {
      throw new Error("HTTP tools/list is missing adapter_list");
    }

    const workspaceShow = await client.request("tools/call", {
      name: "workspace_show",
      arguments: {},
    });
    const workspaceStructured = requireObject(
      workspaceShow.structuredContent,
      "HTTP workspace_show.structuredContent",
    );
    if (
      workspaceStructured.transportMode !== "http"
      || workspaceStructured.httpPreview !== true
      || workspaceStructured.rootsTransportSupport !== "unsupported"
    ) {
      throw new Error(`Unexpected HTTP workspace_show payload: ${JSON.stringify(workspaceStructured)}`);
    }

    const compatibility = await client.request("tools/call", {
      name: "compatibility_check",
      arguments: {},
    });
    const compatibilityStructured = requireObject(
      compatibility.structuredContent,
      "HTTP compatibility_check.structuredContent",
    );
    const transport = requireObject(compatibilityStructured.transport, "compatibility.transport");
    const httpPreview = requireObject(transport.httpPreview, "compatibility.transport.httpPreview");
    if (httpPreview.status !== "degraded") {
      throw new Error(`HTTP compatibility httpPreview mismatch: ${JSON.stringify(httpPreview)}`);
    }

    const resourcesList = await client.request("resources/list");
    const resourceUris = requireArray(resourcesList.resources, "http resources/list.resources")
      .map((value) => requireObject(value, "resource"))
      .map((value) => requireString(value.uri, "resource.uri"));
    for (const expected of [
      "config://workspace/current",
      "config://workspace/defaults",
      "config://adapters/current",
      "config://compatibility/current",
    ]) {
      if (!resourceUris.includes(expected)) {
        throw new Error(`HTTP resources/list is missing ${expected}`);
      }
    }

    const approvalRequired = await client.request("tools/call", {
      name: "workspace_set_root",
      arguments: {
        workspaceRoot: fixture.workspaceRoot,
      },
    });
    const approvalStructured = requireObject(
      approvalRequired.structuredContent,
      "HTTP workspace_set_root approval",
    );
    if (approvalStructured.status !== "approval_required") {
      throw new Error(`HTTP fallback workspace_set_root should require approval: ${JSON.stringify(approvalStructured)}`);
    }
    const approvalToken = requireString(
      approvalStructured.approvalRequestId,
      "HTTP workspace_set_root.approvalRequestId",
    );
    const approved = await client.request("tools/call", {
      name: "workspace_set_root",
      arguments: {
        workspaceRoot: fixture.workspaceRoot,
        approvalToken,
      },
    });
    const approvedStructured = requireObject(
      approved.structuredContent,
      "HTTP workspace_set_root approved",
    );
    const activeRoot = await realpath(requireString(approvedStructured.activeRoot, "HTTP approved activeRoot"));
    if (activeRoot !== fixture.workspaceRoot) {
      throw new Error(`HTTP workspace_set_root returned unexpected activeRoot ${String(approvedStructured.activeRoot)}`);
    }

    const workspaceCurrent = await client.request("resources/read", {
      uri: "config://workspace/current",
    });
    const workspaceCurrentContents = requireArray(workspaceCurrent.contents, "HTTP workspace/current contents");
    const workspaceCurrentBody = requireObject(workspaceCurrentContents[0], "HTTP workspace/current body");
    const workspaceCurrentDecoded = JSON.parse(
      requireString(workspaceCurrentBody.text, "HTTP workspace/current text"),
    ) as Record<string, unknown>;
    if (workspaceCurrentDecoded.transportMode !== "http") {
      throw new Error(`HTTP workspace/current transportMode mismatch: ${JSON.stringify(workspaceCurrentDecoded)}`);
    }

    const getStatus = await client.getStatusCode();
    if (getStatus !== 405) {
      throw new Error(`HTTP preview GET expected 405, got ${getStatus}`);
    }

    const deleteStatus = await client.deleteSession();
    if (deleteStatus !== 204) {
      throw new Error(`HTTP preview DELETE expected 204, got ${deleteStatus}`);
    }

    const postDelete = await client.rawRequest("ping", {}, { id: "after-delete" });
    if (postDelete.statusCode !== 404) {
      throw new Error(`HTTP preview expected 404 after deleting session, got ${postDelete.statusCode}`);
    }
  } finally {
    await client.close();
    await rm(fixture.sandboxDir, { recursive: true, force: true });
  }
}

async function checkMkDocsBuild(repoRoot: string, harnessRoot: string): Promise<void> {
  const docsPython = resolveDocsPython(harnessRoot);
  if (!(await pathExists(docsPython))) {
    throw new Error("MkDocs bootstrap is missing. Run `mise exec -- pnpm -C harness bootstrap` first.");
  }

  const siteDir = await mkdtemp(resolve(tmpdir(), "flutterhelm-harness-site-"));
  try {
    const result = await runCommandCapture(
      docsPython,
      ["-m", "mkdocs", "build", "--strict", "--site-dir", siteDir],
      repoRoot,
    );
    if (result.exitCode !== 0) {
      throw new Error(result.stderr || result.stdout || "mkdocs build failed");
    }
  } finally {
    await rm(siteDir, { recursive: true, force: true });
  }
}

async function checkReadmeNavLinks(repoRoot: string): Promise<void> {
  const readme = await readRepoText(repoRoot, "README.md");
  const mkdocs = await readRepoText(repoRoot, "mkdocs.yml");
  const links = [...readme.matchAll(/\((docs\/[^)\s]+\.md)\)/g)].map((match) => match[1]);

  if (links.length === 0) {
    throw new Error("README does not contain any docs links");
  }

  for (const link of new Set(links)) {
    if (!(await pathExists(resolve(repoRoot, link)))) {
      throw new Error(`README references missing docs file: ${link}`);
    }
    const navPath = link.replace(/^docs\//, "");
    if (!mkdocs.includes(navPath)) {
      throw new Error(`mkdocs nav is missing README-linked file: ${link}`);
    }
  }
}

async function checkRequiredStrings(
  repoRoot: string,
  relativePath: string,
  required: string[],
  label: string,
): Promise<void> {
  const text = await readRepoText(repoRoot, relativePath);
  for (const snippet of required) {
    if (!text.includes(snippet)) {
      throw new Error(`${label} is missing required snippet: ${snippet}`);
    }
  }
}

function requireTableRowValue(
  rows: Array<Record<string, string>>,
  keyColumn: string,
  keyValue: string,
  valueColumn: string,
  expectedValue: string,
  label: string,
): void {
  const row = rows.find((candidate) => normalizeMarkdownValue(candidate[keyColumn] ?? "") === keyValue);
  if (!row) {
    throw new Error(`${label} is missing row for ${keyValue}`);
  }

  const actualValue = normalizeMarkdownValue(row[valueColumn] ?? "");
  if (actualValue !== expectedValue) {
    throw new Error(`${label} expected ${keyValue} -> ${expectedValue}, got ${actualValue || "<empty>"}`);
  }
}

async function checkWorkflowGroups(repoRoot: string): Promise<void> {
  const markdown = await readRepoText(repoRoot, "docs/04-mcp-contract.md");
  const rows = extractMarkdownTable(markdown, "## 3. Workflow Groups");
  const expected = new Map<string, string>([
    ["workspace", "Yes"],
    ["session", "Yes"],
    ["launcher", "Yes"],
    ["runtime_readonly", "Yes"],
    ["tests", "Yes"],
    ["runtime_interaction", "No"],
    ["profiling", "Yes"],
    ["platform_bridge", "Yes"],
  ]);

  if (rows.length !== expected.size) {
    throw new Error(`Workflow Groups table expected ${expected.size} rows, found ${rows.length}`);
  }

  for (const [workflow, initialEnabled] of expected.entries()) {
    requireTableRowValue(rows, "Workflow", workflow, "初期有効", initialEnabled, "Workflow Groups");
  }
}

async function checkToolRiskCatalog(repoRoot: string): Promise<void> {
  const markdown = await readRepoText(repoRoot, "docs/04-mcp-contract.md");
  const requiredChecks = [
    { heading: "## 4.1 workspace", tool: "compatibility_check", risk: "read_only" },
    { heading: "## 4.1 workspace", tool: "adapter_list", risk: "read_only" },
    { heading: "## 4.1 workspace", tool: "dependency_add", risk: "project_mutation" },
    { heading: "## 4.1 workspace", tool: "dependency_remove", risk: "project_mutation" },
    { heading: "## 4.2 session", tool: "artifact_pin", risk: "bounded_mutation" },
    { heading: "## 4.2 session", tool: "artifact_unpin", risk: "bounded_mutation" },
    { heading: "## 4.2 session", tool: "artifact_pin_list", risk: "read_only" },
    { heading: "## 4.3 launcher", tool: "run_app", risk: "runtime_control" },
    { heading: "## 4.3 launcher", tool: "build_app", risk: "build_control" },
    { heading: "## 4.4 runtime_readonly", tool: "capture_screenshot", risk: "bounded_mutation" },
    { heading: "## 4.5 tests", tool: "run_integration_tests", risk: "test_execution" },
    { heading: "## 4.7 runtime_interaction", tool: "hot_restart", risk: "state_destructive" },
  ];

  for (const check of requiredChecks) {
    const rows = extractMarkdownTable(markdown, check.heading);
    requireTableRowValue(rows, "Tool", check.tool, "Risk", check.risk, `Tool catalog ${check.heading}`);
  }
}

async function checkApprovalContract(repoRoot: string): Promise<void> {
  const markdown = await readRepoText(repoRoot, "docs/04-mcp-contract.md");
  const response = extractJsonCodeBlock<Record<string, string>>(markdown, "### Response (approval required)");
  const expectedEntries = {
    status: "approval_required",
    risk: "project_mutation",
  };

  for (const [key, value] of Object.entries(expectedEntries)) {
    if (response[key] !== value) {
      throw new Error(`approval response expected ${key}=${value}, got ${String(response[key])}`);
    }
  }

  if (typeof response.reason !== "string" || response.reason.length === 0) {
    throw new Error("approval response is missing reason");
  }
  if (typeof response.approvalRequestId !== "string" || !response.approvalRequestId.startsWith("apr_")) {
    throw new Error("approval response is missing approvalRequestId");
  }
}

async function checkSafetyRootFallback(repoRoot: string): Promise<void> {
  const security = await readRepoText(repoRoot, "docs/06-security-and-safety.md");
  const adr = await readRepoText(repoRoot, "docs/adrs/ADR-002-transport-roots.md");
  const riskRows = extractMarkdownTable(security, "## 3. Risk Classes");
  const expectedRiskClasses = [
    "read_only",
    "read_only_network",
    "bounded_mutation",
    "runtime_control",
    "project_mutation",
    "state_destructive",
    "build_control",
    "publish_like",
  ];

  for (const riskClass of expectedRiskClasses) {
    const row = riskRows.find((candidate) => normalizeMarkdownValue(candidate["Risk Class"] ?? "") === riskClass);
    if (!row) {
      throw new Error(`Risk Classes table is missing ${riskClass}`);
    }
  }

  const requiredConfirmations = extractBulletItems(security, "### 必ず確認する操作");
  for (const requiredItem of [
    "`dependency_add`",
    "`dependency_remove`",
    "`hot_restart`",
    "`build_app` with `mode=release`",
    "`workspace_set_root` in fallback mode",
  ]) {
    if (!requiredConfirmations.includes(requiredItem)) {
      throw new Error(`Confirmation Policy is missing required item: ${requiredItem}`);
    }
  }

  const rootFallbackItems = extractBulletItems(security, "### Root fallback mode");
  for (const requiredItem of [
    "server 起動時に `--allow-root-fallback` が必要",
    "user が明示 root を選ぶまで write tool を無効",
    "現在 root は `config://workspace/current` で可視化",
  ]) {
    if (!rootFallbackItems.includes(requiredItem)) {
      throw new Error(`Root fallback mode is missing required item: ${requiredItem}`);
    }
  }

  for (const requiredSnippet of [
    "FlutterHelm は初期 transport を `stdio-first` とする。",
    "Filesystem boundary は `roots-aware` を原則とし、roots が壊れている client 向けにのみ `root fallback mode` を提供する。",
    "fallback は server 起動時の明示 opt-in とする。",
  ]) {
    if (!adr.includes(requiredSnippet)) {
      throw new Error(`ADR-002 is missing required snippet: ${requiredSnippet}`);
    }
  }
}

async function checkSessionContract(repoRoot: string): Promise<void> {
  const markdown = await readRepoText(repoRoot, "docs/05-session-and-resources.md");
  const sessionObject = extractJsonCodeBlock<Record<string, unknown>>(markdown, "### Session object");
  const requiredKeys = [
    "sessionId",
    "workspaceRoot",
    "platform",
    "deviceId",
    "target",
    "flavor",
    "mode",
    "state",
    "pid",
    "vmService",
    "dtd",
    "adapters",
    "createdAt",
    "lastSeenAt",
  ];

  for (const key of requiredKeys) {
    if (!(key in sessionObject)) {
      throw new Error(`Session object is missing key: ${key}`);
    }
  }

  const vmService = sessionObject.vmService as Record<string, unknown>;
  const dtd = sessionObject.dtd as Record<string, unknown>;
  const adapters = sessionObject.adapters as Record<string, unknown>;
  for (const [label, object, keys] of [
    ["vmService", vmService, ["available"]],
    ["dtd", dtd, ["available"]],
    ["adapters", adapters, ["delegate", "launcher", "profiling", "runtimeDriver"]],
  ] as const) {
    for (const key of keys) {
      if (!(key in object)) {
        throw new Error(`Session object ${label} is missing key: ${key}`);
      }
    }
  }

  const stateSection = extractSection(markdown, "## 3. Session state machine");
  for (const state of ["created", "starting", "attached", "running", "failed", "stopped", "disposed"]) {
    if (!stateSection.includes(state)) {
      throw new Error(`Session state machine is missing state: ${state}`);
    }
  }
}

async function checkResourceUriContract(repoRoot: string): Promise<void> {
  const markdown = await readRepoText(repoRoot, "docs/05-session-and-resources.md");
  const section = extractSectionBetweenHeadings(markdown, "## 7. Resource URI スキーム", "## 8. Resource metadata");
  const tokens = new Set([...section.matchAll(/`([^`]+)`/g)].map((match) => match[1]));
  const expectedUris = [
    "session://<session-id>/summary",
    "session://<session-id>/health",
    "config://workspace/current",
    "config://workspace/defaults",
    "config://adapters/current",
    "config://artifacts/pins",
    "config://compatibility/current",
    "log://<session-id>/stdout",
    "log://<session-id>/stderr",
    "runtime-errors://<session-id>/current",
    "widget-tree://<session-id>/current?depth=3",
    "app-state://<session-id>/summary",
    "test-report://<run-id>/summary",
    "test-report://<run-id>/details",
    "coverage://<run-id>/lcov",
    "coverage://<run-id>/summary",
    "timeline://<session-id>/<capture-id>",
    "memory://<session-id>/<snapshot-id>",
    "cpu://<session-id>/<capture-id>",
    "screenshot://<session-id>/<capture-id>.png",
    "native-handoff://<session-id>/ios",
    "native-handoff://<session-id>/android",
  ];

  for (const uri of expectedUris) {
    if (!tokens.has(uri)) {
      throw new Error(`Resource URI scheme is missing ${uri}`);
    }
  }
}

async function checkResourceMetadataRetention(repoRoot: string): Promise<void> {
  const markdown = await readRepoText(repoRoot, "docs/05-session-and-resources.md");
  const metadata = extractJsonCodeBlock<Record<string, unknown>>(markdown, "## 8. Resource metadata");
  for (const key of ["uri", "mimeType", "title", "description", "sizeBytes", "createdAt", "sessionId"]) {
    if (!(key in metadata)) {
      throw new Error(`Resource metadata example is missing key: ${key}`);
    }
  }

  const metadataRetention = extractBulletItems(markdown, "### Metadata retention");
  const heavyRetention = extractBulletItems(markdown, "### Heavy artifacts retention");
  const currentImplementation = extractBulletItems(markdown, "### Current implementation");
  const capacityManagement = extractBulletItems(markdown, "### Future capacity management");

  for (const item of ["session metadata: 30 days", "audit log: 30 days"]) {
    if (!metadataRetention.includes(item)) {
      throw new Error(`Metadata retention is missing ${item}`);
    }
  }

  for (const item of [
    "stdout/stderr: 7 days",
    "widget trees / runtime errors: 7 days",
    "test reports / coverage: 14 days",
    "profiles / timelines / memory snapshots: 7 days",
    "screenshots: 7 days",
  ]) {
    if (!heavyRetention.includes(item)) {
      throw new Error(`Heavy artifacts retention is missing ${item}`);
    }
  }

  for (const item of [
    "server startup 時に age-based retention sweep を実行",
    "pinned artifact は sweep 対象から外す",
    "stale pin entry は unpin されるまで保持する",
  ]) {
    if (!currentImplementation.includes(item)) {
      throw new Error(`Current implementation retention is missing ${item}`);
    }
  }

  for (const item of [
    "workspace 単位で容量上限を持つ",
    "上限超過時は LRU で削除",
    "pinned artifact は削除対象から外す",
  ]) {
    if (!capacityManagement.includes(item)) {
      throw new Error(`Capacity management is missing ${item}`);
    }
  }
}

const CHECKS: Record<CheckName, (repoRoot: string, harnessRoot: string) => Promise<void>> = {
  "mkdocs-build": (repoRoot, harnessRoot) => checkMkDocsBuild(repoRoot, harnessRoot),
  "readme-nav-links": (repoRoot) => checkReadmeNavLinks(repoRoot),
  "phase0-foundation": (repoRoot) =>
    checkRequiredStrings(
      repoRoot,
      "docs/07-roadmap.md",
      [
        "## Phase 0 — Foundation",
        "`workspace_show`",
        "`session_open`",
        "`session_list`",
        "`workspace_set_root`",
        "`serverInfo` / capability negotiation",
      ],
      "Phase 0 roadmap",
    ),
  "sprint1-minimum": (repoRoot) =>
    checkRequiredStrings(
      repoRoot,
      "docs/09-implementation-plan.md",
      [
        "### Sprint 1",
        "repo bootstrap",
        "stdio MCP server skeleton",
        "tool registry",
        "`workspace_show`",
        "`workspace_set_root`",
        "`session_open`",
        "config loading",
      ],
      "Sprint 1 plan",
    ),
  "core-principles": (repoRoot) =>
    checkRequiredStrings(
      repoRoot,
      "README.md",
      [
        "FlutterHelm は、これらを置き換えるものではありません。",
        "Replace ではなく compose",
        "Session-first",
        "Resource-first",
        "Safe-by-default",
        "Workflow-grouped",
      ],
      "README core principles",
    ),
  "workflow-groups": (repoRoot) => checkWorkflowGroups(repoRoot),
  "tool-risk-catalog": (repoRoot) => checkToolRiskCatalog(repoRoot),
  "approval-contract": (repoRoot) => checkApprovalContract(repoRoot),
  "safety-root-fallback": (repoRoot) => checkSafetyRootFallback(repoRoot),
  "session-contract": (repoRoot) => checkSessionContract(repoRoot),
  "resource-uri-contract": (repoRoot) => checkResourceUriContract(repoRoot),
  "resource-metadata-retention": (repoRoot) => checkResourceMetadataRetention(repoRoot),
  "phase0-server-smoke": (repoRoot) => checkPhase0ServerSmoke(repoRoot),
  "phase0-tool-exposure": (repoRoot) => checkPhase0ToolExposure(repoRoot),
  "phase0-root-session-flow": (repoRoot) => checkPhase0RootSessionFlow(repoRoot),
  "phase0-audit-log": (repoRoot) => checkPhase0AuditLog(repoRoot),
  "phase1-tool-exposure": (repoRoot) => checkPhase1ToolExposure(repoRoot),
  "phase1-sample-app-flow": (repoRoot) => checkPhase1SampleAppFlow(repoRoot),
  "phase1-runtime-overflow-flow": (repoRoot) => checkPhase1RuntimeOverflowFlow(repoRoot),
  "phase3-profiling-flow": (repoRoot) => checkPhase3ProfilingFlow(repoRoot),
  "phase4-platform-bridge-flow": (repoRoot) => checkPhase4PlatformBridgeFlow(repoRoot),
  "phase5-runtime-interaction-flow": (repoRoot) => checkPhase5RuntimeInteractionFlow(repoRoot),
  "phase6-hardening-docs": (repoRoot) => checkPhase6HardeningDocs(repoRoot),
  "phase6-hardening-flow": (repoRoot) => checkPhase6HardeningFlow(repoRoot),
  "phase6-ecosystem-docs": (repoRoot) => checkPhase6EcosystemDocs(repoRoot),
  "phase6-ecosystem-flow": (repoRoot) => checkPhase6EcosystemFlow(repoRoot),
};

async function main(): Promise<void> {
  const harnessRoot = process.cwd();
  const repoRoot = process.env.HARNESS_REPO_ROOT ?? resolveRepoRoot(harnessRoot);
  const caseId = process.env.HARNESS_CASE_ID ?? "docs-contract";
  const input = JSON.parse(process.env.HARNESS_CASE_INPUT ?? "{}") as ContractCaseInput;
  const checks = input.checks ?? [];

  if (checks.length === 0) {
    console.error("No checks configured for docs-contract target.");
    process.exitCode = 1;
    return;
  }

  for (const check of checks) {
    const runCheck = CHECKS[check];
    if (!runCheck) {
      console.error(`Unknown docs-contract check: ${check}`);
      process.exitCode = 1;
      return;
    }

    console.log(`check:${check}:start`);
    try {
      await runCheck(repoRoot, harnessRoot);
      console.log(`check:${check}:ok`);
    } catch (error) {
      console.error(`check:${check}:fail`);
      console.error(error instanceof Error ? error.message : String(error));
      process.exitCode = 1;
      return;
    }
  }

  console.log(`summary:${caseId}`);
}

void main();
