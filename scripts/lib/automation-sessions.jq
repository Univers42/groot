# Classes each row of GET /api/account/sessions as self | automation | keep and prints
# createdAt(minute) \t authMethod \t userAgent(70) \t class \t id — one TSV line per session.
# Args: $keep (regex of the owner's own user agents), $since (ISO UTC prefix; "" = none).
# Used by scripts/revoke-automation-sessions.sh; tested in scripts/tests/revoke-automation-sessions.bats.
#
# Caveat: automation is recognised by user agent alone. A person whose browser matches a tool
# pattern (a Firefox on X11 Linux without the $keep signature, e.g. a Fedora Firefox) is
# classed automation and signed out; an automation run that spoofs a real browser's user agent
# is kept. An Electron sign-in is automation only when --since names the run's start, as the
# owner's desktop app sends the same user agent as the desktop smoke.

def tool_agent: test("^(curl|Wget|node|undici|python-requests|Go-http-client)\\b|HeadlessChrome"; "i");
# Playwright's bundled Firefox reports plain "X11; Linux x86_64"; a distro Firefox names the distro.
def playwright_firefox: test("Firefox/") and test("X11; Linux x86_64;");
def electron_since: ((.userAgent // "") | test("Electron/")) and $since != "" and ($since <= (.createdAt // ""));

def class:
	(.userAgent // "") as $ua
	| if .current == true then "self"
	elif ($keep != "" and ($ua | test($keep))) then "keep"
	elif ($ua | tool_agent) or ($ua | playwright_firefox) or electron_since then "automation"
	else "keep" end;

.sessions[]
| [(.createdAt // "" | .[0:16]), (.authMethod // ""), ((.userAgent // "") | .[0:70]), class, .id]
| @tsv
