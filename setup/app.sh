# Pi-hole's hooks for the chassis core (sourced by run-core.sh). The core
# gives: say, env_get/env_set, rand, compose, in_volume, cname, svc_up,
# leave_secret, notify, fresh, now, wait_ready, MSG, VAR, APP, LOG, PKG_NAME,
# PKG_TITLE, and the tls_* helpers (chassis tls.sh).
#
# Pi-hole makes a random password at its first start and prints it in its log.
# The package uses it once: it allows app passwords to change settings
# (webserver.api.app_sudo), gives itself an app password (kept in the root-only
# .env), then sets your password — shown once, never stored. Everything after
# goes through Pi-hole's own API with the app password; one session is kept in
# $VAR and reused, because Pi-hole allows only a few at a time.

PH=""; SID_FILE=""

app_validate() {   # key value → 0 if the value has the key's shape
  case "$1" in
    DNS_PORT)   [[ "$2" =~ ^[0-9]{2,5}$ ]] ;;
    TLS)        [[ "$2" =~ ^(dsm|self|off)$ ]] ;;
    PAUSE_FOR)  [[ "$2" =~ ^(300|1800|3600|0)$ ]] ;;   # not SECONDS: that's bash's own clock
    URL_B64)    [[ "$2" =~ ^[A-Za-z0-9_-]+$ ]] && (( ${#2} <= 700 )) ;;
    LIST_ID)    [[ "$2" =~ ^[0-9]{1,9}$ ]] ;;
    KIND)       [[ "$2" =~ ^(allow|deny)$ ]] ;;
    DOMAIN)     [[ "$2" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,62}\.)+[A-Za-z]{2,63}$ ]] && (( ${#2} <= 253 )) ;;
    UPSTREAM)   [[ "$2" =~ ^(cloudflare|quad9|google|custom)$ ]] ;;
    CUSTOM_DNS) [[ "$2" =~ ^[0-9.]{7,15}(\+[0-9.]{7,15})?$ ]] ;;
    *) return 1 ;;
  esac
}

# ------------------------------------------------------------ talking to Pi-hole
b64d() { local s=${1//-/+}; s=${s//_//}; while (( ${#s} % 4 )); do s="$s="; done; printf '%s' "$s" | base64 -d 2>/dev/null; }
scheme() { [[ "$(env_get TLS_SOURCE)" =~ ^(dsm|self)$ ]] && echo https || echo http; }
ph_url() { echo "$(scheme)://127.0.0.1:$(env_get HTTP_PORT)"; }
strong_password() { echo "$(rand 5)-$(rand 5)-$(rand 5)-$(rand 5)"; }
ph_login() {   # password → a session id on stdout
  curl -sk --max-time 15 "$(ph_url)/api/auth" -d "$(jq -cn --arg p "$1" '{password: $p}')" 2>/dev/null | jq -r '.session.sid // empty'
}
ph_sid() {   # the package's session (its app password), reused while it lasts
  local sid; sid=$(cat "$SID_FILE" 2>/dev/null)
  [[ -n "$sid" ]] && fresh "$SID_FILE" 1500 && { printf '%s' "$sid"; return 0; }
  sid=$(ph_login "$(env_get PH_APP)"); [[ -n "$sid" ]] || return 1
  printf '%s' "$sid" > "$SID_FILE"; chmod 600 "$SID_FILE"; printf '%s' "$sid"
}
ph_api() {   # method path [json] → body (HTTP code in PH_CODE); a session that expired is renewed once
  local sid out try
  for try in 1 2; do
    sid=$(ph_sid) || { PH_CODE=0; return 1; }
    out=$(curl -sk --max-time "${PH_TIMEOUT:-30}" -X "$1" "$(ph_url)/api/$2" -H "sid: $sid" -H 'Content-Type: application/json' ${3:+-d "$3"} -w '\n%{http_code}' 2>/dev/null)
    PH_CODE=${out##*$'\n'}; out=${out%$'\n'*}
    [[ "$PH_CODE" == 401 ]] && { rm -f "$SID_FILE"; continue; }
    break
  done
  printf '%s' "$out"; [[ "$PH_CODE" =~ ^2 ]]
}
ph_why() { jq -r '.error.message // .error.key // empty' <<< "$1" 2>/dev/null | head -c 200; }
upstreams_for() {   # choice [custom] → JSON array of upstream servers
  case "$1" in
    cloudflare) echo '["1.1.1.1","1.0.0.1"]' ;; quad9) echo '["9.9.9.9","149.112.112.112"]' ;; google) echo '["8.8.8.8","8.8.4.4"]' ;;
    custom) jq -cn --arg c "$2" '$c | split("+") | map(select(length > 0))' ;;
  esac
}
dns_port_taken() {   # → what else listens on the DNS port on this Synology (empty when it's free, or ours)
  local p; p=$(env_get DNS_PORT); p=${p:-53}
  svc_up server && return 0
  ss -lnup 2>/dev/null | awk -v p=":$p" '$5 ~ p"$" && $5 !~ /^127\./ { print $NF }' | head -n 1
}

