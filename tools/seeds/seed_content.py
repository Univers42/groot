#!/usr/bin/env python3
"""Overhaul note CONTENT for dylan's CS Academy: a distinct, real lesson per note,
with varied rich formatting (2-column compares, coloured callouts, tables, toggles)
to exercise the renderer. Keeps titles/ids/hierarchy/relations — UPDATE by title.

Reuses the taxonomy + code library from seed_academy.py (importing it re-emits the
old SQL as a harmless side effect, which we ignore).
"""
import base64, hashlib, json, sys

sys.path.insert(0, "/home/dlesieur/Documents/ft_transcendence/temp")
from seed_academy import (  # noqa: E402
    N, CURATED, default_code, EXT, LANG_LABEL, slug, snake,
)

WS = "3f009d03-d954-5e35-85b8-db5c37aa859f"   # dylan's actual session workspace

# ---- block builders (own counter so ids are stable per run) ----------------
_bid = 0
def bid():
    global _bid; _bid += 1; return f"c-{_bid}"
def B(t, content="", **x): return {"id": bid(), "type": t, "content": content, **x}
def h1(t): return B("heading_1", t)
def h2(t): return B("heading_2", t)
def h3(t): return B("heading_3", t)
def p(t, **x): return B("paragraph", t, **x)
def bullet(t): return B("bulleted_list", t)
def numbered(t): return B("numbered_list", t)
def todo(t): return B("to_do", t, checked=False)
def quote(t): return B("quote", t)
def divider(): return B("divider")
def callout(t, color="📌"): return B("callout", t, color=color)
def toggle(t, kids): return B("toggle", t, children=kids, collapsed=True)
def code(src, lang, fn=None):
    b = B("code", src, language=lang, lineNumbers=True, codeTheme="dark")
    if fn: b["fileName"] = fn
    return b
def columns(*cols):
    """cols = list of (widthRatio, [blocks]) -> a column_list block."""
    kids = []
    for ratio, blocks in cols:
        kids.append(B("column", widthRatio=ratio, children=blocks))
    return B("column_list", children=kids)
def table(headers, rows, header_row=True):
    data = [list(map(str, headers))] + [list(map(str, r)) for r in rows]
    return B("table_block", tableData=data,
             tableConfig={"headerRow": header_row, "showBorders": True, "stripedRows": True})

def variant_for(title):
    return int(hashlib.md5(title.encode()).hexdigest(), 16) % 4

# ---------------------------------------------------------------------------- #
#  LESSON CONTENT — a real, concise, topic-specific lesson per note.           #
#  L[title] = dict(idea, points[], gotchas[], when[], a/b for 2-col compares)  #
# ---------------------------------------------------------------------------- #
def L_default(title, category, sub, related):
    where = f"{category} › {sub}" if sub else category
    return {
        "idea": f"{title} is a foundational topic in {category.lower()}. The goal of this "
                f"lesson is to give you the working mental model, a real implementation, and "
                f"the failure modes — then connect it to the rest of the curriculum.",
        "points": [
            f"Start from the invariant {title} maintains, not from the code.",
            "Reason about the data layout first; it bounds the achievable complexity.",
            "Prove correctness on a small case, then argue the asymptotic cost.",
            f"{title} shows up wherever the related topics below do — follow the links.",
        ],
        "gotchas": [
            "Boundary conditions (empty / single element / duplicates).",
            "Hidden costs (copies, reallocations, recursion depth).",
            "Confusing average-case with worst-case behaviour.",
        ],
        "when": [f"Reach for {title} when its trade-offs match your constraints.",
                 "Prefer a standard-library equivalent in production unless you measured a win."],
        "a": ("Strengths", ["Clear, well-understood semantics", "Predictable in the common case",
                              "Composes with the related topics"]),
        "b": ("Watch out", ["Degenerate inputs", "Memory pressure at scale", "Subtle off-by-ones"]),
    }

L = {}
def lesson(title, idea, points, gotchas, when, a=None, b=None):
    L[title] = {"idea": idea, "points": points, "gotchas": gotchas, "when": when,
                "a": a or ("Strengths", points[:3]), "b": b or ("Watch out", gotchas[:3])}

