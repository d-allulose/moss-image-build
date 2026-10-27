TOKEN=$(printf "protocol=https\nhost=github.com\n\n" | GIT_TERMINAL_PROMPT=0 git credential fill 2>/dev/null | sed -n 's/^password=//p')
H="Authorization: Bearer $TOKEN"
echo "--- runs (recheck) ---"
curl -s -H "$H" "https://api.github.com/repos/d-allulose/moss-image-build/actions/runs?per_page=5" | python -X utf8 -c "
import json,sys; d=json.load(sys.stdin); print('total=',d.get('total_count'))
for r in d.get('workflow_runs',[])[:5]: print(r.get('id'), r.get('status'), r.get('conclusion'), r.get('head_sha')[:8], r.get('created_at'))
"
echo "--- dispatch ---"
curl -s -o .tmp_disp.json -w "http=%{http_code}\n" -X POST \
  -H "$H" -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/d-allulose/moss-image-build/actions/workflows/build.yml/dispatches" \
  -d '{"ref":"main"}'
cat .tmp_disp.json
