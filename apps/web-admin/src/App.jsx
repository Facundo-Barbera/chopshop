import { useEffect, useState } from "react";
import { errorText } from "./api.js";

function Field({ label, ...props }) {
  return (
    <label className="field">
      <span>{label}</span>
      <input {...props} />
    </label>
  );
}

function Message({ error }) {
  return error ? <p className="error" role="alert">{error}</p> : null;
}

export function Login({ client, onSession }) {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const submit = async (e) => {
    e.preventDefault();
    setBusy(true);
    setError(null);
    try {
      onSession(await client.login({ email, password }));
    } catch (err) {
      setError(errorText(err));
      setBusy(false);
    }
  };
  return (
    <form className="card" onSubmit={submit}>
      <h1>Entrar en chopshop</h1>
      <Field label="Correo" type="email" autoComplete="username" required value={email} onChange={(e) => setEmail(e.target.value)} />
      <Field label="Contraseña" type="password" autoComplete="current-password" required value={password} onChange={(e) => setPassword(e.target.value)} />
      <Message error={error} />
      <button type="submit" disabled={busy}>Entrar</button>
    </form>
  );
}

export function Invite({ client, token, onAccepted }) {
  const [info, setInfo] = useState(null);
  const [error, setError] = useState(token ? null : "El enlace de invitación no es válido.");
  const [password, setPassword] = useState("");
  const [repeat, setRepeat] = useState("");
  const [name, setName] = useState("");
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    if (!token) return;
    client.inspect(token).then(setInfo, (err) => setError(errorText(err)));
  }, [client, token]);
  const submit = async (e) => {
    e.preventDefault();
    if (password !== repeat) return setError("Las contraseñas no coinciden.");
    setBusy(true);
    setError(null);
    try {
      onAccepted(await client.accept({ token, password, display_name: name.trim() }));
    } catch (err) {
      setError(errorText(err));
      setBusy(false);
    }
  };
  if (!info) {
    return (
      <div className="card">
        <h1>Aceptar invitación</h1>
        {error ? <Message error={error} /> : <p>Comprobando la invitación…</p>}
      </div>
    );
  }
  const owner = info.role === "owner";
  return (
    <form className="card" onSubmit={submit}>
      <h1>Aceptar invitación</h1>
      <p>
        Invitación para <strong>{info.email}</strong> como {owner ? "dueño" : "watcher"}.
      </p>
      {info.workspaces?.length > 0 && (
        <ul className="workspaces">
          {info.workspaces.map((w) => <li key={w.id}>{w.name}</li>)}
        </ul>
      )}
      <p className="hint">Caduca el {new Date(info.expires_at).toLocaleString("es")}.</p>
      {info.kind !== "owner_reset" && (
        <Field label="Nombre (opcional)" autoComplete="name" maxLength={64} value={name} onChange={(e) => setName(e.target.value)} />
      )}
      <Field label="Contraseña (12 a 256 caracteres)" type="password" autoComplete="new-password" required minLength={12} maxLength={256} value={password} onChange={(e) => setPassword(e.target.value)} />
      <Field label="Repite la contraseña" type="password" autoComplete="new-password" required value={repeat} onChange={(e) => setRepeat(e.target.value)} />
      <Message error={error} />
      <button type="submit" disabled={busy}>Aceptar y entrar</button>
    </form>
  );
}

export function RecoveryCode({ code, onDone }) {
  return (
    <div className="card">
      <h1>Código de recuperación</h1>
      <p>Guárdalo en un lugar seguro. Es la única vez que se muestra y sirve para recuperar la cuenta del dueño.</p>
      <p className="code">{code}</p>
      <button type="button" onClick={onDone}>Ya lo guardé</button>
    </div>
  );
}

export function Welcome({ user, onLogout }) {
  return (
    <div className="card">
      <h1>Hola, {user.display_name || user.email}</h1>
      <p>Has entrado en chopshop. La gestión de workspaces, máquinas, watchers e invitaciones está en la app de Mac.</p>
      <button type="button" onClick={onLogout}>Cerrar sesión</button>
    </div>
  );
}

export default function App({ client, inviteToken, invite }) {
  const [user, setUser] = useState(null);
  const [recovery, setRecovery] = useState(null);
  const [view, setView] = useState(invite ? "invite" : "loading");
  useEffect(() => {
    if (invite) return;
    client.me().then((r) => { setUser(r.user); setView("welcome"); }, () => setView("login"));
  }, [client, invite]);
  const enter = (r) => {
    setUser(r.user);
    if (r.recovery_code) {
      setRecovery(r.recovery_code);
      setView("recovery");
    } else setView("welcome");
  };
  const logout = async () => {
    await client.logout().catch(() => {});
    setUser(null);
    setView("login");
  };
  return (
    <main>
      {view === "loading" && <p className="card">Cargando…</p>}
      {view === "login" && <Login client={client} onSession={enter} />}
      {view === "invite" && <Invite client={client} token={inviteToken} onAccepted={enter} />}
      {view === "recovery" && <RecoveryCode code={recovery} onDone={() => { setRecovery(null); setView("welcome"); }} />}
      {view === "welcome" && user && <Welcome user={user} onLogout={logout} />}
    </main>
  );
}