lesson("Quicksort",
  "Quicksort partitions an array around a pivot so everything smaller is left and everything larger is right, then recurses on each side. With a randomized pivot it runs in O(n log n) expected time and sorts in place — which is why it backs most standard libraries.",
  ["Partitioning is the whole algorithm; the recursion is bookkeeping.",
   "Randomizing (or median-of-three) the pivot defeats the sorted-input worst case.",
   "Recurse into the smaller side and loop on the larger to bound stack depth to O(log n).",
   "It is NOT stable — equal keys can be reordered."],
  ["A fixed first/last pivot is O(n²) on already-sorted data.",
   "Naive recursion on the large side can blow the stack.",
   "Lomuto vs Hoare partition have different swap counts and edge cases."],
  ["Default in-memory sort when stability isn't required.",
   "Use Quickselect (same partition) when you only need the k-th element."],
  ("Quicksort", ["In place: O(log n) extra", "Fast constant factors", "Cache-friendly scans"]),
  ("Merge Sort", ["Stable", "O(n) extra memory", "Predictable O(n log n) worst case"]))

lesson("Merge Sort",
  "Merge sort splits the array in half, sorts each half recursively, then merges the two sorted runs in linear time. It is stable and guarantees O(n log n) even on adversarial input, at the cost of O(n) scratch space.",
  ["Merging two sorted runs is O(n) with a single pass and three pointers.",
   "Stability comes from preferring the left run on ties (`<=`).",
   "Bottom-up (iterative) merge sort avoids recursion entirely.",
   "It is the natural choice for linked lists and external (on-disk) sorting."],
  ["Forgetting to copy the tail of the non-exhausted run.",
   "Allocating scratch inside the recursion instead of once.",
   "Breaking stability with `<` instead of `<=`."],
  ["When you need a guaranteed worst case or stability.",
   "When sorting linked lists or data that doesn't fit in memory."])

lesson("Binary Search",
  "Binary search finds a target in a sorted sequence by repeatedly halving the search window. Each comparison discards half the remaining candidates, so it costs O(log n). The hard part is never the idea — it's getting the boundaries exactly right.",
  ["Use `lo + (hi - lo)//2` to avoid integer overflow in fixed-width languages.",
   "Decide up front whether the window is `[lo, hi]` or `[lo, hi)` and stay consistent.",
   "`lower_bound` (first index >= target) is more reusable than plain search.",
   "It generalizes to 'binary search on the answer' for monotone predicates."],
  ["Off-by-one in the loop condition (`<` vs `<=`) is the classic bug.",
   "The input MUST be sorted — verify your precondition.",
   "Mid can land on the same index forever if the window doesn't shrink."],
  ["Any lookup over sorted data.",
   "Optimization problems with a monotone feasibility test."])

lesson("Dijkstra",
  "Dijkstra computes shortest paths from a source over non-negative edge weights by always expanding the closest unsettled node, using a min-heap as the frontier. It's greedy, and the non-negativity is what makes the greed correct.",
  ["The heap may hold stale entries; skip a popped node if its distance is out of date.",
   "Each edge relaxation can push a new, smaller-distance entry.",
   "Complexity is O((V + E) log V) with a binary heap.",
   "Predecessor pointers reconstruct the actual path, not just the distance."],
  ["Negative edges break it — use Bellman-Ford instead.",
   "Decrease-key is often faster than push-duplicate, but harder to implement.",
   "Forgetting the stale-entry check makes it re-process nodes."],
  ["Routing / maps with non-negative costs.",
   "Any single-source shortest path where weights are distances or times."],
  ("Dijkstra", ["Greedy + heap", "Non-negative weights only", "O((V+E) log V)"]),
  ("Bellman-Ford", ["Handles negatives", "Detects negative cycles", "O(V·E) slower"]))

lesson("Hash Table",
  "A hash table maps keys to buckets via a hash function, giving expected O(1) lookup, insert and delete. Real-world performance is a story about collisions, load factor, and the quality of the hash.",
  ["Separate chaining stores a list per bucket; open addressing probes in the array itself.",
   "Resize (double) when the load factor passes ~0.75 to keep operations O(1) amortized.",
   "A power-of-two table size lets you mask instead of mod.",
   "Iteration order is unspecified — never rely on it."],
  ["A bad hash collapses everything into one bucket → O(n).",
   "Open addressing degrades badly past ~0.7 load factor.",
   "Mutating a key after insertion corrupts the table."],
  ["The default associative container for unordered keys.",
   "Caches, de-duplication, frequency counting."])

