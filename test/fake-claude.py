#!/usr/bin/env python3
"""Offline stand-in for `claude -p --input-format stream-json`.

Prompt "perm..." asks tool permission first; "slow..." waits two seconds.
Like the real CLI it queues prompts that arrive while busy, reports their
lifecycle by uuid, and honours cancel_async_message.
"""
import json
import queue
import sys
import threading
import time

lock = threading.Lock()
waiting = []                 # queued user messages
arrived = threading.Condition(lock)
answers = queue.Queue()      # control responses from the client


def out(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def lifecycle(msg, state):
    out({"type": "command_lifecycle", "command_uuid": msg.get("uuid"),
         "state": state})


def success(request_id, response):
    out({"type": "control_response",
         "response": {"subtype": "success", "request_id": request_id,
                      "response": response}})


def text_of(content):
    if isinstance(content, str):
        return content
    return "".join(b.get("text", "") for b in content if b["type"] == "text")


def work():
    while True:
        with arrived:
            while not waiting:
                arrived.wait()
            msg = waiting.pop(0)
            lifecycle(msg, "started")
            out({**msg, "isReplay": True, "parent_tool_use_id": None})
        content = msg["message"]["content"]
        text = text_of(content)
        images = 0 if isinstance(content, str) else sum(
            b["type"] == "image" for b in content)
        if text.startswith("perm"):
            with lock:
                out({"type": "control_request", "request_id": "p1",
                     "request": {"subtype": "can_use_tool", "tool_name": "Bash",
                                 "input": {"command": "true"},
                                 "tool_use_id": "t1"}})
            answer = answers.get()
            reply = "perm:" + answer["response"]["response"]["behavior"]
        else:
            if text.startswith("slow"):
                time.sleep(2)
            reply = "echo:" + text + (" +%d image" % images if images else "")
        with lock:
            out({"type": "assistant", "parent_tool_use_id": None,
                 "message": {"role": "assistant",
                             "content": [{"type": "text", "text": reply}]}})
            out({"type": "result", "subtype": "success", "is_error": False,
                 "result": reply})
            lifecycle(msg, "completed")


threading.Thread(target=work, daemon=True).start()
for line in sys.stdin:
    msg = json.loads(line)
    with arrived:
        if msg["type"] == "control_response":
            out(msg)  # the real CLI echoes answers too
            answers.put(msg)
        elif msg["type"] == "user":
            waiting.append(msg)
            lifecycle(msg, "queued")
            arrived.notify()
        elif msg["request"]["subtype"] == "initialize":
            success(msg["request_id"],
                    {"commands": [{"name": "compact", "description": "Compact"}],
                     "models": [{"value": "default", "description": "Fake"}]})
        elif msg["request"]["subtype"] == "cancel_async_message":
            found = [m for m in waiting if m.get("uuid") == msg["request"]["message_uuid"]]
            for m in found:
                waiting.remove(m)
                lifecycle(m, "cancelled")
            success(msg["request_id"], {"cancelled": bool(found)})
        else:
            success(msg["request_id"], {})
