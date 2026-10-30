const TOKEN_RE = /^ci1_[A-Za-z0-9_-]{43}$/;

export class ApiError extends Error {
  constructor(status, body) {
    super(body?.message || `error ${status}`);
    this.status = status;
    this.code = body?.code || "internal";
    this.field = body?.field;
    this.retryAfter = body?.retry_after_s;
  }
}

export function inviteToken(hash) {
  const params = new URLSearchParams(String(hash || "").replace(/^#/, ""));
  const t = params.get("t");
  return t && TOKEN_RE.test(t) ? t : null;
}

export function takeInviteToken(location, history) {
  const token = inviteToken(location.hash);
  if (location.hash) history.replaceState(null, "", location.pathname + location.search);
  return token;
}

export function apiBase(location) {
  return `${location.protocol}//api.${location.host}`;
}

export function createClient({ base, fetch: doFetch = globalThis.fetch.bind(globalThis) }) {
  let csrf = null;
  const call = async (method, path, body) => {
    const headers = {};
    if (body !== undefined) headers["Content-Type"] = "application/json";
    if (method !== "GET" && csrf) headers["X-CSRF-Token"] = csrf;
    const res = await doFetch(base + path, {
      method,
      headers,
      credentials: "include",
      cache: "no-store",
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const data = res.status === 204 ? null : await res.json().catch(() => null);
    if (!res.ok) throw new ApiError(res.status, data);
    if (data?.csrf_token) csrf = data.csrf_token;
    return data;
  };
  return {
    inspect: (token) => call("POST", "/v1/invitations/inspect", { token }),
    accept: ({ token, password, display_name }) =>
      call("POST", "/v1/invitations/accept", {
        token,
        password,
        ...(display_name ? { display_name } : {}),
        device_name: "Navegador",
        client: "web",
      }),
    login: ({ email, password }) =>
      call("POST", "/v1/auth/login", { email, password, device_name: "Navegador", client: "web" }),
    me: () => call("GET", "/v1/auth/me"),
    logout: async () => {
      await call("POST", "/v1/auth/logout");
      csrf = null;
    },
  };
}

export function errorText(err) {
  if (!(err instanceof ApiError)) return "No se pudo conectar con el servidor.";
  if (err.code === "rate_limited") return `Demasiados intentos. Vuelve a probar en ${err.retryAfter ?? 60} s.`;
  if (err.code === "gone") return "La invitación ya se usó, se revocó o caducó. Pide un enlace nuevo.";
  if (err.code === "unauthorized") return err.message || "Credenciales incorrectas.";
  if (err.code === "conflict") return err.message || "Conflicto con el estado actual.";
  if (err.field === "password") return err.message || "La contraseña no cumple la política (12 a 256 caracteres).";
  return err.message || "Error inesperado.";
}
