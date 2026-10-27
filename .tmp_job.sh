TOKEN=$(printf "protocol=https\nhost=github.com\n\n" | GIT_TERMINAL_PROMPT=0 git credential fill 2>/dev/null | sed -n 's/^password=//p')
H="Authorization: Bearer $TOKEN"
RID=$(curl -s -H "$H" "https://api.github.com/repos/d-allulose/moss-image-build/actions/runs?per_page=5" | python -X utf8 -c "
import json,sys; d=json.load(sys.stdin)
for r in d.get('workflow_runs',[]):
    if r.get('status')!='completed' or True:
        print(r.get('id')); break
")
echo "RID=$RID"
curl -s -H "$H" "https://api.github.com/repos/d-allulose/moss-image-build/actions/runs/$RID/jobs" | python -X utf8 -c "
import json,sys; d=json.load(sys.stdin)
for j in d.get('jobs',[]):
    print('job', j.get('id'), j.get('status'), j.get('conclusion'), j.get('started_at'))
    for s in j.get('steps',[]): print('   ', s.get('number'), s.get('name'), '->', s.get('status'), s.get('conclusion'))
"
echo "$RID" > .tmp_rid.txt
