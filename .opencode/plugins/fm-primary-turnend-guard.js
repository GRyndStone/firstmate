import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, realpathSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

const COORDINATOR_KEY = "__firstmateOpenCodeWatchArm";
const followupDeliveryActive = new Set();
let handoffSequence = 0;

function runProcess(command, args, input = "") {
  return new Promise((resolve) => {
    const child = spawn(command, args, {
      stdio: ["pipe", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", () => resolve({ code: 0, stdout: "", stderr: "" }));
    child.on("close", (code) => resolve({ code: code ?? 0, stdout, stderr }));
    child.stdin.end(input);
  });
}

async function resolveRoot(anchor) {
  if (!anchor) return "";
  const result = await runProcess("git", ["-C", anchor, "rev-parse", "--show-toplevel"]);
  const root = result.stdout.trim();
  if (result.code === 0 && root) return root;
  return resolvePath(anchor);
}

function resolvePath(anchor) {
  try {
    return realpathSync(anchor);
  } catch {
    return resolve(anchor);
  }
}

function runGuard(root) {
  if (!root) return Promise.resolve({ code: 0, stderr: "" });
  return runProcess(`${root}/bin/fm-turnend-guard.sh`, [], '{"stop_hook_active":false}');
}

function handoffPath(root, sessionID) {
  const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
  const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
  const key = createHash("sha256").update(sessionID).digest("hex").slice(0, 24);
  return { dir: `${state}/.turnend-handoffs`, path: `${state}/.turnend-handoffs/opencode-${key}.pending` };
}

function persistHandoff(root, sessionID, message) {
  const handoff = handoffPath(root, sessionID);
  mkdirSync(handoff.dir, { recursive: true });
  handoffSequence += 1;
  const token = `${process.pid}-${Date.now()}-${handoffSequence}`;
  const record = JSON.stringify({ token, sessionID, message });
  const temp = `${handoff.path}.tmp.${token}`;
  writeFileSync(temp, `${record}\n`, { mode: 0o600 });
  renameSync(temp, handoff.path);
  return { ...handoff, record };
}

function clearHandoff(root, sessionID, record) {
  const handoff = handoffPath(root, sessionID);
  try {
    if (record !== undefined && readFileSync(handoff.path, "utf8").trim() !== record) return;
    unlinkSync(handoff.path);
  } catch {
  }
}

async function deliverHandoff(client, sessionID, message, handoff) {
  let failure;
  for (let attempt = 0; attempt < 2; attempt += 1) {
    try {
      await client.session.promptAsync({
        path: { id: sessionID },
        body: { parts: [{ type: "text", text: message }] },
      });
      try {
        if (readFileSync(handoff.path, "utf8").trim() === handoff.record) unlinkSync(handoff.path);
      } catch {
      }
      return;
    } catch (error) {
      failure = error;
      if (attempt === 0) await new Promise((resolveDelay) => setTimeout(resolveDelay, 100));
    }
  }
  throw failure instanceof Error ? failure : new Error("turn-end continuation delivery failed");
}

async function letWatchArmRun(sessionID, client) {
  const coordinator = globalThis[COORDINATOR_KEY];
  if (!coordinator?.ensureArmed) return false;
  const status = await coordinator.ensureArmed(sessionID, client);
  return status === "armed" || status === "wake" || status === "failed";
}

export const FmPrimaryTurnendGuard = async ({ client, directory, worktree }) => {
  const root = worktree ? resolvePath(worktree) : await resolveRoot(directory);

  return {
    event: async ({ event }) => {
      if (event.type !== "session.idle") return;

      const sessionID = event.properties?.sessionID;
      if (!sessionID) return;

      await letWatchArmRun(sessionID, client);

      const result = await runGuard(root);
      if (result.code !== 2) {
        clearHandoff(root, sessionID);
        return;
      }
      const message =
        "TURN WOULD END BLIND - supervision is off. " +
        "Resume supervision according to the session-start operating block before ending the turn.\n\n" +
        result.stderr;
      const handoff = persistHandoff(root, sessionID, message);
      if (followupDeliveryActive.has(sessionID)) return;
      followupDeliveryActive.add(sessionID);

      try {
        await deliverHandoff(client, sessionID, message, handoff);
      } finally {
        followupDeliveryActive.delete(sessionID);
      }
    },
  };
};
