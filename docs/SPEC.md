# vbox-relocate - Spezifikation

| Feld    | Wert                                   |
|---------|----------------------------------------|
| Status  | Entwurf                                |
| Version | 0.2.0 (2026-11-22)                     |
| Ziel    | VirtualBox 7.2 auf Linux-Hosts (Ubuntu) |

---

## 1. Ziel und Umfang

`vbox-relocate` verschiebt den **kompletten Ordner einer VirtualBox-VM** auf
demselben Host in ein anderes Verzeichnis bzw. Dateisystem - auch wenn die VM
läuft. Die Ausfallzeit für den Gast soll im Bereich weniger Sekunden liegen
(funktional vergleichbar mit "Storage vMotion" bei VMware, beschränkt auf einen
Host).

### 1.1 Ziele

- Umzug des kompletten VM-Ordners (`.vbox`, Images, Snapshots, NVRAM, Logs,
  gespeicherte Zustände).
- VMs **mit Snapshots** werden vollständig unterstützt (Snapshot-Baum bleibt
  erhalten).
- Laufende VMs: Ausfallzeit nur für das Speichern und Wiederherstellen des
  RAM-Zustands (wenige Sekunden).
- **RAM-Modus:** Ist genug freier Arbeitsspeicher vorhanden, wird die
  RAM-Zustandsdatei (`.sav`) während des Umzugs in einem tmpfs statt auf der
  Platte abgelegt (schont die Platten, ist schneller).
- Start des Umzugs aus einer grafischen Oberfläche mit Fortschrittsanzeige
  (PySide6), alternativ per Kommandozeile.
- Aktuelle Umgebung: btrfs (Quelle und Ziel im selben btrfs-Dateisystem).
  Spätere Umzüge auf **andere Dateisysteme** müssen ebenfalls möglich sein.
- Sicherheit vor Geschwindigkeit: Die Quelle bleibt unverändert nutzbar, bis
  die VM am Ziel erfolgreich läuft.

### 1.2 Nicht-Ziele (Version 1)

- Umzug auf einen anderen Host (dafür existiert VirtualBox-Teleporting).
- Andere Host-Betriebssysteme als Linux.
- btrfs-Subvolume-spezifische Verfahren (`btrfs send/receive`) - werden nicht
  benötigt.
- Verschieben von Medien **außerhalb** des VM-Ordners (z. B. ISO-Bibliotheken,
  gemeinsam genutzte Images). Sie bleiben an ihrem Ort und werden weiter
  referenziert.
- VMs mit VirtualBox-VM-Verschlüsselung.
- VMs, deren Snapshot-Ordner außerhalb des VM-Ordners liegt.
- Ein Menüeintrag direkt im VirtualBox Manager (siehe Abschnitt 3.1).

---

## 2. Begriffe

| Begriff           | Bedeutung |
|-------------------|-----------|
| Quelle            | Bisheriger VM-Ordner (Verzeichnis der `.vbox`-Datei). |
| Ziel              | Neuer VM-Ordner: `<Zielverzeichnis>/<Name des Quellordners>`. |
| Snapshot-Ordner   | `SnapshotFolder` der VM, enthält Differenz-Images und `.sav`-Dateien. |
| `.sav`            | Gespeicherter Maschinenzustand (RAM, Gerätezustände). |
| Umschaltphase     | Zeitraum von `savestate` bis zum erneuten Start der VM am Ziel. Einzige Ausfallzeit. |
| Strategie         | Gewähltes Umzugsverfahren (Abschnitt 6). |
| Helfer            | Kleines root-Programm für Mount-Operationen, freigegeben per polkit. |

---

## 3. Technische Grundlagen (verifiziert)

Die folgenden Aussagen wurden im VirtualBox-Quellcode (GitHub
`VirtualBox/virtualbox`, Branch `main`, Stand 2026-11) bzw. in der offiziellen
Dokumentation geprüft. Sie bestimmen die Architektur.

