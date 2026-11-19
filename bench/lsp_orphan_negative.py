#!/usr/bin/env python3
"""Prove the LSP orphan gate rejects a worker that was not killed."""

import os

import lsp_session as gate

original_kill = os.kill
victims = []
original_step = gate.step


def skip_first_kill(pid, sig):
    victims.append((pid, sig))
    os.kill = original_kill
    print("negative control: deliberately left the held worker alive", flush=True)


def check_step(label, name, ok, detail=""):
    if label == "73j":
        if not victims or ok or "no answer" not in detail:
            raise RuntimeError(f"the orphan gate did not reject the skipped kill: {detail}")
        print(f"negative control: step {label} rejected the skipped kill: {detail}", flush=True)
        raise SystemExit(0)
    original_step(label, name, ok, detail)


try:
    os.kill = skip_first_kill
    gate.step = check_step
    gate.orphan_steps()
    if not victims:
        raise RuntimeError("the held worker was never reached")
finally:
    os.kill = original_kill
    gate.step = original_step
    for pid, sig in victims:
        try:
            original_kill(pid, sig)
        except OSError:
            pass
