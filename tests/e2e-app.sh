# Pi-hole's steps for the chassis harness (chassis/tests/e2e.sh <appdir> act).
# DNS on port 1053 here: this box's own resolver has 53.
app_e2e_answers() { printf "DNS_PORT='1053'\nTLS='off'\n"; }
wait_for() { local i; for i in $(seq 1 "$2"); do touch "$VAR/watching"; jq -e "$1" "$VAR/status.json" >/dev/null 2>&1 && return 0; sleep 1; done; return 1; }
secret() { local s; s=$(jq -r 'select(.kind == "setup") | .password' "$VAR/secret.json" 2>/dev/null); rm -f "$VAR/secret.json"; printf '%s' "$s"; }
login_ok() { [[ "$(curl -sk -d "$(jq -cn --arg p "$2" '{password: $p}')" "$1/api/auth" | jq -r '.session.valid')" == true ]]; }
ask() { dig +short +time=3 +tries=1 @127.0.0.1 -p 1053 "$1" A 2>/dev/null | tail -n 1; }
app_e2e_act() {
  local fail=0 url="http://127.0.0.1:$PORT" pw pw2 i
  log "pihole"
  echo "  (health: $(curl -s "$url/api/info/login" | jq -c .), version $(jq -r .version "$VAR/status.json"))"
  pw=$(secret)
  [[ ${#pw} -ge 20 ]] && echo "  ok   a one-time password was left for the window" || { echo "  FAIL no password secret"; fail=1; }
  login_ok "$url" "$pw" && echo "  ok   it signs in to Pi-hole" || { echo "  FAIL sign-in"; fail=1; }
  wait_for '.app.api == true and .app.blocking.state == "enabled" and .app.stats.gravity > 1000' 30 && echo "  ok   the package has its app password; blocking on, $(jq -r .app.stats.gravity "$VAR/status.json") domains on the default list" || { echo "  FAIL status: $(jq -c '.app | {api, blocking, stats}' "$VAR/status.json")"; fail=1; }
  wait_for '.app.upstreams == ["1.1.1.1","1.0.0.1"]' 20 && echo "  ok   upstream Cloudflare from the start" || { echo "  FAIL upstreams: $(jq -c .app.upstreams "$VAR/status.json")"; fail=1; }
  # DNS answers; a site you block is blocked; pausing lets it through; resuming blocks it again.
  [[ "$(ask example.org)" =~ ^[0-9]+\. && "$(ask example.org)" != 0.0.0.0 ]] && echo "  ok   DNS answers on port 1053: example.org → $(ask example.org)" || { echo "  FAIL dns: $(ask example.org)"; fail=1; }
  request "ACTION='domainadd'" "KIND='deny'" "DOMAIN='example.org'" || fail=1
  for i in $(seq 1 10); do [[ "$(ask example.org)" == 0.0.0.0 ]] && break; sleep 1; done
  [[ "$(ask example.org)" == 0.0.0.0 ]] && echo "  ok   always blocked: example.org → 0.0.0.0" || { echo "  FAIL deny: $(ask example.org)"; fail=1; }
  wait_for '.app.domains | map(select(.type == "deny")) | map(.domain) | index("example.org")' 20 && echo "  ok   listed under your sites" || { echo "  FAIL domains list"; fail=1; }
  wait_for '.app.recent | map(.domain) | index("example.org")' 30 && echo "  ok   …and under blocked just now" || { echo "  FAIL recent: $(jq -c .app.recent "$VAR/status.json")"; fail=1; }
  request "ACTION='pause'" "PAUSE_FOR='300'" || fail=1
  [[ "$(ask example.org)" != 0.0.0.0 ]] && wait_for '.app.blocking.state == "disabled" and .app.blocking.timer > 0' 20 && echo "  ok   paused for 5 minutes: example.org gets through" || { echo "  FAIL pause"; fail=1; }
  request "ACTION='resume'" || fail=1
  [[ "$(ask example.org)" == 0.0.0.0 ]] && echo "  ok   resumed" || { echo "  FAIL resume"; fail=1; }
  request "ACTION='domaindel'" "KIND='deny'" "DOMAIN='example.org'" || fail=1
  # Paused with no timer for over an hour: DSM hears of it (the hour is wound on here).
  request "ACTION='pause'" "PAUSE_FOR='0'" || fail=1
  for i in $(seq 1 150); do [[ -e "$VAR/.off-since" ]] && break; touch "$VAR/watching"; sleep 1; done
  docker run --rm -v "$VAR:/v" --entrypoint sh pihole-setup:local -c 'touch -d "@$(( $(date +%s) - 4000 ))" /v/.off-since; rm -f /v/.off-check'
  for i in $(seq 1 90); do grep -qE "notification \(piholeoff\)|told DSM: piholeoff" "$VAR/package.log" && break; touch "$VAR/watching"; sleep 1; done
  grep -qE "notification \(piholeoff\)|told DSM: piholeoff" "$VAR/package.log" && echo "  ok   blocking off for an hour went to DSM's notifications (only attempted: no DSM here)" || { echo "  FAIL no DSM notification"; fail=1; }
  request "ACTION='resume'" || fail=1
  # Upstreams and blocklists.
  request "ACTION='upstream'" "UPSTREAM='custom'" "CUSTOM_DNS='9.9.9.9+1.1.1.1'" || fail=1
  wait_for '.app.upstreams == ["9.9.9.9","1.1.1.1"]' 20 && echo "  ok   custom upstreams" || { echo "  FAIL custom: $(jq -c .app.upstreams "$VAR/status.json")"; fail=1; }
  request "ACTION='listadd'" "URL_B64='$(printf 'https://raw.githubusercontent.com/StevenBlack/hosts/master/alternates/fakenews-only/hosts' | base64 -w0 | tr '+/' '-_' | tr -d '=')'" || fail=1
  request "ACTION='gravity'" || fail=1
  wait_for '.app.lists | length == 2 and all(.[]; .domains > 0)' 30 && echo "  ok   a second blocklist, fetched: $(jq -c '[.app.lists[].domains]' "$VAR/status.json") domains" || { echo "  FAIL lists: $(jq -c .app.lists "$VAR/status.json")"; fail=1; }
  request "ACTION='listdel'" "LIST_ID='$(jq -r '.app.lists[] | select(.address | test("fakenews")) | .id' "$VAR/status.json")'" || fail=1
  wait_for '.app.lists | length == 1' 20 && echo "  ok   removed again" || { echo "  FAIL listdel"; fail=1; }
  # A new password; HTTPS.
  request "ACTION='newpw'" || fail=1; pw2=$(secret)
  login_ok "$url" "$pw2" && ! login_ok "$url" "$pw" && echo "  ok   a new password works, the old one doesn't" || { echo "  FAIL newpw"; fail=1; }
  request "ACTION='settings'" "TLS='self'" || fail=1
  [[ "$(curl -sk "https://127.0.0.1:$PORT/api/info/login" | jq -r .dns)" == true ]] && login_ok "https://127.0.0.1:$PORT" "$pw2" && echo "  ok   HTTPS self: Pi-hole's page on https, sign-in works" || { echo "  FAIL https"; fail=1; }
  [[ "$(ask example.net)" =~ ^[0-9]+\. ]] && echo "  ok   DNS unaffected by HTTPS" || { echo "  FAIL dns after https"; fail=1; }
  request "ACTION='settings'" "TLS='off'" || fail=1
  [[ "$(curl -s "$url/api/info/login" | jq -r .dns)" == true ]] && echo "  ok   back to plain HTTP" || { echo "  FAIL http again"; fail=1; }
  (( fail )) && { echo "  pihole: something FAILED"; return 1; }; echo "  pihole: all passed"
}
