#!/usr/bin/env python3
"""CI: prepares the emulators for the sync test and checks what the app did against Firestore.

    python3 scripts/backend_check.py prepare      # the test account, with Premium (entitlements/{uid})
    python3 scripts/backend_check.py check <dir>  # the roles' reports and Firestore's copy

The emulators: Auth on 9196, Firestore on 8196 (project spendwise-unes). "Bearer owner" reads past
the rules.
"""
import json
import sys
import urllib.request
from pathlib import Path

PROJECT = "spendwise-unes"
AUTH = "http://127.0.0.1:9196/identitytoolkit.googleapis.com/v1"
FS = f"http://127.0.0.1:8196/v1/projects/{PROJECT}/databases/(default)/documents"
EMAIL, PASSWORD, NAME = "test.user@example.com", "test-only", "Test User"


def call(url, body=None, method=None, owner=False):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method or ("POST" if data else "GET"))
    req.add_header("Content-Type", "application/json")
    if owner:
        req.add_header("Authorization", "Bearer owner")
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return {"error": e.code, "body": e.read().decode()[:300]}


def value(v):
    """A Firestore REST value as Python."""
    if "stringValue" in v: return v["stringValue"]
    if "integerValue" in v: return int(v["integerValue"])
    if "doubleValue" in v: return float(v["doubleValue"])
    if "booleanValue" in v: return v["booleanValue"]
    if "nullValue" in v: return None
    if "timestampValue" in v: return v["timestampValue"]
    if "mapValue" in v: return {k: value(x) for k, x in v["mapValue"].get("fields", {}).items()}
    if "arrayValue" in v: return [value(x) for x in v["arrayValue"].get("values", [])]
    return v


def docs(path):
    out, token = {}, None
    while True:
        r = call(f"{FS}/{path}?pageSize=300" + (f"&pageToken={token}" if token else ""), owner=True)
        for d in r.get("documents", []):
            out[d["name"].rsplit("/", 1)[1]] = {k: value(x) for k, x in d.get("fields", {}).items()}
        token = r.get("nextPageToken")
        if not token:
            return out


def prepare():
    r = call(f"{AUTH}/accounts:signUp?key=fake-api-key", {"email": EMAIL, "password": PASSWORD, "returnSecureToken": True})
    if "localId" not in r:
        r = call(f"{AUTH}/accounts:signInWithPassword?key=fake-api-key", {"email": EMAIL, "password": PASSWORD, "returnSecureToken": True})
    uid = r["localId"]
    call(f"{AUTH}/accounts:update?key=fake-api-key", {"idToken": r["idToken"], "displayName": NAME, "returnSecureToken": True})
    # Premium, as grant_premium.py writes it
    w = call(f"{FS}/entitlements/{uid}", {"fields": {"tier": {"stringValue": "premium"}}}, method="PATCH", owner=True)
    print(f"prepared {EMAIL} ({uid}), entitlement: {'ok' if 'name' in w else w}")


def check(out):
    out = Path(out)
    failures, passes = [], 0

    def expect(ok, what):
        nonlocal passes
        if ok:
            passes += 1
            print(f"PASS {what}")
        else:
            failures.append(what)
            print(f"FAIL {what}")

    reports = {}
    for role in ["ai", "owner", "member", "owner2"]:
        p = out / f"{role}.json"
        r = json.loads(p.read_text()) if p.exists() else {"steps": [], "done": False}
        reports[role] = r
        expect(r.get("done") is True, f"{role}: finished")
        for s in r.get("steps", []):
            expect(s["ok"], f"{role}: {s['name']} {s.get('detail', '')[:160]}")
        if r.get("lastError"):
            print(f"  {role} last error: {r['lastError'][:300]}")

    # The AI's use, as the backend counted it for the anonymous account
    anon = reports["ai"].get("anonymousUid")
    if anon:
        usage = call(f"{FS}/usage/{anon}", owner=True)
        fields = {k: value(x) for k, x in usage.get("fields", {}).items()}
        q = fields.get("quickAdd", {}) or {}
        expect(q.get("count") == 3, f"backend counted 3 quick adds (typed, receipt note, follow-up): {q.get('count')}")
        rc = fields.get("receipt", {}) or {}
        expect(rc.get("count") == 1, f"backend counted 1 receipt photo: {rc.get('count')}")
        expect(not (q.get("held") or {}), "no quick add left held")
        days = docs(f"usage_history/{anon}/days")
        expect(len(days) >= 1, f"usage history recorded ({len(days)} day)")

    # Sync: Firestore holds what the phones made, deleted and changed
    uid = reports["owner"].get("uid")
    if uid:
        lists = docs(f"users/{uid}/shopping_lists")
        items = docs(f"users/{uid}/shopping_items")
        stores = docs(f"users/{uid}/stores")
        list_uid = reports["owner"].get("listUid")
        expect(list_uid in lists, f"list {list_uid} is in users/{uid}/shopping_lists")
        if list_uid in lists:
            l = lists[list_uid]
            expect(l.get("name") == "Shared from iPhone A", f"list name: {l.get('name')}")
            expect(l.get("storeId") in stores and stores[l["storeId"]].get("name") == "Supermarket", "list's store travels as the store's uid")
            expect(set(l.get("_t", {}).keys()) >= {"name", "createdDate", "isCompleted"}, f"change times kept per field: {sorted(l.get('_t', {}).keys())}")
            expect(l.get("_deleted") is False, "list not deleted")
        by_name = {}
        for k, d in items.items():
            by_name.setdefault(d.get("itemName"), []).append((k, d))
        expect(len(by_name.get("From the other phone", [])) == 1, "the other phone's item reached the account once")
        eggs = by_name.get("Eggs", [])
        expect(len(eggs) == 1 and eggs[0][1].get("_deleted") is True, "Eggs is marked deleted")
        bread = by_name.get("Bread", [])
        if bread:
            b = bread[0][1]
            expect(b.get("purchased") == 1, f"Bread ticked by one phone: {b.get('purchased')}")
            expect(b.get("actualPrice") == 1.1, f"Bread's price changed by the other: {b.get('actualPrice')}")
            expect(b.get("_t", {}).get("purchased") != b.get("_t", {}).get("actualPrice"), "the two edits have their own times")
        else:
            expect(False, "Bread is in the account")
        expect(all(d.get("listId") == list_uid for _, d in sum(by_name.values(), []) if d.get("itemName") in ("Milk", "Bread", "Eggs")),
               "items point at the list's uid")
        settings = docs(f"users/{uid}/app_settings")
        expect("settings" in settings or len(settings) <= 1, f"settings row id: {list(settings.keys())}")

    print(f"\n{passes} passed, {len(failures)} failed")
    for f in failures:
        print(f"  - {f}")
    return 1 if failures else 0


if __name__ == "__main__":
    if sys.argv[1] == "prepare":
        prepare()
    else:
        sys.exit(check(sys.argv[2]))
