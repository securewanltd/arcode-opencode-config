import http from "node:http";
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const projectRoot = path.resolve(__dirname, "..");
const cacheDir = path.join(projectRoot, "test", ".cache-test");
const manifestPath = path.join(projectRoot, "manifest.example.json");
const pluginPath = path.join(projectRoot, "dist", "index.js");

async function readManifest() {
  return await fs.readFile(manifestPath, "utf-8");
}

async function startServer(manifestText, status = 200) {
  return new Promise((resolve) => {
    const server = http.createServer((req, res) => {
      res.writeHead(status, { "Content-Type": "application/json" });
      res.end(manifestText);
    });
    server.listen(0, "127.0.0.1", () => {
      const { port } = server.address();
      resolve({ server, url: `http://127.0.0.1:${port}/manifest.json` });
    });
  });
}

function stopServer(server) {
  return new Promise((resolve, reject) => {
    server.close((err) => {
      if (err) reject(err);
      else resolve();
    });
  });
}

async function clearCache() {
  await fs.rm(cacheDir, { recursive: true, force: true });
}

async function assert(condition, message) {
  if (!condition) throw new Error(`Assertion failed: ${message}`);
}

async function createInput() {
  return {
    client: {
      app: {
        log: (msg, ...args) => console.log(msg, ...args),
      },
    },
    project: null,
    directory: projectRoot,
    worktree: null,
    $: null,
  };
}

async function loadPlugin() {
  const pluginFile = pathToFileURL(pluginPath).href;
  const module = await import(pluginFile);
  return module.default;
}

async function runTests() {
  const arcodeOpencodeConfig = await loadPlugin();
  const manifestText = await readManifest();

  // (a) + (b) Successful fetch writes cache and injects agents/MCP.
  await clearCache();
  const { server: server1, url: url1 } = await startServer(manifestText, 200);
  try {
    const hooks = await arcodeOpencodeConfig(await createInput(), { manifestUrl: url1, cacheDir });
    const cfg = {};
    await hooks.config(cfg);

    await assert(cfg.agent && cfg.agent.reviewer && cfg.agent.docs, "agents should be injected from fetch");
    await assert(
      cfg.mcp && cfg.mcp["github-remote"] && cfg.mcp["filesystem-local"],
      "MCP servers should be injected from fetch"
    );
    await assert(cfg.default_agent === "reviewer", "default_agent should be merged from manifest.config");

    const cacheFile = path.join(cacheDir, "manifest.json");
    const cacheContent = await fs.readFile(cacheFile, "utf-8");
    await assert(cacheContent === manifestText, "cache file should contain the raw manifest text");

    console.log("PASS: fetch success injects agents/MCP and writes cache");
  } finally {
    await stopServer(server1);
  }

  // (c) Fetch fails but cache exists => cfg populated from cache.
  const { server: server2, url: url2 } = await startServer(manifestText, 500);
  try {
    const hooks = await arcodeOpencodeConfig(await createInput(), { manifestUrl: url2, cacheDir });
    const cfg = {};
    await hooks.config(cfg);

    await assert(cfg.agent && cfg.agent.reviewer && cfg.agent.docs, "agents should be injected from cache");
    await assert(
      cfg.mcp && cfg.mcp["github-remote"] && cfg.mcp["filesystem-local"],
      "MCP servers should be injected from cache"
    );

    console.log("PASS: fetch failure falls back to cache");
  } finally {
    await stopServer(server2);
  }

  // (d) Fetch fails and no cache => cfg untouched and nothing throws.
  await clearCache();
  const { server: server3, url: url3 } = await startServer(manifestText, 500);
  try {
    const hooks = await arcodeOpencodeConfig(await createInput(), { manifestUrl: url3, cacheDir });
    const cfg = {};
    let threw = false;
    try {
      await hooks.config(cfg);
    } catch (e) {
      threw = true;
    }

    await assert(!threw, "config hook should not throw when fetch and cache both fail");
    await assert(Object.keys(cfg).length === 0, "cfg should remain untouched when no manifest is available");

    console.log("PASS: fetch failure with no cache leaves cfg untouched and does not throw");
  } finally {
    await stopServer(server3);
  }

  // (e) manifest.config allowlist merge: allowed keys set, non-allowlisted keys skipped.
  await clearCache();
  const configManifest = JSON.stringify({
    version: 1,
    config: {
      default_agent: "reviewer",
      model: "openai/gpt-5",
      small_model: "openai/gpt-5.4-mini",
      not_allowed: "should be skipped",
      also_bad: 123,
    },
    agents: {},
    mcp: {},
  });
  const { server: server4, url: url4 } = await startServer(configManifest, 200);
  try {
    const hooks = await arcodeOpencodeConfig(await createInput(), { manifestUrl: url4, cacheDir });
    const cfg = {};
    await hooks.config(cfg);

    await assert(cfg.default_agent === "reviewer", "default_agent should be set from manifest.config");
    await assert(cfg.model === "openai/gpt-5", "model should be set from manifest.config");
    await assert(cfg.small_model === "openai/gpt-5.4-mini", "small_model should be set from manifest.config");
    await assert(cfg.not_allowed === undefined, "non-allowlisted key should be skipped");
    await assert(cfg.also_bad === undefined, "non-allowlisted key should be skipped");

    console.log("PASS: manifest.config allowlist merge works");
  } finally {
    await stopServer(server4);
  }

  console.log("\nAll tests passed.");
}

runTests().catch((err) => {
  console.error("Test failed:", err);
  process.exit(1);
});
