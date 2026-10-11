# Pi-hole's actions, validated by the CGI before they become a request file.
b64u() { printf '%s' "$1" | base64 -w0 | tr '+/' '-_' | tr -d '='; }
app_cgi_post() {   # action body → sets $lines, or error
  local a=$1 body=$2 v u id k d up c
  case "$a" in
    resume|gravity|newpw|refreshcert) lines="ACTION='$a'" ;;
    pause) v=$(param seconds "$body"); [[ "$v" =~ ^(300|1800|3600|0)$ ]] || error "400 Bad Request" "Pick how long."; lines="ACTION='pause'
PAUSE_FOR='$v'" ;;
    listadd) u=$(decode "$(param url "$body")")
      [[ "$u" =~ ^https?://[^[:space:]\"\'\<\>]+$ && ${#u} -le 500 ]] || error "400 Bad Request" "A blocklist is a web address (https://…)."
      lines="ACTION='listadd'
URL_B64='$(b64u "$u")'" ;;
    listdel) id=$(param id "$body"); [[ "$id" =~ ^[0-9]{1,9}$ ]] || error "400 Bad Request" "Pick a list."; lines="ACTION='listdel'
LIST_ID='$id'" ;;
    domainadd|domaindel) k=$(param kind "$body"); d=$(decode "$(param domain "$body")" | tr 'A-Z' 'a-z')
      [[ "$k" =~ ^(allow|deny)$ ]] || error "400 Bad Request" "Allow or block."
      [[ "$d" =~ ^[a-z0-9]([a-z0-9-]{0,62}\.)+[a-z]{2,63}$ && ${#d} -le 253 ]] || error "400 Bad Request" "A site's name, like ads.example.com."
      lines="ACTION='$a'
KIND='$k'
DOMAIN='$d'" ;;
    upstream) up=$(param upstream "$body"); c=$(decode "$(param custom "$body")" | tr -s ' ,' '++' | sed 's/^+//; s/+$//')
      [[ "$up" =~ ^(cloudflare|quad9|google|custom)$ ]] || error "400 Bad Request" "Pick an upstream."
      if [[ "$up" == custom ]]; then [[ "$c" =~ ^[0-9.]{7,15}(\+[0-9.]{7,15})?$ ]] || error "400 Bad Request" "One or two IPv4 addresses, like 192.168.1.1."; else c=""; fi
      lines="ACTION='upstream'
UPSTREAM='$up'
CUSTOM_DNS='$c'" ;;
  esac
}
app_cgi_settings() {   # body → appends TLS to $lines, or errors
  local tls; tls=$(param tls "$1")
  [[ -z "$tls" ]] && return 0
  [[ "$tls" =~ ^(dsm|self|off)$ ]] || error "400 Bad Request" "HTTPS is DSM's certificate, self-signed, or off."
  lines="$lines
TLS='$tls'"
}
