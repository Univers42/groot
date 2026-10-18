# Lifting WAF checks on json.text of /email/v1/send is out of scope

- Decided: 2026-10-17 · by devil (ruling on grobase 09aa55d2, rule 10150)
- Holds while: no real gateway mail's text part has drawn a WAF hit

## The concept

Rule 10150 also removes the XSS family and 921130 from ARGS:json.text, the plain-text part of the account mail.
The reasoning was symmetry with json.html, and the idea that a text part might one day hold `<` or `HTTP/1.1`.

## Why not

- The audit of the refused verification mail showed four hits, all on ARGS:json.html, and nothing on json.text
  (b2b WAF log 2026-10-17; commit 09aa55d2 message).
- m227 has no positive probe or line mutant that needs the json.text lines. They lift inspection without proving
  they do anything (`scripts/verify/m227-waf-app-content.sh`, the `line_mutant` calls).
- What would change the answer: a real rendered gateway message (`mail-templates.mjs` MESSAGES) whose text part
  scores against a lifted rule. The m227 fixture run with all four messages would show it as a 403 on a
  `content-email-*` probe.

## Prior requests

- 2026-10-17 (builder, 09aa55d2): bundled with the json.html lift.

## Reopen when

A `content-email-*` probe built from a real template is refused, and the audit names ARGS:json.text. Then lift only
the rule that hit, and add its line mutant.