| # | Befund | Fundstelle |
|---|--------|------------|
| G1 | Extension Packs haken sich nur in VBoxSVC (`VBoxExtPackRegister`) und den VM-Prozess (`VBoxExtPackVMRegister`) ein. Die Qt-GUI bietet keine Erweiterungspunkte für Menüs/Dialoge Dritter. | `include/VBox/ExtPack/ExtPack.h`, `src/VBox/Frontends/VirtualBox/src/` |
| G2 | `IMedium::moveTo` und `IMedium::setLocation` verweigern, solange eine VM-Session offen ist ("Stop all VMs before ..."). | `src/VBox/Main/src-server/MediumImpl.cpp` |
| G3 | Die `.sav`-Datei wird immer unter `<SnapshotFolder>/<YYYY-MM-DDTHH-MM-SS-NNNNNNNNNZ>.sav` angelegt. Der Name ist vorher nicht bekannt. | `Machine::i_composeSavedStateFilename` in `MachineImpl.cpp` |
| G4 | `SnapshotFolder` lässt sich nur in den Zuständen PoweredOff, Aborted, Teleported ändern - nicht bei laufender oder gespeicherter VM. | `Machine::setSnapshotFolder`, `MutableStateDep` in `MachineImpl.cpp` |
| G5 | Pfade innerhalb des VM-Ordners werden in der `.vbox`-Datei relativ gespeichert. | `Machine::i_copyPathRelativeToMachine` in `MachineImpl.cpp` |
| G6 | Ein Online-Snapshot schreibt ebenfalls eine `.sav`-Datei (RAM-Inhalt). | `SnapshotImpl.cpp` (takeSnapshot, online) |
| G7 | Beim Löschen eines Snapshots eines Basis-Images wird das Differenz-Image in das Basis-Image zurückgeführt (backward merge); bei Differenz-Images wählt VirtualBox die Richtung nach Dateigröße. Online-Löschen ist bei laufender VM möglich. | `SnapshotImpl.cpp`, `Medium::i_queryPreferredMergeDirection` |
| G8 | Teleporting setzt gemeinsamen Speicher und **keine Snapshots** voraus - daher nicht verwendbar. | Handbuch, Kapitel Teleporting |
| G9 | Nach erfolgreichem Start aus einem per `savestate` gespeicherten Zustand löscht VirtualBox die `.sav`-Datei. | `VirtualBox.xidl` (IMachine::saveState) |

### 3.1 Konsequenz für die GUI-Integration

Wegen G1 ist eine native Integration in den VirtualBox Manager per Extension
Pack nicht möglich. Alternativen und Entscheidung:

| Variante | Bewertung |
|----------|-----------|
| Eigene Begleit-App (PySide6) | **Gewählt.** Volle Kontrolle, echte Fortschrittsbalken, keine Änderung an VirtualBox. |
| Patch/Fork des VirtualBox Managers | Verworfen: muss bei jedem VirtualBox-Update neu gebaut werden. |
| Beitrag an Oracle (GitHub, OCA nötig) | Optional langfristig, außerhalb dieses Projekts. |

Der VirtualBox Manager zeigt die Zustandswechsel der VM (Saving, Saved,
Restoring, Running, Deleting Snapshot) während des Umzugs trotzdem live an.

### 3.2 Konsequenz für den RAM-Modus

Wegen G3 und G4 lässt sich der Ablageort der `.sav` bei laufender VM nicht mit
VirtualBox-Mitteln umlenken. Ein Symlink auf die Datei scheitert am unbekannten
Namen (G3). Ein Symlink oder tmpfs-Mount auf den ganzen Snapshot-Ordner würde
die dort liegenden, aktiven Differenz-Images verdecken.

Gewählte Lösung: **overlayfs nur während `savestate`** über den
Snapshot-Ordner (Abschnitt 7).

---

## 4. Rahmenbedingungen und Annahmen

- Host: Ubuntu (aktuelle LTS), Kernel >= 6.8, VirtualBox 7.2 aus den
  Oracle-Paketen (kein Snap/Flatpak, damit VBoxSVC dieselben Mounts sieht).
- VBoxSVC und VM-Prozesse laufen als der jeweilige Benutzer. Das Werkzeug läuft
  ebenfalls als dieser Benutzer; nur Mount-Operationen benötigen root.
- `VBoxManage` ist die einzige Schnittstelle zu VirtualBox in Version 1
  (keine Python-SDK-Bindings nötig).
- Benötigte Werkzeuge: `bash` >= 5, `coreutils` (`cp --reflink`), `findmnt`,
  `rsync`, `flock`, `pkexec` (polkit), Python >= 3.10 und PySide6 für die GUI.

---

## 5. Architektur

```
+---------------------------+        startet / liest Fortschritt
| vbox-relocate-gui         | ----------------------------------+
| (Python, PySide6)         |                                   |
+---------------------------+                                   v
                                                  +---------------------------+
                                                  | vbox-relocate (Bash, CLI) |
                                                  | laeuft als Benutzer       |
                                                  +---------------------------+
                                                     |                    |
                                     VBoxManage      |                    | pkexec
                                     cp/rsync        v                    v
                                         +----------------+   +--------------------------+
                                         | VBoxSVC / VMs  |   | vbox-relocate-helper     |
                                         | (Benutzer)     |   | (root, Whitelist)        |
                                         +----------------+   | tmpfs, overlayfs mounten |
                                                              +--------------------------+
```

| Komponente | Sprache | Aufgabe |
|------------|---------|---------|
| `vbox-relocate` | Bash | Gesamte Logik: Prüfungen, Strategiewahl, Ablauf, Rückfall, Fortschritt. |
| `vbox-relocate-helper` | Bash | Nur privilegierte Schritte (Mounts). Strikte Eingabeprüfung. |
| polkit-Policy | XML | Freigabe des Helfers. |
| `vbox-relocate-gui` | Python/PySide6 | Bedienoberfläche. Enthält keine Umzugslogik, ruft nur die CLI auf. |

