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

## Layout

Cards are arranged so the historic data is the centrepiece:

1. **Track map** beside a stacked **Race distance** and **Pit stop time loss** —
   the context for reading everything below.
2. **Historic data**, full width: season range control, lap time chart, results
   table, then derived summaries.
3. **Tire compounds**, full width, one card per compound.
4. **Live timing**, collapsed and parked at the bottom.

## Switching circuits

The dropdown in the header swaps circuits. Three are seeded — Monaco,
Silverstone, and Monza — chosen because they sit at opposite ends of lap count,
tire degradation, and pit loss, so every panel visibly changes.

## Where the historic results come from

The **Historic data** card fetches real results at runtime from an
Ergast-compatible API — [Jolpica](https://api.jolpi.ca/ergast/f1/) by default,
the maintained successor to Ergast. The request comes from your browser, so
nothing needs to be pre-baked into the repo.

Per circuit it makes two calls:

- `/circuits/{id}/results/1.json` — winner, team, grid slot, laps, fastest lap
- `/circuits/{id}/results/2.json` — the runner-up's gap, which is the winning margin

Then a second pass fills in, per race, the pole time
(`/{season}/{round}/qualifying.json`) and the winner's pit stop count
(`/{season}/{round}/pitstops.json`). That pass is concurrency-capped at two
requests to stay inside the public API's burst limit, and the table re-renders
as each row lands. Pole times don't exist in the data before 2003 and pit stop
counts before 2011, so those cells show `—` rather than guessing.

The card shows 10 seasons by default (`meta.api.seasons`), switchable to 5 or 20.
Up to 20 seasons are fetched once per circuit; changing the range re-slices what
was already fetched, and only the rows actually on screen get the second-pass
enrichment — widening the range enriches just the rows that became visible, and
narrowing then widening again costs no requests at all.

Above the table, a two-series line chart plots pole time and fastest lap by
season — both are lap times in seconds, so they share one axis. Seasons with no
pole time break the line rather than being interpolated across. Hovering
anywhere on the plot gives a crosshair and a tooltip with that year's winner and
both times; the table underneath is the same data in text form. The two series
colors are shared with the track map sectors and were checked against the dark
card surfaces for lightness, chroma, colorblind separation, and contrast.

Behaviour when things go wrong:

- The seeded `history` arrays in `data.json` render immediately and stay on
  screen until the live results arrive, so the card is never empty.
- If the API is unreachable, the seeded rows remain and the card says so.
- The pill above the table reads **live** or **sample** so it is always obvious
  which one you are looking at.
- Results are cached per circuit for the session, and a slow response for a
  circuit you have already switched away from is discarded.

To point at a different Ergast-compatible host, or change how many seasons are
shown, edit `meta.api` in `data.json`:

```json
"api": { "base": "https://api.jolpi.ca/ergast/f1", "label": "the Jolpica F1 API", "seasons": 8 }
```

Removing `meta.api` turns the fetching off entirely and leaves the dashboard on
the seeded sample data.

Note that safety car counts and starting compounds are not in this API, so they
are no longer shown in the table; the seeded values remain in `data.json`.

## `data.json` shape

Top level is `{ "meta": {...}, "circuits": [...] }`. Each circuit entry:

| Field | Notes |
| --- | --- |
| `id`, `event`, `name`, `country`, `round` | Identity, used in the header and dropdown |
| `ergastCircuitId` | Circuit key used against the results API (e.g. `monza`); omit it to leave that circuit on sample data |
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

## What is parked

The **Live timing** section is parked: collapsed at the bottom of the page,
behind a "Parked" pill, out of the way of the rest of the dashboard. Expanding
it shows the intended layout for lap times, sector times, and tire usage as
empty states.

The wiring is still there for when it is picked back up — `state.live` is
`null`, and `renderLive()` runs on every `refresh()` and is where a feed would
be rendered (see the `TODO` comments in `index.html`). Nothing is simulated or
faked.

## Data caveats

Circuit, tire and pit stop figures in `data.json` are approximate public
reference values gathered for prototype purposes, not authoritative data.

Historic results are real once the API responds. The client was written against
the documented Ergast/Jolpica response shape and verified against mocked
responses of that shape — but it has not been exercised against the live host,
because the sandbox it was built in blocks outbound traffic to everything except
an allowlist. First run in a real browser is the check that matters: if the
table shows the **live** pill and plausible winners, the schema matched.
