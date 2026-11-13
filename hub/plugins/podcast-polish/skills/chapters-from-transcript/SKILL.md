---
name: chapters-from-transcript
description: Add chapter markers to a long video or podcast from what is said in it, and give the user a YouTube-ready chapter list. Use when the user asks for chapters, timestamps or show notes.
---

# Chapters from the transcript

## 1. Read all of it

`get_transcript` for the speech clip, page after page until `nextWord` is absent. Do not write chapters from the
first page of a two-hour recording.

## 2. Choose the chapters

- One chapter where the subject changes, not where a speaker changes.
- 5 to 12 chapters for an hour; none shorter than 10 seconds (YouTube refuses shorter ones); at least three.
- The first chapter starts at 0:00.
- A title is 2 to 6 words that say what is covered ("Why the first cut is too long"), not "Part 2" or
  "Introduction" for anything except the opening.

## 3. Put them on the timeline

1. `inspect_timeline` for markers that are already there; do not add a second marker at the same time.
2. `add_marker` for each chapter, at the start of its first sentence, named with the title.
3. `export_chapters` returns the list as YouTube reads it. Paste it in your reply inside a code block.

## 4. Show notes, when asked

Under the chapter list, three to five lines: who speaks, the main points in the order they come, and any name,
book or link said out loud, with its time. Only what is in the transcript; do not add facts from elsewhere.
