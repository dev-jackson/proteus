# Proteus

**Windows games on your Mac. Drop the file, get an app.**
**Juegos de Windows en tu Mac. Suelta el archivo, obtén una app.**

> Proteus was the sea god who changed form at will — a lion, a serpent, water,
> fire, whatever the moment asked. "Protean" comes from him. A Windows game
> becoming a Mac app is the same trick.

---

## English

Drop an `.exe`, an `.iso`, a `.zip` or a game folder on the window. Proteus
reads the game, works out what it needs, installs it, and leaves an ordinary
app in `/Applications` with the game's own icon.

Then it starts the game, watches for a window, looks at the frame it drew, and
sends real keyboard and mouse events to check they arrive — before telling you
it is ready.

**It does not promise your game will work. It promises to tell you the truth
about whether it does, and to fix what it can without you learning anything.**

### Why this exists

Everything else in this space asks you to be the integrator. Create a bottle.
Pick an engine. Guess whether the game wants `vcrun2019` or `vcrun2022`. Choose
between WineD3D, DXVK, DXMT and D3DMetal without being told which one your game
can even use. Find out you guessed wrong when the game silently does nothing.

Proton — by far the most successful compatibility layer ever shipped — does not
detect anything either: it bundles translation layers and relies on
`protonfixes`, a table of hand-written patches, plus players reporting results.
When a game fails, the documented procedure is for *you* to set `PROTON_LOG=1`,
reproduce the crash and read the log.

**A Windows executable already declares most of what it needs.** Proteus reads
it instead of asking you. See [docs/ALGORITHM.md](docs/ALGORITHM.md) for how,
and where it runs out.

### What it actually does that others don't

| | Proteus | The others |
|---|---|---|
| Dependency detection | Reads the PE import table of the game binary and maps each imported DLL to the exact runtime it needs | You pick verbs from a list |
| Graphics backend | Chosen from what the game imports (`d3d12.dll` → D3DMetal, `d3d11.dll` → DXMT, `d3d9.dll` → WineD3D) | You pick from a dropdown |
| Which .exe is the game | Scored by size, depth, GUI subsystem, icon presence, graphics imports, and `autorun.inf` | You browse and pick |
| Installers | Fingerprints NSIS / Inno Setup / InstallShield / MSI and uses the correct silent flags | You click through the wizard inside a fake Windows |
| ISOs | Mounted, `autorun.inf` parsed, disc name used, redistributable folders ignored | You mount it yourself |
| Icon | Extracted from the executable's resource tree and converted to `.icns`, pixel-art upscaled without blurring | Generic Wine glass |
| Verification | **Starts the game and waits for a real window before saying "ready"** | Nobody does this |
| Disk cost | Engine unpacked once and APFS-cloned into each app: ~365 MB per extra game | ~1.4 GB per game |
| Uninstall | Drag the app to the Trash. Everything lived inside it | Bottles, prefixes and registry entries left behind |

### Requirements

- macOS 14 or later, Apple Silicon or Intel
- Nothing else. No Homebrew, no Xcode tools, no Rosetta prompt unless a
  DirectX 12 game actually needs it.

The Wine engine (~166 MB) and wrapper template (~80 MB) download once, on
first use. If you already have Sikarugir or Kegworks installed, Proteus reuses
their copies and downloads nothing.

### Build and run

```bash
./scripts/bundle.sh release
open build/Proteus.app
```

### Command line

The same engine, without the window:

```bash
proteus inspect ~/Downloads/game.iso     # say what it needs, change nothing
proteus install ~/Downloads/setup.exe    # build the app
proteus install ~/Games/MyGame --name "My Game"
proteus fix "/Applications/My Game.app"  # re-run the installer with its UI
proteus uninstall "My Game"
```

`inspect` never writes anything, so it is safe to run on anything.

### Known limits

- A fullscreen game at 320×240 or 640×480 renders at its native size on a
  black backdrop rather than scaling to fill the display. This is Wine's
  display handling, not something Proteus can fix from outside.
