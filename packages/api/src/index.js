// Cliente mínimo (fetch) de la API de chopshop-agent. Sin dependencias: sirve en el WKWebView, en Node o en tests.
export class ChopshopClient {
  constructor({ baseUrl, token = null, fetchImpl = globalThis.fetch } = {}) {
    if (!baseUrl) throw new Error("baseUrl requerido");
    this.baseUrl = baseUrl.replace(/\/+$/, "");
    this.token = token;
    this.fetch = fetchImpl;
  }
  async _req(method, path, body) {
    const headers = { Accept: "application/json" };
    if (body !== undefined) headers["Content-Type"] = "application/json";
    if (this.token) headers.Authorization = "Bearer " + this.token;
    const r = await this.fetch(this.baseUrl + path, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
    const data = await r.json().catch(() => ({}));
    if (!r.ok) throw Object.assign(new Error(data.error || "HTTP " + r.status), { status: r.status });
    return data;
  }
  health() { return this._req("GET", "/health"); }
  snapshot() { return this._req("GET", "/snapshot"); }
  metrics({ from, to, group = "project", step } = {}) {
    const q = new URLSearchParams({ group, ...(from && { from }), ...(to && { to }), ...(step && { step }) });
    return this._req("GET", "/metrics?" + q);
  }
  events(after = 0, limit = 200) { return this._req("GET", `/events?after=${after}&limit=${limit}`); }
  answer(thread_id, choice, request) { return this._req("POST", "/answer", { thread_id, choice, request }); }
  settle(thread_id) { return this._req("POST", "/settle", { thread_id }); }
  requestLease(args) { return this._req("POST", "/leases/request", args); }
  releaseLease(args) { return this._req("POST", "/leases/release", args); }
}