Grundsatz: **Die Logik liegt ausschließlich in der CLI.** Die GUI ist eine
Hülle; jede Funktion ist auch ohne GUI nutzbar.

---

## 6. Umzugsverfahren

### 6.1 Strategiewahl (`--strategy auto`)

| VM-Zustand | Quelle und Ziel im selben Dateisystem? | Strategie |
|------------|----------------------------------------|-----------|
| PoweredOff, Aborted, Saved, AbortedSaved | egal | `offline` |
| Running, Paused | ja, btrfs (Reflink möglich) | `reflink` |
| Running, Paused | nein, oder kein Reflink möglich | `copy` |
| alle anderen (Saving, Restoring, Snapshotting, ...) | - | Abbruch: VM in Übergangszustand |

"Selbes Dateisystem" wird über die Dateisystem-UUID bestimmt
(`findmnt -n -o UUID --target <pfad>`), nicht über `st_dev` (btrfs-Subvolumes
haben eigene Gerätenummern). Ob Reflink wirklich funktioniert, prüft die CLI mit
einer kleinen Testdatei im Zielverzeichnis.

### 6.2 Gemeinsame Vorprüfungen

Alle Prüfungen laufen vor jeder Änderung. Jede Verletzung führt zu Abbruch mit
verständlicher Meldung (Ausnahme: als Warnung markierte Punkte).

1. `VBoxManage` vorhanden, Version 7.2.x.
2. VM existiert; Daten per `VBoxManage showvminfo <uuid> --machinereadable`
   (`CfgFile`, `SnapFldr`, `VMState`, `memory`, `vram`, Medien-Anhänge).
3. Kein paralleler Lauf für dieselbe VM (Lock-Datei, `flock`).
4. Zielverzeichnis: absolut, existiert, beschreibbar; `<Ziel>/<Ordnername>`
   existiert noch nicht; Ziel liegt nicht innerhalb der Quelle.
5. Snapshot-Ordner liegt innerhalb des VM-Ordners.
6. Keine VM-Verschlüsselung.
7. Medien klassifizieren:
   - innerhalb des VM-Ordners -> werden mit verschoben,
   - außerhalb -> bleiben, **Warnung**.
8. Kein Medium im VM-Ordner hat Kind-Images anderer VMs (Linked Clones, deren
   Basis in dieser VM liegt) -> sonst Abbruch.
9. Kein Medium im VM-Ordner ist zusätzlich in der globalen Medien-Registry
   (`VirtualBox.xml`) mit absolutem Pfad eingetragen (Altlast älterer VMs) ->
   sonst Abbruch mit Hinweis.
10. Keine fremde Session-Sperre (z. B. offener Einstellungsdialog).
11. Speicherplatz am Ziel >= belegter Platz des VM-Ordners + Reserve
    (bei `reflink` nur Reserve für Metadaten).
12. Nur Strategie `copy`: keine `writethrough`- oder `shareable`-Platten im
    VM-Ordner (diese werden von Snapshots nicht erfasst); Platz auf der Quelle
    für das temporäre Differenz-Image und die temporäre Snapshot-`.sav`.
13. RAM-Modus-Prüfung (Abschnitt 7.2).

### 6.3 Strategie `offline`

Für VMs, die nicht laufen. Keine Ausfallzeit im eigentlichen Sinn.

1. Vorprüfungen.
2. Ordner nach `<Ziel>/<Ordnername>.relocate-tmp` kopieren: per
   `cp -a --reflink=always`, wenn Reflink möglich ist, sonst per `rsync`.
3. Kopie prüfen (Abschnitt 6.6), dann in den endgültigen Namen umbenennen.
4. `VBoxManage unregistervm <uuid>` (ohne `--delete`).
5. `VBoxManage registervm <Ziel>/<Name>.vbox`.
6. Registrierung prüfen: `CfgFile`, Medienpfade, Zustand unverändert.
7. Aufräumen (Abschnitt 6.7).

### 6.4 Strategie `reflink` (laufende VM, selbes btrfs)

Der Hauptfall der aktuellen Umgebung. Daten werden nicht kopiert, sondern per
Reflink geteilt; die Umschaltphase dauert nur so lange wie das Speichern und
Laden des RAM-Zustands.

1. Vorprüfungen.
2. *[RAM-Modus]* tmpfs und overlayfs über den Snapshot-Ordner einrichten
   (Abschnitt 7.3, Schritte R1-R2).
3. **Beginn Umschaltphase:** `VBoxManage controlvm <uuid> savestate`.
4. *[RAM-Modus]* `.sav` in den tmpfs verschieben, overlay lösen, Symlink anlegen
   (Abschnitt 7.3, Schritte R3-R6).
