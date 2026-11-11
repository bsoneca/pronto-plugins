"""A stand-in for flagd's OFREP answer (live.nu's FLAGS_OFREP_CMD), reading the live object of the fake
gcloud (FAKE_GCLOUD_STATE) and evaluating its targeting for the context given in the environment
(FLAG, TARGETING_KEY; empty is no context). FAKE_OFREP_STALE=1 answers from the version before the live one,
as a flagd that has not read the new object yet."""
import json, os

state = json.load(open(os.environ["FAKE_GCLOUD_STATE"]))
versions = state["objects"]["gs://shop-prod-flags/flags.json"]
live = [v for v in versions if v["timeDeleted"] is None][0]
if os.environ.get("FAKE_OFREP_STALE"):
    older = sorted((v for v in versions if v["timeDeleted"] is not None), key=lambda v: int(v["generation"]), reverse=True)
    live = older[0] if older else live
flag = json.loads(live["data"])["flags"].get(os.environ["FLAG"], {"variants": {"default": None}, "defaultVariant": "default"})
ctx = {"targetingKey": os.environ.get("TARGETING_KEY") or None}


def ev(r):
    if not isinstance(r, dict):
        return r
    if "var" in r:
        return ctx.get(r["var"])
    if "in" in r:
        needle, hay = (ev(x) for x in r["in"])
        return needle is not None and needle in hay
    args = r["if"]
    for i in range(0, len(args) - 1, 2):
        if ev(args[i]):
            return ev(args[i + 1])
    return ev(args[-1]) if len(args) % 2 else None


name = ev(flag.get("targeting")) or flag["defaultVariant"]
print(json.dumps({"value": flag["variants"][name], "variant": name}))
