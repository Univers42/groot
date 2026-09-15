# Fixing `make docker-rm-all` — "image has dependent child images"

## The error

```
Error response from daemon: conflict: unable to delete 05bcdc7384fa (cannot be forced) - image has dependent child images
make: *** [infrastructure/makes/docker.mk:15: docker-rm-all] Error 1
```

## What happened

When I ran `make docker-rm-all`, the target iterated over all local images with
`docker images -aq` and called `docker rmi -f` on each one in arbitrary order.
Docker cannot remove an image that still has **child images** referencing it as a
layer — not even with `-f`. The `-f` flag only bypasses the "image is used by a
running container" guard; it does not override the layer-dependency graph.

In this case the chain was:

```
05bcdc7384fa  (intermediate Bitwarden CLI build layer, no tag)
  └── 76cbb8127f4b  (intermediate layer, no tag)
        └── 1f6fc10f1f3a  vite-gourmand-secrets:latest
```

The loop hit `05bcdc7384fa` before `1f6fc10f1f3a` and `76cbb8127f4b` were
removed. `docker rmi -f` failed. The error-handling block then ran
`docker image inspect` on the same ID — the image still existed, so the block
`exit 1`-ed, aborting the whole make target.

## How I diagnosed it

```bash
# Identify the problematic object
docker inspect 05bcdc7384fa
# → Architecture: amd64, Entrypoint: ["bw"] — an intermediate Bitwarden image

# Find its direct child
FULL=$(docker image inspect 05bcdc7384fa --format '{{.Id}}')
docker images -a --format "{{.ID}}" | \
  xargs -I{} sh -c \
  'p=$(docker image inspect {} --format "{{.Parent}}" 2>/dev/null); [ "$p" = "'"$FULL"'" ] && echo "child: {}"'
# → child: 76cbb8127f4b

# Find the grandchild
FULL2=$(docker image inspect 76cbb8127f4b --format '{{.Id}}')
# repeat the pattern → grandchild: 1f6fc10f1f3a  (vite-gourmand-secrets:latest)
```

The dependency chain explained exactly why the single-pass deletion loop always
failed: the leaf image `vite-gourmand-secrets` had to be removed first so
`76cbb8127f4b` became removable, which in turn allowed `05bcdc7384fa` to go.

## The root cause in the Makefile

The old logic:

```makefile
@docker images -aq | sort -u | while read -r image_id; do \
    if docker image inspect "$$image_id" >/dev/null 2>&1; then \
        docker rmi -f "$$image_id" || { \
            if docker image inspect "$$image_id" >/dev/null 2>&1; then exit 1; fi; \
        }; \
    fi; \
done
```

The `exit 1` branch fired whenever an image still existed after a failed `rmi`.
That is the correct state for an image with live children — it should not be an
error at that moment in the loop; it just means we need to delete the children
first.

## The fix

I replaced the single-pass `while read` loop with a **multi-pass** loop that
retries until no image can be removed in a full iteration:

```makefile
@removed=1; while [ "$$removed" = "1" ]; do \
    removed=0; \
    for image_id in $$(docker images -aq 2>/dev/null); do \
        if docker rmi -f "$$image_id" >/dev/null 2>&1; then \
            removed=1; \
        fi; \
    done; \
done; true
```

**Why this works:**

- Pass 1 deletes leaf images (no children). `removed=1` triggers another pass.
- Pass 2 deletes images that were previously blocked because their children are
  now gone.
- The loop terminates when a full pass yields zero deletions — meaning everything
  removable has been removed. Truly un-removable images (e.g., base images still
  needed by BuildKit cache) are cleaned by the subsequent `docker system prune`.
- The final `; true` ensures the make recipe does not propagate a non-zero exit
  from the shell `for` construct.

## File changed

[infrastructure/makes/docker.mk](../../../../infrastructure/makes/docker.mk) —
`docker-rm-all` target, image-removal section.

## Prevention

Docker image layers form a **DAG** (directed acyclic graph). Any deletion loop
that processes images in arbitrary order will hit this problem whenever a
multi-stage build or a layered build has left intermediate images. The
multi-pass approach handles this generically without requiring topological
pre-sorting.
