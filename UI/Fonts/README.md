# Retrace fonts

Bundled typefaces for the Retrace design system (Linen / Dusk). Both are licensed under the
SIL Open Font License 1.1 (see the `OFL-*` files in this directory).

| File | Family | PostScript name | Used for |
| --- | --- | --- | --- |
| `SourceSerif4-Regular.ttf` | Source Serif 4 | `SourceSerif4-Regular` | body, captions, controls |
| `SourceSerif4-Semibold.ttf` | Source Serif 4 | `SourceSerif4-Semibold` | titles, labels |
| `SourceSerif4-Bold.ttf` | Source Serif 4 | `SourceSerif4-Bold` | rare emphasis |
| `SourceSerif4-It.ttf` | Source Serif 4 | `SourceSerif4-It` | captions and metadata |
| `IBMPlexMono-Regular.ttf` | IBM Plex Mono | `IBMPlexMono` | numbers, IDs, code |
| `IBMPlexMono-Medium.ttf` | IBM Plex Mono | `IBMPlexMono-Medm` | stat values |

Fonts are registered once at launch by `UI/Components/RetraceFontRegistry.swift`. If registration fails the
UI falls back to the system serif / monospaced faces.