lesson("Ownership",
  "Ownership is Rust's compile-time memory discipline: every value has exactly one owner, and when the owner goes out of scope the value is dropped (freed). No garbage collector, no manual free, no use-after-free.",
  ["Assigning or passing a non-Copy value MOVES it; the source is no longer usable.",
   "Borrowing (`&T` / `&mut T`) lends access without transferring ownership.",
   "`Clone` makes an explicit deep copy when you genuinely need two owners.",
   "Drop order is deterministic — reverse of declaration."],
  ["Trying to use a value after it was moved (the borrow checker stops you).",
   "Returning a reference to a local (dangling) — lifetimes forbid it.",
   "Reaching for `.clone()` reflexively instead of borrowing."],
  ["All Rust code — it's the core model.",
   "Anywhere you'd otherwise need a GC or manual malloc/free."],
  ("Ownership/Move", ["Zero runtime cost", "No GC pauses", "Compile-time safety"]),
  ("Garbage Collection", ["Convenient", "Runtime pauses", "Less control over freeing"]))

lesson("Goroutines",
  "Goroutines are Go's lightweight, runtime-scheduled threads — you can have hundreds of thousands. The idiom is 'don't communicate by sharing memory; share memory by communicating' via channels.",
  ["`go f()` starts a goroutine; it is cheap (a few KB of growable stack).",
   "A `sync.WaitGroup` waits for a known set of goroutines to finish.",
   "The fan-out/fan-in pattern: many workers read jobs, write to one results channel.",
   "Close the results channel from a single owner once all writers are done."],
  ["Leaking goroutines that block forever on a channel nobody reads.",
   "Data races on shared variables — use channels or a mutex.",
   "Closing a channel twice, or writing to a closed channel, panics."],
  ["I/O-bound concurrency: servers, pipelines, crawlers.",
   "Whenever work decomposes into independent units."])

lesson("Generators",
  "A Python generator is a function that `yield`s values lazily, computing each only when asked. It turns an unbounded or expensive sequence into O(1)-memory iteration and composes into clean pipelines.",
  ["`yield` suspends the function and resumes it on the next `next()`.",
   "Generators are single-pass — once exhausted, they're done.",
   "Generator expressions `(x for x in it)` are lazy comprehensions.",
   "They underpin `itertools` and async iteration."],
  ["Re-iterating an exhausted generator silently yields nothing.",
   "Holding a reference prevents the producer from being garbage collected.",
   "Side effects inside a generator run lazily — at consumption time, not definition."],
  ["Streaming large/infinite data.",
   "Building lazy, composable transformation pipelines."])

lesson("BST",
  "A BST keeps keys ordered so that for every node, the left subtree is smaller and the right is larger. That invariant gives O(h) search/insert/delete — great when balanced (h≈log n), terrible when it degenerates into a list.",
  ["In-order traversal yields keys in sorted order — a free sorted view.",
   "Search walks left or right by comparing to the current key.",
   "Deletion has three cases: leaf, one child, two children (swap with successor).",
   "Height h drives every cost — balance is everything."],
  ["Inserting sorted data builds a degenerate O(n) chain.",
   "Deletion with two children is the bug-prone case.",
   "Recursive traversal can overflow on a skewed tree."],
  ["Ordered maps/sets when you also need range queries.",
   "Use a self-balancing variant (AVL/Red-Black) in practice."])

# ---------------------------------------------------------------------------- #
#  Category-aware, topic-specific default lesson (distinct per note, not a      #
#  blank template): it weaves in the category angle + the real related topics. #
# ---------------------------------------------------------------------------- #
CAT_ANGLE = {
 "Algorithms": ("an algorithm", "the recurrence / loop invariant that proves it correct",
    "its time and space complexity in the worst and average case"),
 "Data Structures": ("a data structure", "the invariant every operation must preserve",
    "the cost of each operation and the memory layout behind it"),
 "Programming Languages": ("a language feature", "the mental model the compiler/runtime enforces",
    "the idioms it enables and the foot-guns it removes (or adds)"),
 "Paradigms": ("a design principle", "the property it guarantees about your code",
    "where it pays off and where it adds ceremony"),
 "Systems": ("a systems concept", "what the hardware/OS is actually doing underneath",
    "the performance and correctness consequences for your programs"),
 "Complexity Theory": ("a complexity-theory tool", "the formal definition and what it bounds",
    "how to reason about scalability rather than wall-clock time"),
 "Misc": ("a practical topic", "the precise rule that governs it", "the bugs it prevents"),
}

