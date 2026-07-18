import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { lstatSync, mkdirSync, readFileSync, readdirSync, realpathSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { parse, relative, resolve } from "node:path";
import { effectivePrimaryPaths, sessionLockOwnership } from "../lib/fm-primary-session-lock.js";

const COORDINATOR_KEY = "__firstmateOpenCodeWatchArm";
let handoffSequence = 0;
const processEpoch = `${process.pid}-${Date.now()}-${Math.random().toString(16).slice(2)}`;

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
  const dir = `${state}/.turnend-handoffs`;
  const path = `${dir}/opencode-${key}.pending`;
  return { home: fmHome, state, dir, path, flight: `${path}.flight`, acknowledged: `${path}.acknowledged` };
}

function rejectSymlinkedComponents(_base, target) {
  const scopedTarget = resolve(target);
  const root = parse(scopedTarget).root;
  const components = relative(root, scopedTarget).split(/[\\/]/).filter(Boolean);
  let cursor = root;
  for (let index = 0; index < components.length; index += 1) {
    const component = components[index];
    cursor = resolve(cursor, component);
    let info;
    try {
      info = lstatSync(cursor);
    } catch (error) {
      if (error?.code === "ENOENT") continue;
      throw error;
    }
    if (info.isSymbolicLink()) throw new Error("symlinked Firstmate state path component");
    if (index < components.length - 1 && !info.isDirectory()) throw new Error("non-directory Firstmate state path component");
  }
}

function safeHandoffDirectory(root, sessionID, create = false) {
  const handoff = handoffPath(root, sessionID);
  rejectSymlinkedComponents(handoff.home, handoff.state);
  const stateInfo = lstatSync(handoff.state);
  if (stateInfo.isSymbolicLink() || !stateInfo.isDirectory()) throw new Error("unsafe Firstmate state directory");
  try {
    const dirInfo = lstatSync(handoff.dir);
    if (dirInfo.isSymbolicLink() || !dirInfo.isDirectory()) throw new Error("unsafe Firstmate handoff directory");
  } catch (error) {
    if (error?.code !== "ENOENT" || !create) throw error;
    mkdirSync(handoff.dir, { mode: 0o700 });
    const dirInfo = lstatSync(handoff.dir);
    if (dirInfo.isSymbolicLink() || !dirInfo.isDirectory()) throw new Error("unsafe Firstmate handoff directory");
  }
  return handoff;
}

function writeAtomic(path, value, token) {
  const temp = `${path}.tmp.${token}`;
  writeFileSync(temp, `${value}\n`, { mode: 0o600, flag: "wx" });
  renameSync(temp, path);
}

function readRegularFile(path) {
  const info = lstatSync(path);
  if (info.isSymbolicLink() || !info.isFile()) throw new Error("unsafe Firstmate handoff record");
  return readFileSync(path, "utf8").trim();
}

function pathExists(path) {
  try {
    lstatSync(path);
    return true;
  } catch (error) {
    if (error?.code === "ENOENT" || error?.code === "ENOTDIR") return false;
    return true;
  }
}

function replaceableRecord(path) {
  try {
    const info = lstatSync(path);
    return !info.isSymbolicLink() && info.isFile();
  } catch (error) {
    return error?.code === "ENOENT";
  }
}

function persistHandoff(root, sessionID, message, generation) {
  const handoff = safeHandoffDirectory(root, sessionID, true);
  handoffSequence += 1;
  const token = `${process.pid}-${Date.now()}-${handoffSequence}`;
  const epoch = processEpoch;
  const record = JSON.stringify({ token, sessionID, message, generation, epoch });
  if (!replaceableRecord(handoff.path)) throw new Error("unsafe Firstmate handoff record");
  writeAtomic(handoff.path, record, token);
  return { ...handoff, record, token, sessionID, message, generation, epoch };
}

function readHandoff(root, sessionID) {
  let handoff;
  try {
    handoff = safeHandoffDirectory(root, sessionID);
    const record = readRegularFile(handoff.path);
    const parsed = JSON.parse(record);
    if (parsed?.sessionID !== sessionID || typeof parsed.token !== "string" || typeof parsed.message !== "string") return undefined;
    const generation = Number.isSafeInteger(parsed.generation) && parsed.generation >= 0 ? parsed.generation : 0;
    const epoch = typeof parsed.epoch === "string" ? parsed.epoch : "";
    return { ...handoff, record, token: parsed.token, sessionID, message: parsed.message, generation, epoch };
  } catch {
    return undefined;
  }
}

