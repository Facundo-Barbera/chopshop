# Agente ficticio (verificación con varias máquinas)

`mock_agent.py` sirve en loopback uno de los agentes de `tools/screenshots/fixture.json` (datos ficticios). Sirve para
verificar la app de Mac con dos máquinas a la vez, sin T3 ni agentes reales. Las capturas se toman con el protocolo de
`Capture.swift`: la app captura sus propias ventanas, sin ratón ni teclado.

```sh
python3 tools/mock_agent/mock_agent.py --agent host-a --port 3791 &
python3 tools/mock_agent/mock_agent.py --agent host-b --port 3792 &   # --require-pairing: fila «sin emparejar»

cfg=$(mktemp -d)/config.toml
printf '[app]\nrefresh_seconds = 1\n\n[app.agents.host-a]\nurl = "http://127.0.0.1:3791"\n\n[app.agents.host-b]\nurl = "http://127.0.0.1:3792"\n' > "$cfg"
(cd apps/mac && CHOPSHOP_CONFIG="$cfg" swift run ChopshopUI --capture) &

echo "machines /tmp/cs-machines.png" > /tmp/chopshop-shot.req    # espera a /tmp/cs-machines.png.done
echo "settings /tmp/cs-settings.png" > /tmp/chopshop-shot.req
```

Para la migración, usa un config viejo (`[app]\nagent_url = "http://127.0.0.1:3791"`): al arrancar, la app lo reescribe como
`[app.agents.agente]`. Al terminar, cierra la app y los dos agentes ficticios (`kill %1 %2 %3`).