def L_default(title, category, sub, related):
    kind, invariant, cost = CAT_ANGLE.get(category, CAT_ANGLE["Misc"])
    rel = ", ".join(related[:4]) if related else "the rest of this section"
    return {
        "idea": f"{title} is {kind} in {category.lower()}. The lesson below builds the mental "
                f"model, walks a real implementation line by line, and connects it to {rel}. "
                f"Focus on {invariant} — the code is just that idea made executable.",
        "points": [
            f"Anchor on {invariant}.",
            f"Track {cost}; that's what decides whether {title} fits your constraints.",
            f"{title} is not isolated — it interlocks with {rel}.",
            "Run the implementation, then change one line and predict what breaks.",
        ],
        "gotchas": [
            "Degenerate inputs: empty, single element, all-equal, already-processed.",
            "Hidden costs — copies, re-allocations, recursion depth, cache misses.",
            "Average-case intuition masking a nasty worst case.",
        ],
        "when": [f"Use {title} when {cost.split(' in ')[0]} matches what you need.",
                 f"Cross-reference {rel} before committing to a design."],
        "a": (f"Why {title} works", [invariant.capitalize(), "Composes with related topics",
                                       "Predictable in the common case"]),
        "b": ("Where it bites", ["Degenerate inputs", "Memory / recursion at scale",
                                   "Worst-case surprises"]),
    }

# ---------------------------------------------------------------------------- #
#  Rich, VARIED content per note (4 layout variants, rotated by title hash).    #
# ---------------------------------------------------------------------------- #
COLORS = ["📌", "✅", "🔥", "❗", "ℹ️", "💡", "📝"]

def code_blocks(title, lang):
    """The real implementation block(s), >=100 LOC (curated + full reference, or default)."""
    cl, primary = CURATED.get(title, (None, None))
    if primary is None:
        cl, primary = lang, default_code(title, lang)
    blocks = [h2(f"Implementation — {LANG_LABEL.get(cl, cl)}"),
              code(primary, cl, fn=f"{snake(title)}.{EXT.get(cl,'txt')}")]
    if title in CURATED:
        blocks += [h3("Full runnable reference (tests & benchmark)"),
                   code(default_code(title, cl), cl, fn=f"{snake(title)}_reference.{EXT.get(cl,'txt')}")]
    return blocks

def starter(title, lang):
    """A short 'your turn' scaffold — adds a code block + a pedagogical hook."""
    fn = snake(title)
    if lang == "python":
        return (f"# Practice: implement {title} yourself, then check against the lesson.\n"
                f"def {fn}(data):\n"
                "    # TODO: replace this stub with your implementation.\n"
                "    raise NotImplementedError\n\n\n"
                "def test():\n"
                f"    result = {fn}([3, 1, 2])\n"
                "    assert result is not None, 'should return something'\n"
                "    print('ok:', result)\n\n\n"
                'if __name__ == "__main__":\n'
                "    test()\n")
    if lang == "c":
        return ("/* Practice: implement and test, then compare to the lesson. */\n"
                "#include <assert.h>\n#include <stdio.h>\n\n"
                f"int {fn}(const int *a, int n); /* TODO: your implementation */\n\n"
                "int main(void) {\n"
                "    int a[] = {3, 1, 2};\n"
                "    /* assert(" + fn + "(a, 3) == EXPECTED); */\n"
                "    printf(\"todo: implement " + title.replace('"', "'") + "\\n\");\n"
                "    return 0;\n}\n")
    if lang == "rust":
        return (f"// Practice: implement {title}, then compare to the lesson.\n"
                f"fn {fn}(data: &[i64]) -> Vec<i64> {{\n"
                "    todo!(\"your implementation\")\n}\n\n"
                "#[cfg(test)]\nmod practice {\n    use super::*;\n    #[test]\n"
                f"    fn works() {{ assert!(!{fn}(&[3, 1, 2]).is_empty()); }}\n}}\n\n"
                f"fn main() {{ println!(\"{{:?}}\", {fn}(&[3, 1, 2])); }}\n")
    if lang == "go":
        return ("package main\n\nimport \"fmt\"\n\n"
                f"// Practice: implement {title}, then compare to the lesson.\n"
                f"func {fn}(data []int) []int {{\n"
                "\tpanic(\"TODO: your implementation\")\n}\n\n"
                f"func main() {{ fmt.Println({fn}([]int{{3, 1, 2}})) }}\n")
    return (f"// Practice: implement {title}, then compare to the lesson.\n"
            f"export function {fn}(data: number[]): number[] {{\n"
            "  // TODO: replace this stub with your implementation.\n"
            "  throw new Error('not implemented');\n}\n\n"
            f"console.assert({fn}([3, 1, 2]).length > 0, '{title}');\n")

