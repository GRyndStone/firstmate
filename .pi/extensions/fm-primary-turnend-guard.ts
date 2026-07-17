import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { lstatSync, mkdirSync, readFileSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { dirname, isAbsolute, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

let guardFollowupDeliveryActive = false;
let guardFollowupAwaitingAck = "";
let guardFollowupRetryTimer: ReturnType<typeof setTimeout> | undefined;
let guardFollowupPendingMessage = "";
let guardFollowupCleanupPending = false;

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

function primaryCheckout(): boolean {
  const result = spawnSync("git", ["-C", root, "rev-parse", "--git-dir", "--git-common-dir"], { encoding: "utf8" });
  if (result.status !== 0) return false;
  const paths = result.stdout.trim().split("\n");
  return paths.length === 2 && paths[0] === paths[1];
}

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
  try {
    rejectSymlinkedComponents(fmHome, state);
  } catch {
    return;
  }
  mkdirSync(state, { recursive: true });
  writeFileSync(marker, `${extensionVersion}\n${process.pid}\n`);
}

function runGuard(): Promise<{ code: number; stderr: string }> {
  return new Promise((resolveResult) => {
    let settled = false;
    const finish = (result: { code: number; stderr: string }) => {
      if (settled) return;
      settled = true;
      resolveResult(result);
    };
    const child = spawn(`${root}/bin/fm-turnend-guard.sh`, {
      stdio: ["pipe", "ignore", "pipe"],
    });
    let stderr = "";
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.stdin.on("error", () => {});
    child.on("error", (error) => finish({ code: 125, stderr: error.message }));
    child.on("close", (code) => finish({ code: code ?? 125, stderr }));
    child.stdin.end('{"stop_hook_active":false}');
  });
}

type Handoff = { record: string; token: string; message: string };

function rejectSymlinkedComponents(base: string, target: string): void {
  const scopedBase = resolve(base);
  const scopedTarget = resolve(target);
  const suffix = relative(scopedBase, scopedTarget);
  if (suffix.startsWith("..") || isAbsolute(suffix)) return;
  let cursor = scopedBase;
  const baseInfo = lstatSync(cursor);
  if (baseInfo.isSymbolicLink() || !baseInfo.isDirectory()) throw new Error("unsafe Firstmate home directory");
  for (const component of suffix.split(/[\\/]/).filter(Boolean)) {
    cursor = resolve(cursor, component);
    const info = lstatSync(cursor);
    if (info.isSymbolicLink()) throw new Error("symlinked Firstmate state path component");
  }
}

function safeHandoffDirectory(create = false): void {
  rejectSymlinkedComponents(fmHome, state);
  const stateInfo = lstatSync(state);
  if (stateInfo.isSymbolicLink() || !stateInfo.isDirectory()) throw new Error("unsafe Firstmate state directory");
  try {
    const dirInfo = lstatSync(handoffDir);
    if (dirInfo.isSymbolicLink() || !dirInfo.isDirectory()) throw new Error("unsafe Firstmate handoff directory");
  } catch (error) {
    if (typeof error !== "object" || error === null || !("code" in error) || error.code !== "ENOENT" || !create) throw error;
    mkdirSync(handoffDir, { mode: 0o700 });
    const dirInfo = lstatSync(handoffDir);
    if (dirInfo.isSymbolicLink() || !dirInfo.isDirectory()) throw new Error("unsafe Firstmate handoff directory");
  }
}

function readHandoffRecord(): string {
  safeHandoffDirectory();
  const info = lstatSync(handoffPath);
  if (info.isSymbolicLink() || !info.isFile()) throw new Error("unsafe Firstmate handoff record");
  return readFileSync(handoffPath, "utf8").trim();
}

function readHandoff(): Handoff | undefined {
  try {
    const record = readHandoffRecord();
    const parsed = JSON.parse(record) as { token?: unknown; message?: unknown };
    if (typeof parsed.token !== "string" || typeof parsed.message !== "string") return undefined;
    return { record, token: parsed.token, message: parsed.message };
  } catch {
    return undefined;
  }
}

function persistHandoff(message: string): Handoff {
  if (lockOwnership() !== "owned") throw new Error("Firstmate session lock is not owned");
  safeHandoffDirectory(true);
  try {
    const info = lstatSync(handoffPath);
    if (info.isSymbolicLink() || !info.isFile()) throw new Error("unsafe Firstmate handoff record");
  } catch (error) {
    if (typeof error !== "object" || error === null || !("code" in error) || error.code !== "ENOENT") throw error;
  }
  handoffSequence += 1;
  const token = `${process.pid}-${Date.now()}-${handoffSequence}`;
  const record = JSON.stringify({ token, message });
  const temp = `${handoffPath}.tmp.${token}`;
  writeFileSync(temp, `${record}\n`, { mode: 0o600, flag: "wx" });
  renameSync(temp, handoffPath);
  return { record, token, message };
}

function clearHandoff(record?: string): boolean {
  if (lockOwnership() !== "owned") return false;
  try {
    if (record !== undefined && readHandoffRecord() !== record) return false;
    unlinkSync(handoffPath);
  } catch (error) {
    if (typeof error !== "object" || error === null || !("code" in error) || error.code !== "ENOENT") return false;
  }
  try {
    readFileSync(handoffPath, "utf8");
    return false;
  } catch (error) {
    return typeof error === "object" && error !== null && "code" in error && error.code === "ENOENT";
  }
}

function handoffAbsent(): boolean {
  try {
    safeHandoffDirectory();
    lstatSync(handoffPath);
    return false;
  } catch (error) {
    return typeof error === "object" && error !== null && "code" in error && error.code === "ENOENT";
  }
}

function retryDelay(): number {
  const configured = Number(process.env.FM_TURNEND_HANDOFF_RETRY_MS ?? 30000);
  if (!Number.isFinite(configured)) return 30000;
  return Math.max(10, Math.min(300000, Math.trunc(configured)));
}

function cancelRetryOwner(): void {
  if (guardFollowupRetryTimer !== undefined) clearTimeout(guardFollowupRetryTimer);
  guardFollowupRetryTimer = undefined;
}

function ensureHandoff(): Handoff | undefined {
  if (guardFollowupPendingMessage) {
    try {
      const handoff = persistHandoff(guardFollowupPendingMessage);
      guardFollowupPendingMessage = "";
      return handoff;
    } catch {
      return undefined;
    }
  }
  return readHandoff();
}

function scheduleDelivery(pi: ExtensionAPI, delay = retryDelay()): void {
  if (lockOwnership() !== "owned") {
    cancelRetryOwner();
    return;
  }
  if (guardFollowupRetryTimer !== undefined
    || (!readHandoff() && !guardFollowupPendingMessage && !guardFollowupCleanupPending)) return;
  guardFollowupRetryTimer = setTimeout(() => {
    guardFollowupRetryTimer = undefined;
    deliverHandoff(pi);
  }, delay);
}

function deliverHandoff(pi: ExtensionAPI): void {
  if (lockOwnership() !== "owned") {
    cancelRetryOwner();
    return;
  }
  if (guardFollowupDeliveryActive) return;
  if (guardFollowupCleanupPending) {
    acknowledgeHandoff();
    if (guardFollowupCleanupPending || readHandoff()) scheduleDelivery(pi);
    return;
  }
  const handoff = ensureHandoff();
  if (!handoff) {
    scheduleDelivery(pi);
    return;
  }
  guardFollowupDeliveryActive = true;
  try {
    pi.sendUserMessage(handoff.message, { deliverAs: "followUp" });
    guardFollowupAwaitingAck = handoff.token;
  } catch {
    guardFollowupAwaitingAck = "";
  } finally {
    guardFollowupDeliveryActive = false;
    scheduleDelivery(pi);
  }
}

function acknowledgeHandoff(): void {
  if (lockOwnership() !== "owned") {
    cancelRetryOwner();
    return;
  }
  const handoff = readHandoff();
  if (!handoff) {
    if (handoffAbsent()) {
      guardFollowupAwaitingAck = "";
      guardFollowupPendingMessage = "";
      guardFollowupCleanupPending = false;
      cancelRetryOwner();
    }
    return;
  }
  if (handoff.token !== guardFollowupAwaitingAck) {
    guardFollowupCleanupPending = false;
    guardFollowupAwaitingAck = "";
    return;
  }
  if (!clearHandoff(handoff.record)) {
    guardFollowupCleanupPending = true;
    return;
  }
  guardFollowupAwaitingAck = "";
  guardFollowupPendingMessage = "";
  guardFollowupCleanupPending = false;
  cancelRetryOwner();
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
  const inPrimaryCheckout = primaryCheckout();

  if (inPrimaryCheckout) {
    pi.on?.("session_start", () => {
      if (lockOwnership() !== "owned") {
        cancelRetryOwner();
        return;
      }
      markLoaded();
      scheduleDelivery(pi, 0);
    });

    pi.on?.("agent_start", () => {
      if (lockOwnership() !== "owned") {
        cancelRetryOwner();
        return;
      }
      guardFollowupCleanupPending = true;
      acknowledgeHandoff();
      if (guardFollowupCleanupPending || readHandoff()) scheduleDelivery(pi);
    });
  }

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

  if (inPrimaryCheckout) {
    pi.on("agent_settled", async () => {
      if (lockOwnership() !== "owned") {
        cancelRetryOwner();
        return;
      }
      const result = await runGuard();
      if (lockOwnership() !== "owned") {
        cancelRetryOwner();
        return;
      }
      if (result.code === 0) {
        const retained = readHandoff();
        if (!clearHandoff()) {
          if (retained) guardFollowupAwaitingAck = retained.token;
          guardFollowupCleanupPending = true;
          scheduleDelivery(pi);
          return;
        }
        guardFollowupAwaitingAck = "";
        guardFollowupPendingMessage = "";
        guardFollowupCleanupPending = false;
        cancelRetryOwner();
        return;
      }
      const detail = result.stderr.trim();
      const reason = result.code === 2
        ? detail || "shared turn-end guard blocked"
        : `shared turn-end guard failed with exit ${result.code}${detail ? `: ${detail}` : ""}`;
      const message =
        "TURN WOULD END BLIND - supervision is off. " +
        "Resume supervision according to the session-start operating block before ending the turn.\n\n" +
        reason;
      guardFollowupPendingMessage = message;
      guardFollowupAwaitingAck = "";
      guardFollowupCleanupPending = false;
      cancelRetryOwner();
      deliverHandoff(pi);
    });

    markLoaded();
    if (lockOwnership() === "owned") scheduleDelivery(pi, 0);
  }
}