5. Ordner per `cp -a --reflink=always` nach `<Ziel>/<Ordnername>.relocate-tmp`
   kopieren (Symlinks bleiben Symlinks), prüfen, umbenennen.
6. `unregistervm` (Quelle), `registervm` (Ziel), Registrierung prüfen.
7. `VBoxManage startvm <uuid> --type <wie vorher>`; warten bis `running`.
   **Ende Umschaltphase.**
8. Aufräumen (Abschnitt 6.7).

### 6.5 Strategie `copy` (laufende VM, anderes Dateisystem)

Für spätere Umzüge auf andere Dateisysteme. Idee: Ein temporärer Snapshot macht
alle vorhandenen Images schreibgeschützt; diese werden kopiert, während die VM
läuft. In der Umschaltphase wird nur der kleine Rest kopiert.

1. Vorprüfungen.
2. Temporären Live-Snapshot anlegen:
   `VBoxManage snapshot <uuid> take vbox-relocate-<zeitstempel> --live`.
   Danach sind alle bisherigen Images (auch die bestehender Snapshots)
   schreibgeschützt; neue Schreibzugriffe gehen in neue Differenz-Images.
   Die dabei entstehende Snapshot-`.sav` wird ebenfalls nicht mehr verändert.
3. **Vorkopie bei laufender VM:** alle Dateien des VM-Ordners außer
   - den aktuellen (beschreibbaren) Differenz-Images,
   - `.vbox`, `.vbox-prev`, `.nvram`,
   - `Logs/`
   nach `<Ziel>/<Ordnername>.relocate-tmp` kopieren
   (`rsync -a --sparse --info=progress2`; Werkzeug wird im Prototyp final
   festgelegt).
4. Vorkopie prüfen (Abschnitt 6.6).
5. *[RAM-Modus]* overlay einrichten (R1-R2).
6. **Beginn Umschaltphase:** `savestate`.
7. *[RAM-Modus]* R3-R6.
8. Restabgleich: zweiter `rsync`-Lauf über den ganzen Ordner (überträgt nur
   geänderte und neue Dateien), prüfen, umbenennen.
9. `unregistervm` (Quelle), `registervm` (Ziel), Registrierung prüfen.
10. `startvm`, warten bis `running`. **Ende Umschaltphase.**
11. Temporären Snapshot online löschen:
    `VBoxManage snapshot <uuid> delete vbox-relocate-<zeitstempel>`.
    Das Zusammenführen geschieht vollständig im Ziel (G7).
12. Aufräumen (Abschnitt 6.7).

Hinweis: Die Dauer der Umschaltphase hängt hier von der Datenmenge ab, die der
Gast zwischen Schritt 2 und 6 geschrieben hat.

Offener Punkt: Im RAM-Modus wird bei dieser Strategie in Version 1 nur die
**finale** `.sav` (Schritt 6) im tmpfs abgelegt. Die `.sav` des temporären
Snapshots (Schritt 2) geht auf die Platte, weil sonst auch die neuen
Differenz-Images im tmpfs landen und dort während der gesamten Vorkopie wachsen
würden.

### 6.6 Prüfung der Kopie

| Stufe (`--verify`) | Inhalt |
|--------------------|--------|
| `size` (Standard)  | Vollständige Dateiliste und Dateigrößen identisch. |
| `checksum`         | Zusätzlich SHA-256 aller Images (bei `reflink` nicht nötig, bei `copy` empfohlen). |

### 6.7 Aufräumen

Erst nachdem die VM am Ziel läuft (bzw. bei `offline` korrekt registriert ist):

- Quellordner löschen (Standard) oder mit `--keep-source` umbenennen in
  `<Ordnername>.relocated-<zeitstempel>`.
- *[RAM-Modus]* tmpfs-Datei und tmpfs lösen (Helfer).
- Lock und Journal entfernen.

---

## 7. RAM-Modus

### 7.1 Zweck

Die `.sav`-Datei der Umschaltphase (Größe bis RAM + VRAM der VM) soll nicht auf
die Platte geschrieben werden. Bei `reflink` entstehen dadurch praktisch keine
Daten-Schreibzugriffe auf die Platte.

### 7.2 Speicherprüfung

```
geschaetzte_sav_groesse = (memory + vram) * 1.05            [MiB]
reserve                 = max(VBOX_RELOCATE_RAM_RESERVE, 10 % von MemTotal)
benoetigt               = geschaetzte_sav_groesse + reserve
verfuegbar              = MemAvailable aus /proc/meminfo
```

| `--ram-mode` | Verhalten |
|--------------|-----------|
| `auto` (Standard) | RAM-Modus, wenn `verfuegbar >= benoetigt`; sonst `.sav` auf Platte mit deutlicher Meldung. |
| `require` | Abbruch, wenn nicht genug Speicher frei ist. |
| `off` | `.sav` immer auf Platte. |

