# TalkType für Mac

Drücke ein Tastenkürzel in irgendeiner App, sprich, und der Text landet dort, wo der Cursor steht.
Alles läuft auf dem Mac selbst: kostenlos, offline, und deine Stimme verlässt das Gerät nicht.

## Installieren

1. Öffne `TalkType.dmg` und ziehe **TalkType** in den Ordner **Programme**.
2. Öffne TalkType. macOS warnt beim ersten Mal, weil die App nicht von Apple geprüft ist. Klicke
   auf **Fertig**, gehe zu **Systemeinstellungen > Datenschutz & Sicherheit**, scrolle nach unten
   und klicke bei TalkType auf **Dennoch öffnen**. Der Knopf steht dort etwa eine Stunde lang.
3. In den Einstellungen von TalkType: erlaube **Mikrofon** und **Bedienungshilfen** und lade das
   Sprachmodell. Die Bedienungshilfen braucht TalkType zum Einfügen.

## Benutzen

| Das tun | Dafür |
| :- | :- |
| **⌃⌥T** tippen, sprechen, nochmal tippen | Diktieren, so lange du willst |
| **⌃⌥T** halten, sprechen, loslassen | Etwas Kurzes diktieren |
| Stattdessen **⌃⌥C** | Sauberen, klaren Text statt Wort für Wort |
| Stattdessen **⌃⌥G** | Deutsch sprechen, Englisch bekommen |
| **Esc** während der Aufnahme | Aufnahme verwerfen |

Du kannst statt eines Kürzels auch ein Stichwort sagen: „zusammenfassen“ oder „übersetzen“, als
allererstes oder allerletztes Wort und für sich allein. Beides lässt sich in den Einstellungen ändern.

## Wenn es dem Mac zu viel wird

In den Einstellungen gibt es leichtere Modelle, falls gerade viel anderes läuft: **Mittel** und
**Ultraleicht** für die Spracherkennung, **Leicht** fürs Übersetzen und Zusammenfassen. Ab macOS 15
kann außerdem die Übersetzung von macOS selbst übersetzen. Sie braucht fast keinen Speicher.

## Bauen (für Entwickler)

Jeder Push baut die App auf GitHubs Macs (siehe `.github/workflows/build.yml`) und legt
`TalkType.dmg` als Artefakt ab. Auf einem Mac geht es auch mit `scripts/build-app.sh`.
`TalkType --selftest` lässt die Modelle ohne Mikrofon laufen. `TalkTypeCore` enthält die Logik, die
mit der Windows-Version übereinstimmt, und wird mit `swift test` geprüft.