# ------------------------------------------------------------ lifecycle hooks
app_first_env() {
  env_set PH_IMAGE pihole/pihole:latest
  env_set DNS_PORT "${DNS_PORT:-53}"; env_set UPSTREAM cloudflare; env_set DSM_ALERTS 1
  env_set TLS "${TLS:-off}"
  tls_fix_scheme || true
  touch "$VAR/.needs-password"
}
app_load_env() { PH=$(cname server); SID_FILE="$VAR/.ph-sid"; }
app_before_up() {
  local who
  [[ -n "$(env_get TLS)" ]] || env_set TLS off
  who=$(dns_port_taken)
  [[ -n "$who" ]] && say "✗ port $(env_get DNS_PORT) (DNS) is already used on this Synology by ${who} — usually DSM's DNS Server package. Stop it (Package Center → DNS Server → Stop), then Run Pi-hole again."
  setup_tls || say "✗ HTTPS couldn't be set up: $MSG"
}
setup_tls() {   # Pi-hole wants key and certificate in one PEM file, readable by its own user (1000)
  tls_fix_scheme || true
  tls_prepare etc || return 1
  if [[ "$(env_get TLS_SOURCE)" =~ ^(dsm|self)$ ]]; then
    in_volume etc rw -- 'cat /vol/tls/privkey.pem /vol/tls/fullchain.pem > /vol/dsm-tls.pem && chown 1000:1000 /vol/dsm-tls.pem && chmod 600 /vol/dsm-tls.pem' </dev/null 2>>"$LOG" \
      || { MSG="The certificate couldn't be put in place for Pi-hole."; return 1; }
    env_set TLS_PEM /etc/pihole/dsm-tls.pem; env_set INNER_PORT 443
  else env_set TLS_PEM /etc/pihole/tls.pem; env_set INNER_PORT 80; fi
  rm -f "$SID_FILE"
}
app_health() { [[ "$(curl -sk --max-time 5 "$(ph_url)/api/info/login" 2>/dev/null | jq -r '.dns // empty' 2>/dev/null)" == true ]]; }
app_version() {   # Pi-hole's own version (the image's tag is a date)
  local v; v=$(ph_api GET info/version 2>/dev/null | jq -r '.version.core.local.version // empty' 2>/dev/null | sed 's/^v//')
  [[ -n "$v" ]] || v=$(docker inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "$PH" 2>/dev/null)
  tr -cd '0-9A-Za-z.-' <<< "$v" | head -c 30
}
app_after_up() { make_password 90; }
make_password() {   # [tries] — the first time: the package's app password, then yours (shown once)
  [[ -f "$VAR/.needs-password" ]] || return 0
  local i first sid out app hash pw
  for i in $(seq 1 "${1:-1}"); do app_health && break; sleep 2; done
  app_health || { say "Pi-hole isn't answering yet — its password is set when it does"; return 0; }
  first=$(docker logs "$PH" 2>&1 | sed -n 's/.*assigning random password: //p' | tail -n 1 | tr -d '\r')
  [[ -n "$first" ]] && sid=$(ph_login "$first")
  [[ -n "${sid:-}" ]] || { say "Pi-hole's first password isn't in its log any more (or was changed) — the window can't manage it; reinstalling with a fresh volume starts over"; rm -f "$VAR/.needs-password"; return 0; }
  out=$(curl -sk --max-time 15 -X PATCH "$(ph_url)/api/config" -H "sid: $sid" -H 'Content-Type: application/json' -d '{"config":{"webserver":{"api":{"app_sudo":true}}}}' -w '\n%{http_code}')
  [[ "${out##*$'\n'}" =~ ^2 ]] || { say "✗ Pi-hole didn't allow the package's settings access: $(ph_why "${out%$'\n'*}")"; return 0; }
  out=$(curl -sk --max-time 15 "$(ph_url)/api/auth/app" -H "sid: $sid"); app=$(jq -r '.app.password // empty' <<< "$out"); hash=$(jq -r '.app.hash // empty' <<< "$out")
  [[ -n "$app" && -n "$hash" ]] || { say "✗ Pi-hole didn't make an app password: $(ph_why "$out")"; return 0; }
  out=$(curl -sk --max-time 15 -X PATCH "$(ph_url)/api/config" -H "sid: $sid" -H 'Content-Type: application/json' -d "$(jq -cn --arg h "$hash" '{config: {webserver: {api: {app_pwhash: $h}}}}')" -w '\n%{http_code}')
  [[ "${out##*$'\n'}" =~ ^2 ]] || { say "✗ the app password wasn't saved: $(ph_why "${out%$'\n'*}")"; return 0; }
  env_set PH_APP "$app"; rm -f "$SID_FILE"
  pw=$(strong_password)
  out=$(ph_api PATCH config "$(jq -cn --arg p "$pw" '{config: {webserver: {api: {password: $p}}}}')") || { say "✗ your Pi-hole password couldn't be set: $(ph_why "$out") — trying again shortly"; return 0; }
  ph_api PATCH config "$(jq -cn --argjson u "$(upstreams_for "$(env_get UPSTREAM)" "$(env_get CUSTOM_DNS)")" '{config: {dns: {upstreams: $u}}}')" >/dev/null || true
  leave_secret "Pi-hole" "$pw" setup; rm -f "$VAR/.needs-password"
  say "first start: Pi-hole's password was set (shown once in the window); the package uses an app password of its own"
}