Zusätzliche Hinweise in der Planausgabe:
- Ist Swap aktiv, können tmpfs-Seiten ausgelagert werden (Warnung).
- Die Schätzung ist eine Obergrenze; die tatsächliche Größe wird im Prototyp
  gemessen (V9).

### 7.3 Ablauf

| Schritt | Aktion | Ausführung |
|---------|--------|------------|
| R1 | tmpfs mit `size=<benoetigt>` unter `/run/vbox-relocate/<uuid>/ram` einhängen, Eigentümer = Benutzer. | Helfer |
| R2 | overlayfs über den Snapshot-Ordner: `lowerdir=<SnapFldr>`, `upperdir`/`workdir` im tmpfs. Vorhandene Dateien bleiben sichtbar, **neue** Dateien landen im tmpfs. | Helfer |
| (savestate) | VirtualBox schreibt die `.sav` -> landet im tmpfs. | CLI |
| R3 | Prüfen: `upperdir` enthält **genau eine** neue `.sav` und sonst nichts (keine kopierten Differenz-Images). Sonst Abbruch mit Rückfall. | CLI |
| R4 | `.sav` innerhalb des tmpfs aus dem `upperdir` in `/run/vbox-relocate/<uuid>/ram/state/` verschieben (Umbenennung, kein Kopieren). | Helfer |
| R5 | overlay lösen. Der Snapshot-Ordner ist wieder reines btrfs. | Helfer |
| R6 | Im Quell-Snapshot-Ordner Symlink `<name>.sav -> /run/vbox-relocate/<uuid>/ram/state/<name>.sav` anlegen. Damit ist die Quelle weiterhin startbar (Rückfall), und die Kopie übernimmt den Symlink. | CLI |
| (start) | VirtualBox liest die `.sav` über den Symlink und löscht danach den Symlink (G9). | CLI |
| R7 | tmpfs-Datei löschen, tmpfs lösen. | Helfer |

Restrisiko: Fällt der Host zwischen `savestate` und dem Ende des Starts aus, ist
der RAM-Zustand verloren. Die VM startet dann kalt (wie nach Stromausfall); die
Images sind konsistent zum Zeitpunkt des Anhaltens. Die Planausgabe weist darauf
hin.

---

## 8. Fehlerbehandlung und Rückfall

### 8.1 Grundsatz

Die Quelle wird bis zum erfolgreichen Start am Ziel **nicht verändert**
(abgesehen vom gespeicherten Zustand und ggf. dem temporären Snapshot). Jeder
Fehler vor Abschluss führt zum Rückfall auf die Quelle.

### 8.2 Rückfall je Phase

| Fehler in Phase | Rückfall |
|-----------------|----------|
| Vorprüfungen | Nichts zu tun. |
| Vorkopie (`copy`) | Zielkopie löschen, temporären Snapshot online löschen. VM lief durchgehend. |
| `savestate` | Zielkopie löschen; Zustand prüfen. Läuft die VM noch, temporären Snapshot löschen (`copy`). Verhalten von VirtualBox bei fehlgeschlagenem `savestate` ist zu verifizieren (V4). |
| Kopie/Prüfung nach `savestate` | Zielkopie löschen, Quelle starten (`.sav` über Symlink bzw. auf Platte). |
| `registervm` am Ziel | Ziel abmelden (falls registriert), Quelle registrieren und starten. |
| Start am Ziel | Ziel abmelden, Quelle registrieren und starten. |
| Online-Löschen des temp. Snapshots | VM läuft bereits am Ziel; Snapshot bleibt stehen, Warnung mit Anleitung. |

### 8.3 Journal und Wiederaufnahme

Jeder abgeschlossene Schritt wird in ein Journal geschrieben:
`${XDG_STATE_HOME:-${HOME}/.local/state}/vbox-relocate/<uuid>.journal`.
Bricht das Werkzeug selbst ab (Absturz, Abmeldung), kann
`vbox-relocate recover <vm>` den Rückfall oder den Abschluss durchführen.

---

## 9. Kommandozeile `vbox-relocate`

Umsetzung nach den Skript-Konventionen (Header mit Programmablaufplan, ASCII,
Englisch für Ausgaben und Kommentare, `"${var}"`-Quoting, aussagekräftige
Fehlermeldungen, Exit-Status 0/1, Aufruffehler 2).

### 9.1 Unterbefehle

| Unterbefehl | Zweck |
|-------------|-------|
| `list` | VMs mit Zustand, Ordner, Größe, Anzahl Snapshots. |
| `plan <vm> -t <dir>` | Probelauf: alle Prüfungen, gewählte Strategie, RAM-Modus-Entscheidung, geschätzte Umschaltzeit, Warnungen. Ändert nichts. |
| `run <vm> -t <dir>` | Umzug durchführen. |
| `recover <vm>` | Abgebrochenen Lauf anhand des Journals zurückrollen oder abschließen. |