- Installers that download optional components only when a human clicks
  through them (OpenTTD's graphics set is the classic case) will install but
  arrive incomplete. Proteus's startup check catches this and `proteus fix`
  re-runs the installer with its interface visible.
- Games with kernel-level anti-cheat do not work, here or anywhere else on
  macOS.

---

## Español

Sueltas un `.exe`, un `.iso`, un `.zip` o la carpeta del juego en la ventana.
Proteus lee el juego, deduce lo que necesita, lo instala y deja una app normal
en `/Aplicaciones` con el icono del propio juego. Luego arranca el juego una
vez para comprobar que de verdad funciona antes de decirte que está listo.

Eso es todo el producto. No hay que crear una "botella", ni nombrar un
prefijo, ni buscar un verbo de winetricks, ni adivinar un override de DLL, ni
configurar un wrapper.

### Por qué existe

Todo lo que hoy ejecuta juegos de Windows en macOS — Wineskin, Kegworks,
Sikarugir, Bottles, Porting Kit, Wine a pelo — te pide ser el integrador.
Creas una "botella". Eliges un "motor". Adivinas si el juego quiere
`vcrun2019` o `vcrun2022`. Escoges entre WineD3D, DXVK, DXMT y D3DMetal sin
que nadie te diga cuál puede usar tu juego. Te enteras de que fallaste cuando
el juego no hace absolutamente nada.

Proteus le da la vuelta. **El programa ya sabe lo que necesita: está escrito en
su tabla de importaciones.** Así que Proteus la lee en vez de preguntarte.

### Lo que hace y los demás no

| | Proteus | Los demás |
|---|---|---|
| Detección de dependencias | Lee la tabla de imports PE del binario y mapea cada DLL al runtime exacto | Eliges verbos de una lista |
| Backend gráfico | Elegido según lo que importa el juego (`d3d12.dll` → D3DMetal, `d3d11.dll` → DXMT, `d3d9.dll` → WineD3D) | Eliges de un desplegable |
| Cuál `.exe` es el juego | Puntuado por tamaño, profundidad, subsistema GUI, icono, imports gráficos y `autorun.inf` | Buscas y eliges tú |
| Instaladores | Identifica NSIS / Inno Setup / InstallShield / MSI y usa los flags silenciosos correctos | Haces clic por el asistente dentro de un Windows falso |
| ISOs | Se monta, se lee el `autorun.inf`, se usa el nombre del disco, se ignoran las carpetas de redistribuibles | Lo montas tú |
| Icono | Extraído del árbol de recursos del ejecutable y convertido a `.icns`, con pixel-art escalado sin emborronar | La copa genérica de Wine |
| Verificación | **Arranca el juego y espera una ventana real antes de decir "listo"** | Nadie hace esto |
| Coste en disco | Motor descomprimido una vez y clonado con APFS en cada app: ~365 MB por juego extra | ~1,4 GB por juego |
| Desinstalar | Arrastras la app a la Papelera. Todo vivía dentro | Quedan botellas, prefijos y entradas de registro |

### Requisitos

- macOS 14 o posterior, Apple Silicon o Intel
- Nada más. Ni Homebrew, ni herramientas de Xcode, ni Rosetta salvo que un
  juego de DirectX 12 lo necesite de verdad.

El motor de Wine (~166 MB) y la plantilla (~80 MB) se descargan una sola vez,
la primera vez. Si ya tienes Sikarugir o Kegworks instalado, Proteus reutiliza
sus copias y no descarga nada.

### Compilar y ejecutar

```bash
./scripts/bundle.sh release
open build/Proteus.app
```

### Línea de comandos

El mismo motor, sin ventana:

```bash
proteus inspect ~/Descargas/juego.iso      # dice qué necesita, no toca nada
proteus install ~/Descargas/setup.exe      # crea la app
proteus install ~/Juegos/MiJuego --name "Mi Juego"
proteus fix "/Applications/Mi Juego.app"   # reejecuta el instalador con su interfaz
proteus uninstall "Mi Juego"
```

`inspect` no escribe nada, así que es seguro ejecutarlo sobre cualquier cosa.

### Límites conocidos

- Un juego a pantalla completa a 320×240 o 640×480 se dibuja a su tamaño
  nativo sobre un fondo negro en vez de escalar a toda la pantalla. Es cómo
  Wine gestiona la pantalla, no algo que Proteus pueda arreglar desde fuera.
- Los instaladores que descargan componentes opcionales solo cuando un humano
  hace clic (el conjunto gráfico de OpenTTD es el caso clásico) se instalan
  pero llegan incompletos. La comprobación de arranque de Proteus lo detecta y
  `proteus fix` reejecuta el instalador con su interfaz visible.
- Los juegos con anticheat a nivel de kernel no funcionan, ni aquí ni en
  ningún otro sitio en macOS.

---

## License / Licencia

Proteus builds on [Sikarugir](https://github.com/Sikarugir-App/Sikarugir) for
its wrapper template and Wine engines, and on
[Winetricks](https://github.com/Winetricks/winetricks) for component
installation. Both are used unmodified and keep their own licences.

Proteus se apoya en [Sikarugir](https://github.com/Sikarugir-App/Sikarugir)
para la plantilla y los motores de Wine, y en
[Winetricks](https://github.com/Winetricks/winetricks) para instalar
componentes. Ambos se usan sin modificar y conservan sus licencias.