def lesson_for(title, category, sub, related):
    return L.get(title) or L_default(title, category, sub, related)

def build_content(title, lang, related, category, sub):
    d = lesson_for(title, category, sub, related)
    v = variant_for(title)
    accent = COLORS[(v * 2) % len(COLORS)]
    where = f"{category} › {sub}" if sub else category
    head = [h1(title), callout(f"{where}  ·  {LANG_LABEL.get(lang, lang)}  ·  "
                               f"{len(related)} linked topics", "ℹ️")]
    idea = callout(d["idea"], accent)
    points = [h2("Key ideas")] + [bullet(x) for x in d["points"]]
    gotchas = [h2("Pitfalls")] + [callout(d["gotchas"][0], "❗")] + [bullet(x) for x in d["gotchas"][1:]]
    compare = columns(
        (1, [h3("✅ " + d["a"][0])] + [bullet(x) for x in d["a"][1]]),
        (1, [h3("⚠️ " + d["b"][0])] + [bullet(x) for x in d["b"][1]]),
    )
    when = [h2("When to use it")] + [todo(x) for x in d["when"]]
    related_b = [h2("Related")] + [bullet(f"→ {r}") for r in related] if related else []
    exercises = [h2("Exercises"),
        numbered(f"Re-implement {title} from memory and diff against the code above."),
        numbered("Add a failing test for a degenerate input, then make it pass."),
        numbered(f"Write one paragraph linking {title} to two Related topics."),
        h3("Practice scaffold"),
        code(starter(title, lang), lang, fn=f"practice_{snake(title)}.{EXT.get(lang,'txt')}"),
        divider(), quote(f"“{title}” — understand the invariant, the rest is typing.")]
    impl = code_blocks(title, lang)

    if v == 0:      # idea → key ideas → impl → compare → pitfalls → when
        body = [idea] + points + impl + [h2("Trade-offs"), compare] + gotchas + when
    elif v == 1:    # compare-first → idea → impl → pitfalls(toggle) → when
        body = [h2("At a glance"), compare, idea] + impl + \
               [toggle("▸ Pitfalls & edge cases", gotchas[1:])] + when
    elif v == 2:    # idea → impl → key ideas in 2 cols → pitfalls → when
        half = (len(d["points"]) + 1) // 2
        body = [idea] + impl + [h2("Key ideas"),
                columns((1, [bullet(x) for x in d["points"][:half]]),
                        (1, [bullet(x) for x in d["points"][half:]]))] + gotchas + when
    else:           # callout idea → key ideas → pitfalls → impl → compare(toggle) → when
        body = [idea] + points + gotchas + impl + \
               [toggle("▸ Strengths vs. trade-offs", [compare])] + when
    return head + body + related_b + exercises

# ---------------------------------------------------------------------------- #
#  Emit UPDATEs (content only) keyed by title — keep ids/hierarchy/relations.   #
# ---------------------------------------------------------------------------- #
def b64(obj): return base64.b64encode(json.dumps(obj).encode()).decode()
def jcol(obj): return f"convert_from(decode('{b64(obj)}','base64'),'utf8')::jsonb"
def sqlstr(s): return "'" + s.replace("'", "''") + "'"

lines = ["BEGIN;"]
for cat, sub, title, lang, related in N:
    content = build_content(title, lang, related, cat, sub)
    lines.append(
        f"UPDATE public.osionos_pages SET content={jcol(content)}, updated_at=now() "
        f"WHERE workspace_id='{WS}' AND title={sqlstr(title)} AND surface IS NULL;")
lines.append("COMMIT;")
out = "/home/dlesieur/Documents/ft_transcendence/temp/seed_content.sql"
with open(out, "w") as fh:
    fh.write("\n".join(lines) + "\n")
authored = sum(1 for _, _, t, _, _ in N if t in L)
print(f"notes: {len(N)}  authored-lessons: {authored}  variants: 4", file=sys.stderr)
print(out)