### 9.2 Optionen

Präzedenz: Kommandozeile > Umgebungsvariable > Konfigurationsdatei >
Standardwert.

**Konfigurationsdatei (E2):** nur nutzerspezifisch im Home-Verzeichnis, wird
gesourct, die erste gefundene Datei gilt:

1. `~/.config/<ORGANIZATION>/vbox-relocate.conf` (ORGANIZATION aus `/etc/org.conf`)
2. `~/.config/orgdefault/vbox-relocate.conf`
3. `~/.config/vbox-relocate.conf`

Schlüssel: `TARGET`, `STRATEGY`, `RAM_MODE`, `RAM_RESERVE`, `VERIFY`,
`KEEP_SOURCE`, `START_TYPE`, `VBOXMANAGE`, `STATE_DIR`, `VERBOSE`, `SILENT`.
Beispiel: `examples/vbox-relocate.conf`.

| Option | Umgebungsvariable | Standard | Bedeutung |
|--------|-------------------|----------|-----------|
| `<vm>` (Argument) | `VBOX_RELOCATE_VM` | - | Name oder UUID der VM. |
| `-t, --target DIR` | `VBOX_RELOCATE_TARGET` | - | Zielverzeichnis (übergeordnet); der Ordnername bleibt gleich. |
| `--strategy S` | `VBOX_RELOCATE_STRATEGY` | `auto` | `auto`, `offline`, `reflink`, `copy`. |
| `--ram-mode M` | `VBOX_RELOCATE_RAM_MODE` | `auto` | `auto`, `require`, `off`. |
| `--ram-reserve MIB` | `VBOX_RELOCATE_RAM_RESERVE` | `1024` | Mindestreserve an freiem RAM. |
| `--verify L` | `VBOX_RELOCATE_VERIFY` | `size` | `size`, `checksum`. |
| `--keep-source` | `VBOX_RELOCATE_KEEP_SOURCE` | aus | Quelle umbenennen statt löschen. |
| `--start-type T` | `VBOX_RELOCATE_START_TYPE` | `auto` | `auto` (wie vorher), `gui`, `headless`, `separate`. |
| `-y, --yes` | `VBOX_RELOCATE_YES` | aus | Keine interaktive Rückfrage. |
| `--machine-readable` | `VBOX_RELOCATE_MACHINE_READABLE` | aus | Ausgabe im Protokoll aus 9.3 (für die GUI). |
| `-s, --silent` | `VBOX_RELOCATE_SILENT` | aus | Nur Fehler ausgeben. |
| `-v, --verbose` | `VBOX_RELOCATE_VERBOSE` | aus | Zusätzliche Diagnose. Zusammen mit `--silent` ein Aufruffehler. |
| `-h, --help` | - | - | Hilfe. |

### 9.3 Maschinenlesbares Protokoll (stdout)

Zeilenbasiert, ASCII, ohne JSON-Abhängigkeit. Fehlermeldungen und die
Ausgaben aufgerufener VBoxManage-Befehle gehen nach stderr, damit stdout nur
Protokollzeilen enthält. `list` gibt je VM eine Zeile
`VM uuid=".." name=".." state=".." folder=".." size_bytes=".." snapshots=".."` aus.

```
PLAN key="value"                 # nur bei "plan", eine Zeile je Eigenschaft
STEP <id> <text>                 # Beginn eines Schritts
PROGRESS <0-100> <id>            # Fortschritt des aktuellen Schritts
DOWNTIME begin|end               # Beginn/Ende der Umschaltphase
INFO <text> / DEBUG <text>       # Statusmeldungen
WARN <text>
RESULT ok|failed|rolled-back     # letzte Zeile
```

Schritt-IDs (Auswahl): `precheck`, `snapshot-take`, `precopy`, `ram-setup`,
`savestate`, `copy`, `verify`, `register`, `start`, `snapshot-delete`,
`cleanup`, `rollback`.

---

## 10. Root-Helfer und polkit

- Pfad: `/usr/libexec/vbox-relocate/vbox-relocate-helper`, Aufruf per `pkexec`.
- polkit-Aktion: `io.github.roemer2201.vboxrelocate.helper`
  (Standard: `auth_admin_keep`; optional eine `rules.d`-Regel, die aktiven
  lokalen Sitzungen der Gruppe `vboxusers` die Aktion ohne Passwort erlaubt).
- Erlaubte Unterbefehle (abschließende Liste):

