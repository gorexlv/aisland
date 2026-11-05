# Live Summary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Add an explicit Live switch that reveals a Summary tab next to Chat and keeps a sourced summary and local memory current.

**Architecture:** A separate observable summary controller owns debounce, bounded refresh, cancellation, source snapshots and generation checks. ReviewModel supplies canonical numbered opinions plus nonduplicate chat messages and persists accepted results through ReviewStore. The existing Codex analysis runner performs structured extraction; no automatic actions are executed.

**Tech Stack:** Swift, SwiftUI, Combine, Codable, existing read-only Codex runner.

## Tasks

- [x] Define structured sources, overview, decisions, todos and open questions with validated source references. Keep confirmed/proposed and task statuses explicit.
- [x] Implement Live controller: 2-second debounce / 8-second maximum wait, single request at a time, reschedule changed input, cancel on disable/close/target change, preserve accepted results on errors.
- [x] Wire canonical review/chat changes, optional session fields and memory.json/memory.md snapshots. Save through the existing actor and prevent writes from closed sessions.
- [x] Add Live switch, conditional Chat/Summary tabs and readable grouped summary. Preserve chat draft and existing composer when switching tabs.
- [x] Add offline fixtures for toggling, debounce, single-flight, late results, invalid references, persistence and native tabs. Use no real AI service or microphone.
- [x] Run focused regressions and independent review. Do not build or install an application package for this task.

## Behavioral decisions

Live is opt-in per review session. Turning it off returns to Chat, stops future requests and retains the latest accepted summary. Existing manual AI cleanup remains available. Confirmed decisions and explicit todos appear in local memory with provenance; proposed content remains marked as tentative. No other agent memory backend exists in this project, so memory is scoped to the current review directory rather than claiming an external memory integration.
