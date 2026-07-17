import { spawn } from "node:child_process";
import { readFileSync } from "node:fs";

function parentPid(pid) {
  return new Promise((resolve) => {
    let settled = false;
    const finish = (value) => {
      if (settled) return;
      settled = true;
      resolve(value);
    };
    const child = spawn("ps", ["-o", "ppid=", "-p", pid], {
      stdio: ["ignore", "pipe", "ignore"],
    });
    let stdout = "";
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.on("error", () => finish({ status: "unknown", pid: "" }));
    child.on("close", (code) => {
      const parent = stdout.trim();
      finish(code === 0 && /^[0-9]+$/.test(parent)
        ? { status: "known", pid: parent }
        : { status: "unknown", pid: "" });
    });
  });
}

export function effectivePrimaryPaths(root) {
  const fmRoot = process.env.FM_ROOT_OVERRIDE || root;
  const home = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || fmRoot;
  const state = process.env.FM_STATE_OVERRIDE || `${home}/state`;
  const config = process.env.FM_CONFIG_OVERRIDE || `${home}/config`;
  return { root: fmRoot, home, state, config };
}

export async function sessionLockOwnership(paths) {
  let lockPid = "";
  try {
    lockPid = readFileSync(`${paths.state}/.lock`, "utf8").trim();
  } catch (error) {
    return error?.code === "ENOENT" ? "other" : "unknown";
  }
  if (lockPid === "1") return "other";
  if (!/^[0-9]+$/.test(lockPid)) return "unknown";
  let pid = String(process.pid);
  for (let i = 0; i < 8; i += 1) {
    if (pid === lockPid) return "owned";
    const parent = await parentPid(pid);
    if (parent.status !== "known") return "unknown";
    pid = parent.pid;
    if (pid === "1") return "other";
  }
  return "other";
}

export async function sessionOwnsLock(paths) {
  return await sessionLockOwnership(paths) === "owned";
}
