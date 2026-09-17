# -*- coding: utf-8 -*-
"""按 SHA 锁定轮询 GitHub Actions CI 状态（cancelled 视为被新提交顶掉）。"""
import json
import sys
import time
import urllib.request

REPO = "woyaoxingfua/ZhishengWeather"
SHA = sys.argv[1] if len(sys.argv) > 1 else "2e6a5d1"
TOKEN = sys.argv[2] if len(sys.argv) > 2 else None


def opener():
    handlers = []
    handlers.append(urllib.request.ProxyHandler(
        {"https": "http://127.0.0.1:7897", "http": "http://127.0.0.1:7897"}))
    return urllib.request.build_opener(*handlers)


def fetch(url):
    headers = {"User-Agent": "ci-watch", "Accept": "application/vnd.github+json"}
    if TOKEN:
        headers["Authorization"] = "token " + TOKEN
    return opener().open(urllib.request.Request(url, headers=headers), timeout=60).read()


def main():
    op = opener()
    for attempt in range(90):
        try:
            raw = fetch("https://api.github.com/repos/%s/actions/runs?head_sha=%s&per_page=10" % (REPO, SHA))
            runs = json.loads(raw)["workflow_runs"]
            if runs:
                r = runs[0]
                print("[%d] run %s status=%s conclusion=%s url=%s"
                      % (attempt, r["id"], r["status"], r["conclusion"], r["html_url"]))
                if r["status"] == "completed":
                    print("FINAL", r["conclusion"], "RUN_ID", r["id"])
                    return
            else:
                print("[%d] no run for sha yet" % attempt)
        except Exception as exc:
            print("[%d] poll error: %r" % (attempt, exc))
        time.sleep(30)
    print("TIMEOUT")


if __name__ == "__main__":
    main()
