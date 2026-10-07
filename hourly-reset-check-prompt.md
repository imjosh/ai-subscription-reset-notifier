Check hourly for newly announced usage-limit resets for Claude and OpenAI Codex
Use these sources:
- For Codex, use https://codex-reset.com/ as the primary source.
- For Claude, use https://claude-resets.com/ as the primary source.
- Cross-check both with https://didreset.com/.
- Do not treat an unverified DidReset event as confirmation.
- For Codex, only treat an event as a reset when the source considers it a confirmed/announced reset, not merely a hint, tease, prediction, or possible reset.
- For Claude, distinguish regular resets from banked resets where possible.
If neither Claude nor Codex has a newly announced reset, do nothing.
If one or both services have announced a new reset:
1. Output a concise summary of what you found, including:
  - Which service announced the reset
  - Reset date/time
  - Reset type, such as regular or banked, if known
  - Scope, if known
  - Source used to confirm it
2. Visit exactly one of the following URLs based on which service or services announced resets:
If only Claude announced a reset:
https://tunnelName.example.com/notify?claude=true
If only Codex/OpenAI announced a reset:
https://tunnelName.example.com/notify?chatgpt=true
If both Claude and Codex/OpenAI announced resets:
https://tunnelName.example.com/notify?claude=true&chatgpt=true
Important rules:
- claude=true means Claude announced a reset.
- chatgpt=true means OpenAI Codex announced a reset.
- Only visit the notification URL when a newly confirmed reset has been announced.
- Do not notify for rumors, predictions, hints, or unverified events.
- Do not send the same notification repeatedly for the same reset. Track previously observed reset IDs or timestamps and only act on a reset that is newer than the last one already processed.
- If both services announced new resets during the same check, make one request using both query parameters rather than two separate requests.
If the notify endpoint is unreachable or does not return 200 OK, retry every hour until it returns 200 OK, for up to 15 hours. After 15 retry attempts, do not attempt redelivery again for that reset announcement.