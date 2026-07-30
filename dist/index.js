import { mkdir, writeFile, readFile } from "node:fs/promises";
import path from "node:path";
import os from "node:os";
import { ALLOWLISTED_CONFIG_KEYS } from "./types.js";
function isObject(value) {
    return typeof value === "object" && value !== null && !Array.isArray(value);
}
function getLogger(input) {
    if (input.client?.app?.log && typeof input.client.app.log === "function") {
        return (message, ...args) => {
            input.client.app.log(`[arcode] ${message}`, ...args);
        };
    }
    return (message, ...args) => {
        console.log(`[arcode] ${message}`, ...args);
    };
}
function isGitHubHost(url) {
    try {
        const parsed = new URL(url);
        return (parsed.hostname === "github.com" ||
            parsed.hostname === "raw.githubusercontent.com");
    }
    catch {
        return false;
    }
}
async function fetchManifest(url, token, timeoutMs) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    try {
        const headers = {};
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
    }
    catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        return { ok: false, reason: message };
    }
    finally {
        clearTimeout(timer);
    }
}
async function loadCache(cacheDir) {
    const cachePath = path.join(cacheDir, "manifest.json");
    try {
        const text = await readFile(cachePath, "utf-8");
        const parsed = JSON.parse(text);
        if (isObject(parsed) && typeof parsed.version === "number") {
            return parsed;
        }
        return undefined;
    }
    catch {
        return undefined;
    }
}
function filterValidEntries(section, log) {
    const valid = {};
    for (const [name, value] of Object.entries(section)) {
        if (isObject(value)) {
            valid[name] = value;
        }
        else {
            log(`Skipping malformed entry "${name}"`);
        }
    }
    return valid;
}
function injectConfig(cfg, manifestConfig, log) {
    for (const key of Object.keys(manifestConfig)) {
        if (ALLOWLISTED_CONFIG_KEYS.includes(key)) {
            cfg[key] = manifestConfig[key];
        }
        else {
            log(`Skipping non-allowlisted manifest.config key "${key}"`);
        }
    }
}
function injectManifest(cfg, manifest, log) {
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
export default async function arcodeOpencodeConfigPlugin(input, options) {
    const log = getLogger(input);
    const manifestUrl = options?.manifestUrl;
    const token = options?.token || process.env.GITHUB_TOKEN;
    const timeoutMs = options?.timeoutMs ?? 5000;
    const cacheDir = options?.cacheDir || path.join(os.homedir(), ".cache", "arcode-opencode-config");
    return {
        config: async (cfg) => {
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
                        const manifest = parsed;
                        try {
                            await mkdir(cacheDir, { recursive: true });
                            await writeFile(path.join(cacheDir, "manifest.json"), result.text, "utf-8");
                        }
                        catch (cacheErr) {
                            const msg = cacheErr instanceof Error ? cacheErr.message : String(cacheErr);
                            log(`Failed to write manifest cache: ${msg}`);
                        }
                        injectManifest(cfg, manifest, log);
                        log(`Injected manifest from ${manifestUrl}`);
                        return;
                    }
                    catch (parseErr) {
                        const msg = parseErr instanceof Error ? parseErr.message : String(parseErr);
                        log(`Failed to parse manifest: ${msg}. Falling back to cache.`);
                    }
                }
                else {
                    log(`Failed to fetch manifest: ${result.reason}. Falling back to cache.`);
                }
            }
            catch (err) {
                const msg = err instanceof Error ? err.message : String(err);
                log(`Unexpected error in arcode-opencode-config config hook: ${msg}. Falling back to cache.`);
            }
            try {
                const cached = await loadCache(cacheDir);
                if (cached) {
                    injectManifest(cfg, cached, log);
                    log("Injected manifest from cache");
                }
                else {
                    log("No manifest cache available; leaving config unchanged");
                }
            }
            catch (cacheErr) {
                const msg = cacheErr instanceof Error ? cacheErr.message : String(cacheErr);
                log(`Failed to load manifest cache: ${msg}; leaving config unchanged`);
            }
        },
    };
}
