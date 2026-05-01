---
name: deep-research
description: Multi-source research workflow — search the web, fetch and read primary sources, cross-reference, synthesize a report with citations. Use when the user says "deep research", "thoroughly investigate", "find everything about", or wants a written report rather than a quick answer.
emoji: magnifyingglass
os: macOS
requirements: search_web, fetch_url_content
---

# Deep Research

A search → fetch → read → cross-reference → synthesize loop. Produce a written report with citations, not a chat answer. Reach for this skill whenever the user wants depth over speed.

## Workflow

1. **Decompose the question.** Break the user's prompt into 3–6 sub-questions. State them back so the user can correct course before you spend 2 minutes searching.
2. **Search broadly.** Call `search_web` once per sub-question. Save the top 3–5 result URLs per query. Keep a running list of `(claim, source_url)` pairs.
3. **Fetch primary sources.** For each promising URL, call `fetch_url_content`. Skip aggregator pages (Reddit threads, Twitter, low-trust SEO blogs) unless the user explicitly wants vibes; prefer official docs, peer-reviewed papers, government / standards bodies, vendor announcements, and the original reporting source for news.
4. **Read and quote.** Pull direct quotes for any claim that's surprising, numerical, or contested. Plain paraphrasing without a quote is how you hallucinate.
5. **Cross-reference.** When two sources agree, mark the claim as confident. When they disagree, surface the disagreement instead of picking a winner — the user can decide.
6. **Synthesize.** Write the report at the length the user asked for (default: 600–1200 words). Open with a 2-sentence verdict, then sections with H2 headers, then a "Sources" footer.

## Output format

```
## Verdict
<two sentences>

## <Section 1>
<paragraph with inline [1] citations>

## Sources
[1] <Title> — <site>, <date>, <URL>
[2] ...
```

Keep citations dense — every non-obvious claim should trace back to a numbered source. If a claim has no source, flag it as inference.

## Stop conditions

- Stop after ~10 fetches unless the user explicitly asked for exhaustive coverage. Diminishing returns kick in fast and you'll burn the user's API budget.
- Stop early if your first 3 sources fully answer the question.
- Stop and ask if the user's question turns out to be ambiguous or has changed since they asked (e.g., "best Mac in 2024" — confirm whether they want current or historical).

## Composing with other skills

- Pair with `summarize-document` if the user already has the source files and just wants synthesis.
- Pair with `create-word` or `pptx` if they want the report delivered in a document or slide deck, not chat.
- Pair with `orchestrate` when sub-questions are large enough to fan out as parallel sub-agents.

## Gotchas

- Paywalled articles: `fetch_url_content` will return a stub. Note that in the report instead of inventing the body.
- News from the last 24h: search results may not have indexed yet. Re-query with the specific publication if you suspect a story is too fresh.
- For numerical claims (market share, performance benchmarks), always quote the source — numbers age fast and "X% according to Y in 2023" beats "X%" alone.
