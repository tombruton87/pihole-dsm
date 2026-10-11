# Pi-hole's CGI checks (sourced by chassis/tests/test-api.sh).
expect "pause" 202 "$(post "$me" pause 'action=pause&seconds=300')"; request_is "pause request" "ACTION='pause'
PAUSE_FOR='300'
BY='$me'"
expect "pause bad" 400 "$(post "$me" pause 'action=pause&seconds=99999')"
expect "listadd" 202 "$(post "$me" listadd 'action=listadd&url=https%3A%2F%2Fexample.com%2Flist.txt%3Fa%3D1%26b%3D2')"; request_is "listadd request" "ACTION='listadd'
URL_B64='aHR0cHM6Ly9leGFtcGxlLmNvbS9saXN0LnR4dD9hPTEmYj0y'
BY='$me'"
expect "listadd bad" 400 "$(post "$me" listadd 'action=listadd&url=file%3A%2F%2F%2Fetc%2Fpasswd')"
expect "domainadd" 202 "$(post "$me" domainadd 'action=domainadd&kind=allow&domain=Ads.Example.com')"; request_is "domainadd request" "ACTION='domainadd'
KIND='allow'
DOMAIN='ads.example.com'
BY='$me'"
expect "domainadd bad" 400 "$(post "$me" domainadd 'action=domainadd&kind=deny&domain=a%3Bb.com')"
expect "upstream custom" 202 "$(post "$me" upstream 'action=upstream&upstream=custom&custom=192.168.1.1%2C%201.1.1.1')"; request_is "upstream request" "ACTION='upstream'
UPSTREAM='custom'
CUSTOM_DNS='192.168.1.1+1.1.1.1'
BY='$me'"
expect "upstream bad" 400 "$(post "$me" upstream 'action=upstream&upstream=custom&custom=evil.com')"
