#!/bin/bash

# ws-watch.sh v3
# Sorts apps by estimated WindowServer impact / "HEAVY" score.
#
# Usage:
#   ~/ws-watch.sh
#   ~/ws-watch.sh once
#   ~/ws-watch.sh watch
#   ~/ws-watch.sh 2

INTERVAL="${1:-watch}"
SWIFT_SCRIPT="/tmp/ws_window_list.swift"

cat > "$SWIFT_SCRIPT" <<'SWIFT'
import Foundation
import CoreGraphics

let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]

guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
    exit(1)
}

struct AppInfo {
    var name: String
    var pid: Int
    var windows: Int
    var area: Int
}

var apps: [Int: AppInfo] = [:]

for w in windows {
    guard let pid = w[kCGWindowOwnerPID as String] as? Int else { continue }
    guard let owner = w[kCGWindowOwnerName as String] as? String else { continue }

    let layer = w[kCGWindowLayer as String] as? Int ?? 0
    if layer != 0 { continue }

    var area = 0
    if let bounds = w[kCGWindowBounds as String] as? [String: Any],
       let width = bounds["Width"] as? Double,
       let height = bounds["Height"] as? Double {
        area = Int(width * height)
    }

    if area < 5000 { continue }

    if var existing = apps[pid] {
        existing.windows += 1
        existing.area += area
        apps[pid] = existing
    } else {
        apps[pid] = AppInfo(name: owner, pid: pid, windows: 1, area: area)
    }
}

for app in apps.values {
    print("\(app.pid)|\(app.name)|\(app.windows)|\(app.area)")
}
SWIFT

get_windowserver() {
  wspid="$(pgrep -x WindowServer)"
  if [ -z "$wspid" ]; then
    echo "WindowServer not found"
    return
  fi

  ps -p "$wspid" -o pid=,%cpu=,%mem=,rss=,comm= | awk '
  {
    printf "WindowServer PID=%s CPU=%s%% MEM=%s%% RSS=%.1f MB\n", $1, $2, $3, $4/1024
  }'
}

get_front_app() {
  osascript 2>/dev/null <<'APPLESCRIPT'
tell application "System Events"
  try
    return name of first application process whose frontmost is true
  on error
    return "Unknown"
  end try
end tell
APPLESCRIPT
}

print_report() {
  clear
  echo "=== WindowServer monitor v3 - sorted by HEAVY score ==="
  date
  echo

  get_windowserver
  echo "Front app: $(get_front_app)"
  echo

  printf "%-8s %-8s %-8s %-9s %-8s %-10s %-45s %s\n" "PID" "CPU%" "MEM%" "RSS_MB" "WINS" "HEAVY" "APP" "PIXELS"
  printf "%-8s %-8s %-8s %-9s %-8s %-10s %-45s %s\n" "--------" "------" "------" "-------" "----" "--------" "---------------------------------------------" "----------"

  /usr/bin/swift "$SWIFT_SCRIPT" 2>/dev/null | while IFS='|' read -r pid app wins area; do
    [ -z "$pid" ] && continue

    ps_line="$(ps -p "$pid" -o %cpu=,%mem=,rss= 2>/dev/null)"
    if [ -n "$ps_line" ]; then
      cpu="$(echo "$ps_line" | awk '{print $1}')"
      mem="$(echo "$ps_line" | awk '{print $2}')"
      rss="$(echo "$ps_line" | awk '{printf "%.1f", $3/1024}')"
    else
      cpu="0"
      mem="0"
      rss="0"
    fi

    # HEAVY score:
    # CPU is weighted strongly.
    # PIXELS show visible compositing load.
    # WINS adds cost for multiple visible windows.
    # RSS adds small weight for memory-heavy apps.
    heavy="$(awk -v cpu="$cpu" -v rss="$rss" -v wins="$wins" -v area="$area" '
      BEGIN {
        score = (cpu * 100) + (area / 100000) + (wins * 20) + (rss / 20)
        printf "%.1f", score
      }
    ')"

    printf "%-8s %-8s %-8s %-9s %-8s %-10s %-45s %s\n" "$pid" "$cpu" "$mem" "$rss" "$wins" "$heavy" "$app" "$area"
  done | sort -k6 -nr

  echo
  echo "Meaning:"
  echo "  HEAVY  = estimated impact score, sorted high to low"
  echo "  CPU%   = app CPU usage now"
  echo "  WINS   = visible windows owned by the app"
  echo "  PIXELS = total visible window area"
  echo
  echo "Interpretation:"
  echo "  Top app is the strongest suspect, not guaranteed proof."
  echo "  Quit top apps one by one and watch if WindowServer CPU drops."
}

case "$INTERVAL" in
  once)
    print_report
    ;;
  watch)
    while true; do
      print_report
      sleep 5
    done
    ;;
  *)
    if [[ "$INTERVAL" =~ ^[0-9]+$ ]]; then
      while true; do
        print_report
        sleep "$INTERVAL"
      done
    else
      echo "Usage:"
      echo "  ~/ws-watch.sh once"
      echo "  ~/ws-watch.sh watch"
      echo "  ~/ws-watch.sh 2"
      exit 1
    fi
    ;;
esac
