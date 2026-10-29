// Pruebas de renderizado de la UI en Node (sin navegador ni servidores): se empaqueta App.jsx con esbuild a un
// directorio ignorado, se alimenta con el fixture de capturas (dos agentes ficticios) pasando por la misma
// combinación de snapshots que usa la app (createStore) y se dibujan las vistas con react-dom/server.
import test, { before, after } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { build } from "esbuild";
import { createElement as h } from "react";
import { renderToString } from "react-dom/server";
import { createStore } from "@chopshop/api";

const here = dirname(fileURLToPath(import.meta.url));
const outDir = join(here, "..", ".test-build");
const fx = JSON.parse(readFileSync(join(here, "..", "..", "..", "tools", "screenshots", "fixture.json"), "utf8"));
const now = Date.parse(fx.now.replace(/([+-]\d\d)(\d\d)$/, "$1:$2"));
let ui;

before(async () => {
  globalThis.window = globalThis.window || {};
  await build({ entryPoints: [join(here, "..", "src", "App.jsx")], bundle: true, format: "esm", platform: "node", jsx: "automatic",
    packages: "external", outfile: join(outDir, "app.mjs"), logLevel: "silent" });
  ui = await import(pathToFileURL(join(outDir, "app.mjs")).href);
});
after(() => rmSync(outDir, { recursive: true, force: true }));

const view = () => createStore({ now: () => now }).update(fx.agents);
const render = (V, props) => renderToString(h(V, props));
const base = () => {
  const v = view();
  const snap = v.state;
  return { v, snap, c: ui.collect(snap), titles: {} };
};

test("el fixture combina dos agentes: lotes del orquestador y lote sintético del sensor", () => {
  const { snap } = base();
  assert.ok(snap.batches.some((b) => b.id === "b-0006"));
  assert.ok(snap.batches.some((b) => b.id === "host-b/app-ejemplo" && b.synthetic));
  assert.equal(snap.multi, true);
});

test("Resumen y Lotes se dibujan", () => {
  const { snap, c, titles } = base();
  const html = render(ui.Overview, { snap, c, now, go() {}, nav() {}, titles });
  assert.match(html, /Necesita atención/);
  assert.match(html, /Lotes recientes/);
  assert.match(render(ui.ProjectView, { snap, c, now, project: "" }), /host-b\/app-ejemplo/);
});

test("Preguntas incluye las del orquestador y las de hilos que solo ve el agente", () => {
  const { c } = base();
  const html = render(ui.Questions, { c, now });
  assert.match(html, /Conservamos los nombres de las variables CSS/);
  assert.equal(c.questions.length >= 2, true);
});

test("Máquinas: apps y proyectos, de solo lectura (sin servidores de prueba)", () => {
  const { v, snap } = base();
  const a = render(ui.Machines, { metrics: v.machines, snap, sel: "host-a", pick() {} });
  assert.match(a, /Por app/);
  assert.match(a, /claude/);
  assert.doesNotMatch(a, /Servidores de prueba/);
  assert.doesNotMatch(a, /Liberar/);
  const b = render(ui.Machines, { metrics: v.machines, snap, sel: "host-b", pick() {} });
  assert.match(b, /chrome/);
  assert.match(b, /app-ejemplo/);
});

test("Actividad, Reacciones y Grafo se dibujan con los datos del orquestador", () => {
  const { snap, c, titles } = base();
  assert.match(render(ui.Events, { snap, c, now, titles }), /Línea de tiempo/);
  assert.match(render(ui.Reactions, { snap, now }), /Nivel 1/);
  assert.match(render(ui.Graph, { snap, now }), /Planificador/);
});

test("agente caído: banner con el estado y datos viejos; sin datos: pantalla de conexión", () => {
  const store = createStore({ now: () => now });
  store.update(fx.agents);
  const v = store.update([{ name: "host-a", status: "unreachable", error: "tiempo de espera agotado" }, fx.agents[1]]);
  const banner = render(ui.AgentBanner, { agents: v.agents });
  assert.match(banner, /host-a/);
  assert.match(banner, /agente no alcanzable/);
  assert.match(banner, /mostrando datos de hace/);
  const never = createStore().update([{ name: "host-a", status: "forbidden" }]);
  const html = render(ui.Connecting, { agents: never.agents, configPath: "" });
  assert.match(html, /No pude conectar/);
  assert.match(html, /403/);
  assert.match(render(ui.Connecting, { agents: [], configPath: "~/.config/chopshop/config.toml" }), /Ningún agente configurado/);
  assert.match(render(ui.Connecting, { agents: null }), /Conectando/);
});
