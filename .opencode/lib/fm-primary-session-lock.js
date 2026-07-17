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
    child.on("error", () => finish(""));
    child.on("close", (code) => finish(code === 0 ? stdout.trim() : ""));
  });
}

export function effectivePrimaryPaths(root) {
  const fmRoot = process.env.FM_ROOT_OVERRIDE || root;
  const home = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || fmRoot;
  const state = process.env.FM_STATE_OVERRIDE || `${home}/state`;
  const config = process.env.FM_CONFIG_OVERRIDE || `${home}/config`;
  return { root: fmRoot, home, state, config };
}

export async function sessionOwnsLock(paths) {
  let lockPid = "";
  try {
    lockPid = readFileSync(`${paths.state}/.lock`, "utf8").trim();
  } catch {
    return false;
  }
  if (!/^[0-9]+$/.test(lockPid) || lockPid === "1") return false;
  let pid = String(process.pid);
  for (let i = 0; i < 8; i += 1) {
    if (pid === lockPid) return true;
    pid = await parentPid(pid);
    if (!pid || pid === "1") return false;
  }
  return false;
}
