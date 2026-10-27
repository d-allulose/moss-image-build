TOKEN=$(printf "protocol=https\nhost=github.com\n\n" | GIT_TERMINAL_PROMPT=0 git credential fill 2>/dev/null | sed -n 's/^password=//p')
H="Authorization: Bearer $TOKEN"
echo "--- repo actions permissions ---"
curl -s -H "$H" https://api.github.com/repos/d-allulose/moss-image-build/actions/permissions
echo
echo "--- workflows ---"
curl -s -H "$H" https://api.github.com/repos/d-allulose/moss-image-build/actions/workflows | head -40
echo
echo "--- account actions permissions ---"
curl -s -H "$H" https://api.github.com/user/settings/actions/permissions 2>/dev/null | head -5
