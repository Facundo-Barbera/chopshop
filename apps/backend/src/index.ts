export const VERSION = "0.1.0";

export interface Env {
  DB?: D1Database;
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
  });
}

export default {
  async fetch(request: Request, _env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/health" && request.method === "GET") return json({ ok: true, version: VERSION });
    return json({ code: "not_found" }, 404);
  },
} satisfies ExportedHandler<Env>;
