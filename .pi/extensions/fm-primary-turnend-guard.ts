import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

let guardFollowupDeliveryActive = false;

type LockOwnership = "owned" | "missing" | "other";

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const root = resolve(extensionDir, "../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
const marker = `${state}/.pi-turnend-extension-loaded`;
const handoffDir = `${state}/.turnend-handoffs`;
const handoffPath = `${handoffDir}/pi.pending`;
const extensionVersion = `sha256:${createHash("sha256").update(readFileSync(extensionFile)).digest("hex")}`;
let handoffSequence = 0;

function parentPid(pid: string): string {
  const result = spawnSync("ps", ["-o", "ppid=", "-p", pid], { encoding: "utf8" });
  if (result.status !== 0) return "";
  return result.stdout.trim();
}

function pidAlive(pid: string): boolean {
  try {
    process.kill(Number(pid), 0);
    return true;
  } catch {
    return false;
  }
}

function lockOwnership(): LockOwnership {
  let lockPid = "";
  try {
    lockPid = readFileSync(`${state}/.lock`, "utf8").trim();
  } catch {
    return "missing";
  }
  if (!/^[0-9]+$/.test(lockPid) || lockPid === "1") return "other";
  let pid = String(process.pid);
  for (let i = 0; i < 8; i += 1) {
    if (pid === lockPid) return "owned";
    pid = parentPid(pid);
    if (!pid || pid === "1") break;
  }
  return pidAlive(lockPid) ? "other" : "missing";
}

function markLoaded(): void {
  if (lockOwnership() === "other") return;
  mkdirSync(state, { recursive: true });
  writeFileSync(marker, `${extensionVersion}\n${process.pid}\n`);
}

function runGuard(): Promise<{ code: number; stderr: string }> {
  return new Promise((resolveResult) => {
    const child = spawn(`${root}/bin/fm-turnend-guard.sh`, {
      stdio: ["pipe", "ignore", "pipe"],
    });
    let stderr = "";
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", () => resolveResult({ code: 0, stderr: "" }));
    child.on("close", (code) => resolveResult({ code: code ?? 0, stderr }));
    child.stdin.end('{"stop_hook_active":false}');
  });
}

function persistHandoff(message: string): string {
  mkdirSync(handoffDir, { recursive: true });
  handoffSequence += 1;
  const token = `${process.pid}-${Date.now()}-${handoffSequence}`;
  const record = JSON.stringify({ token, message });
  const temp = `${handoffPath}.tmp.${token}`;
  writeFileSync(temp, `${record}\n`, { mode: 0o600 });
  renameSync(temp, handoffPath);
  return record;
}

function clearHandoff(record?: string): void {
  try {
    if (record !== undefined && readFileSync(handoffPath, "utf8").trim() !== record) return;
    unlinkSync(handoffPath);
  } catch {
  }
}

async function deliverHandoff(pi: ExtensionAPI, record: string, message: string): Promise<void> {
  let failure: unknown;
  for (let attempt = 0; attempt < 2; attempt += 1) {
    try {
      await pi.sendUserMessage(message, { deliverAs: "followUp" });
      clearHandoff(record);
      return;
    } catch (error) {
      failure = error;
      if (attempt === 0) await new Promise((resolveDelay) => setTimeout(resolveDelay, 100));
    }
  }
  throw failure instanceof Error ? failure : new Error("turn-end continuation delivery failed");
}

// PreToolUse seatbelts (bin/fm-arm-pretool-check.sh, docs/arm-pretool-check.md;
// bin/fm-cd-pretool-check.sh, docs/cd-guard.md). Both piggyback on this same
// extension file rather than separate ones so no extra Pi -e flag is needed at
// launch - the primary already loads this file for the turn-end guard, and
// pi.on("tool_call", ...) can block (verified 2026-07-09 against pi 0.80.5:
// returning {block: true} prevents the bash command from running). Each owner
// script owns its own decision and is inert outside the real primary checkout.
function runChecker(script: string, command: string): Promise<{ code: number; stderr: string }> {
  return new Promise((resolveResult) => {
    const child = spawn(`${root}/bin/${script}`, ["--command", command], {
      stdio: ["ignore", "ignore", "pipe"],
    });
    let stderr = "";
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", () => resolveResult({ code: 0, stderr: "" }));
    child.on("close", (code) => resolveResult({ code: code ?? 0, stderr }));
  });
}

function runPretoolCheck(command: string): Promise<{ code: number; stderr: string }> {
  return runChecker("fm-arm-pretool-check.sh", command);
}

function runCdCheck(command: string): Promise<{ code: number; stderr: string }> {
  return runChecker("fm-cd-pretool-check.sh", command);
}

export default function (pi: ExtensionAPI) {
  pi.on?.("session_start", () => {
    markLoaded();
  });

  pi.on("tool_call", async (event) => {
    if (event.type !== "tool_call" || event.toolName !== "bash") return {};
    const command = String((event.input as { command?: unknown })?.command ?? "");
    if (!command) return {};
    const cdResult = await runCdCheck(command);
    if (cdResult.code === 2) {
      return { block: true, reason: cdResult.stderr.trim() || "denied by the cd-guard PreToolUse seatbelt" };
    }
    const result = await runPretoolCheck(command);
    if (result.code !== 2) return {};
    return { block: true, reason: result.stderr.trim() || "denied by the watcher-arm PreToolUse seatbelt" };
  });

  pi.on("agent_settled", async () => {
    const result = await runGuard();
    if (result.code !== 2) {
      clearHandoff();
      return;
    }
    const message =
      "TURN WOULD END BLIND - supervision is off. " +
      "Resume supervision according to the session-start operating block before ending the turn.\n\n" +
      result.stderr;
    const record = persistHandoff(message);
    if (guardFollowupDeliveryActive) return;
    guardFollowupDeliveryActive = true;
    try {
      await deliverHandoff(pi, record, message);
    } finally {
      guardFollowupDeliveryActive = false;
    }
  });

  markLoaded();
}
