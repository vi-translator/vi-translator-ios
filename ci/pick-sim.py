"""The newest iOS runtime's first available simulator whose name starts with argv[1] ("iPhone",
"iPad"), leaving out the small ones (SE, mini): its UDID."""
import json
import re
import subprocess
import sys

want = sys.argv[1] if len(sys.argv) > 1 else "iPhone"
d = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))["devices"]


def ver(k):
    m = re.search(r"iOS-(\d+)-(\d+)", k)
    return (int(m.group(1)), int(m.group(2))) if m else (0, 0)


for k in sorted((k for k in d if "iOS" in k), key=ver, reverse=True):
    for dev in d[k]:
        n = dev["name"]
        if n.startswith(want) and "SE" not in n and "mini" not in n:
            print(dev["udid"])
            sys.exit(0)
sys.exit(1)
