# IDE user identity through a globally exported nss_wrapper LD_PRELOAD is out of scope

- Decided: 2026-10-17 · by devil (ruling devil-verdict-ide-user-shell-2026-10-17, S3b)
- Holds while: gcc's ASan runtime refuses to start when another library is preloaded ahead of it

## The concept

The terminal shows the osionos username (`whoami`, the prompt) without writing /etc. The box image
ships libnss-wrapper, and the login profile exports `LD_PRELOAD=libnss_wrapper.so` together with
NSS_WRAPPER_PASSWD and NSS_WRAPPER_GROUP pointing at a generated passwd file.

## Why not

- The fact that decides it: with that preload exported, every `gcc -fsanitize=address` binary aborts
  with "ASan runtime does not come first in initial library list". This was measured on
  osionos-ide-sandbox:latest with libnss-wrapper 1.1.12-1 on 2026-10-17. Exporting
  `ASAN_OPTIONS=verify_asan_link_order=0` cures it only until a tester or Makefile sets its own
  ASAN_OPTIONS (`detect_leaks=1` re-broke it, measured).
- The image exists for 42 school C work (`infrastructure/docker/osionos/ide-sandbox/Dockerfile:46-48`),
  where ASan is a daily tool. valgrind, LSan and UBSan were unaffected.

## Prior requests

- 2026-10-17 (dylan, via the plan-ide-user-shell plan): the username as the box account.

## Reopen when

ASan no longer checks link order under a preload, or the preload stops reaching the user's programs:
it is scoped to the login shell (`export -n LD_PRELOAD` after start) and a PTY test shows
`heap-buffer-overflow`, both with no ASAN_OPTIONS and with `ASAN_OPTIONS=detect_leaks=1`.
