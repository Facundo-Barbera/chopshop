## Servidores de prueba (Chopshop)

Esta máquina comparte CPU y RAM entre muchos agentes. **No levantes dev servers, watchers ni procesos de larga vida por tu cuenta**
(`pnpm dev`, `vite`, `next dev`, `uvicorn --reload`...).

- Si necesitas un servidor para probar, pídelo con la tool MCP `chopshop_request_test_server` (infiere el proyecto y el worktree del
  directorio actual; usa `wait_seconds` si puede quedar en cola). Úsalo en el puerto y la URL que te devuelva.
- Si solo necesitas un puerto estable para tu worktree, usa `chopshop_request_port`.
- **Al terminar, libera** con `chopshop_release` (también se libera solo al dar el hilo por terminado o tras un rato de inactividad).
- `chopshop_status` muestra qué hay activo y en cola.
- Los tests y los builds puntuales (`pnpm test`, `tsc`) sí puedes correrlos directamente; lo que no, es dejar procesos corriendo.
