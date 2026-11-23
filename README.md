# vbox-extensions

Erweiterungen und Werkzeuge rund um Oracle VirtualBox auf Linux-Hosts.

## vbox-relocate

Zieht den kompletten Ordner einer VirtualBox-VM auf demselben Host in ein
anderes Verzeichnis um – auch bei laufender VM, mit Snapshots.

- **Ausgeschaltete oder gespeicherte VMs** (Strategie `offline`): Der Ordner
  wird kopiert (auf btrfs per Reflink, sonst per `rsync`) und die VM am neuen
  Ort registriert.
- **Laufende VMs auf demselben btrfs** (Strategie `reflink`): Zustand speichern,
  Ordner per Reflink klonen (es werden keine Daten kopiert), neu registrieren,
  wieder starten. Ausfallzeit: Speichern und Laden des RAM-Zustands.
- Die Quelle bleibt erhalten, bis die VM am Ziel läuft; bei Fehlern wird
  automatisch zurückgerollt.

- **Laufende VMs auf einem anderen Dateisystem** (Strategie `copy`):
  Ein temporärer Live-Snapshot friert die bisherige Plattenkette ein. Während
  der Gast weiterläuft, kopiert die CLI deren Images und die Snapshot-Zustände.
  Nach dem Speichern des Gasts folgen Restabgleich, Prüfung und Start am Ziel.
  Erst dann führt VirtualBox den temporären Snapshot am Ziel zusammen.

Die CLI implementiert die Phasen 1, 2 und 4. Die Abnahme mit einer tatsächlich
laufenden VM unter VirtualBox 7.2 ist offen. [Prüfpunkte und Phasenplan](docs/SPEC.md#14-im-prototyp-zu-verifizieren)

### Voraussetzungen

Linux, VirtualBox 7.2, Bash ab Version 5, GNU coreutils/findutils, util-linux
(inklusive `logger`) und `rsync` für Kopien ohne Reflink bzw. `--strategy copy`.
Der optionale RAM-Modus benötigt Python ab 3.9, polkit, tmpfs und OverlayFS
mit Unterstützung für `userxattr`. Die CLI läuft als Eigentümer der VM.

### Installation (vorläufig)

```bash
install -m 0755 bin/vbox-relocate ~/.local/bin/vbox-relocate
# optional: Nutzerkonfiguration
install -D -m 0644 examples/vbox-relocate.conf ~/.config/vbox-relocate.conf
```

Für den RAM-Modus zusätzlich den Helfer und seine polkit-Aktion als root
installieren. Die Befehle werden im ausgecheckten Repository ausgeführt.

```bash
sudo install -D -o root -g root -m 0755 libexec/vbox-relocate-helper /usr/libexec/vbox-relocate/vbox-relocate-helper
sudo install -D -o root -g root -m 0644 polkit/io.github.roemer2201.vboxrelocate.policy /usr/share/polkit-1/actions/io.github.roemer2201.vboxrelocate.policy
```

`--ram-mode auto` prüft Helfer und RAM-Reserve und fällt bei Bedarf auf
Platte zurück. `require` verlangt RAM, `off` speichert auf Platte.
Bei `copy` betrifft das nur die finale `.sav` während der Umschaltung.
Der vorherige Live-Snapshot benötigt Platz auf der Quelle.
Bei Stromausfall vor dem Wiederanlauf geht der in tmpfs gehaltene Zustand
verloren. Aktiver Swap kann tmpfs-Seiten auf die Platte schreiben.

### Verwendung

```bash
vbox-relocate list
vbox-relocate plan "Meine VM" -t /srv/vms      # Probelauf, ändert nichts
vbox-relocate run  "Meine VM" -t /srv/vms      # Umzug nach /srv/vms/<Ordnername>
vbox-relocate run  "Meine VM" -t /srv/vms --keep-source --verify checksum
vbox-relocate recover "Meine VM"               # abgebrochenen Lauf abschließen/zurückrollen
vbox-relocate --help
```

Alle Optionen lassen sich auch per Umgebungsvariable (`VBOX_RELOCATE_*`) oder
in `~/.config/vbox-relocate.conf` setzen. Präzedenz: Kommandozeile >
Umgebungsvariable > Konfigurationsdatei > Standardwert.

### Logging und Wiederaufnahme

Syslog erhält unter dem Tag `vbox-relocate` die Schritte, Warnungen, Fehler
und das Ergebnis. `--verbose` ergänzt Diagnosemeldungen, im Terminal erscheint
der Ablauf zusätzlich direkt. Auf systemd-Hosts zeigt
`journalctl -t vbox-relocate` die Einträge. `--machine-readable` liefert das
Zeilenprotokoll auf stdout auch ohne Terminal.

Schlägt das Zusammenführen nach dem Neustart fehl, läuft die VM am Ziel
weiter. `vbox-relocate recover <VM> --yes` versucht den Merge dort erneut.
Mit `--keep-source` bleibt der gespeicherte Quellzustand samt temporärem
Snapshot erhalten. Dafür schreibt die CLI die RAM-Zustandsdatei nach dem
Start am Ziel in die aufbewahrte Quellkopie.

### Tests

```bash
shellcheck -x bin/vbox-relocate tests/helpers/vboxmanage-sim
bats tests/unit.bats tests/workflow.bats    # mit echtem rsync, ohne Hypervisor
python3 -B tests/ram_helper.py             # Capture, Wiederholung und unerwartete Overlay-Dateien
VBOX_RELOCATE_MOUNT_TEST=1 bats tests/ram-mounts.bats  # optional, installierter Helfer + polkit
sudo bats tests/integration.bats     # braucht VBoxManage; root + btrfs-progs für Reflink-Tests
```

Die Integrationstests verwenden ein eigenes `VBOX_USER_HOME` und berühren die
eigenen VMs nicht. Laufende VMs werden dort durch
`tests/helpers/vboxmanage-sim` simuliert; ein Test auf einem echten Host mit
einer laufenden VM ersetzt das nicht.

## Lizenz

GPL-3.0, siehe [LICENSE](LICENSE).
