# waybar-google-calendar

A [Waybar](https://github.com/Alexays/Waybar) widget that shows your next Google Calendar event in the bar, with today's full agenda in the tooltip.

![widget states](https://img.shields.io/badge/waybar-custom%20module-blue)

## Features

- Next upcoming event with countdown timer in the bar (`45m`, `2h30m`, `now`)
- Today's full agenda in the tooltip (all-day + timed events)
- Interactive calendar picker — choose which calendars to display
- Color-coded states: green (ongoing), orange (starting soon), dimmed (no events)
- Click to open Google Calendar in your browser

## Prerequisites

- [Waybar](https://github.com/Alexays/Waybar)
- [Google Workspace CLI (`gws`)](https://github.com/googleworkspace/cli) — authenticated with `gws auth login`
- [jq](https://jqlang.github.io/jq/)
- A [Nerd Font](https://www.nerdfonts.com/) (for the calendar icon)

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
    "tooltip": true,
    "on-click": "xdg-open https://calendar.google.com",
    "signal": 4
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

Run `--setup` again at any time to change which calendars are displayed:

```bash
./google-calendar.sh --setup
```

The selection is saved to `calendar-config.json` in the same directory as the script.

## CSS Classes

| Class | Meaning |
|-------|---------|
| `ongoing` | An event is happening right now |
| `urgent` | Next event starts within 5 minutes |
| `empty` | No remaining events today |
| `error` | Authentication or setup issue |

## License

MIT
