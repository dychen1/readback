---
name: readback
description: Use when the user invokes readback, asks to hear the latest visible agent answer, or wants an agent reply adapted and played through the local ReadBack app.
---

# ReadBack

Turn the immediately preceding visible assistant answer into a complete spoken brief, then play it through ReadBack. Send only the adapted brief to the local service.

Use a fast, lower-tier model with thinking disabled for the spoken adaptation when the host supports it. Otherwise, use the current active model.

## Select the source

- Use the latest visible assistant final answer before this invocation.
- Exclude hidden reasoning, system or developer text, tool calls, tool output, credentials, and secrets.
- If no prior visible answer exists, state that there is nothing to read and stop.

## Write for listening

Create the brief in this order:

1. Lead with the result or conclusion.
2. Preview the main points when there are several.
3. Explain them in causal or procedural order with short sentences and one main idea per sentence.
4. Use explicit transitions such as "First," "Next," "The main risk is," and "The final step is."
5. Put a blank line between logical sections.

Use active voice, familiar words, and a conversational tone. Expand an abbreviation on first use when its spoken form may be unclear.

Preserve every conclusion, fact, figure, date, name, requirement, constraint, decision, warning, uncertainty, failure, dependency, and next action. Keep the source's urgency and confidence. Do not invent facts or resolve uncertainty.

For code, logs, tables, paths, and URLs, state their purpose, key values, exact result, and any error. Say that the exact artifact remains on screen. Read an exact literal only when the listener needs it for the next action.

Remove Markdown marks, raw citation syntax, repeated headings, visual layout cues, and duplicate prose. Expand abbreviations or symbols when that improves pronunciation. Do not impose a length limit that drops facts.

## Play the brief

Send only the adapted brief, never the original answer. Use the first channel in this list that the host supports:

1. ReadBack MCP tool, preferred. If a `play` tool from the `readback` MCP server is available, call it with the brief as `text`. An example name is `mcp__readback__play`. The tool returns when playback starts. Reply only with "Reading it aloud."
2. Standard input. Use this channel if the host gives subprocesses an interactive standard-input channel. Send the brief through it to the client below, with no arguments. After the client exits, reply only with "Read-back complete."
3. File handoff, discouraged. Use this channel only if the host can run nothing but command strings:
   1. Resolve `$TMPDIR` to an absolute path. Only the user can read it.
   2. Use the host's file-writing tool, not a shell command, to write the brief to `<TMPDIR>/readback-brief-<random>.txt`. Write the file one time. Do not rewrite it or append to it.
   3. Run the client with standard input redirected from that file. The command string contains only the path, never the brief.
   4. Delete the file, even if the client failed.
   5. Reply "Read-back complete."
   6. Tell the user one time that read-back is faster with the ReadBack MCP server. They connect it in ReadBack Settings, under Agent Read-Back.

```text
$HOME/Library/Application Support/ReadBack/Skills/readback/scripts/readback-skill-client
```

If the host has none of these channels, state that read-back is unavailable in this host and stop.

Never put the brief in a shell command string. Text in the brief can match a here-document delimiter or break out of quotes. Do not use the clipboard, an environment variable, a model option, a voice option, a speed option, or an endpoint option.

On failure, give the shortest actionable fix without repeating the brief.

## Example

Written answer: "**Result:** 27 tests passed. `Sources/App.swift` now retries twice. Warning: the API key is missing. Run the shown command next."

Spoken brief: "The change is working, and all 27 tests passed. The app now retries failed work twice. The exact code and file path remain on screen. The main warning is that the API key is missing. Next, run the command shown in the answer."
