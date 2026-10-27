TOKEN=$(printf "protocol=https\nhost=github.com\n\n" | GIT_TERMINAL_PROMPT=0 git credential fill 2>/dev/null | sed -n 's/^password=//p')
curl -s -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
 "https://api.github.com/repos/d-allulose/moss-image-build/actions/runs?per_page=3" \
 | python -X utf8 -c "
import json,sys
d=json.load(sys.stdin)
print('total_runs=',d.get('total_count'))
for r in d.get('workflow_runs',[])[:3]:
    print(r.get('status'), r.get('conclusion'), r.get('name'), r.get('created_at'), r.get('html_url'))
"
