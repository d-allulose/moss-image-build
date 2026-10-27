import json, time, urllib.request, urllib.error
TOKEN = "97a2af56-9ba4-4f14-955f-c72faab96ba5-20261027144508"
BASE = "https://openapi.suanli.cn"

def call(path, method="GET", body=None, timeout=25):
    url = BASE + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("token", TOKEN)
    req.add_header("timestamp", str(int(time.time() * 1000)))
    req.add_header("version", "1.0.0")
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")
    except Exception as e:
        return -1, repr(e)

for path in [
    "/api/deployment/resource/search",
    "/api/user/info",
    "/api/deployment/task/list",
    "/api/storage/volume/list",
    "/api/deployment/image/list",
]:
    code, txt = call(path)
    print("==", path, "->", code)
    print(txt[:400].replace("\n", " "))
    print()
