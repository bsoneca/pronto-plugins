"""A stand-in for the few gcloud commands flags/live.nu runs, keeping buckets and
object versions in a JSON file (FAKE_GCLOUD_STATE), as Cloud Storage keeps them:
each write a new generation, the one before it noncurrent, a write refused when
--if-generation-match is not the live generation. Run by fake_mise.sh."""
import json, os, sys, time

STATE = os.environ["FAKE_GCLOUD_STATE"]
state = json.load(open(STATE)) if os.path.exists(STATE) else {"buckets": {}, "objects": {}, "next": 1000}
save = lambda: json.dump(state, open(STATE, "w"), indent=1)
args = [a for a in sys.argv[1:] if a != "--quiet"]


def fail(msg):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def opt(name):
    for i, a in enumerate(args):
        if a.startswith(f"--{name}="):
            return a.split("=", 1)[1]
        if a == f"--{name}":
            return args[i + 1] if i + 1 < len(args) and not args[i + 1].startswith("--") else True
    return None


def versions(url):
    return state["objects"].setdefault(url, [])


def live(url):
    vs = [v for v in versions(url) if v["timeDeleted"] is None]
    return vs[0] if vs else None


def write(url, data, metadata):
    match = opt("if-generation-match")
    now = live(url)
    if match is not None and int(match) != (int(now["generation"]) if now else 0):
        fail(f"{url}: 412 Precondition Failed")
    stamp = time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime())
    if now:
        now["timeDeleted"] = stamp
    state["next"] += 1
    versions(url).insert(0, {"generation": str(state["next"]), "timeCreated": stamp, "timeDeleted": None, "data": data, "metadata": metadata})


a = args
if a[:3] == ["config", "get-value", "account"]:
    print("operator@example.com")
elif a[:3] == ["storage", "objects", "describe"]:
    url = a[3]
    v = live(url)
    if not v:
        fail(f"{url} not found: 404.")
    print(v["generation"])
elif a[:2] == ["storage", "cp"]:
    src, dst = a[2], a[3]
    if src.startswith("gs://"):
        url, _, gen = src.partition("#")
        found = [v for v in versions(url) if v["generation"] == gen]
        if not found:
            fail(f"{src} not found: 404.")
        data, metadata = found[0]["data"], found[0]["metadata"]
    else:
        data = open(src).read()
        custom = opt("custom-metadata")
        metadata = dict(kv.split("=", 1) for kv in custom.split(",")) if custom else {}
    bucket = dst[len("gs://"):].split("/")[0]
    if bucket not in state["buckets"]:
        fail(f"gs://{bucket} not found: 404.")
    write(dst, data, metadata)
elif a[:4] == ["storage", "ls", "-a", "--json"]:
    url = a[4]
    print(json.dumps([{"url": f"{url}#{v['generation']}", "type": "cloud_object", "metadata": dict(
        {"generation": v["generation"], "timeCreated": v["timeCreated"]},
        **({"timeDeleted": v["timeDeleted"]} if v["timeDeleted"] else {}),
        **({"metadata": v["metadata"]} if v["metadata"] else {}))} for v in versions(url)]))
elif a[:3] == ["storage", "buckets", "describe"]:
    name = a[3][len("gs://"):]
    if name not in state["buckets"]:
        fail(f"{a[3]} not found: 404.")
    print(json.dumps(state["buckets"][name]))
elif a[:3] == ["storage", "buckets", "create"]:
    state["buckets"][a[3][len("gs://"):]] = {"project": opt("project"), "location": opt("location"), "uniform": opt("uniform-bucket-level-access") is not None, "pap": opt("public-access-prevention") is not None, "versioning": False, "lifecycle": None, "readers": []}
elif a[:3] == ["storage", "buckets", "update"]:
    b = state["buckets"][a[3][len("gs://"):]]
    if opt("versioning"):
        b["versioning"] = True
    if opt("lifecycle-file"):
        b["lifecycle"] = json.load(open(opt("lifecycle-file")))
elif a[:3] == ["storage", "buckets", "add-iam-policy-binding"]:
    state["buckets"][a[3][len("gs://"):]]["readers"].append([opt("member"), opt("role")])
else:
    fail(f"the stand-in doesn't speak gcloud {' '.join(a)}")
save()
