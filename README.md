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

Status: Phase 1 (CLI). RAM-Modus, GUI und Umzug laufender VMs auf andere
Dateisysteme sind geplant – siehe [docs/SPEC.md](docs/SPEC.md).

### Voraussetzungen

VirtualBox 7.2, bash >= 5, coreutils, util-linux (`findmnt`, `flock`), `rsync`
(nur für Kopien ohne Reflink).

### Installation (vorläufig)

```bash
install -m 0755 bin/vbox-relocate ~/.local/bin/vbox-relocate
# optional: Nutzerkonfiguration
install -D -m 0644 examples/vbox-relocate.conf ~/.config/vbox-relocate.conf
```

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

### Tests

```bash
shellcheck -x bin/vbox-relocate tests/helpers/vboxmanage-sim
bats tests/unit.bats                 # ohne VirtualBox
sudo bats tests/integration.bats     # braucht VBoxManage; root + btrfs-progs für Reflink-Tests
```

Die Integrationstests verwenden ein eigenes `VBOX_USER_HOME` und berühren die
eigenen VMs nicht. Laufende VMs werden dort durch
`tests/helpers/vboxmanage-sim` simuliert; ein Test auf einem echten Host mit
einer laufenden VM ersetzt das nicht.

## Lizenz

GPL-3.0, siehe [LICENSE](LICENSE).
