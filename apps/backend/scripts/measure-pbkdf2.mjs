import { spawn } from "node:child_process";
import { mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { createServer } from "node:net";
import { tmpdir, cpus } from "node:os";
import { join } from "node:path";
import { performance } from "node:perf_hooks";

const ITERATIONS = (process.env.ITERATIONS ?? "1,10000,20000,50000,100000").split(",").map(Number);
const REPS = Number(process.env.REPS ?? 30);
const WARMUP = 3;

const WORKER = `
const enc = new TextEncoder();
export default {
  async fetch(request) {
    const url = new URL(request.url);
    const iterations = Number(url.searchParams.get("i"));
    const pepper = url.searchParams.get("pepper") === "1";
    const t0 = performance.now();
    let material = enc.encode("correct horse battery staple");
    if (pepper) {
      const hk = await crypto.subtle.importKey("raw", enc.encode("x".repeat(32)), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
      material = new Uint8Array(await crypto.subtle.sign("HMAC", hk, material));
    }
    try {
      const key = await crypto.subtle.importKey("raw", material, "PBKDF2", false, ["deriveBits"]);
      await crypto.subtle.deriveBits({ name: "PBKDF2", hash: "SHA-256", salt: new Uint8Array(16), iterations }, key, 256);
    } catch (e) {
      return Response.json({ error: String(e) }, { status: 500 });
    }
    return Response.json({ inWorkerMs: performance.now() - t0 });
  },
};
`;

function freePort() {
  return new Promise((resolve, reject) => {
    const srv = createServer();
    srv.once("error", reject);
    srv.listen(0, "127.0.0.1", () => {
      const { port } = srv.address();
      srv.close(() => resolve(port));
    });
  });
}

function cpuNs(pid) {
  let total = 0n;
  for (const tid of readdirSync(`/proc/${pid}/task`)) {
    try {
      total += BigInt(readFileSync(`/proc/${pid}/task/${tid}/schedstat`, "utf8").split(" ")[0]);
    } catch {}
  }
  return total;
}

function quantile(sorted, q) {
  const idx = Math.min(sorted.length - 1, Math.ceil(q * sorted.length) - 1);
  return sorted[Math.max(0, idx)];
}

function stats(values) {
  const s = [...values].sort((a, b) => a - b);
  return { median: quantile(s, 0.5), p95: quantile(s, 0.95), min: s[0], max: s[s.length - 1] };
}

async function waitReady(base) {
  for (let i = 0; i < 100; i++) {
    try {
      const res = await fetch(`${base}/?i=1`);
      if (res.ok) return;
    } catch {}
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error("workerd no arrancó");
}

async function sample(base, pid, iterations, pepper) {
  const c0 = cpuNs(pid);
  const t0 = performance.now();
  const res = await fetch(`${base}/?i=${iterations}&pepper=${pepper ? 1 : 0}`);
  const body = await res.json();
  const wall = performance.now() - t0;
  const cpu = Number(cpuNs(pid) - c0) / 1e6;
  if (!res.ok) throw new Error(body.error);
  return { wall, cpu };
}

async function main() {
  const require = createRequire(createRequire(import.meta.url).resolve("wrangler/package.json"));
  const workerdMod = await import(require.resolve("workerd"));
  const bin = workerdMod.default.default ?? workerdMod.default;
  const dir = mkdtempSync(join(tmpdir(), "pbkdf2-"));
  const port = await freePort();
  writeFileSync(join(dir, "worker.mjs"), WORKER);
  writeFileSync(
    join(dir, "config.capnp"),
    `using Workerd = import "/workerd/workerd.capnp";
const config :Workerd.Config = (
  services = [ (name = "main", worker = .w) ],
  sockets = [ (name = "http", address = "127.0.0.1:${port}", http = (), service = "main") ],
);
const w :Workerd.Worker = (
  modules = [ (name = "worker.mjs", esModule = embed "worker.mjs") ],
  compatibilityDate = "2026-10-01",
);
`,
  );
  const child = spawn(bin, ["serve", join(dir, "config.capnp")], { stdio: ["ignore", "ignore", "inherit"] });
  const base = `http://127.0.0.1:${port}`;
  try {
    await waitReady(base);
    console.log(`workerd ${workerdMod.version ?? workerdMod.default.version}, ${cpus()[0].model}, node ${process.version}, ${REPS} repeticiones\n`);
    const rows = [];
    for (const pepper of [false, true]) {
      for (const iterations of ITERATIONS) {
        for (let i = 0; i < WARMUP; i++) await sample(base, child.pid, iterations, pepper);
        const runs = [];
        for (let i = 0; i < REPS; i++) runs.push(await sample(base, child.pid, iterations, pepper));
        const wall = stats(runs.map((r) => r.wall));
        const cpu = stats(runs.map((r) => r.cpu));
        rows.push({ iterations, pepper, wall, cpu });
      }
    }
    const baseline = rows.find((r) => r.iterations === 1 && !r.pepper);
    console.log("| iteraciones | pepper | wall mediana (ms) | wall p95 (ms) | CPU workerd mediana (ms) | CPU workerd p95 (ms) | CPU neta mediana (ms) |");
    console.log("|---:|:---:|---:|---:|---:|---:|---:|");
    for (const r of rows) {
      const net = Math.max(0, r.cpu.median - (baseline?.cpu.median ?? 0));
      console.log(
        `| ${r.iterations} | ${r.pepper ? "sí" : "no"} | ${r.wall.median.toFixed(2)} | ${r.wall.p95.toFixed(2)} | ${r.cpu.median.toFixed(2)} | ${r.cpu.p95.toFixed(2)} | ${net.toFixed(2)} |`,
      );
    }
    try {
      await sample(base, child.pid, 100_001, false);
      console.log("\n100001 iteraciones: aceptado (workerd local no aplica el tope)");
    } catch (e) {
      console.log(`\n100001 iteraciones: ${e.message}`);
    }
  } finally {
    child.kill("SIGTERM");
    rmSync(dir, { recursive: true, force: true });
  }
}

await main();
