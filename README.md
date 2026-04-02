# waybar-google-calendar

A [Waybar](https://github.com/Alexays/Waybar) widget that shows your next Google Calendar event in the bar, with today's and tomorrow's agenda in the tooltip.

```
  Bar:     󰃵 Sprint Pl... (09:30)          󰃵 Design Rev... (3m)          󰃵 1:1 with L... (2m ago)          󰃮 No events
            ╰─ upcoming                      ╰─ urgent (yellow)             ╰─ ongoing (green)                 ╰─ empty (dimmed)
```

```
  Tooltip:
  ┌─────────────────────────────────┐
  │ Today                           │
  │ ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ │
  │ 09:00–09:15  Daily Standup      │
  │ 09:30–10:30  Sprint Planning    │
  │ 11:00–11:30  1:1 with Lisa      │
  │ 13:00–14:00  Design Review      │
  │ 15:00–16:00  Tech Deep Dive     │
  │                                 │
  │ Anna on vacation                │
  │ Erik working remote             │
  │                                 │
  │ Tomorrow                        │
  │ ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ │
  │ 09:00–09:15  Daily Standup      │
  │ 10:00–11:00  Product Demo       │
  │ 14:00–15:00  Retro              │
  │                                 │
  │ Erik working remote             │
  │                                 │
  │ ─────────────────────────────── │
  │ Last fetched: 14:32             │
  │ Click to refresh                │
  │ Double-click to open Calendar   │
  └─────────────────────────────────┘
```

## Features

- Next upcoming event with countdown in the bar (`5m`, `15:00`, `3m ago`)
- Today's and tomorrow's agenda in the tooltip
- Interactive calendar picker — choose which calendars to display
- Configurable all-day event filtering by keyword
- Configurable event title truncation length
- Color-coded states: green (ongoing), orange (starting within 10 min), dimmed (no events)
- Custom icons via waybar `format-icons` (`alt` field: `events` / `no-events`)
- Fetches from API every 15 min, renders every 60s
- Click to refresh, double-click to open Google Calendar

## Prerequisites

- [Google Workspace CLI (`gws`)](https://github.com/googleworkspace/cli) — authenticated with `gws auth login`
- [jq](https://jqlang.github.io/jq/)

## Installation

1. Clone the repository:

```bash
git clone https://github.com/twiking/waybar-google-calendar.git
cd waybar-google-calendar
```

2. Run the setup to pick which calendars to show:

```bash
./google-calendar.sh --setup
```

3. Add the module to your Waybar config (`~/.config/waybar/config.jsonc`):

```jsonc
// Add to your modules-right (or modules-center/modules-left):
"modules-right": [
    // ...
    "custom/calendar",
    "clock",
    // ...
],

// Module definition:
"custom/calendar": {
    "exec": "/path/to/waybar-google-calendar/google-calendar.sh",
    "return-type": "json",
    "interval": 60,
    "format": "{icon} {text}",
    "format-icons": {
        "no-events": "󰃮",
        "events": "󰃵",
    },
    "tooltip": true,
    "on-click": "/path/to/waybar-google-calendar/google-calendar.sh --fetch && pkill -RTMIN+4 waybar",
    "on-double-click": "xdg-open https://calendar.google.com",
    "signal": 4,
},
```

4. Optionally, add styling to `~/.config/waybar/style.css`:

```css
#custom-calendar.urgent {
    color: #ffb86c;
}

#custom-calendar.ongoing {
    color: #50fa7b;
}

#custom-calendar.error {
    color: #ff5555;
}

#custom-calendar.empty {
    opacity: 0.5;
}
```

5. Restart Waybar (`Super + Alt + Space` on Omarchy, or `killall waybar && waybar &`)

## Configuration

### Calendars

Run `--setup` again at any time to change which calendars are displayed:

```bash
./google-calendar.sh --setup
```

The selection is saved to `calendars.json` in the same directory as the script.

### Settings

Edit `config.json` to customize behavior:

```json
{
    "max-title-length": 10,
    "filter-out": ["Office", "Home"]
}
```

| Setting | Description | Default |
|---------|-------------|---------|
| `max-title-length` | Max characters for event title in the bar before truncating | `10` |
| `filter-out` | All-day event keywords to hide from the tooltip (case-insensitive, exact match) | `["Office", "Kontoret"]` |

A default `config.json` is created automatically during `--setup`.

### Caching

Events are fetched from the Google Calendar API every 15 minutes and cached locally in `.cache/events.json`. Click the widget to force a refresh.

## Bar display

| State | Format | Example |
|-------|--------|---------|
| Upcoming (> 10 min) | `Event (HH:MM)` | `Standup (15:00)` |
| Upcoming (<= 10 min) | `Event (Xm)` | `Standup (5m)` |
| Ongoing | `Event (Xm ago)` | `Standup (3m ago)` |
| No timed events | `No events` | |

## CSS Classes

| Class | Meaning |
|-------|---------|
| `ongoing` | An event is happening right now |
| `urgent` | Next event starts within 10 minutes |
| `empty` | No remaining timed events today |
| `error` | Authentication or setup issue |

## License

MIT
