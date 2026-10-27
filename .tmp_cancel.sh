TOKEN=$(printf "protocol=https\nhost=github.com\n\n" | GIT_TERMINAL_PROMPT=0 git credential fill 2>/dev/null | sed -n 's/^password=//p')
curl -s -o /dev/null -w "cancel dispatcher: http=%{http_code}\n" -X POST -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" "https://api.github.com/repos/d-allulose/moss-image-build/actions/runs/40463602794/cancel"
