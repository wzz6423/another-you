# Export conversations and usage

**English** | [简体中文](exporting.zh-CN.md)

Open a conversation and choose **Export conversation** to save a UTF-8 Markdown file. Export becomes available after its full history has loaded and the current request has finished. The native save dialog lets you choose the destination; cancellation does not create a file.

The file includes the stored conversation ID, title, state, timestamps, linked application, fork origin when available, all loaded messages in order, errors, available snapshot metadata, and retained activity events with an explicit matching conversation or request ID. Original text is preserved inside fenced blocks. Snapshot image data, accessibility trees, raw model reasoning and account configuration are excluded. Content no longer retained by the app cannot be recovered by exporting. Metadata field names are stable English identifiers; message content keeps its original language.

On **Today → Usage overview**, choose **24h / 7d / 15d / 30d**, then **Export usage**. The UTF-8 CSV uses the same records and reference time as the displayed overview, including both range endpoints. The save dialog does not change this captured snapshot.

CSV rows share one header. `row_type` distinguishes `summary`, `model`, `reasoning`, `tool`, `request`, and `tool_call`. Summary and model rows contain request counts, reported/unreported counts, failed request counts and reported token totals. Reasoning rows count requests; tool rows count calls. Request rows preserve the usage record ID, timestamp, source, model, outcome, reasoning effort and reported token fields. Tool-call rows refer to that record using `record_id`; this is a usage record ID, not a conversation request ID. Do not sum summary and detail rows together.

Unreported token cells are blank, including totals when no request reported usage. An explicitly reported zero remains `0`. `usage_status` is `reported`, `unreported`, `partial`, or `no_requests`. Empty periods still export their range and zero request counts. All cells are quoted; embedded quotes and line breaks follow CSV escaping. Text that could be interpreted as a spreadsheet formula receives a leading apostrophe. Timestamps use ISO 8601 UTC.

Both exports are generated locally and written only to the location selected in the save dialog. They can contain private messages, errors and application names; review their contents before sharing.
