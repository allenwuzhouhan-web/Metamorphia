---
name: create-podcast
description: Generate an audio podcast from a script or article. Currently a stub — the underlying generation tool is not yet installed.
emoji: waveform
os: macOS
requirements: GenerateAudioTool (not yet implemented)
status: stub
---

# Create Podcast — coming soon

This skill is a **placeholder**. Native podcast/audio generation isn't wired into Metamorphia yet.

## What's missing

A `generate_audio` tool — an executor that can take a script and emit a `.m4a` or `.mp3`. The likely components when this lands:

- A high-quality text-to-speech path (the macOS `say` command works but sounds robotic; a real podcast needs neural TTS — e.g., an `ElevenLabs` or `OpenAI tts-1-hd` API binding)
- Multi-voice support so two-host shows are possible
- Music-bed mixing via `ffmpeg`
- Show-notes generation (could compose with `summarize-document`)

## What to do today

If the user asked to create a podcast, tell them this skill is a stub and offer one of:

1. **Generate just the script** as text or a `create-word` document — they can record it themselves later.
2. **Quick-and-dirty TTS** via `say -v Samantha -o /tmp/draft.aiff "<script text>"` if the user is okay with the built-in macOS voice as a draft.
3. **Wait** until the real `generate_audio` tool ships. The Metamorphia maintainer specifically asked to be reminded to build this tool.

## Don't pretend

Do not synthesize a fake audio file path. Do not claim to have produced a podcast when all you did was write a script. The honest "this skill is a stub" answer is what the user wants — it surfaces the gap so the underlying tool can be built.
