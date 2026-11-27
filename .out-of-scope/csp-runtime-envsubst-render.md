# Rendering the CSP at container start with `envsubst` is out of scope

- Decided: 2026-11-23 · by devil (osionos #342 ruling, `scratch/csp342/RULING.md` §8)
- Holds while: each web image serves exactly one deployment

## The concept

Keep a policy template in the image and fill the origins from the container's environment in the nginx entrypoint (design option C), so one image serves any deployment.

## Why not

- The bundle's origins are fixed at build time (`VITE_*`), the policy's would be fixed at start time. Two inputs for one fact: a container started with a different env than its build blocks its own bridge origin, and page loads and saves fail for every user.
- The failure only shows at runtime, after the image passed its build gates.

## Prior requests

- 2026-11-23 (design, #342): listed as option C.

## Reopen when

One web image must serve several deployments. Then the bundle's origins have to move to runtime too, so both read the same input.
