TOKEN=$(printf "protocol=https\nhost=github.com\n\n" | GIT_TERMINAL_PROMPT=0 git credential fill 2>/dev/null | sed -n 's/^password=//p')
curl -s -H "Authorization: Bearer $TOKEN" "https://api.github.com/repos/d-allulose/moss-image-build/actions/runs?per_page=5" | python -X utf8 -c "
import json,sys; d=json.load(sys.stdin)
for r in d.get('workflow_runs',[])[:5]:
    print(r.get('id'), r.get('status'), r.get('conclusion'), r.get('head_sha')[:8], r.get('created_at'), r.get('updated_at'))
"
