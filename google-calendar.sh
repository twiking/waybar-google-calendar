#!/usr/bin/env bash

# Google Calendar widget for waybar
# Shows next upcoming event in bar, today's agenda in tooltip
# Uses: gws (https://github.com/googleworkspace/cli)
#
# Setup: Run this script with --setup to pick which calendars to show
#   ./google-calendar.sh --setup

# Ensure mise shims are in PATH (for gws installed via mise/node)
export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CALENDARS_FILE="$SCRIPT_DIR/calendars.json"
CONFIG_FILE="$SCRIPT_DIR/config.json"
EVENTS_CACHE="/tmp/waybar-calendar-events.json"
FETCH_INTERVAL=900  # 15 minutes in seconds

# --- Setup mode: interactive calendar picker ---
if [[ "$1" == "--setup" ]]; then
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
    i=1
    declare -a cal_ids cal_names
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

    # Save to JSON config with id and name
    config="[]"
    for ((i=0; i<${#selected_ids[@]}; i++)); do
        config=$(echo "$config" | jq --arg id "${selected_ids[$i]}" --arg name "${selected_names[$i]}" \
            '. + [{"id": $id, "name": $name}]')
    done
    jq -n --argjson cals "$config" '{calendars: $cals}' > "$CALENDARS_FILE"

    # Create default config.json if it doesn't exist
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

# --- Fetch mode: pull events from API and save raw data to cache ---
if [[ "$1" == "--fetch" ]]; then
    if ! command -v gws &>/dev/null || [[ ! -f "$CALENDARS_FILE" ]]; then
        exit 1
    fi

    mapfile -t cal_ids < <(jq -r '.calendars[].id' "$CALENDARS_FILE" 2>/dev/null)
    if [[ ${#cal_ids[@]} -eq 0 ]]; then
        exit 1
    fi

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

    jq -cn --argjson today "$today_events" --argjson tomorrow "$tomorrow_events" \
        '{today: $today, tomorrow: $tomorrow}' > "$EVENTS_CACHE"
    exit 0
fi

# --- Widget mode (default, called by waybar every 60s) ---
if ! command -v gws &>/dev/null; then
    echo '{"text":"N/A","tooltip":"gws not installed","class":"error"}'
    exit 0
fi
if [[ ! -f "$CALENDARS_FILE" ]]; then
    echo '{"text":"setup","tooltip":"Run: ./google-calendar.sh --setup","class":"error"}'
    exit 0
fi

# Trigger background fetch if cache is missing or older than FETCH_INTERVAL
if [[ ! -f "$EVENTS_CACHE" ]]; then
    nohup "$0" --fetch >/dev/null 2>&1 &
    echo '{"text":"fetching...","tooltip":"Fetching calendar events...","class":""}'
    exit 0
elif [[ $(( $(date +%s) - $(stat -c %Y "$EVENTS_CACHE") )) -ge $FETCH_INTERVAL ]]; then
    nohup "$0" --fetch >/dev/null 2>&1 &
fi

# --- Render from cached events ---
cache=$(cat "$EVENTS_CACHE")
all_events=$(echo "$cache" | jq '.today // []')
all_tomorrow=$(echo "$cache" | jq '.tomorrow // []')

# Read config
max_title_length=$(jq -r '.["max-title-length"] // 10' "$CONFIG_FILE" 2>/dev/null)
filtered_keywords=$(jq -r '(.["filter-out"] // []) | map("(?i)^" + . + "$") | join("|")' "$CONFIG_FILE" 2>/dev/null)

filter_timed() {
    echo "$1" | jq '[.[] | select(.start | test("T")) | select(.start | test("T00:00:00") | not)] | sort_by(.start)'
}

filter_allday() {
    local data="$1"
    if [[ -n "$filtered_keywords" ]]; then
        echo "$data" | jq --arg pat "$filtered_keywords" \
            '[.[] | select((.start | test("T") | not) or (.start | test("T00:00:00"))) | select(.summary | test($pat) | not)]'
    else
        echo "$data" | jq '[.[] | select((.start | test("T") | not) or (.start | test("T00:00:00")))]'
    fi
}

events=$(filter_timed "$all_events")
allday_events=$(filter_allday "$all_events")
tomorrow_events=$(filter_timed "$all_tomorrow")
tomorrow_allday=$(filter_allday "$all_tomorrow")

now_epoch=$(date +%s)
bar_text=""
class=""

# Parse timed events to find next/current
event_count=$(echo "$events" | jq 'length')
for ((i=0; i<event_count; i++)); do
    start_str=$(echo "$events" | jq -r ".[$i].start")
    end_str=$(echo "$events" | jq -r ".[$i].end")
    summary=$(echo "$events" | jq -r ".[$i].summary")

    start_epoch=$(date -d "$start_str" +%s 2>/dev/null)
    end_epoch=$(date -d "$end_str" +%s 2>/dev/null)
    [[ -z "$start_epoch" || -z "$end_epoch" ]] && continue

    # Truncate long titles
    display_title="$summary"
    if [[ ${#display_title} -gt $max_title_length ]]; then
        display_title="${display_title:0:$max_title_length}"
        display_title="${display_title% }..."
    fi

    if (( now_epoch >= start_epoch && now_epoch < end_epoch )); then
        ago=$(( (now_epoch - start_epoch) / 60 ))
        bar_text="${display_title} (${ago}m ago)"
        class="ongoing"
        break
    elif (( start_epoch > now_epoch )); then
        diff=$(( start_epoch - now_epoch ))
        if (( diff <= 600 )); then
            class="urgent"
        fi
        if (( diff <= 600 )); then
            mins=$(( diff / 60 ))
            bar_text="${display_title} (${mins}m)"
        else
            start_hm=$(date -d "$start_str" +%H:%M)
            bar_text="${display_title} (${start_hm})"
        fi
        break
    fi
done

[[ -z "$bar_text" ]] && bar_text="No events" && class="empty"

# Build tooltip (use real newlines so jq encodes them as \n in JSON)
nl=$'\n'
tooltip="<b>Today${nl}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━</b>"

# Timed events
for ((i=0; i<event_count; i++)); do
    start_str=$(echo "$events" | jq -r ".[$i].start")
    end_str=$(echo "$events" | jq -r ".[$i].end")
    summary=$(echo "$events" | jq -r ".[$i].summary")

    start_hm=$(date -d "$start_str" +%H:%M 2>/dev/null)
    end_hm=$(date -d "$end_str" +%H:%M 2>/dev/null)

    safe="${summary//&/&amp;}"
    safe="${safe//</&lt;}"
    safe="${safe//>/&gt;}"
    tooltip+="${nl}${start_hm} – ${end_hm}  ${safe}"
done

# All-day events
allday_count=$(echo "$allday_events" | jq 'length')
if (( event_count > 0 && allday_count > 0 )); then
    tooltip+="${nl}"
fi
for ((i=0; i<allday_count; i++)); do
    summary=$(echo "$allday_events" | jq -r ".[$i].summary")
    safe="${summary//&/&amp;}"
    safe="${safe//</&lt;}"
    safe="${safe//>/&gt;}"
    tooltip+="${nl}${safe}"
done

if (( event_count == 0 && allday_count == 0 )); then
    tooltip+="${nl}No events"
fi

# Tomorrow section
tomorrow_event_count=$(echo "$tomorrow_events" | jq 'length')
tomorrow_allday_count=$(echo "$tomorrow_allday" | jq 'length')

tooltip+="${nl}${nl}<b>Tomorrow${nl}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━</b>"

for ((i=0; i<tomorrow_event_count; i++)); do
    start_str=$(echo "$tomorrow_events" | jq -r ".[$i].start")
    end_str=$(echo "$tomorrow_events" | jq -r ".[$i].end")
    summary=$(echo "$tomorrow_events" | jq -r ".[$i].summary")

    start_hm=$(date -d "$start_str" +%H:%M 2>/dev/null)
    end_hm=$(date -d "$end_str" +%H:%M 2>/dev/null)

    safe="${summary//&/&amp;}"
    safe="${safe//</&lt;}"
    safe="${safe//>/&gt;}"
    tooltip+="${nl}${start_hm} – ${end_hm}  ${safe}"
done

if (( tomorrow_event_count > 0 && tomorrow_allday_count > 0 )); then
    tooltip+="${nl}"
fi
for ((i=0; i<tomorrow_allday_count; i++)); do
    summary=$(echo "$tomorrow_allday" | jq -r ".[$i].summary")
    safe="${summary//&/&amp;}"
    safe="${safe//</&lt;}"
    safe="${safe//>/&gt;}"
    tooltip+="${nl}${safe}"
done

if (( tomorrow_event_count == 0 && tomorrow_allday_count == 0 )); then
    tooltip+="${nl}No events"
fi

# Footer
last_fetched=$(date -r "$EVENTS_CACHE" +%H:%M 2>/dev/null || echo "unknown")
tooltip+="${nl}${nl}<small>Last fetched: ${last_fetched} · Click to refresh</small>"

alt="events"
[[ "$class" == "empty" ]] && alt="no-events"

jq -cn --arg text "$bar_text" --arg tooltip "$tooltip" --arg class "$class" --arg alt "$alt" \
    '{text: $text, tooltip: $tooltip, class: $class, alt: $alt}'
