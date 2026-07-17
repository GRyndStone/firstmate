import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, readdirSync, realpathSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { effectivePrimaryPaths, sessionOwnsLock } from "../lib/fm-primary-session-lock.js";

const COORDINATOR_KEY = "__firstmateOpenCodeWatchArm";
let handoffSequence = 0;

function runProcess(command, args, input = "") {
  return new Promise((resolve) => {
    let settled = false;
    const finish = (result) => {
      if (settled) return;
      settled = true;
      resolve(result);
    };
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
    child.stdin.on("error", () => {});
    child.on("error", (error) => finish({ code: 125, stdout: "", stderr: error.message }));
    child.on("close", (code) => finish({ code: code ?? 125, stdout, stderr }));
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

async function primaryCheckout(root) {
  const result = await runProcess("git", ["-C", root, "rev-parse", "--git-dir", "--git-common-dir"]);
  if (result.code !== 0) return false;
  const paths = result.stdout.trim().split("\n");
  return paths.length === 2 && paths[0] === paths[1];
}

function resolvePath(anchor) {
  try {
    return realpathSync(anchor);
  } catch {
    return resolve(anchor);
  }
}

function runGuard(root) {
  if (!root) return Promise.resolve({ code: 125, stderr: "firstmate root is unavailable" });
  return runProcess(`${root}/bin/fm-turnend-guard.sh`, [], '{"stop_hook_active":false}');
}

function handoffPath(root, sessionID) {
  const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
  const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
  const key = createHash("sha256").update(sessionID).digest("hex").slice(0, 24);
  return { dir: `${state}/.turnend-handoffs`, path: `${state}/.turnend-handoffs/opencode-${key}.pending` };
}

function persistHandoff(root, sessionID, message, generation) {
  const handoff = handoffPath(root, sessionID);
  mkdirSync(handoff.dir, { recursive: true });
  handoffSequence += 1;
  const token = `${process.pid}-${Date.now()}-${handoffSequence}`;
  const record = JSON.stringify({ token, sessionID, message, generation });
  const temp = `${handoff.path}.tmp.${token}`;
  writeFileSync(temp, `${record}\n`, { mode: 0o600 });
  renameSync(temp, handoff.path);
  return { ...handoff, record, token, sessionID, message, generation };
}

function readHandoff(root, sessionID) {
  const handoff = handoffPath(root, sessionID);
  try {
    const record = readFileSync(handoff.path, "utf8").trim();
    const parsed = JSON.parse(record);
    if (parsed?.sessionID !== sessionID || typeof parsed.token !== "string" || typeof parsed.message !== "string") return undefined;
    const generation = Number.isSafeInteger(parsed.generation) && parsed.generation >= 0 ? parsed.generation : 0;
    return { ...handoff, record, token: parsed.token, sessionID, message: parsed.message, generation };
  } catch {
    return undefined;
  }
}

function clearHandoff(root, sessionID, record) {
  const handoff = handoffPath(root, sessionID);
  try {
    if (record !== undefined && readFileSync(handoff.path, "utf8").trim() !== record) return false;
    unlinkSync(handoff.path);
  } catch (error) {
    if (error?.code !== "ENOENT") return false;
  }
  try {
    readFileSync(handoff.path, "utf8");
    return false;
  } catch (error) {
    return error?.code === "ENOENT";
  }
}

function retryDelay() {
  const configured = Number(process.env.FM_TURNEND_HANDOFF_RETRY_MS ?? 30000);
  if (!Number.isFinite(configured)) return 30000;
  return Math.max(10, Math.min(300000, Math.trunc(configured)));
}

function promptTimeout() {
  const configured = Number(process.env.FM_TURNEND_HANDOFF_PROMPT_TIMEOUT_MS ?? 15000);
  if (!Number.isFinite(configured)) return 15000;
  return Math.max(10, Math.min(300000, Math.trunc(configured)));
}

async function letWatchArmRun(sessionID, client) {
  const coordinator = globalThis[COORDINATOR_KEY];
  if (!coordinator?.ensureArmed) return false;
  const status = await coordinator.ensureArmed(sessionID, client);
  return status === "armed" || status === "wake" || status === "failed";
}

export const FmPrimaryTurnendGuard = async ({ client, directory, worktree }) => {
  const root = worktree ? resolvePath(worktree) : await resolveRoot(directory);
  if (!await primaryCheckout(root)) return { event: async () => {} };
  const paths = effectivePrimaryPaths(root);
  const deliveryFlights = new Map();
  const retryTimers = new Map();
  const pendingMessages = new Map();
  const acknowledgedRecords = new Map();
  const invocationGenerations = new Map();
  const satisfiedGenerations = new Map();
  const idleChains = new Map();

  const cancelRetryOwner = (sessionID) => {
    const timer = retryTimers.get(sessionID);
    if (timer) clearTimeout(timer);
    retryTimers.delete(sessionID);
  };

  const scheduleDelivery = (sessionID, delay = retryDelay()) => {
    if (retryTimers.has(sessionID)) return;
    const timer = setTimeout(() => {
      retryTimers.delete(sessionID);
      void deliverHandoff(sessionID);
    }, delay);
    retryTimers.set(sessionID, timer);
  };

  const ensureHandoff = (sessionID) => {
    const pending = pendingMessages.get(sessionID);
    if (pending !== undefined) {
      try {
        const handoff = persistHandoff(root, sessionID, pending.message, pending.generation);
        pendingMessages.delete(sessionID);
        return handoff;
      } catch {
        return undefined;
      }
    }
    return readHandoff(root, sessionID);
  };

  const settleDelivery = async (sessionID, flight, acknowledged) => {
    if (deliveryFlights.get(sessionID) !== flight) return;
    deliveryFlights.delete(sessionID);
    if (!await sessionOwnsLock(paths)) {
      cancelRetryOwner(sessionID);
      return;
    }
    if (acknowledged) {
      const satisfiedThrough = invocationGenerations.get(sessionID) ?? flight.handoff.generation;
      satisfiedGenerations.set(sessionID, satisfiedThrough);
      pendingMessages.delete(sessionID);
      const current = readHandoff(root, sessionID);
      const acknowledgedRecord = current && current.generation <= satisfiedThrough
        ? current.record
        : flight.handoff.record;
      acknowledgedRecords.set(sessionID, acknowledgedRecord);
      if (clearHandoff(root, sessionID, acknowledgedRecord)) {
        acknowledgedRecords.delete(sessionID);
        cancelRetryOwner(sessionID);
      }
    }
    if (!acknowledged || acknowledgedRecords.has(sessionID) || pendingMessages.has(sessionID) || readHandoff(root, sessionID)) {
      scheduleDelivery(sessionID);
    }
  };

  const startDelivery = async (sessionID, handoff) => {
    let resolveSettled;
    let timeout;
    const settled = new Promise((resolve) => { resolveSettled = resolve; });
    const flight = { handoff, settled };
    deliveryFlights.set(sessionID, flight);
    Promise.resolve()
      .then(() => client.session.promptAsync({
        path: { id: sessionID },
        body: { parts: [{ type: "text", text: handoff.message }] },
      }))
      .then(
        () => settleDelivery(sessionID, flight, true),
        () => settleDelivery(sessionID, flight, false),
      )
      .catch(() => {})
      .finally(() => resolveSettled());
    await Promise.race([
      settled,
      new Promise((resolve) => { timeout = setTimeout(resolve, promptTimeout()); }),
    ]);
    if (timeout) clearTimeout(timeout);
    if (deliveryFlights.get(sessionID) === flight) scheduleDelivery(sessionID);
  };

  const deliverHandoff = async (sessionID) => {
    if (!await sessionOwnsLock(paths)) {
      cancelRetryOwner(sessionID);
      return;
    }
    const acknowledgedRecord = acknowledgedRecords.get(sessionID);
    if (acknowledgedRecord !== undefined) {
      const current = readHandoff(root, sessionID);
      if (current && current.record !== acknowledgedRecord) {
        acknowledgedRecords.delete(sessionID);
      } else if (clearHandoff(root, sessionID, acknowledgedRecord)) {
        acknowledgedRecords.delete(sessionID);
        cancelRetryOwner(sessionID);
        return;
      } else {
        scheduleDelivery(sessionID);
        return;
      }
    }
    if (deliveryFlights.has(sessionID)) {
      scheduleDelivery(sessionID);
      return;
    }
    const handoff = ensureHandoff(sessionID);
    if (!handoff) {
      if (pendingMessages.has(sessionID)) scheduleDelivery(sessionID);
      else cancelRetryOwner(sessionID);
      return;
    }
    await startDelivery(sessionID, handoff);
  };

  if (await sessionOwnsLock(paths)) {
    const handoff = handoffPath(root, "recovery");
    try {
      for (const name of readdirSync(handoff.dir)) {
        if (!name.startsWith("opencode-") || !name.endsWith(".pending")) continue;
        try {
          const parsed = JSON.parse(readFileSync(`${handoff.dir}/${name}`, "utf8"));
          if (typeof parsed?.sessionID === "string") scheduleDelivery(parsed.sessionID, 0);
        } catch {
        }
      }
    } catch {
    }
  }

  const handleIdle = async (sessionID, generation) => {
    if (!await sessionOwnsLock(paths)) {
      cancelRetryOwner(sessionID);
      return;
    }

    await letWatchArmRun(sessionID, client);

    const result = await runGuard(root);
    if (result.code === 0) {
      if (invocationGenerations.get(sessionID) !== generation) return;
      const retained = readHandoff(root, sessionID);
      if (!clearHandoff(root, sessionID)) {
        if (retained) acknowledgedRecords.set(sessionID, retained.record);
        scheduleDelivery(sessionID);
        return;
      }
      acknowledgedRecords.delete(sessionID);
      pendingMessages.delete(sessionID);
      cancelRetryOwner(sessionID);
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
    if ((satisfiedGenerations.get(sessionID) ?? 0) >= generation) return;
    if (deliveryFlights.has(sessionID)) {
      pendingMessages.set(sessionID, { message, generation });
      ensureHandoff(sessionID);
    } else if (!readHandoff(root, sessionID) && !pendingMessages.has(sessionID)) {
      pendingMessages.set(sessionID, { message, generation });
    }
    acknowledgedRecords.delete(sessionID);
    cancelRetryOwner(sessionID);
    await deliverHandoff(sessionID);
  };

  return {
    event: async ({ event }) => {
      if (event.type !== "session.idle") return;

      const sessionID = event.properties?.sessionID;
      if (!sessionID) return;
      const generation = (invocationGenerations.get(sessionID) ?? 0) + 1;
      invocationGenerations.set(sessionID, generation);
      const prior = idleChains.get(sessionID) ?? Promise.resolve();
      const current = prior.catch(() => {}).then(() => handleIdle(sessionID, generation));
      idleChains.set(sessionID, current);
      try {
        await current;
      } finally {
        if (idleChains.get(sessionID) === current) idleChains.delete(sessionID);
      }
    },
  };
};