function clearHandoff(root, sessionID, record) {
  let handoff;
  try {
    handoff = safeHandoffDirectory(root, sessionID);
    if (record !== undefined && readRegularFile(handoff.path) !== record) return false;
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

function parseDurableRecord(path, sessionID, kind) {
  try {
    const record = readRegularFile(path);
    const parsed = JSON.parse(record);
    if (parsed?.kind !== kind || parsed.sessionID !== sessionID || typeof parsed.token !== "string"
      || !Number.isSafeInteger(parsed.generation) || parsed.generation < 0
      || typeof parsed.pendingRecord !== "string") return undefined;
    const pending = JSON.parse(parsed.pendingRecord);
    const epoch = typeof parsed.epoch === "string" ? parsed.epoch : "";
    const pendingEpoch = typeof pending?.epoch === "string" ? pending.epoch : "";
    if (pending?.token !== parsed.token || pending.sessionID !== sessionID || pending.generation !== parsed.generation
      || pendingEpoch !== epoch || typeof pending.message !== "string") return undefined;
    return { ...parsed, epoch, record };
  } catch {
    return undefined;
  }
}

function readFlight(root, sessionID) {
  try {
    const handoff = safeHandoffDirectory(root, sessionID);
    return parseDurableRecord(handoff.flight, sessionID, "unresolved-flight");
  } catch {
    return undefined;
  }
}

function persistFlight(root, handoff) {
  const paths = safeHandoffDirectory(root, handoff.sessionID, true);
  if (pathExists(paths.flight)) throw new Error("an unresolved OpenCode delivery is already quarantined");
  const existing = parseDurableRecord(paths.flight, handoff.sessionID, "unresolved-flight");
  if (existing) throw new Error("an unresolved OpenCode delivery is already quarantined");
  const record = JSON.stringify({
    kind: "unresolved-flight",
    token: handoff.token,
    sessionID: handoff.sessionID,
    generation: handoff.generation,
    epoch: handoff.epoch,
    pendingRecord: handoff.record,
    ownerPid: process.pid,
  });
  writeAtomic(paths.flight, record, `${handoff.token}.flight`);
  return { ...JSON.parse(record), record };
}

function clearFlight(root, sessionID, record) {
  try {
    const handoff = safeHandoffDirectory(root, sessionID);
    if (record !== undefined && readRegularFile(handoff.flight) !== record) return false;
    unlinkSync(handoff.flight);
  } catch (error) {
    if (error?.code !== "ENOENT") return false;
  }
  try {
    readFileSync(handoffPath(root, sessionID).flight, "utf8");
    return false;
  } catch (error) {
    return error?.code === "ENOENT";
  }
}

function readAcknowledged(root, sessionID) {
  try {
    const handoff = safeHandoffDirectory(root, sessionID);
    const acknowledged = parseDurableRecord(handoff.acknowledged, sessionID, "acknowledged-cleanup");
    if (!acknowledged) return undefined;
    const coverageEpoch = typeof acknowledged.coverageEpoch === "string"
      ? acknowledged.coverageEpoch
      : acknowledged.epoch;
    return { ...acknowledged, coverageEpoch };
  } catch {
    return undefined;
  }
}

function persistAcknowledged(root, handoff, coveredGeneration, coverageEpoch) {
  const paths = safeHandoffDirectory(root, handoff.sessionID, true);
  if (pathExists(paths.acknowledged)) throw new Error("an OpenCode acknowledgement is already pending cleanup");
  const record = JSON.stringify({
    kind: "acknowledged-cleanup",
    token: handoff.token,
    sessionID: handoff.sessionID,
    generation: handoff.generation,
    epoch: handoff.epoch,
    coveredGeneration,
    coverageEpoch,
    pendingRecord: handoff.record,
  });
  writeAtomic(paths.acknowledged, record, `${handoff.token}.acknowledged`);
  return { ...JSON.parse(record), record };
}

function cleanupAcknowledged(root, sessionID, acknowledged) {
  let handoff;
  try {
    handoff = safeHandoffDirectory(root, sessionID);
    const current = readHandoff(root, sessionID);
    const coveredGeneration = Number.isSafeInteger(acknowledged.coveredGeneration)
      ? acknowledged.coveredGeneration
      : acknowledged.generation;
    if (current && (current.record === acknowledged.pendingRecord
      || (acknowledged.coverageEpoch !== "" && current.epoch !== ""
        && current.epoch === acknowledged.coverageEpoch && current.generation <= coveredGeneration))) {
      if (!clearHandoff(root, sessionID, current.record)) return false;
    }
    const flight = readFlight(root, sessionID);
    if (flight && flight.pendingRecord === acknowledged.pendingRecord) {
      if (!clearFlight(root, sessionID, flight.record)) return false;
    }
    if (readRegularFile(handoff.acknowledged) !== acknowledged.record) return false;
    unlinkSync(handoff.acknowledged);
  } catch (error) {
    if (error?.code !== "ENOENT") return false;
  }
  return !pathExists(handoffPath(root, sessionID).acknowledged);
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
  const ownershipRetryTimers = new Map();
  const ownershipPending = new Map();
  const pendingMessages = new Map();
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

  const cancelOwnershipRetry = (sessionID) => {
    const timer = ownershipRetryTimers.get(sessionID);
    if (timer) clearTimeout(timer);
    ownershipRetryTimers.delete(sessionID);
    ownershipPending.delete(sessionID);
  };

  const scheduleOwnershipRetry = (sessionID, generation) => {
    ownershipPending.set(sessionID, generation);
    if (ownershipRetryTimers.has(sessionID)) return;
    const timer = setTimeout(async () => {
      ownershipRetryTimers.delete(sessionID);
      const retainedGeneration = ownershipPending.get(sessionID);
      const ownership = await sessionLockOwnership(paths);
      if (ownership === "unknown") {
        scheduleOwnershipRetry(sessionID, retainedGeneration);
        return;
      }
      ownershipPending.delete(sessionID);
      if (ownership !== "owned") return;
      await handleIdle(sessionID, retainedGeneration);
    }, retryDelay());
    ownershipRetryTimers.set(sessionID, timer);
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

  const settleDelivery = async (sessionID, flight, acknowledged, coveredGeneration = flight.coveredGeneration) => {
    if (deliveryFlights.get(sessionID) !== flight) return;
    if (flight.settling) return;
    flight.settling = true;
    flight.outcome = acknowledged;
    if (acknowledged) {
      if (flight.coverageEpoch === processEpoch) {
        flight.coveredGeneration = Math.max(
          0,
          Number.isSafeInteger(coveredGeneration) ? coveredGeneration : flight.coveredGeneration,
        );
      } else {
        flight.coveredGeneration = flight.handoff.generation;
      }
    }
    const ownership = await sessionLockOwnership(paths);
    if (ownership === "unknown") {
      flight.settling = false;
      scheduleDelivery(sessionID);
      return;
    }
    if (ownership !== "owned") {
      deliveryFlights.delete(sessionID);
      cancelRetryOwner(sessionID);
      return;
    }
    if (acknowledged) {
      let durableAcknowledged;
      try {
        durableAcknowledged = persistAcknowledged(
          root,
          flight.handoff,
          flight.coveredGeneration,
          flight.coverageEpoch,
        );
      } catch {
        flight.settling = false;
        scheduleDelivery(sessionID);
        return;
      }
      if (flight.coverageEpoch === processEpoch) {
        satisfiedGenerations.set(
          sessionID,
          Math.max(satisfiedGenerations.get(sessionID) ?? 0, flight.coveredGeneration),
        );
      }
      const pending = pendingMessages.get(sessionID);
      if (flight.coverageEpoch === processEpoch && pending && pending.generation <= flight.coveredGeneration) {
        pendingMessages.delete(sessionID);
      }
      deliveryFlights.delete(sessionID);
      cleanupAcknowledged(root, sessionID, durableAcknowledged);
    } else {
      if (!clearFlight(root, sessionID, flight.durable.record)) {
        flight.settling = false;
        scheduleDelivery(sessionID);
        return;
      }
      deliveryFlights.delete(sessionID);
    }
    if (readAcknowledged(root, sessionID) || pendingMessages.has(sessionID) || readHandoff(root, sessionID)) {
      scheduleDelivery(sessionID);
    } else {
      cancelRetryOwner(sessionID);
    }
  };

  const startDelivery = async (sessionID, handoff) => {
    let resolveSettled;
    let timeout;
    const settled = new Promise((resolve) => { resolveSettled = resolve; });
    let durable;
    try {
      durable = persistFlight(root, handoff);
    } catch {
      if (!readFlight(root, sessionID)) scheduleDelivery(sessionID);
      else cancelRetryOwner(sessionID);
      return;
    }
    const flight = {
      handoff,
      durable,
      settled,
      outcome: undefined,
      settling: false,
      coveredGeneration: handoff.epoch === processEpoch ? handoff.generation : 0,
      coverageEpoch: handoff.epoch === processEpoch ? processEpoch : "",
    };
    deliveryFlights.set(sessionID, flight);
    Promise.resolve()
      .then(() => client.session.promptAsync({
        path: { id: sessionID },
        body: { parts: [{ type: "text", text: handoff.message }] },
      }))
      .then(
        () => {
          const currentGeneration = invocationGenerations.get(sessionID);
          if (Number.isSafeInteger(currentGeneration) && currentGeneration > 0) {
            if (flight.coverageEpoch !== processEpoch) flight.coveredGeneration = currentGeneration;
            else flight.coveredGeneration = Math.max(flight.coveredGeneration, currentGeneration);
            flight.coverageEpoch = processEpoch;
          }
          return settleDelivery(sessionID, flight, true, flight.coveredGeneration);
        },
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
    const ownership = await sessionLockOwnership(paths);
    if (ownership === "unknown") {
      scheduleDelivery(sessionID);
      return;
    }
    if (ownership !== "owned") {
      cancelRetryOwner(sessionID);
      return;
    }
    const handoffPaths = handoffPath(root, sessionID);
    const acknowledged = readAcknowledged(root, sessionID);
    if (acknowledged) {
      if (cleanupAcknowledged(root, sessionID, acknowledged)) {
        if (pendingMessages.has(sessionID) || readHandoff(root, sessionID)) scheduleDelivery(sessionID, 0);
        else cancelRetryOwner(sessionID);
      } else {
        scheduleDelivery(sessionID);
      }
      return;
    }
    if (pathExists(handoffPaths.acknowledged)) {
      cancelRetryOwner(sessionID);
      return;
    }
    const activeFlight = deliveryFlights.get(sessionID);
    if (activeFlight) {
      if (activeFlight.outcome !== undefined) {
        await settleDelivery(sessionID, activeFlight, activeFlight.outcome);
      } else {
        scheduleDelivery(sessionID);
      }
      return;
    }
    if (readFlight(root, sessionID) || pathExists(handoffPaths.flight)) {
      cancelRetryOwner(sessionID);
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

  const recoverHandoffs = async () => {
    const ownership = await sessionLockOwnership(paths);
    if (ownership === "unknown") {
      setTimeout(() => { void recoverHandoffs(); }, retryDelay());
      return;
    }
    if (ownership !== "owned") return;
    let handoff;
    try {
      handoff = safeHandoffDirectory(root, "recovery");
      const sessionIDs = new Set();
      for (const name of readdirSync(handoff.dir)) {
        if (!name.startsWith("opencode-")) continue;
        try {
          const parsed = JSON.parse(readRegularFile(`${handoff.dir}/${name}`));
          if (typeof parsed?.sessionID === "string") sessionIDs.add(parsed.sessionID);
        } catch {
        }
      }
      for (const sessionID of sessionIDs) {
        if (readAcknowledged(root, sessionID)) scheduleDelivery(sessionID, 0);
        else if (!readFlight(root, sessionID) && readHandoff(root, sessionID)) scheduleDelivery(sessionID, 0);
      }
    } catch {
    }
  };

  void recoverHandoffs();

  const handleIdle = async (sessionID, generation) => {
    const initialOwnership = await sessionLockOwnership(paths);
    if (initialOwnership === "unknown") {
      scheduleOwnershipRetry(sessionID, generation);
      return;
    }
    if (initialOwnership !== "owned") {
      cancelOwnershipRetry(sessionID);
      cancelRetryOwner(sessionID);
      return;
    }
    cancelOwnershipRetry(sessionID);

    await letWatchArmRun(sessionID, client);

    const result = await runGuard(root);
    const finalOwnership = await sessionLockOwnership(paths);
    if (finalOwnership === "unknown") {
      scheduleOwnershipRetry(sessionID, generation);
      return;
    }
    if (finalOwnership !== "owned") {
      cancelRetryOwner(sessionID);
      return;
    }
    if (result.code === 0) {
      if (invocationGenerations.get(sessionID) !== generation) return;
      pendingMessages.delete(sessionID);
      const retained = readHandoff(root, sessionID);
      if (retained && !clearHandoff(root, sessionID, retained.record)) {
        scheduleDelivery(sessionID);
        return;
      }
      const acknowledged = readAcknowledged(root, sessionID);
      if (acknowledged) {
        scheduleDelivery(sessionID, 0);
      } else if (!deliveryFlights.has(sessionID) && !readFlight(root, sessionID)) {
        cancelRetryOwner(sessionID);
      }
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
    if (deliveryFlights.has(sessionID) || readFlight(root, sessionID)) {
      const activeFlight = deliveryFlights.get(sessionID);
      if (activeFlight && activeFlight.outcome === undefined) {
        if (activeFlight.coverageEpoch !== processEpoch) activeFlight.coveredGeneration = generation;
        else activeFlight.coveredGeneration = Math.max(activeFlight.coveredGeneration, generation);
        activeFlight.coverageEpoch = processEpoch;
      }
      pendingMessages.set(sessionID, { message, generation });
      ensureHandoff(sessionID);
    } else if (!readHandoff(root, sessionID) && !pendingMessages.has(sessionID)) {
      pendingMessages.set(sessionID, { message, generation });
    }
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