| Unterbefehl | Aktion |
|-------------|--------|
| `ram-setup <uuid> <bytes>` | tmpfs unter `/run/vbox-relocate/<uuid>/ram` für `PKEXEC_UID` einhängen. |
| `overlay-mount <uuid> <snapfldr>` | overlayfs über den Snapshot-Ordner. |
| `overlay-move-sav <uuid>` | Einzige `.sav` aus `upperdir` nach `state/` verschieben. |
| `overlay-umount <uuid>` | overlay lösen. |
| `ram-teardown <uuid>` | tmpfs lösen und Verzeichnis entfernen. |

- Eingabeprüfung: UUID-Format; `<snapfldr>` wird kanonisiert, muss ein
  Verzeichnis sein, `PKEXEC_UID` gehören und der Snapshot-Ordner einer
  `.vbox`-Datei desselben Benutzers sein (genaues Prüfverfahren wird im
  Prototyp festgelegt). Keine beliebigen Pfade, keine Shell-Auswertung von
  Argumenten.

---

## 11. GUI `vbox-relocate-gui` (PySide6)

### 11.1 Funktionen

- VM-Liste (aus `vbox-relocate list --machine-readable`): Name, Zustand,
  Ordner, Größe, Snapshots.
- Zielverzeichnis über Dateidialog.
- Optionen: RAM-Modus, Quelle behalten, Prüfstufe.
- Schaltfläche **Prüfen**: zeigt die Ausgabe von `plan` (Strategie,
  RAM-Entscheidung mit Zahlen, geschätzte Ausfallzeit, Warnungen).
- Schaltfläche **Umziehen**: startet `run --machine-readable --yes`, zeigt
  - Gesamtfortschritt und Fortschritt des aktuellen Schritts,
  - Schrittliste mit Status,
  - Markierung der Umschaltphase,
  - aufklappbares Protokoll (stdout/stderr).
- **Abbrechen**: nur bis zum Beginn der Umschaltphase; danach nur noch
  "Rückfall erzwingen".
- Start über `.desktop`-Datei im Anwendungsmenü.

### 11.2 Abgrenzung

Die GUI enthält keine eigene Umzugslogik und ruft VirtualBox nicht direkt auf.

---

## 12. Repository-Struktur

```
README.md
docs/SPEC.md                         # dieses Dokument
bin/vbox-relocate                    # CLI (Bash)
libexec/vbox-relocate-helper         # Root-Helfer (Bash)
polkit/io.github.roemer2201.vboxrelocate.policy
gui/vbox_relocate_gui/               # PySide6-Anwendung
gui/vbox-relocate-gui.desktop
examples/vbox-relocate.conf          # Beispiel der Nutzerkonfiguration
tests/unit.bats                      # Unit-Tests (ohne VirtualBox)
tests/integration.bats               # Tests gegen echtes VBoxManage
tests/helpers/vboxmanage-sim         # simuliert laufende VMs im Container
LICENSE                              # GPL-3.0
packaging/                           # spaeter: .deb
```

---

## 13. Tests

In der Entwicklungsumgebung (Container) gibt es kein VirtualBox. Dort laufen nur
Syntax- und Unit-Tests (`bash -n`, `shellcheck`, bats für Parser und
Berechnungen). Integrationstests laufen auf einem echten Host.

| # | Testfall |
|---|----------|
| T1 | Ausgeschaltete VM, ohne Snapshots, selbes btrfs. |
| T2 | Ausgeschaltete VM mit Snapshot-Baum (verzweigt). |
| T3 | Gespeicherte VM (Saved). |
| T4 | Laufende VM, `reflink`, RAM-Modus an. |
| T5 | Laufende VM mit Snapshots, `reflink`, RAM-Modus aus. |
| T6 | Laufende VM, `copy` auf ext4/XFS, mit Snapshots, Last im Gast (fio). |
| T7 | Mehrere Platten, ISO außerhalb des VM-Ordners. |
| T8 | Zu wenig RAM für den RAM-Modus (`auto` -> Platte, `require` -> Abbruch). |
| T9 | Fehlerinjektion je Phase (Ziel voll, Abbruch per Signal, Start schlägt fehl) -> Rückfall korrekt, Quelle startbar. |
| T10 | `recover` nach hartem Abbruch der CLI. |
| T11 | VirtualBox Manager während des Umzugs geöffnet (Gruppen, Reihenfolge, Auswahl bleiben). |
| T12 | Gast-Prüfung nach Umzug: Dateisystem-Check, Uhrzeit, Netzwerkverbindungen. |

---

## 14. Im Prototyp zu verifizieren

