// D-024: demo contact data must be unmistakably fictional. This scans rendered text, not the
// generator's fields, so a value smuggled into a note body or a SQL literal is caught too.
//
// Caveat: pattern-based. A phone written without the "+" prefix (06 12 …) or an email with
// an obfuscated "@" is not seen, so a miss is possible in that direction; an ISBN or a DOI is
// never mistaken for a phone because both lack the leading "+".
const EMAIL = /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g;
const PHONE = /\+\d[\d .-]{7,}\d/g;
const URL_HOST = /https?:\/\/[A-Za-z0-9.-]+/g;

const ALLOWED_EMAIL = /^[a-z0-9._-]+@([a-z0-9-]+\.example\.com|[a-z0-9.-]+\.test)$/;
const ALLOWED_PHONE = /^\+33 6 39 98 \d{2} \d{2}$/;
const ALLOWED_HOST = /^https?:\/\/([a-z0-9.-]+\.)?(example\.com|[a-z0-9-]+\.test)$/;

export function contactViolations(text) {
  const out = [];
  const scan = (regex, allowed, kind) => {
    for (const match of text.matchAll(regex)) {
      if (!allowed.test(match[0])) out.push({ kind, value: match[0] });
    }
  };
  scan(EMAIL, ALLOWED_EMAIL, 'email');
  scan(PHONE, ALLOWED_PHONE, 'phone');
  scan(URL_HOST, ALLOWED_HOST, 'url');
  return out;
}
