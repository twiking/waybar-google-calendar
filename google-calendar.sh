#!/usr/bin/env bash
#
# waybar-google-calendar — Google Calendar widget for Waybar
# https://github.com/twiking/waybar-google-calendar
#
# Usage:
#   ./google-calendar.sh          Render widget (called by waybar every 60s)
#   ./google-calendar.sh --setup  Interactive calendar picker
#   ./google-calendar.sh --fetch  Fetch events from API and update cache

set -euo pipefail

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CALENDARS_FILE="$SCRIPT_DIR/calendars.json"
CONFIG_FILE="$SCRIPT_DIR/config.json"
CACHE_DIR="$SCRIPT_DIR/.cache"
EVENTS_CACHE="$CACHE_DIR/events.json"
FETCH_INTERVAL=900 # seconds (15 min)

# Extend PATH for common tool locations (mise shims, local bin)
[[ -d "$HOME/.local/share/mise/shims" ]] && export PATH="$HOME/.local/share/mise/shims:$PATH"
[[ -d "$HOME/.local/bin" ]] && export PATH="$HOME/.local/bin:$PATH"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Output a single-line JSON object for waybar and exit.
waybar_output() {
    local text="$1" tooltip="${2:-}" class="${3:-}" alt="${4:-}"
    jq -cn \
        --arg text "$text" \
        --arg tooltip "$tooltip" \
        --arg class "$class" \
        --arg alt "$alt" \
        '{text: $text, tooltip: $tooltip, class: $class, alt: $alt}'
    exit 0
}

# Escape text for Pango markup used in waybar tooltips.
pango_escape() {
    local s="$1"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    echo "$s"
}

# Filter JSON events array to timed events only (sorted by start).
# Excludes all-day events (no "T" in start) and multi-day midnight events.
filter_timed() {
    echo "$1" | jq '[.[]
        | select(.start | test("T"))
        | select(.start | test("T00:00:00") | not)
    ] | sort_by(.start)'
}

# Filter JSON events array to all-day events only.
# Applies keyword filter from config to exclude location/status events.
filter_allday() {
    local data="$1" pat="$2"
    if [[ -n "$pat" ]]; then
        echo "$data" | jq --arg pat "$pat" '[.[]
            | select((.start | test("T") | not) or (.start | test("T00:00:00")))
            | select(.summary | test($pat) | not)
        ]'
    else
        echo "$data" | jq '[.[]
            | select((.start | test("T") | not) or (.start | test("T00:00:00")))
        ]'
    fi
}

# Render a day section (timed + all-day events) for the tooltip.
# Args: $1=heading, $2=timed_events_json, $3=allday_events_json
render_day_section() {
    local heading="$1" timed="$2" allday="$3"
    local timed_count allday_count
    local nl=$'\n'

    timed_count=$(echo "$timed" | jq 'length')
    allday_count=$(echo "$allday" | jq 'length')

    local section="<b>${heading}${nl}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━</b>"

    # Timed events
    for ((i = 0; i < timed_count; i++)); do
        local start_str end_str summary start_hm end_hm safe
        start_str=$(echo "$timed" | jq -r ".[$i].start")
        end_str=$(echo "$timed" | jq -r ".[$i].end")
        summary=$(echo "$timed" | jq -r ".[$i].summary")
        start_hm=$(date -d "$start_str" +%H:%M 2>/dev/null)
        end_hm=$(date -d "$end_str" +%H:%M 2>/dev/null)
        safe=$(pango_escape "$summary")
        section+="${nl}<tt>${start_hm}–${end_hm}</tt>  ${safe}"
    done

    # Separator between timed and all-day
    if (( timed_count > 0 && allday_count > 0 )); then
        section+="${nl}"
    fi

    # All-day events
    for ((i = 0; i < allday_count; i++)); do
        local summary safe
        summary=$(echo "$allday" | jq -r ".[$i].summary")
        safe=$(pango_escape "$summary")
        section+="${nl}${safe}"
    done

    # Empty state
    if (( timed_count == 0 && allday_count == 0 )); then
        section+="${nl}No events"
    fi

    echo "$section"
}

# ---------------------------------------------------------------------------
# Setup mode — interactive calendar picker
# ---------------------------------------------------------------------------

