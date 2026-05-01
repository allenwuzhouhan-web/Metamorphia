---
name: create-video
description: Generate a video file from a script, image sequence, or screen recording. Currently a stub — the underlying generation tool is not yet installed.
emoji: video
os: macOS
requirements: GenerateVideoTool (not yet implemented)
status: stub
---

# Create Video — coming soon

This skill is a **placeholder**. Native video generation isn't wired into Metamorphia yet.

## What's missing

A `generate_video` tool — an executor that can take a script, image sequence, or recorded source and emit a `.mp4`. The likely components when this lands:

- `AVFoundation` for stitching image sequences into a video track
- `ffmpeg` (via `run_shell_command`) for transcoding and concat
- A text-to-speech path (macOS `say` command) for narration
- A QuickTime / Keynote-export path for "video from a deck" flows

## What to do today

If the user asked to create a video, tell them this skill is a stub and offer one of:

1. **Make a deck instead** (`pptx`) and export it as video manually from PowerPoint or Keynote. Metamorphia can build the slides; the user does the export click.
2. **Screen recording** via `screencapture -v -V <seconds> /path/out.mov` if the user really wants a screen capture rather than authored video.
3. **Wait** until the real `generate_video` tool ships. The user has been notified that this is on the list.

## Don't pretend

Do not synthesize a fake video file path. Do not claim to have generated a video when you stitched together AppleScript steps. Be explicit that the skill is a stub — the Metamorphia maintainer specifically asked to be reminded to build this tool, so an honest "not yet" surfaces the gap rather than papering over it.
