import { createRoot } from "react-dom/client";
import App from "./App.jsx";
import { apiBase, createClient, takeInviteToken } from "./api.js";

const invite = location.pathname === "/invite";
const token = invite ? takeInviteToken(location, history) : null;
const client = createClient({ base: apiBase(location) });

createRoot(document.getElementById("root")).render(<App client={client} invite={invite} inviteToken={token} />);