if [[ "${1:-}" == "--setup" ]]; then
    if ! command -v gws &>/dev/null; then
        echo "Error: gws not found. Install from https://github.com/googleworkspace/cli"
        exit 1
    fi

    echo "Fetching your calendars..."
    raw=$(gws calendar calendarList list --format json 2>/dev/null)

    if [[ -z "$raw" ]] || ! echo "$raw" | jq -e '.items' &>/dev/null; then
        echo "Failed to fetch calendars. Make sure you're authenticated: gws auth login"
        exit 1
    fi

    echo ""
    echo "Available calendars:"
    echo "────────────────────"

    declare -a cal_ids cal_names
    i=1
    while IFS=$'\t' read -r id name; do
        cal_ids+=("$id")
        cal_names+=("$name")
        echo "  $i) $name  ($id)"
        ((i++))
    done < <(echo "$raw" | jq -r '.items[] | [.id, .summary] | @tsv' | sort -t$'\t' -k2)

    if [[ ${#cal_ids[@]} -eq 0 ]]; then
        echo "No calendars found."
        exit 1
    fi

    echo ""
    echo "Enter the numbers of calendars to show (comma-separated, e.g. 1,3,5):"
    read -rp "> " selection

    selected_ids=()
    selected_names=()
    IFS=',' read -ra nums <<< "$selection"
    for num in "${nums[@]}"; do
        num=$(echo "$num" | tr -d ' ')
        idx=$((num - 1))
        if [[ $idx -ge 0 && $idx -lt ${#cal_ids[@]} ]]; then
            selected_ids+=("${cal_ids[$idx]}")
            selected_names+=("${cal_names[$idx]}")
        fi
    done

    if [[ ${#selected_ids[@]} -eq 0 ]]; then
        echo "No valid selection. Aborting."
        exit 1
    fi

    # Build calendars JSON
    cals_json="[]"
    for ((i = 0; i < ${#selected_ids[@]}; i++)); do
        cals_json=$(echo "$cals_json" | jq \
            --arg id "${selected_ids[$i]}" \
            --arg name "${selected_names[$i]}" \
            '. + [{"id": $id, "name": $name}]')
    done
    jq -n --argjson cals "$cals_json" '{calendars: $cals}' > "$CALENDARS_FILE"

    # Create default config if missing
    if [[ ! -f "$CONFIG_FILE" ]]; then
        jq -n '{
            "max-title-length": 10,
            "filter-out": ["Office", "Home", "Kontoret", "Hemma"]
        }' > "$CONFIG_FILE"
    fi

    echo ""
    echo "Saved to $CALENDARS_FILE:"
    cat "$CALENDARS_FILE"
    echo ""
    echo "Config at $CONFIG_FILE:"
    cat "$CONFIG_FILE"
    echo ""

    echo "Fetching initial events..."
    "$0" --fetch

    echo "Restart waybar to apply (Super+Alt+Space on Omarchy, or: killall waybar && waybar &)"
    exit 0
fi

# ---------------------------------------------------------------------------
# Fetch mode — pull events from API into cache
# ---------------------------------------------------------------------------

if [[ "${1:-}" == "--fetch" ]]; then
    if ! command -v gws &>/dev/null || [[ ! -f "$CALENDARS_FILE" ]]; then
        exit 1
    fi

    mapfile -t cal_ids < <(jq -r '.calendars[].id' "$CALENDARS_FILE" 2>/dev/null)
    if [[ ${#cal_ids[@]} -eq 0 ]]; then
        exit 1
    fi

    mkdir -p "$CACHE_DIR"

    today_events="[]"
    tomorrow_events="[]"
    for cal_id in "${cal_ids[@]}"; do
        raw=$(gws calendar +agenda --today --calendar "$cal_id" --format json 2>/dev/null)
        if echo "$raw" | jq -e '.events' &>/dev/null; then
            today_events=$(echo "$today_events" "$raw" | jq -s '.[0] + (.[1].events // [])')
        fi

        raw=$(gws calendar +agenda --tomorrow --calendar "$cal_id" --format json 2>/dev/null)
        if echo "$raw" | jq -e '.events' &>/dev/null; then
            tomorrow_events=$(echo "$tomorrow_events" "$raw" | jq -s '.[0] + (.[1].events // [])')
        fi
    done

    # Atomic write via tmp file
    jq -cn --argjson today "$today_events" --argjson tomorrow "$tomorrow_events" \
        '{today: $today, tomorrow: $tomorrow}' > "$EVENTS_CACHE.tmp" \
        && mv "$EVENTS_CACHE.tmp" "$EVENTS_CACHE"

    exit 0
fi

# ---------------------------------------------------------------------------
# Widget mode — render bar text + tooltip from cached events
# ---------------------------------------------------------------------------

# Pre-flight checks
if ! command -v gws &>/dev/null; then
    waybar_output "N/A" "gws not installed" "error"
fi
if [[ ! -f "$CALENDARS_FILE" ]]; then
    waybar_output "setup" "Run: ./google-calendar.sh --setup" "error"
fi

# Trigger background fetch if cache is missing or stale
if [[ ! -f "$EVENTS_CACHE" ]]; then
    nohup "$0" --fetch >/dev/null 2>&1 &
    waybar_output "fetching..." "Fetching calendar events..."
fi
if [[ $(( $(date +%s) - $(stat -c %Y "$EVENTS_CACHE") )) -ge $FETCH_INTERVAL ]]; then
    nohup "$0" --fetch >/dev/null 2>&1 &
fi

# Load cached events
cache=$(cat "$EVENTS_CACHE")
all_today=$(echo "$cache" | jq '.today // []')
all_tomorrow=$(echo "$cache" | jq '.tomorrow // []')

# Load config
max_title_length=$(jq -r '.["max-title-length"] // 10' "$CONFIG_FILE" 2>/dev/null)
filter_pattern=$(jq -r '(.["filter-out"] // []) | map("(?i)^" + . + "$") | join("|")' "$CONFIG_FILE" 2>/dev/null)

# Separate timed and all-day events
today_timed=$(filter_timed "$all_today")
today_allday=$(filter_allday "$all_today" "$filter_pattern")
tomorrow_timed=$(filter_timed "$all_tomorrow")
tomorrow_allday=$(filter_allday "$all_tomorrow" "$filter_pattern")

# ---------------------------------------------------------------------------
# Bar text — show next/current event with countdown
# ---------------------------------------------------------------------------

now_epoch=$(date +%s)
bar_text=""
class=""

event_count=$(echo "$today_timed" | jq 'length')
for ((i = 0; i < event_count; i++)); do
    start_str=$(echo "$today_timed" | jq -r ".[$i].start")
    end_str=$(echo "$today_timed" | jq -r ".[$i].end")
    summary=$(echo "$today_timed" | jq -r ".[$i].summary")

    start_epoch=$(date -d "$start_str" +%s 2>/dev/null)
    end_epoch=$(date -d "$end_str" +%s 2>/dev/null)
    [[ -z "$start_epoch" || -z "$end_epoch" ]] && continue

    # Truncate title for bar display
    title="$summary"
    if [[ ${#title} -gt $max_title_length ]]; then
        title="${title:0:$max_title_length}"
        title="${title% }..."
    fi

    # Ongoing event
    if (( now_epoch >= start_epoch && now_epoch < end_epoch )); then
        ago=$(( (now_epoch - start_epoch) / 60 ))
        bar_text="${title} (${ago}m ago)"
        class="ongoing"
        break
    fi

    # Upcoming event
    if (( start_epoch > now_epoch )); then
        diff=$(( start_epoch - now_epoch ))
        if (( diff <= 600 )); then
            class="urgent"
            bar_text="${title} ($(( diff / 60 ))m)"
        else
            bar_text="${title} ($(date -d "$start_str" +%H:%M))"
        fi
        break
    fi
done

[[ -z "$bar_text" ]] && bar_text="No events" && class="empty"

# ---------------------------------------------------------------------------
# Tooltip — today + tomorrow agenda with footer
# ---------------------------------------------------------------------------

nl=$'\n'
tooltip=$(render_day_section "Today" "$today_timed" "$today_allday")
tooltip+="${nl}${nl}"
tooltip+=$(render_day_section "Tomorrow" "$tomorrow_timed" "$tomorrow_allday")

# Footer
last_fetched=$(date -r "$EVENTS_CACHE" +%H:%M 2>/dev/null || echo "unknown")
tooltip+="${nl}${nl}─────────────────────────────"
tooltip+="${nl}<small>Last fetched: ${last_fetched}"
tooltip+="${nl}Click to refresh"
tooltip+="${nl}Double-click to open Google Calendar</small>"

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

alt="events"
[[ "$class" == "empty" ]] && alt="no-events"

waybar_output "$bar_text" "$tooltip" "$class" "$alt"
