<div align="center">

<img src="docs/images/social-card.png" alt="Proteus — Juegos de Windows en tu Mac. Suelta el archivo, obtén una app." width="720">

[![build](https://github.com/dev-jackson/proteus/actions/workflows/build.yml/badge.svg)](https://github.com/dev-jackson/proteus/actions/workflows/build.yml)
[![licencia: GPL v3](https://img.shields.io/badge/licencia-GPL%20v3-blue.svg)](LICENSE)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black.svg)](#requisitos)
[![descargar](https://img.shields.io/github/v/release/dev-jackson/proteus?label=descargar&color=2ea44f)](https://github.com/dev-jackson/proteus/releases/latest)

**[Descargar para macOS](https://github.com/dev-jackson/proteus/releases/latest)**  ·  [English](README.md)  ·  [Cómo funciona](docs/ALGORITHM.md)

</div>

---

Sueltas un `.exe`, un `.iso`, un `.zip` o la carpeta del juego en la ventana.
Proteus lee el juego, deduce lo que necesita, lo instala y deja una app normal
en `/Aplicaciones` con el icono del propio juego.

Sin botellas. Sin prefijos. Sin verbos de winetricks. Sin elegir entre WineD3D,
DXVK, DXMT y D3DMetal sin que nadie te diga cuál puede usar tu juego.

## Te dice qué encontró, y por qué

<img src="docs/images/analysis.png" alt="Proteus mostrando lo que necesita GZDoom, con la evidencia de cada línea" width="820">

Cada línea lleva su evidencia detrás. GZDoom **no importa ninguna** librería
gráfica: si solo lees su tabla de importaciones, concluyes que no necesita nada.
Carga `vulkan-1.dll` por nombre en tiempo de ejecución, y por eso aparece esa
línea.

Esa es la idea entera: **un ejecutable de Windows ya declara casi todo lo que
necesita**, en estructuras que no han cambiado desde los noventa. Proteus las lee
en vez de preguntarte.

## Y luego lo comprueba, en vez de confiar

Tras instalar, arranca el juego, espera una ventana real, mira el fotograma que
dibujó y envía eventos de teclado y ratón de verdad para confirmar que llegan
—antes de decirte que está listo.

**No te promete que tu juego vaya a funcionar. Te promete decirte la verdad
sobre si funciona, y arreglar lo que pueda sin que tú aprendas nada.**

<img src="docs/images/library.png" alt="La ventana de Proteus con cuatro juegos instalados" width="820">

## Instalar

Descarga el `.dmg` desde [**Releases**](https://github.com/dev-jackson/proteus/releases/latest),
ábrelo y arrastra **Proteus** a Aplicaciones.

Firmado con un Developer ID y notarizado por Apple, así que se abre con doble
clic: sin clic derecho, sin terminal, sin `xattr -d com.apple.quarantine`.

## Comparación

|  | Proteus | Wineskin · Kegworks · Bottles · Porting Kit |
|---|---|---|
| Dependencias | Lee imports, delay imports, el manifiesto y las librerías cargadas en ejecución, y mapea cada una al runtime exacto | Eliges verbos de una lista |
| Backend gráfico | Elegido según lo que el juego usa de verdad (`d3d12` → D3DMetal, `d3d11` → DXMT, `d3d9` → WineD3D o DXVK) | Eliges de un desplegable |
| Cuál `.exe` es el juego | Puntuado por tamaño, profundidad, subsistema GUI, icono, imports gráficos y `autorun.inf` | Buscas y eliges tú |
| Instaladores | Identifica NSIS / Inno Setup / InstallShield / MSI y usa los flags silenciosos correctos | Haces clic por un asistente dentro de un Windows falso |
| ISOs | Se monta, se lee el `autorun.inf`, se usa el nombre del disco, se ignoran los redistribuibles | Lo montas tú |
| Icono | Extraído del árbol de recursos del ejecutable, con pixel art escalado sin emborronar | La copa genérica de Wine |
| Verificación | **Lo arranca y confirma ventana, imagen sana y entrada funcionando** | Nadie hace esto |
| Coste en disco | Motor descomprimido una vez y clonado con APFS por juego: ~365 MB cada uno | ~1,4 GB por juego |
| Desinstalar | Arrastras a la Papelera. Todo vivía dentro de la app | Quedan botellas, prefijos y entradas de registro |

Incluso Proton —de lejos la capa de compatibilidad más exitosa jamás publicada—
no detecta nada. Empaqueta capas de traducción y se apoya en `protonfixes`, una
tabla de parches escritos a mano por juego, más los informes de los jugadores.
Cuando un juego falla ahí, el procedimiento documentado es que *tú* pongas
`PROTON_LOG=1`, reproduzcas el fallo y leas el registro.

## Probado con

Instalaciones reales, jugadas de forma interactiva —no solo arrancadas— en tres
categorías de peso, porque un juego 2D de 40 MB y uno de DirectX 12 de 55 GB
fallan de maneras completamente distintas.

| Juego | Cómo llegó | Tamaño | Qué demostró |
|---|---|---|---|
| 7-Zip | `.msi` | 2 MB | la vía MSI, con `msiexec` |
| Cave Story | `.exe` e `.iso` | 40 MB | montaje de disco, `autorun.inf`, solo teclado |
| Steam | instalador NSIS | 2 MB | título conocido que necesita `-no-cef-sandbox` |
| OpenTTD | instalador NSIS | 1,5 GB | la instalación silenciosa omite sus gráficos: detectado y reparado |
| GZDoom + Freedoom | `.zip` portable | 1,6 GB | un renderer que solo aparece en cadenas de ejecución |
| Warzone 2100 | Inno Setup | 371 MB → 2,5 GB | progreso en instalación larga; cambio de motor y recuperación |
| Un título CryEngine de DirectX 12 | imagen de disco de 40 GB | 55 GB instalado | el camino pesado de principio a fin |

De ese último salieron casi todas las lecciones caras. Una instalación de 40 GB
no se rehace a la ligera, así que obligó a la recuperación de instalaciones
interrumpidas (`proteus finish`), a la comprobación previa de espacio en disco,
al progreso real, y al descubrimiento de que **todos los juegos de DirectX 12
recibían el motor de Wine equivocado** —porque el motor hay que elegirlo antes
de ejecutar el instalador, que es antes de que se pueda saber nada del juego—.
Ahora Proteus cambia el motor después sin copiar un solo byte de nuevo.

Sin probar y dicho sin adornos: **InstallShield** y los **mandos** —el código
está, pero ningún mando físico ha pasado por ahí—. Ver
[docs/TESTS.md](docs/TESTS.md), que también recoge las hipótesis fallidas.

## Requisitos

macOS 14 o posterior, Apple Silicon o Intel. Nada más: ni Homebrew, ni
herramientas de Xcode, ni Rosetta salvo que un juego de DirectX 12 lo necesite
de verdad.

El motor de Wine (~166 MB) y la plantilla (~80 MB) se descargan una sola vez.
Si ya tienes Sikarugir o Kegworks, Proteus reutiliza sus copias y no descarga
nada.

## Línea de comandos

El mismo motor, sin ventana:

```bash
proteus inspect ~/Descargas/juego.iso      # dice qué necesita, no toca nada
proteus install ~/Descargas/setup.exe      # crea la app
proteus install ~/Juegos/MiJuego --name "Mi Juego"
proteus fix "/Applications/Mi Juego.app"   # reejecuta el instalador con su interfaz
proteus uninstall "Mi Juego"
```

`inspect` no escribe nada, así que es seguro ejecutarlo sobre cualquier cosa.

## Límites conocidos

- Un juego a pantalla completa a 320×240 o 640×480 se dibuja a su tamaño nativo
  sobre fondo negro en vez de escalar. Es cómo Wine gestiona la pantalla, no
  algo que Proteus pueda arreglar desde fuera.
- Los instaladores que descargan contenido opcional solo cuando un humano hace
  clic llegan incompletos. La comprobación de arranque lo detecta y
  `proteus fix` reejecuta el instalador con su interfaz visible.
- Los juegos con anticheat a nivel de kernel no funcionan, ni aquí ni en ningún
  otro sitio en macOS.

## Compilar desde el código

```bash
swift test              # 16 tests, menos de un segundo
./scripts/bundle.sh     # crea build/Proteus.app
open build/Proteus.app
```

## Contribuir

Los informes de juegos que **no** funcionan son lo más útil que se puede
mandar. Clic derecho en el juego dentro de Proteus → **Copiar informe de
diagnóstico** → abre un issue.

Ver [CONTRIBUTING.md](CONTRIBUTING.md). Una sola regla: nunca afirmar que un
juego funciona sin haberlo visto funcionar.

## Licencia

Software libre bajo la **GPL, versión 3 o posterior**. Ver [LICENSE](LICENSE).

Es deliberado: cualquiera puede usarlo, estudiarlo, modificarlo y
redistribuirlo, y toda versión distribuida debe llegar con las mismas
libertades. Nadie, ni su autor, puede cerrar una versión posterior.

Proteus **no empaqueta código de terceros**. El motor de Wine, la plantilla
([Sikarugir](https://github.com/Sikarugir-App/Sikarugir)), DXMT y
[Winetricks](https://github.com/Winetricks/winetricks) se descargan en tu
máquina la primera vez, como Homebrew descarga una fórmula, y se usan sin
modificar bajo sus propias licencias. Ver [THIRD-PARTY.md](THIRD-PARTY.md).

---

<div align="center">
<sub>Proteo era el dios marino que cambiaba de forma a voluntad: león, serpiente,
agua, fuego, lo que pidiera el momento. De él viene "proteico".<br>
Que un juego de Windows se vuelva una app de Mac es el mismo truco.</sub>
</div>
