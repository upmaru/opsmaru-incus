"""Verify portable API constants against unchanged pinned Incus exports.

--write explicitly regenerates the fixture-only Go oracle and portable data.
No backend, credentials, host command adapter or runtime state is involved.
"""
import argparse
import json
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--write", action="store_true")
args = parser.parse_args()
inventory = json.loads((root / "priv/incus/inventory.json").read_text())
names = sorted(entry["name"] for entry in inventory["entries"]
               if entry["package"] == "shared/api" and entry["kind"] == "const")
source = '''// Generated pinned-native constant oracle. Regenerate with scripts/check-incus-constants.py --write.
// Imports unchanged Incus v7.0.1; fixture-only, no connections or host tools.
package main

import (
 "encoding/json"
 "os"
 "github.com/lxc/incus/v7/shared/api"
)

func main() {
 values := map[string]any{
''' + "".join(f"  {json.dumps(name)}: api.{name},\n" for name in names) + ''' }
 if err := json.NewEncoder(os.Stdout).Encode(values); err != nil { panic(err) }
}
'''
formatted = subprocess.run(["mise", "exec", "--", "gofmt"], input=source, text=True,
                           capture_output=True, check=True, cwd=root).stdout
driver = root / "test/reference/constants/main.go"
if args.write:
    driver.parent.mkdir(exist_ok=True)
    driver.write_text(formatted)
else:
    assert driver.read_text() == formatted, "Native constant oracle declarations changed"
native = subprocess.run(["mise", "exec", "--", "go", "run", "./constants"],
                        cwd=root / "test/reference", capture_output=True, text=True,
                        check=True, env=None)
values = json.loads(native.stdout)
assert sorted(values) == names, "Native constant inventory changed"
assert all(type(value) in [str, int, bool] for value in values.values())
expected = {"reference_revision": inventory["reference"]["revision"], "values": values}
output = root / "priv/incus/constants.json"
if args.write:
    output.write_text(json.dumps(expected, indent=2, sort_keys=True) + "\n")
else:
    assert json.loads(output.read_text()) == expected, "Native constant values changed"
print(f"{len(values)} native API constants verified; no protocol/feature activation implied")
