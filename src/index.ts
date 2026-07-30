import { mkdir, writeFile, readFile } from "node:fs/promises";
import path from "node:path";
import os from "node:os";
import type {
  PluginInput,
  PluginOptions,
  Hooks,
  Config,
  AgentManifest,
} from "./types.js";
import { ALLOWLISTED_CONFIG_KEYS } from "./types.js";

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function getLogger(input: PluginInput): (message: string, ...args: unknown[]) => void {
  if (input.client?.app?.log && typeof input.client.app.log === "function") {
    return (message: string, ...args: unknown[]) => {
      input.client.app.log(`[arcode] ${message}`, ...args);
    };
  }
  return (message: string, ...args: unknown[]) => {
    console.log(`[arcode] ${message}`, ...args);
  };
}

function isGitHubHost(url: string): boolean {
  try {
    const parsed = new URL(url);
    return (
      parsed.hostname === "github.com" ||
      parsed.hostname === "raw.githubusercontent.com"
    );
  } catch {
    return false;
  }
}

async function fetchManifest(
  url: string,
  token: string | undefined,
  timeoutMs: number
): Promise<{ ok: true; text: string } | { ok: false; reason: string }> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const headers: Record<string, string> = {};
    if (token) {
      headers["Authorization"] = `Bearer ${token}`;
    }
    if (isGitHubHost(url)) {
      headers["Accept"] = "application/vnd.github.raw+json";
    }
    const response = await fetch(url, {
      signal: controller.signal,
      headers,
    });
    if (!response.ok) {
      return { ok: false, reason: `HTTP ${response.status} ${response.statusText}` };
    }
    const text = await response.text();
    return { ok: true, text };
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return { ok: false, reason: message };
  } finally {
    clearTimeout(timer);
  }
}

async function loadCache(cacheDir: string): Promise<AgentManifest | undefined> {
  const cachePath = path.join(cacheDir, "manifest.json");
  try {
    const text = await readFile(cachePath, "utf-8");
    const parsed = JSON.parse(text);
    if (isObject(parsed) && typeof parsed.version === "number") {
      return parsed as unknown as AgentManifest;
    }
    return undefined;
  } catch {
    return undefined;
  }
}

function filterValidEntries(
  section: Record<string, unknown>,
  log: (message: string) => void
): Record<string, Record<string, unknown>> {
  const valid: Record<string, Record<string, unknown>> = {};
  for (const [name, value] of Object.entries(section)) {
    if (isObject(value)) {
      valid[name] = value;
    } else {
      log(`Skipping malformed entry "${name}"`);
    }
  }
  return valid;
}

function injectConfig(
  cfg: Config,
  manifestConfig: Record<string, unknown>,
  log: (message: string) => void
): void {
  for (const key of Object.keys(manifestConfig)) {
    if ((ALLOWLISTED_CONFIG_KEYS as readonly string[]).includes(key)) {
      cfg[key] = manifestConfig[key];
    } else {
      log(`Skipping non-allowlisted manifest.config key "${key}"`);
    }
  }
}

function injectManifest(
  cfg: Config,
  manifest: AgentManifest,
  log: (message: string) => void
): void {
  if (manifest.config && isObject(manifest.config)) {
    injectConfig(cfg, manifest.config, log);
  }

  if (manifest.agents && isObject(manifest.agents)) {
    const validAgents = filterValidEntries(manifest.agents, log);
    cfg.agent = { ...cfg.agent, ...validAgents };
  }

  if (manifest.mcp && isObject(manifest.mcp)) {
    const validMcp = filterValidEntries(manifest.mcp, log);
    cfg.mcp = { ...cfg.mcp, ...validMcp };
  }
}

export default async function arcodeOpencodeConfigPlugin(
  input: PluginInput,
  options?: PluginOptions
): Promise<Hooks> {
  const log = getLogger(input);

  const manifestUrl = options?.manifestUrl;
  const token = options?.token || process.env.GITHUB_TOKEN;
  const timeoutMs = options?.timeoutMs ?? 5000;
  const cacheDir = options?.cacheDir || path.join(os.homedir(), ".cache", "arcode-opencode-config");

  return {
    config: async (cfg: Config): Promise<void> => {
      try {
        if (!manifestUrl) {
          log("manifestUrl option is required; leaving config unchanged");
          return;
        }

        const result = await fetchManifest(manifestUrl, token, timeoutMs);

        if (result.ok) {
          try {
            const parsed = JSON.parse(result.text);
            if (!isObject(parsed) || typeof parsed.version !== "number") {
              throw new Error("Manifest must be an object with a numeric version");
            }
            const manifest = parsed as unknown as AgentManifest;

            try {
              await mkdir(cacheDir, { recursive: true });
              await writeFile(
                path.join(cacheDir, "manifest.json"),
                result.text,
                "utf-8"
              );
            } catch (cacheErr) {
              const msg = cacheErr instanceof Error ? cacheErr.message : String(cacheErr);
              log(`Failed to write manifest cache: ${msg}`);
            }

            injectManifest(cfg, manifest, log);
            log(`Injected manifest from ${manifestUrl}`);
            return;
          } catch (parseErr) {
            const msg = parseErr instanceof Error ? parseErr.message : String(parseErr);
            log(`Failed to parse manifest: ${msg}. Falling back to cache.`);
          }
        } else {
          log(`Failed to fetch manifest: ${result.reason}. Falling back to cache.`);
        }
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        log(`Unexpected error in arcode-opencode-config config hook: ${msg}. Falling back to cache.`);
      }

      try {
        const cached = await loadCache(cacheDir);
        if (cached) {
          injectManifest(cfg, cached, log);
          log("Injected manifest from cache");
        } else {
          log("No manifest cache available; leaving config unchanged");
        }
      } catch (cacheErr) {
        const msg = cacheErr instanceof Error ? cacheErr.message : String(cacheErr);
        log(`Failed to load manifest cache: ${msg}; leaving config unchanged`);
      }
    },
  };
}
