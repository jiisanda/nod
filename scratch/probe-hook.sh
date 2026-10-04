#!/usr/bin/env bash
# Throwaway logging hook for the hooks-contract experiment (docs/design.md §2).
# Not nod code. Logs every event; for PermissionRequest it can stay alive and
# print a late decision, controlled by the `mode` file next to this script:
#
#   none            exit immediately, no decision (default)
#   hold <secs>     stay alive <secs>, logging a heartbeat, then exit silently
#   allow <secs>    stay alive <secs>, then print an allow decision
#   deny <secs>     stay alive <secs>, then print a deny decision

dir="$(cd "$(dirname "$0")" && pwd)"
log="$dir/log/events.log"
payloads="$dir/log/payloads"
mkdir -p "$payloads"

payload="$(cat)"
ts() { date +%H:%M:%S.%3N; }
logln() { echo "$(ts) pid=$$ $*" >>"$log"; }

event="$(jq -r '.hook_event_name // "?"' <<<"$payload" 2>/dev/null)"
detail="$(jq -r '[.tool_name, .tool_use_id, .notification_type, .source, .reason] | map(select(. != null)) | join(" ")' <<<"$payload" 2>/dev/null)"
logln "$event $detail"
jq . <<<"$payload" >"$payloads/$(date +%H%M%S.%3N)-$event.json" 2>/dev/null

[ "$event" = "PermissionRequest" ] || exit 0

read -r action secs <"$dir/mode" 2>/dev/null
action="${action:-none}"
secs="${secs:-0}"
[ "$action" = "none" ] && exit 0

trap 'logln "PermissionRequest got SIGTERM"; exit 0' TERM
trap 'logln "PermissionRequest got SIGINT"; exit 0' INT
trap 'logln "PermissionRequest got SIGHUP"; exit 0' HUP
logln "PermissionRequest holding ${secs}s, then: $action"

for ((i = 1; i <= secs; i++)); do
	sleep 1
	if ((i % 5 == 0)); then logln "PermissionRequest still alive at ${i}s"; fi
done

case "$action" in
allow | deny)
	logln "PermissionRequest printing $action"
	printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"%s","message":"from probe-hook"}}}\n' "$action"
	;;
*)
	logln "PermissionRequest exiting silently"
	;;
esac
exit 0