| # | Annahme | Stand |
|---|---------|-------|
| V1 | `unregistervm` ohne `--delete` lässt `.vbox` (inkl. Snapshots und gespeichertem Zustand) unverändert; `registervm` am neuen Ort löst alle relativen Pfade korrekt auf. | Bestätigt mit VirtualBox 7.0.16 im Testcontainer (ausgeschaltete VM mit Snapshot-Baum, gespeicherter Zustand per `adoptstate`). Auf 7.2 mit echter laufender VM noch zu prüfen. |
| V2 | Wiederherstellung aus einer `.sav`, die ein Symlink in den tmpfs ist, funktioniert; VirtualBox löscht danach nur den Symlink. | offen (Phase 2) |
| V3 | Während `savestate` landet im overlay-`upperdir` nur die neue `.sav` (kein Copy-up von Differenz-Images). | offen (Phase 2) |
| V4 | Verhalten bei fehlgeschlagenem `savestate` (z. B. tmpfs voll): läuft die VM weiter? | offen; die CLI prüft den Zustand nach dem Fehler und bricht ohne Änderung ab, wenn die VM noch läuft. |
| V5 | `cp --reflink=always` funktioniert zwischen den betroffenen Verzeichnissen (auch über Subvolume- und Mount-Grenzen desselben btrfs). | Bestätigt zwischen Subvolumes (Kernel 6.18, Testcontainer). Die CLI prüft das vor jedem Lauf mit einer Probedatei. |
| V6 | VirtualBox Manager verhält sich beim Ab- und Anmelden derselben UUID unauffällig. | offen (Host-Test) |
| V7 | Online-Löschen des temporären Snapshots am Ziel führt korrekt zusammen und entfernt dessen `.sav`. | offen (Phase 4) |
| V8 | Ermittlung des ursprünglichen Start-Typs (`gui`/`headless`) aus `showvminfo`. | Laut Quellcode (`MachineImpl.cpp`): `SessionName` ist `GUI/Qt` (auch für `separate`) oder `headless`. Umgesetzt; auf dem Host zu prüfen. |
| V9 | Tatsächliche `.sav`-Größe im Vergleich zur Schätzung. | offen (Host-Test) |
| V10 | Erkennung von Medien in der globalen Registry mit absolutem Pfad. | Umgesetzt als Textsuche in `VirtualBox.xml`; mit echten Altlasten noch nicht getestet. |

---

## 15. Phasen

| Phase | Inhalt | Ergebnis |
|-------|--------|----------|
| 0 | Spezifikation (dieses Dokument) | `docs/SPEC.md` |
| 1 | CLI: `list`, `plan`, Vorprüfungen, Strategien `offline` und `reflink` (ohne RAM-Modus), Rückfall, Journal | **umgesetzt** (`bin/vbox-relocate` 0.1.0), Host-Test ausstehend |
| 2 | RAM-Modus: Helfer, polkit, overlay/tmpfs | Umschaltphase ohne Platten-Schreibzugriffe |
| 3 | GUI (PySide6) | Bedienung mit Fortschrittsanzeige |
| 4 | Strategie `copy` (anderes Dateisystem) | Umzug auf beliebige Dateisysteme |
| 5 | Paketierung (.deb), Dokumentation | Installation per apt |

---

## 16. Entscheidungen

| # | Frage | Stand |
|---|-------|-------|
| E1 | Logging (syslog/journal, Format, Stufen) | **offen** – wird vom Auftraggeber festgelegt; bis dahin nur stdout/stderr (im Code als TODO markiert). |
| E2 | Konfigurationsdatei | **entschieden:** nutzerspezifische Datei im Home (Abschnitt 9.2). |
| E3 | Standardverhalten Quelle: löschen oder behalten? | **entschieden:** löschen nach erfolgreichem Abschluss, `--keep-source` optional. |
| E4 | Kopierwerkzeug ohne Reflink | **entschieden:** `rsync`. |
| E5 | Lizenz des Repositories | **entschieden:** GPL-3.0 (`LICENSE`). |

---

## 17. Quellen

- VirtualBox-Quellcode, GitHub `VirtualBox/virtualbox`, Branch `main`:
  `include/VBox/ExtPack/ExtPack.h`, `include/VBox/vd-filter-backend.h`,
  `src/VBox/Main/idl/VirtualBox.xidl`,
  `src/VBox/Main/src-server/MachineImpl.cpp`,
  `src/VBox/Main/src-server/MediumImpl.cpp`,
  `src/VBox/Main/src-server/SnapshotImpl.cpp`,
  `src/VBox/Main/src-server/MachineImplMoveVM.cpp`,
  `src/VBox/Main/src-client/ConsoleImpl.cpp`,
  `src/VBox/Frontends/VirtualBox/src/`,
  `doc/manual/en_US/dita/topics/teleporting.dita`,
  `doc/manual/en_US/man_VBoxManage-modifymedium.xml`, `CONTRIBUTING.md`
- Oracle VirtualBox User Guide 7.1/7.2 - Programming Interfaces:
  https://docs.oracle.com/en/virtualization/virtualbox/7.1/user/VirtualBoxAPI.html
- VirtualBox SDK Reference: https://download.virtualbox.org/virtualbox/SDKRef.pdf
