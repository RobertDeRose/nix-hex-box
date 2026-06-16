#!/usr/bin/env python3
import json
import sys

PLAN_PATH = "/tmp/lix-plan.json"

try:
    with open(PLAN_PATH, "r", encoding="utf-8") as plan_file:
        plan = json.load(plan_file)
except (OSError, json.JSONDecodeError) as error:
    print(f"ERROR: failed to read {PLAN_PATH}: {error}", file=sys.stderr)
    sys.exit(1)

modified = False
for step in plan.get("actions", []):
    action = step.get("action", {})
    if action.get("action_name") != "configure_nix":
        continue

    setup_default_profile = action.get("setup_default_profile")
    if setup_default_profile is None:
        continue

    setup_default_profile["state"] = "Completed"
    modified = True

if not modified:
    print(
        "ERROR: configure_nix.setup_default_profile not found in Lix install plan",
        file=sys.stderr,
    )
    sys.exit(1)

try:
    with open(PLAN_PATH, "w", encoding="utf-8") as plan_file:
        json.dump(plan, plan_file, indent=2)
        plan_file.write("\n")
except OSError as error:
    print(f"ERROR: failed to write {PLAN_PATH}: {error}", file=sys.stderr)
    sys.exit(1)
