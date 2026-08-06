// Proteus — Windows games on macOS, without the ceremony.
// Copyright (C) 2026 Jackson Sánchez Rodríguez
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. It is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY. See <https://www.gnu.org/licenses/>.

import Foundation

/// Proteus ships in English and Spanish. Rather than a .strings file per
/// language — overkill for one screen — every string is a pair, picked once at
/// launch from the system language.
enum Lang {
    static let isSpanish: Bool = {
        let preferred = Locale.preferredLanguages.first ?? "en"
        return preferred.hasPrefix("es")
    }()

    static func pick(_ en: String, _ es: String) -> String { isSpanish ? es : en }
}

/// `S.dropTitle` reads better than a call at every use site.
enum S {
    static var appTagline: String { Lang.pick("Windows games on your Mac", "Juegos de Windows en tu Mac") }

    static var dropTitle: String { Lang.pick("Drop a game here", "Suelta un juego aquí") }
    static var dropSubtitle: String {
        Lang.pick("An .exe, an .iso, a .zip, or the game's folder",
                  "Un .exe, un .iso, un .zip o la carpeta del juego")
    }
    static var chooseFile: String { Lang.pick("Choose a file…", "Elegir un archivo…") }

    static var analysing: String { Lang.pick("Looking at the game…", "Revisando el juego…") }
    static var whatItNeeds: String { Lang.pick("What this game needs", "Lo que necesita este juego") }
    static var nothingExtra: String {
        Lang.pick("Nothing extra — it runs on Wine as-is",
                  "Nada extra: funciona con Wine tal cual")
    }
    static var handledAutomatically: String {
        Lang.pick("Proteus installs all of this for you.",
                  "Proteus instala todo esto por ti.")
    }

    static var nameLabel: String { Lang.pick("Name", "Nombre") }
    static var typeLabel: String { Lang.pick("Type", "Tipo") }
    static var programLabel: String { Lang.pick("Program", "Programa") }
    static var graphicsLabel: String { Lang.pick("Graphics", "Gráficos") }
    static var downloadLabel: String { Lang.pick("One-time download", "Descarga única") }
    static var noDownload: String { Lang.pick("Already downloaded", "Ya descargado") }

    static var typePortable: String { Lang.pick("Ready to run", "Listo para ejecutar") }
    static var typeInstaller: String { Lang.pick("Installer", "Instalador") }
    static var typeDisc: String { Lang.pick("Disc image", "Imagen de disco") }

    static var install: String { Lang.pick("Install", "Instalar") }
    static var cancel: String { Lang.pick("Cancel", "Cancelar") }
    static var installing: String { Lang.pick("Installing", "Instalando") }
    static var startOver: String { Lang.pick("Add another game", "Añadir otro juego") }

    static func readyTitle(_ name: String) -> String {
        Lang.pick("\(name) is ready", "\(name) está listo")
    }
    static var readyBody: String {
        Lang.pick("It's in your Applications folder, like any other app.",
                  "Está en tu carpeta Aplicaciones, como cualquier otra app.")
    }
    static var play: String { Lang.pick("Play", "Jugar") }
    static var showInFinder: String { Lang.pick("Show in Finder", "Mostrar en Finder") }
    static var notes: String { Lang.pick("Notes", "Notas") }

    static var somethingWentWrong: String { Lang.pick("That didn't work", "Eso no funcionó") }
    static var tryAgain: String { Lang.pick("Try again", "Intentar de nuevo") }

    static var library: String { Lang.pick("Your games", "Tus juegos") }
    static var libraryEmpty: String {
        Lang.pick("Games you add will show up here.",
                  "Los juegos que añadas aparecerán aquí.")
    }
    static var remove: String { Lang.pick("Remove", "Eliminar") }
    static func removeConfirm(_ name: String) -> String {
        Lang.pick("Remove \(name)? This deletes the game and its saved files.",
                  "¿Eliminar \(name)? Esto borra el juego y sus partidas guardadas.")
    }
    static var removeAction: String { Lang.pick("Remove", "Eliminar") }
    static var keep: String { Lang.pick("Keep", "Conservar") }

    static var engineLabel: String { Lang.pick("Built with", "Hecho con") }
    static var controlsLabel: String { Lang.pick("Controls", "Controles") }
    static var keyboard: String { Lang.pick("keyboard", "teclado") }
    static var mouse: String { Lang.pick("mouse", "ratón") }
    static var gamepad: String { Lang.pick("gamepad", "mando") }

    static var inputChecked: String { Lang.pick("Controls checked", "Controles comprobados") }
    static var startedChecked: String {
        Lang.pick("Proteus started it and saw it open a window.",
                  "Proteus lo arrancó y vio que abrió una ventana.")
    }