# ------------------------------------------------------------ what the window shows
app_status() {
  svc_up server || { echo '{"up": false}'; return 0; }
  local sum='{}' blk='{}' top='[]' recent='[]' lists='[]' doms='[]' ups='[]'
  sum=$(ph_api GET stats/summary) || sum='{}'
  blk=$(ph_api GET dns/blocking) || blk='{}'
  if fresh "$VAR/watching" 30 || [[ ! -s "$VAR/ph-detail.json" ]]; then   # the lists only while the window is open
    top=$(ph_api GET "stats/top_domains?blocked=true&count=10" | jq -c '[.domains[]? | {domain, count}]') || top='[]'
    recent=$(ph_api GET "queries?length=300" | jq -c '[.queries[]? | select(.status | test("GRAVITY|DENYLIST|REGEX|BLOCKED|SPECIAL")) | {domain, at: (.time | floor), client: (.client.name // .client.ip), status}] | .[:15]') || recent='[]'
    lists=$(ph_api GET lists | jq -c '[.lists[]? | select(.type == "block") | {id, address, enabled, domains: .number, updated: .date_updated, status}]') || lists='[]'
    doms=$(ph_api GET domains | jq -c '[.domains[]? | {domain, type, kind, enabled}]') || doms='[]'
    ups=$(ph_api GET config/dns/upstreams | jq -c '.config.dns.upstreams // []') || ups='[]'
    jq -n -c --argjson top "${top:-[]}" --argjson recent "${recent:-[]}" --argjson lists "${lists:-[]}" --argjson doms "${doms:-[]}" --argjson ups "${ups:-[]}" \
      '{top: $top, recent: $recent, lists: $lists, domains: $doms, upstreams: $ups}' > "$VAR/ph-detail.json.tmp" 2>/dev/null && mv "$VAR/ph-detail.json.tmp" "$VAR/ph-detail.json"
  fi
  [[ -s "$VAR/cert.json" ]] || tls_info etc
  jq -c --argjson sum "${sum:-{\}}" --argjson blk "${blk:-{\}}" --arg url "$(env_get APP_URL)" --arg ip "$(env_get LAN_IP)" --arg dport "$(env_get DNS_PORT)" \
     --arg up "$(env_get UPSTREAM)" --arg custom "$(env_get CUSTOM_DNS)" --arg alerts "$(env_get DSM_ALERTS)" --arg app "$([[ -n "$(env_get PH_APP)" ]] && echo 1)" \
     --arg tls "$(env_get TLS)" --arg tls_source "$(env_get TLS_SOURCE)" --argjson cert "$(cat "$VAR/cert.json" 2>/dev/null || echo null)" \
     '. + {up: true, url: $url, dns: {ip: $ip, port: ($dport | tonumber? // 53)}, upstream: $up, custom: ($custom | split("+") | map(select(length > 0))), alerts: ($alerts == "1"), api: ($app == "1"),
           stats: {queries: ($sum.queries.total // 0), blocked: ($sum.queries.blocked // 0), percent: ($sum.queries.percent_blocked // 0), gravity: ($sum.gravity.domains_being_blocked // 0),
                   gravity_at: ($sum.gravity.last_update // 0), clients: ($sum.clients.active // 0)},
           blocking: {state: ($blk.blocking // "unknown"), timer: $blk.timer},
           tls: {mode: $tls, source: $tls_source, cert: $cert}}' "$VAR/ph-detail.json" 2>/dev/null || echo '{"up": true}'
}

# ------------------------------------------------------------ blocking left off → DSM
check_off() {   # blocking off with no timer for an hour → a DSM notification (again every 12 hours while it stays off)
  local b; b=$(ph_api GET dns/blocking) || return 0
  if [[ "$(jq -r '.blocking' <<< "$b")" == disabled && "$(jq -r '.timer // empty' <<< "$b")" == "" ]]; then
    [[ -f "$VAR/.off-since" ]] || touch "$VAR/.off-since"
    fresh "$VAR/.off-since" 3600 || { [[ "$(env_get DSM_ALERTS)" == 1 ]] && notify piholeoff 12; }
  else rm -f "$VAR/.off-since"; fi
}
app_tick() {
  make_password 1
  svc_up server || return 0
  fresh "$VAR/.off-check" 120 || { touch "$VAR/.off-check"; check_off || true; }
  fresh "$VAR/.cert-check" 86400 && return 0; touch "$VAR/.cert-check"
  tls_refresh_dsm etc
  [[ "$CERT_REFRESH" == changed ]] && { setup_tls && docker restart "$PH" >> "$LOG" 2>&1; } || true
  return 0
}

# ------------------------------------------------------------ settings, logs, storage, backups, report
app_settings() {
  [[ -n "${TLS:-}" ]] && env_set TLS "$TLS"
  setup_tls || return 1
  return 0
}
app_logs() { :; }
app_storage() {
  in_volume etc ro -- 'cd /vol; printf "gravity\t%s\n" "$(du -cm gravity.db 2>/dev/null | tail -n 1 | cut -f1)"; printf "history\t%s\n" "$(du -cm pihole-FTL.db* 2>/dev/null | tail -n 1 | cut -f1)"; true' </dev/null 2>/dev/null \
    | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {key: .[0], value: (.[1] | tonumber? // 0)}) | from_entries' 2>/dev/null || echo "{}"
}
app_backup() {   # dir — Pi-hole's own Teleporter export (settings, lists, domains), and its databases copied consistently
  local sid; sid=$(ph_sid) && curl -sk --max-time 120 -f -o "$1/teleporter.zip" "$(ph_url)/api/teleporter" -H "sid: $sid" 2>/dev/null \
    || { rm -f "$1/teleporter.zip"; say "the Teleporter export didn't come (Pi-hole isn't answering?) — the files below still are"; }   # a zip: straight to the file
  in_volume etc rw -- 'set -e; mkdir -p /tmp/b; cd /vol; tar -cf - --exclude="./*.db" --exclude="./*.db-*" --exclude=./tls --exclude=./dsm-tls.pem . | tar -C /tmp/b -xf -
    for f in gravity.db pihole-FTL.db; do [ -f "$f" ] && sqlite3 "$f" ".backup /tmp/b/$f"; done
    tar -C /tmp/b -czf - .' > "$1/etc.tar.gz" 2>>"$LOG" </dev/null \
    && grep -q 'gravity.db' < <(tar -tzf "$1/etc.tar.gz" 2>/dev/null) || { say "✗ Pi-hole's files didn't copy"; return 1; }
}
app_restore() {   # dir — the core has stopped the containers
  [[ -s "$1/etc.tar.gz" ]] || { MSG="That backup has no Pi-hole files."; return 1; }
  in_volume etc rw -- 'find /vol -mindepth 1 -delete && tar -C /vol -xzf - && chown -R 1000:1000 /vol' < "$1/etc.tar.gz" 2>>"$LOG" || { MSG="Pi-hole's files didn't unpack."; return 1; }
  rm -f "$SID_FILE" "$VAR/.needs-password"
}
app_report() {
  local s; s=$(ph_api GET stats/summary) || s='{}'
  echo "== today: $(jq -r '.queries.total // "?"' <<< "$s") queries, $(jq -r '.queries.blocked // "?"' <<< "$s") blocked, $(jq -r '.clients.active // "?"' <<< "$s") clients; $(jq -r '.gravity.domains_being_blocked // "?"' <<< "$s") domains on blocklists"
  echo "== blocking: $(ph_api GET dns/blocking | jq -c '{blocking, timer}' 2>/dev/null)"
  echo "== DNS port $(env_get DNS_PORT), upstream $(env_get UPSTREAM) $(ph_api GET config/dns/upstreams | jq -c '.config.dns.upstreams' 2>/dev/null)"
  echo "== lists"; ph_api GET lists | jq -r '.lists[]? | "\(.type)  \(.enabled)  \(.number) domains  \(.address)"' 2>/dev/null
  echo; echo "== HTTPS"; echo "mode $(env_get TLS), in use: $(env_get TLS_SOURCE)"; jq -c 'del(.names)' "$VAR/cert.json" 2>/dev/null
  :
}

# ------------------------------------------------------------ the window's actions
app_act() {   # action (request vars are set)
  local out url pw
  case "$1" in
    pause)
      out=$(ph_api POST dns/blocking "$(jq -cn --argjson t "${PAUSE_FOR:-300}" 'if $t > 0 then {blocking: false, timer: $t} else {blocking: false, timer: null} end')") || { MSG="Pi-hole said no: $(ph_why "$out")"; return 1; }
      MSG=$([[ "${PAUSE_FOR:-300}" == 0 ]] && echo "Blocking is off until you turn it on again." || echo "Blocking is paused for $(( PAUSE_FOR / 60 )) minutes; it comes back by itself.") ;;
    resume) out=$(ph_api POST dns/blocking '{"blocking": true, "timer": null}') || { MSG="Pi-hole said no: $(ph_why "$out")"; return 1; }; rm -f "$VAR/.off-since"; MSG="Blocking is on." ;;
    listadd)
      url=$(b64d "${URL_B64:-}"); [[ "$url" =~ ^https?://[^[:space:]\"\'\<\>]+$ && ${#url} -le 500 ]] || { MSG="A blocklist is a web address (https://…)."; return 1; }
      out=$(ph_api POST "lists?type=block" "$(jq -cn --arg a "$url" '{address: $a, comment: "added in DSM", enabled: true}')") || { MSG="Pi-hole didn't add it: $(ph_why "$out")"; return 1; }
      MSG="Added. Press Update the lists to fetch its domains." ;;
    listdel)
      out=$(ph_api GET lists) || { MSG="Pi-hole isn't answering."; return 1; }
      url=$(jq -r --argjson id "$LIST_ID" '.lists[] | select(.id == $id) | .address' <<< "$out"); [[ -n "$url" ]] || { MSG="That list isn't there any more."; return 1; }
      out=$(ph_api DELETE "lists/$(jq -rn --arg u "$url" '$u | @uri')?type=block") || { MSG="Pi-hole didn't remove it: $(ph_why "$out")"; return 1; }
      MSG="Removed. Its domains go at the next list update." ;;
    gravity)
      PH_TIMEOUT=600 ph_api POST action/gravity >/dev/null || { MSG="The lists didn't update — is this Synology online? (Pi-hole's own log has the details.)"; return 1; }
      MSG="Lists updated: $(ph_api GET stats/summary | jq -r '.gravity.domains_being_blocked // "?"') domains are blocked." ;;
    domainadd)
      out=$(ph_api POST "domains/$KIND/exact" "$(jq -cn --arg d "$DOMAIN" '{domain: $d, comment: "added in DSM", enabled: true}')") || { MSG="Pi-hole didn't add it: $(ph_why "$out")"; return 1; }
      MSG=$([[ "$KIND" == allow ]] && echo "$DOMAIN is always allowed now." || echo "$DOMAIN is always blocked now.") ;;
    domaindel)
      out=$(ph_api DELETE "domains/$KIND/exact/$DOMAIN") || { MSG="Pi-hole didn't remove it: $(ph_why "$out")"; return 1; }
      MSG="$DOMAIN is off the $([[ "$KIND" == allow ]] && echo allowed || echo blocked) list." ;;
    upstream)
      [[ "$UPSTREAM" == custom && -z "${CUSTOM_DNS:-}" ]] && { MSG="Give one or two DNS server addresses."; return 1; }
      out=$(ph_api PATCH config "$(jq -cn --argjson u "$(upstreams_for "$UPSTREAM" "${CUSTOM_DNS:-}")" '{config: {dns: {upstreams: $u}}}')") || { MSG="Pi-hole said no: $(ph_why "$out")"; return 1; }
      env_set UPSTREAM "$UPSTREAM"; env_set CUSTOM_DNS "${CUSTOM_DNS:-}"
      MSG="Pi-hole now asks $(upstreams_for "$UPSTREAM" "${CUSTOM_DNS:-}" | jq -r 'join(" and ")') for everything it doesn't block." ;;
    newpw)
      pw=$(strong_password)
      out=$(ph_api PATCH config "$(jq -cn --arg p "$pw" '{config: {webserver: {api: {password: $p}}}}')") || { MSG="The password wasn't changed: $(ph_why "$out")"; return 1; }
      leave_secret "Pi-hole" "$pw" setup; MSG="Your new password is shown below, once." ;;
    refreshcert)
      tls_refresh_dsm etc; setup_tls || return 1; docker restart "$PH" >> "$LOG" 2>&1; wait_ready 180
      MSG=$([[ "$(env_get TLS_SOURCE)" == dsm ]] && echo "DSM's certificate was read again." || echo "A new self-signed certificate is in use.") ;;
    *) MSG="Unknown request."; return 1 ;;
  esac
}
