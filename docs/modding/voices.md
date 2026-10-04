# Give units new voices

Every unit answers clicks and orders with a line from its voice set. Sets are plain JSON in
`data/sounds/voice_sets/`, and `data/sounds/voices.json` says which unit uses which set.
See [data/README.md](../../data/README.md#sounds) for every field.

## Record or generate lines

Any `.ogg` (or `.wav`) works. Keep clips short (under 2 s), mono, and around 22 kHz;
`ffmpeg -i in.wav -ac 1 -ar 22050 -c:a libvorbis -q:a 2 out.ogg` gives ~10 KB per line.

The base voices are made by `tools/audio/make_voices.py` from the script in
`tools/audio/voice_lines.json`: edit a line there and rerun it to change what units say (see
the top of the script for the free voice model it uses). Machine sounds (drone, automated
vehicles, buildings) are synthesized by the same script without any model.

## Give a unit its own voice in a mod

1. Put the clips in `mods/my_mod/audio/sergeant/`.
2. Add `mods/my_mod/data/sounds/voice_sets/sergeant.json`:

   ```json
   {
     "id": "sergeant",
     "kind": "speech",
     "folder": "res://mods/my_mod/audio/sergeant/",
     "lines": {
       "select": [{"file": "select_1.ogg", "text": "Sergeant here."}, {"file": "select_2.ogg"}, {"file": "select_3.ogg"}],
       "move": [{"file": "move_1.ogg"}, {"file": "move_2.ogg"}, {"file": "move_3.ogg"}]
     }
   }
   ```

   List every action from `unit_actions` in `voices.json` (`select`, `move`, `attack`,
   `retreat`, `build`, `cannot`, `under_attack`, `ready`), with at least three lines each for
   speech so replies do not repeat.
3. Point the unit at it, either with `"voice": "sergeant"` in its unit file or with
   `mods/my_mod/data/sounds/voices.json`: `{"unit_voices": {"militia": "sergeant"}}`.
4. Check it: `godot --headless --path . res://tests/audio/VoiceCheck.tscn` fails if any
   action has no sound or a file does not load.

To add lines to an existing set instead, give a set with the same `id` and only the actions
you change; your `folder` applies to your lines, the rest of the set stays as it is.