    static var gamepadToggle: String { Lang.pick("Controller support", "Soporte de mando") }
    static var gamepadHint: String {
        Lang.pick("Turn this off if the game stops responding while a controller is plugged in.",
                  "Desactívalo si el juego deja de responder con un mando conectado.")
    }
    static var windowedToggle: String { Lang.pick("Play in a window", "Jugar en ventana") }
    static var windowedHint: String {
        Lang.pick("Use this when a fullscreen game renders too small to read.",
                  "Úsalo cuando un juego a pantalla completa se ve demasiado pequeño.")
    }
    static var openLogs: String { Lang.pick("Open logs", "Abrir registros") }
    static var openSaves: String { Lang.pick("Open saved games", "Abrir partidas guardadas") }
    static var saveChanges: String { Lang.pick("Save", "Guardar") }
    static var savedNote: String {
        Lang.pick("Saved. It takes effect next time you play.",
                  "Guardado. Se aplica la próxima vez que juegues.")
    }
    static var close: String { Lang.pick("Close", "Cerrar") }
    static var doubleClickToPlay: String {
        Lang.pick("Double-click to play", "Doble clic para jugar")
    }
    static var verifyItWorks: String { Lang.pick("Check it still works", "Comprobar que sigue funcionando") }
    static var resetSettings: String { Lang.pick("Reset settings", "Restablecer ajustes") }
    static var copyLog: String { Lang.pick("Copy last log", "Copiar último registro") }
    static var copyReport: String { Lang.pick("Copy diagnostic report", "Copiar informe de diagnóstico") }
    static var showLogs: String { Lang.pick("Show logs in Finder", "Mostrar registros en Finder") }
    static var showSaves: String { Lang.pick("Show saved games", "Mostrar partidas guardadas") }
    static var rebuildWindows: String {
        Lang.pick("Rebuild Windows environment", "Reconstruir el entorno de Windows")
    }
    static var deleteSaves: String { Lang.pick("Delete saved games…", "Borrar partidas guardadas…") }

    static func deleteSavesConfirm(_ name: String, _ size: String) -> String {
        Lang.pick("Delete \(name)'s saved games? That is \(size) of progress, and it goes to the Trash.",
                  "¿Borrar las partidas guardadas de \(name)? Son \(size) de progreso, y van a la Papelera.")
    }
    static func rebuildConfirm(_ name: String) -> String {
        Lang.pick("Rebuild the Windows environment for \(name)? The game and its saved games are kept; only Windows itself is made new.",
                  "¿Reconstruir el entorno de Windows de \(name)? Se conservan el juego y las partidas; solo se rehace Windows.")
    }
    static var copiedNote: String { Lang.pick("Copied to the clipboard", "Copiado al portapapeles") }
    static var noLogNote: String {
        Lang.pick("No log yet — play the game once", "Aún no hay registro: juega una vez")
    }
    static var settingsResetNote: String { Lang.pick("Settings reset", "Ajustes restablecidos") }
    static var workingNote: String { Lang.pick("Working…", "Trabajando…") }
    static var whySetUp: String { Lang.pick("Why it is set up this way", "Por qué está configurado así") }
    static var noReasonsYet: String {
        Lang.pick("This game was set up before Proteus started recording its reasoning.",
                  "Este juego se configuró antes de que Proteus guardara su razonamiento.")
    }
    static var reanalyse: String { Lang.pick("Work it out again", "Volver a analizar") }
    static var reanalyseHint: String {
        Lang.pick("Reads the installed game again and applies what it finds, including switching the Wine engine if the game turns out to need DirectX 12.",
                  "Vuelve a leer el juego instalado y aplica lo que encuentra, incluido cambiar el motor de Wine si resulta que necesita DirectX 12.")
    }
    static var ifSomethingIsWrong: String { Lang.pick("If something is wrong", "Si algo va mal") }
    static var rebuildHint: String {
        Lang.pick("Rebuilding replaces Windows itself. The game and your saved games are untouched.",
                  "Reconstruir rehace solo Windows. El juego y tus partidas no se tocan.")
    }
    static var settings: String { Lang.pick("Settings", "Ajustes") }

    static var rosettaNote: String {
        Lang.pick("This game needs Rosetta 2. macOS will offer to install it the first time you play.",
                  "Este juego necesita Rosetta 2. macOS te ofrecerá instalarlo la primera vez que juegues.")
    }
    static var thirtyTwoBitNote: String {
        Lang.pick("This is a 32-bit game. It runs, but expect the odd rough edge.",
                  "Es un juego de 32 bits. Funciona, pero puede tener algún detalle.")
    }
}
