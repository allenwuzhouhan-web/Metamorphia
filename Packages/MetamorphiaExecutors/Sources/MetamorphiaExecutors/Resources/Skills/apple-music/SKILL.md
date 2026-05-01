---
name: apple-music
description: Control Music.app playback (play/pause/next/previous), search and queue songs, adjust volume. Use when the user says "play X", "pause the music", "skip this song".
---

# Apple Music

Music.app has the fullest AppleScript dictionary on macOS. Drive it via `run_applescript`.

## Transport

```applescript
tell application "Music" to play
tell application "Music" to pause
tell application "Music" to playpause   -- toggle
tell application "Music" to next track
tell application "Music" to previous track
```

## Play a specific song

```applescript
tell application "Music"
  set matches to (every track whose name contains "Clair de Lune")
  if (count of matches) > 0 then
    play (item 1 of matches)
  else
    return "No match"
  end if
end tell
```

For artist + title, chain: `whose name is "X" and artist is "Y"`.

## Now playing

```applescript
tell application "Music"
  if player state is playing then
    return (name of current track) & " — " & (artist of current track)
  else
    return "not playing"
  end if
end tell
```

## Volume

App-level (0–100): `tell application "Music" to set sound volume to 50`

System-wide (0–100): `set volume output volume 50`

## Playlists

- List: `tell application "Music" to get name of every playlist`
- Play one: `tell application "Music" to play playlist "Chill"`
- Create: `tell application "Music" to make new playlist with properties {name:"NewMix"}`

## Shuffle & repeat

```applescript
tell application "Music"
  set shuffle enabled to true
  set song repeat to all    -- or `one`, `off`
end tell
```

## Gotchas

- Apple Music streaming tracks are visible in the library once added; pure search-and-play from the streaming catalog isn't scriptable — you need the track in the library first.
- If Music.app is quit, AppleScript will launch it (brief delay).
- On macOS with no iTunes Match / Apple Music subscription, only local tracks are available.
