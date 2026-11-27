# Guarding normalizeInlineLinkHref with "no whitespace" is out of scope

- Decided: 2026-11-23 · by devil (osionos #240 S1)
- Holds while: `normalizeInlineLinkHref` adds `https://` to schemeless hrefs that contain spaces or tabs after `/`, `?` or `#`

## The concept

Fix the ReDoS at markdown-engine `inlineLinks.ts:29` by testing `!/\s/.test(cleanHref)` before the schemeless-domain regex.

## Why not

- It is linear, but it changes answers. `example.com/my page`, `google.com/search?q=hello world`, `example.com?q=a b`, `example.com#a b` and `example.com/a<TAB>b` get `https://` today and resolve to working URLs (the browser percent-encodes them). With the guard they become same-origin relative links. Measured in `scratch/md240/devil-s1/run1.jsonl`, q:2.
- An exact linear scan exists and matches the regex on 5,257,437 of 5,257,437 strings.

## Prior requests

- 2026-11-23 (#240 security review S1): proposed as the smallest fix.

## Reopen when

The product decides that spaced schemeless hrefs should not auto-link, or `normalizeInlineLinkHref` stops prefixing them for another reason.
