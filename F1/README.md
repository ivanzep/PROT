# F1 Race Weekend Dashboard

A static prototype dashboard for a Formula 1 race weekend: track map with timing
sectors, race distance, historic results, tire compound allocation, pit stop
time loss, and a placeholder section for real-time timing.

No build step, no package manager, no external dependencies — just an HTML file
and a JSON file.

## Running it

The dashboard loads its data with `fetch('data.json')`, which browsers block on
`file://`. Serve the folder over HTTP:

```
cd F1
python3 -m http.server
```

Then open <http://localhost:8000/>.

Opening `index.html` directly still works, but it shows an explanatory message
instead of the dashboard.

## Files

| File | Purpose |
| --- | --- |
| `index.html` | Markup, inline styles, and all rendering logic |
| `data.json` | Circuit and weekend dataset |

## Switching circuits

The dropdown in the header swaps circuits. Three are seeded — Monaco,
Silverstone, and Monza — chosen because they sit at opposite ends of lap count,
tire degradation, and pit loss, so every panel visibly changes.

## `data.json` shape

Top level is `{ "meta": {...}, "circuits": [...] }`. Each circuit entry:

| Field | Notes |
| --- | --- |
| `id`, `event`, `name`, `country`, `round` | Identity, used in the header and dropdown |
| `sessions` | `[{ label, day, time }]` — rendered as the schedule strip; the entry whose label contains "Race" is highlighted |
| `lapDistanceKm`, `raceLaps`, `raceDistanceKm`, `turns`, `drsZones` | Race distance tiles |
| `lapRecord` | `{ driver, time, year }`, `time` in seconds |
| `map` | `{ viewBox, outline }` — `outline` is an SVG path `d` string |
| `sectors` | `[{ n, path, note }]` — one `d` string per timing sector, drawn over the outline |
| `corners` | `[{ n, x, y, name }]` — numbered markers in `viewBox` coordinates |
| `history` | `[{ year, winner, team, startCompound, stops, safetyCars, poleTime, fastestLap, winMarginSec }]`, times in seconds |
| `tyres` | `[{ compound, label, sets, expectedLifeLaps, degPerLapSec, note }]` |
| `pit` | `{ pitLaneLengthM, speedLimitKph, pitLaneTimeSec, stationaryTimeSec, totalLossSec, breakdown: [{ label, seconds }] }` |

All times are stored as seconds and formatted for display by `formatLapTime` /
`formatDelta`. Tire band colors are keyed off `label` (Soft, Medium, Hard,
Intermediate, Wet), so a new compound only needs the right label to pick up its
color.

Derived values are computed in JS rather than stored: the historic summaries
(most successful team, most common strategy, safety car frequency, average
margin), each compound's stint bar as a share of race distance, and the pit loss
expressed as a fraction of a racing lap.

Adding a circuit is a matter of appending an object to `circuits` — no code
changes.

## What is stubbed

The **Live timing** card is a placeholder shell. Its three panels — lap times,
sector times, tire usage — render empty states under a "Not connected" pill.
The wiring is in place: `state.live` is `null`, and `renderLive()` runs on every
`refresh()` and is where a feed would be rendered (see the `TODO` comments in
`index.html`). Nothing is simulated or faked.

## Data caveat

The figures in `data.json` are approximate public reference values gathered for
prototype purposes. They are not a live feed and should not be treated as
authoritative timing data.
