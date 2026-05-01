---
name: summarize-url
description: Fetch a web page or YouTube video and produce a summary. Use when the user says "what's this link about", "summarize this article", "tl;dr of this URL".
---

# Summarize URL

Metamorphia already has `fetch_url_content` (text extraction) and `search_web`. Summarization is a read → condense workflow, not a separate tool.

## Workflow

1. Call `fetch_url_content` with the URL
2. Read the returned text
3. Produce a summary at the length the user asked for (default: 3–5 bullets + one takeaway)

## Choosing length

Match the user's ask:
- "one-liner" / "tl;dr" → 1 sentence
- "quick summary" → 3–5 bullets
- "detailed" → 8–12 bullets with section headers
- "extract all key facts" → bulleted list with no commentary

## Paywalled or JS-heavy pages

If `fetch_url_content` returns little content or looks like a cookie wall:
1. Try appending the URL to an archive service the user has access to
2. Fall back to driving Safari/Chrome (see `browser-automation`): open the page, wait, use `execute javascript` in Chrome to pull `document.body.innerText`
3. If still blocked, say so — don't hallucinate a summary

## YouTube

`fetch_url_content` on a YouTube URL returns metadata (title, description) but not the transcript. Options:
- Ask the user to paste the transcript from YouTube's built-in transcript panel
- If `yt-dlp` is installed locally: `run_shell_command "yt-dlp --write-auto-subs --skip-download -o '/tmp/yt.%(ext)s' <URL>"` then read the `.vtt` file
- If neither works, summarize from the description + title and say so

## PDF URLs

`fetch_url_content` handles PDFs if the server returns `Content-Type: application/pdf`. For PDFs already downloaded locally, use `run_shell_command` with `pdftotext` (from `poppler`) or `mdls -name kMDItemTextContent`.

## Citations

When summarizing, include:
- A one-line attribution (site + author if known)
- Any dates mentioned (publication date matters for news/technical content)
- Direct-quote any claim the user might want to verify, using "quotation marks" and noting roughly where in the article it appears

## Gotchas

- Don't summarize a page you couldn't actually fetch. If `fetch_url_content` errored, say so.
- Long articles may exceed the model's input window — for > ~50KB of text, summarize in passes: split into sections, summarize each, then summarize the summaries.
