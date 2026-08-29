#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const repo = path.resolve(__dirname, "..");
const source = fs.readFileSync(path.join(repo, "shell", "DockerPanel.qml"), "utf8");

function extractFunction(name) {
  const start = source.indexOf(`  function ${name}(`);
  if (start < 0) throw new Error(`missing QML function ${name}`);
  let depth = 0;
  let opened = false;
  for (let i = source.indexOf("{", start); i < source.length; i++) {
    if (source[i] === "{") { depth++; opened = true; }
    else if (source[i] === "}" && opened && --depth === 0) return source.slice(start + 2, i + 1);
  }
  throw new Error(`unterminated QML function ${name}`);
}

const definitions = ["contextOptions", "helperCommand", "dockerCommand", "updateInfo", "shellQuote", "openPort", "launchTool"]
  .map(extractFunction).join("\n");
const makeFunctions = new Function("ctx", `with (ctx) { ${definitions}; return { contextOptions, helperCommand, dockerCommand, updateInfo, openPort, launchTool }; }`);

const ctx = {
  panelScript: "/plugin/bin/docker-panel",
  selectedContext: "",
  effectiveContext: "remote-production",
  info: { context: "remote-production", marker: "current" },
  selectedContainer: null,
  currentView: "containers",
  inspectContainer: () => { throw new Error("unexpected inspection"); },
  launchedCommands: [],
  openTerminal(args) { this.launchedCommands.push(args); },
  detachedCommand: "",
  runDetached(command) { this.detachedCommand = command; }
};
const functions = makeFunctions(ctx);

const initialCtx = {
  panelScript: ctx.panelScript,
  effectiveContext: "",
  info: {},
  selectedContainer: null
};
const discovering = makeFunctions(initialCtx);
const initialProbe = discovering.helperCommand([]);
if (JSON.stringify(initialProbe) !== JSON.stringify([ctx.panelScript])) {
  throw new Error(`initial probe cannot discover the active Docker context: ${JSON.stringify(initialProbe)}`);
}
discovering.updateInfo(JSON.stringify({ context: "default", marker: "discovered", containers: [] }));
if (initialCtx.info.marker !== "discovered") {
  throw new Error("initial context discovery result was rejected as stale");
}

const helper = functions.helperCommand(["--prune"]);
if (JSON.stringify(helper) !== JSON.stringify([ctx.panelScript, "--context", ctx.effectiveContext, "--prune"])) {
  throw new Error(`helper action was not pinned to displayed context: ${JSON.stringify(helper)}`);
}

const docker = functions.dockerCommand(["stop", "abc123"]);
if (JSON.stringify(docker) !== JSON.stringify(["docker", "--context", ctx.effectiveContext, "stop", "abc123"])) {
  throw new Error(`Docker action was not pinned to displayed context: ${JSON.stringify(docker)}`);
}

functions.updateInfo(JSON.stringify({ context: "old-context", marker: "stale", containers: [] }));
if (ctx.info.marker !== "current") {
  throw new Error("late output from a previous context replaced current panel state");
}

for (const [tool, container, command] of [
  ["lazydocker", null, ["lazydocker"]],
  ["dive", { image: "registry.example/app:latest" }, ["dive", "registry.example/app:latest"]],
  ["trivy", { image: "registry.example/app:latest" }, ["trivy", "image", "registry.example/app:latest"]]
]) {
  functions.launchTool(tool, container);
  const launched = ctx.launchedCommands.pop();
  const expected = ["env", `DOCKER_CONTEXT=${ctx.effectiveContext}`, ...command];
  if (JSON.stringify(launched) !== JSON.stringify(expected)) {
    throw new Error(`${tool} was not pinned to displayed context: ${JSON.stringify(launched)}`);
  }
}

functions.openPort("8080;notify-send injected");
if (ctx.detachedCommand !== "xdg-open 'http://localhost:8080;notify-send injected'") {
  throw new Error(`published port was interpolated into a shell command without quoting: ${ctx.detachedCommand}`);
}

console.log("QML safety tests passed");
