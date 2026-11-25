# Table Layout — seating planner

Single-file, no-dependency web app for planning seat assignments for an event (built around ~150 guests, works for any size). Open `index.html` in a browser — no server needed.

## How it works

- **Guests** are cards in the left panel (bottom panel on phones), color-coded by **group** (family, friends, work…). Add one at a time, or **Bulk add / paste list** with `Name, Group, Table, Menu` per line — straight from Excel/Google Sheets, or a CSV file. A header row is detected (`Name`/`Nombre`, `Group`/`Grupo`, `Table`/`Mesa`); a numeric table like `3` maps to `Table 3`, and unknown tables are created with 10 seats. **More → Download guest CSV template** gives a blank `Name, Group, Table, Menu` sheet to fill in and import.
- **Tables**: **+ Table** adds one or several at once — any seat count (1–40), round or rectangular. Drag a table by its center to move it. Tap a table to open its panel: rename, change seats/shape, see who's seated, duplicate, unseat all, delete.
- **Seating**: drag a guest card onto a table (takes the next free seat) or onto a specific seat. Dropping on an occupied seat swaps the two guests. Drag a seated guest back to the list to unseat. On touch screens, press-and-hold a card briefly before dragging (so the list can still scroll); seated guests drag immediately.
- **Menu 1 / Menu 2**: set per guest (add form, guest editor, CSV `Menu` column = `1`/`2`, or tap the `M1`/`M2` button in a table's panel to cycle 1 → 2 → none). Seats carry a small badge (white `1`, black `2`); each table shows its M1/M2 counts, the header shows totals, and the Menu chips highlight one menu across the room.
- **At a glance**: seat colors show how groups are clustering; tap a group chip to dim everyone else. Each table shows `seated/seats`; header pills show totals, unseated count, and any seat shortfall.
- **More menu**: auto-arrange tables in a grid, auto-seat remaining guests (keeps groups together where they fit), export seating CSV (`Table, Seat, Name, Group, Menu`), save/load the whole plan as `.json`, print the layout, load a 150-guest sample.
- Tap a guest card or seat (without dragging) to edit name/group/table or delete.

## Storage

The plan autosaves to the browser's `localStorage` (`table-layout-plan-v1`) — it lives in that one browser only. Use **Save plan (.json)** to back it up or move it to another device, **Load plan** to restore.
