#!/usr/bin/env python3
"""Opt-in, local metadata probe. Never makes approval or continuation decisions."""
import argparse
import json
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path

EVENTS = {"SessionStart", "UserPromptSubmit", "PermissionRequest", "PostToolUse", "Stop", "Interrupt", "SessionEnd", "Notification"}
FIELDS = ("session_id", "turn_id", "hook_event_name", "tool_name", "notification_type")


def sanitize(payload, source):
    if not isinstance(payload, dict) or payload.get("hook_event_name") not in EVENTS:
        return None
    event = {"schema": 1, "source": source, "observed_at": datetime.now(timezone.utc).isoformat()}
    for field in FIELDS:
        value = payload.get(field)
        if isinstance(value, str):
            event[field] = value[:200]
    # Deliberately exclude prompts, messages, tool arguments, outputs, tokens and cwd.
    return event


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", choices=("Codex", "Claude"), required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        raw = sys.stdin.read(4_194_305)
        if len(raw) <= 4_194_304:
            event = sanitize(json.loads(raw), args.source)
            if event:
                args.output.mkdir(parents=True, exist_ok=True, mode=0o700)
                target = args.output / (uuid.uuid4().hex + ".json")
                with target.open("x", encoding="utf-8") as stream:
                    json.dump(event, stream, ensure_ascii=False)
                target.chmod(0o600)
    except (ValueError, OSError):
        pass
    # Empty JSON is an observer response, without allow/deny/block/continue fields.
    print("{}")


if __name__ == "__main__":
    main()
