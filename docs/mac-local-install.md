# Chopshop de uso en una Mac (build local firmada, sin publicar)

Cómo dejar Chopshop en uso diario en una Mac con una build Release local, firmada con Developer ID pero sin notarizar ni publicar. El pipeline completo (notarización, R2, Sparkle) está en `docs/release.md`.

## Build y firma

Desde `apps/mac`:

```sh
# runtime de Python fijado (python-runtime.version); sin caché local se puede tomar de una Chopshop.app ya instalada
cp -R /Applications/Chopshop.app/Contents/Resources/agent/python /tmp/pyrt/
SHORT_VERSION=<version de package.json> BUILD_NUMBER=$(date +%Y%m%d%H%M) BUNDLE_ID=<bundle id> \
UPDATES_BASE_URL=<base del feed> SPARKLE_ED_PUBLIC_KEY=<SUPublicEDKey> RELEASE_MODE=release PYTHON_RUNTIME_SRC=/tmp/pyrt \
  bash release/assemble-app.sh
SIGN_IDENTITY=<hash SHA-1 de «Developer ID Application»> APPLE_TEAM_ID=<team> RELEASE_MODE=release \
  bash release/sign-app.sh build/release/Chopshop.app
codesign --verify --deep --strict build/release/Chopshop.app
```

- `SIGN_IDENTITY` va por hash (`security find-identity -v -p codesigning`): con el nombre, una tilde en el nombre del certificado puede hacer que codesign no encuentre la identidad.
- Sin notarizar, `spctl` responde «Unnotarized Developer ID». Como la build es local no tiene cuarentena y abre igual.
- El feed y la clave pública de Sparkle se pueden leer del Info.plist de la app instalada para no cambiar de canal.

## Instalación

1. Cierra la app y copia la anterior aparte (`ditto /Applications/Chopshop.app ~/Applications/Chopshop-<versión>.app.bak`).
2. Copia la nueva con `ditto build/release/Chopshop.app /Applications/Chopshop.app`.
3. Ábrela. Con «Usar esta Mac», la app registra el agente con SMAppService (`<bundle id>.agent`, puerto 3790) y se empareja sola con él (`POST /pair` local).

## Llavero

Los ítems del llavero (servicio `com.chopshop.agent`) quedan atados a la firma de la app que los creó. Si una build ad-hoc o de dev creó el ítem de `127.0.0.1:3790`, la app firmada con Developer ID pide permiso al leerlo. Para que no pregunte, borra solo ese ítem, sin leer su contenido, y deja que la app se vuelva a emparejar:

```sh
security delete-generic-password -s com.chopshop.agent -a '<máquina>@127.0.0.1:3790'
```

Los ítems que creó una build Developer ID del mismo bundle id y del mismo equipo se leen sin aviso en las builds siguientes.

## Arranque al login y MCP persistente (LaunchAgents de usuario, no versionados)

- `~/Library/LaunchAgents/<bundle id>.app.plist`: `RunAtLoad` con `/usr/bin/open -g /Applications/Chopshop.app`.
- `~/Library/LaunchAgents/<bundle id>.mcp.plist`: `RunAtLoad` + `KeepAlive`. Ejecuta el Python y el paquete incrustados en la app: `Contents/Resources/agent/python/bin/python3 -I -B Contents/Resources/agent/chopshop-agent.py mcp serve`.
  En `EnvironmentVariables` lleva `HOME`, `PATH` y `CHOPSHOP_CONFIG`. El log va a `~/Library/Logs/Chopshop/mcp.log`.
- Cárgalos con `launchctl bootstrap gui/$(id -u) <plist>` y reinicia el MCP con `launchctl kickstart -k gui/$(id -u)/<label>`.
- Config (`~/.config/chopshop/config.toml`): `[mcp] port = 3797, path = "/mcp", include_local = true, token_file = "~/.config/chopshop/mcp/token"`.
  El token se crea con `chopshop mcp token` (0600; solo muestra la ruta).

## Pasos que necesitan a una persona

Emparejar una máquina remota configurada en `[app.agents.<nombre>]` que responde 401 («sin emparejar»):

1. En esa máquina, ejecuta `chopshop pair create --name "<esta Mac>"`. Muestra un código `XXXX-XXXX` que caduca en 10 minutos.
2. En la app, abre Ajustes, escribe el código en la fila de esa máquina y pulsa «Emparejar».
3. Para el MCP, crea otro código en esa máquina y ejecuta aquí, con el Python incrustado, `chopshop-agent.py mcp pair <nombre> <código>`. La credencial se guarda en `~/.config/chopshop/mcp/credentials.json`.
