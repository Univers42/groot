# 0012. WAF rule 10150 lifts the XSS checks on the HTML body of POST /email/v1/send, behind the service-only acl

- Status: accepted with conditions (W150-1 to W150-12; nothing merged or deployed yet)
- Date: 2026-10-17
- Deciders: devil (risk ruling of 2026-10-17). The user runs the b2b deploy.

## Context

- The b2b WAF log (2026-10-17, about 20:20 CEST) shows the site gateway's real verification mail scoring 20 and
  being refused by 949110. It is a POST to /email/v1/send with JSON {to, subject, html, text, listUnsubscribe}.
  Rules 921130, 941100, 941160 and 941260 all hit ARGS:json.html, and nothing hit json.text. A local replay
  names the argument `ARGS:json.html` (scratchpad audit.txt, ModSecurity v3.0.14, CRS 4.25.0).
- 10150 matches `REQUEST_FILENAME @streq /email/v1/send` and POST. It removes the attack-xss tag and 921130 from
  ARGS:json.html and ARGS:json.text (grobase 09aa55d2, `infra/docker/services/waf/conf/exclusions.conf:140-163`).
- emailsvc has no auth of its own (`src/control-plane/internal/orchestrator/emailsvc/emailsvc.go:20-24`). Kong
  is the only gate:
  - In the tree 10150 sits on (a42a8077), email-routes carry key-auth plus jwt anonymous and no acl
    (`infra/docker/services/kong/conf/kong.yml:825-853`), so the anon key reaches /send.
  - The acl `allow [baas-admin]` is commit bbe8995f on feat/titan-mail (`kong.yml:866-871`), and m206 proves it
    (`scripts/verify/m206-kong-admin-acl.sh:72`).
  - b2b runs that Kong config. Measured on 2026-10-17: anon gets 403 and service `{}` gets 400.
- Neither html nor text can reach a mail header:
  - The headers are written and terminated before the body, and the multipart boundary is 24 random hex
    (`emailsvc/message.go:39-63`).
  - The subject goes through `mime.QEncoding`. To must match `^[^\s@]+@[^\s@]+\.[^\s@]+$` (`handler.go:41`).
  - net/smtp `Data()` dot-stuffs the body (`smtpclient.go:156`).
- emailsvc never stores, echoes or previews the html. It answers `{messageId}` or a fixed error string, and it
  logs `to` and `messageId` only (`handler.go:57-82`).
- On a42a8077, emailsvc writes listUnsubscribe raw into a header with no CRLF check (`message.go:45-47`). The
  check (`handler.go:47-49`) and its test (`emailsvc_test.go:80-81`) exist only on feat/titan-mail.
- The gateway sends 4 messages: confirmEmail, resetPassword, passwordChanged and accountExists. It HTML-escapes
  every interpolated value (opposite-osiris redesign/auth `scripts/auth/mail-templates.mjs:10-20,37`).
- The image bakes exclusions.conf (`waf/Dockerfile:53`). m227 mounts the tree's file over whatever image it runs
  (`m227-waf-app-content.sh:152-157`). CI builds the waf from the commit and runs m227 (`ci.yml:1208-1209,1285-1288`).
- Unknown when this was written:
  - which image the 20:36 m227 run used;
  - whether passwordChanged and accountExists pass;
  - whether Mailpit's HTML preview is sandboxed (local only);
  - signup volume against the Funnel-shared 10/min, 200/h bucket on /email/v1.

## Decision

On POST to exactly /email/v1/send, the XSS family and 921130 no longer inspect ARGS:json.html. Every other
argument, header and the query string, every other family, and every other path and method keep full inspection.
The lift ships only where Kong refuses every key except service_role on /email/v1. The WAF is not who decides who
may send.

## Alternatives considered

- **Keep inspecting the body and send mail on-VM only**: the gateway runs on Fly and reaches grobase only through
  Funnel, then the WAF. Every HTML account mail would stay refused, as measured.
- **Base64-encode the html in the gateway**: changes a contract that has two callers (gateway, newslettersvc
  internal) and hides content from every family, not only XSS. That is a wider lift with more code.
- **Also lift json.text**: no rule hit it (audit), so the gate has no leg showing it is needed. Rejected
  (`.out-of-scope/waf-lift-on-email-text-part.md`).
- **Bypass the WAF for /email/v1 in nginx**: drops 921xxx, SQLi and RCE inspection on to, subject and
  listUnsubscribe. listUnsubscribe is written into a header.

## Consequences

- From here on, the acl is the only control that stops anyone from sending arbitrary HTML as
  devfast@archicode.codes. A Kong config without it means an HTML open relay. That is why 10150 cannot land on
  main ahead of bbe8995f (W150-1).
- The b2b WAF runs another host-built image until CI publishes one with 10150. The 921130 M4 hold (no unscoped
  up, build or pull of waf) extends until that happens (W150-9).
- A mail whose html trips a family that was not lifted (942, 932 and so on) is still refused. That is a new ruling,
  not an extension of 10150.
- Conditions are in groot `.claude/agent-memory/devil/verdict-waf-10150.md` and the ruling of 2026-10-17.

## Amendment 2026-10-17: what the conditions changed

grobase fix/waf-10150-email-body at 1ef7986a (on a42a8077):

- W150-3: 10150 lifts ARGS:json.html only. json.text keeps full inspection: no text part of the ten
  messages the gateway sends drew a hit, and `text: <script>` answers 403.
- W150-4: the m227 fixture carries all ten messages the site gateway sends through /email/v1/send
  (four `renderMessage` mails, two sign-in alerts, account created, three newsletter mails). Each answers
  200 and is refused without 10150, without its 921130 line, and without its attack-xss line.
- W150-6: case-variant keys (`Subject`, `TO`) carrying `<script>` answer 403.
- W150-7: grobase feat/titan-mail 88c6687b, `TestBodyCannotReachSMTPHeaders`: CRLF `Bcc:` lines and
  boundary-shaped lines in html or text stay inside the body; a CRLF subject is Q-encoded.
- W150-8/12: image `grobase-waf:fix-10150-1ef7986a`. Its baked REQUEST-900 conf has the same sha256 as
  the tree file (ef5464c4...). m227 ran on that image: 143 passed, 0 failed.
- Found by W150-4: a sign-in alert whose User-Agent is `<script>alert(1)</script>` is escaped to
  `&lt;script&gt;...`, which CRS 932235 (unix command injection) refuses. 10150 does not lift 932235.
  The gateway is to drop attack-shaped characters from request metadata before rendering it, so
  that the WAF is not widened.

Open: W150-1 (merge after the email acl), W150-2/9/10 (the user-run b2b deploy, after PR #41 clears its hold).
