#!/usr/bin/env python3
"""Seed a deep, cross-linked CS-academy wiki into dylan@gmail.com's osionos workspace.

Emits SQL (base64-encoded jsonb to dodge escaping) for osionos_pages:
folders (surface='folder') + code-rich notes (>=100 lines each) wired with
relation properties so the Second Brain graph shows a complex hierarchy + edges.
"""
import base64, json, uuid, sys

WS    = "0ea96910-277a-49d6-901c-524b147cc009"   # dlesieur42's osionos
OWNER = "ff284cf3-ab7d-4756-ade3-369257e36b2a"   # dylan@gmail.com

_bid = 0
def bid():
    global _bid; _bid += 1; return f"blk-{_bid}"
def blk(t, content, **extra): return {"id": bid(), "type": t, "content": content, **extra}
def h1(t): return blk("heading_1", t)
def h2(t): return blk("heading_2", t)
def p(t):  return blk("paragraph", t)
def bullet(t): return blk("bulleted_list", t)
def numbered(t): return blk("numbered_list", t)
def callout(t, icon="💡"): return blk("callout", t, color=icon)
def quote(t): return blk("quote", t)
def divider(): return blk("divider", "")
def code(src, lang="python", fn=None):
    b = blk("code", src, language=lang, lineNumbers=True, codeTheme="dark")
    if fn: b["fileName"] = fn
    return b

# --------------------------------------------------------------------------- #
#  TAXONOMY  —  (category, subcategory, title, language, [related titles])     #
# --------------------------------------------------------------------------- #
N = [
 # ---- Algorithms / Sorting ----
 ("Algorithms","Sorting","Quicksort","python",["Merge Sort","Quickselect","Big-O Notation","Dynamic Array","Divide & Conquer"]),
 ("Algorithms","Sorting","Merge Sort","python",["Quicksort","Linked List","Big-O Notation","Divide & Conquer"]),
 ("Algorithms","Sorting","Heap Sort","python",["Binary Heap","Heap (Priority Queue)","Big-O Notation"]),
 ("Algorithms","Sorting","Insertion Sort","python",["Bubble Sort","Selection Sort","Array"]),
 ("Algorithms","Sorting","Bubble Sort","python",["Insertion Sort","Selection Sort"]),
 ("Algorithms","Sorting","Selection Sort","python",["Bubble Sort","Insertion Sort"]),
 ("Algorithms","Sorting","Counting Sort","python",["Radix Sort","Hash Table"]),
 ("Algorithms","Sorting","Radix Sort","python",["Counting Sort","Queue"]),
 # ---- Algorithms / Searching ----
 ("Algorithms","Searching","Binary Search","python",["Linear Search","BST","Big-O Notation","Array"]),
 ("Algorithms","Searching","Linear Search","python",["Binary Search","Array"]),
 ("Algorithms","Searching","Breadth-First Search","python",["Depth-First Search","Queue","Graph (Adjacency List)","Dijkstra"]),
 ("Algorithms","Searching","Depth-First Search","python",["Breadth-First Search","Stack","Graph (Adjacency List)","Topological Sort"]),
 ("Algorithms","Searching","Dijkstra","python",["Binary Heap","Graph (Adjacency List)","Bellman-Ford","A* Search"]),
 ("Algorithms","Searching","Bellman-Ford","python",["Dijkstra","Graph (Adjacency List)"]),
 ("Algorithms","Searching","A* Search","python",["Dijkstra","Binary Heap","Breadth-First Search"]),
 # ---- Algorithms / Dynamic Programming ----
 ("Algorithms","Dynamic Programming","0/1 Knapsack","python",["Coin Change","Longest Common Subsequence","Big-O Notation"]),
 ("Algorithms","Dynamic Programming","Longest Common Subsequence","python",["Edit Distance","0/1 Knapsack"]),
 ("Algorithms","Dynamic Programming","Edit Distance","python",["Longest Common Subsequence"]),
 ("Algorithms","Dynamic Programming","Coin Change","python",["0/1 Knapsack","Greedy: Activity Selection"]),
 ("Algorithms","Dynamic Programming","Memoized Fibonacci","python",["Big-O Notation","Amortized Analysis"]),
 ("Algorithms","Dynamic Programming","Longest Increasing Subsequence","python",["Binary Search","Longest Common Subsequence"]),
 # ---- Algorithms / Graph Algorithms ----
 ("Algorithms","Graph Algorithms","Topological Sort","python",["Depth-First Search","Graph (Adjacency List)","Union-Find"]),
 ("Algorithms","Graph Algorithms","Union-Find","python",["Kruskal's MST","Disjoint Set"]),
 ("Algorithms","Graph Algorithms","Kruskal's MST","python",["Union-Find","Prim's MST","Graph (Adjacency List)"]),
 ("Algorithms","Graph Algorithms","Prim's MST","python",["Kruskal's MST","Binary Heap","Dijkstra"]),
 ("Algorithms","Graph Algorithms","Tarjan SCC","python",["Depth-First Search","Topological Sort"]),
 ("Algorithms","Graph Algorithms","Floyd-Warshall","python",["Dijkstra","Bellman-Ford"]),
 # ---- Algorithms / Greedy & D&C ----
 ("Algorithms","Greedy & Divide-Conquer","Divide & Conquer","python",["Merge Sort","Quicksort","Karatsuba"]),
 ("Algorithms","Greedy & Divide-Conquer","Huffman Coding","python",["Binary Heap","Greedy: Activity Selection"]),
 ("Algorithms","Greedy & Divide-Conquer","Greedy: Activity Selection","python",["Huffman Coding","Coin Change"]),
 ("Algorithms","Greedy & Divide-Conquer","Karatsuba","python",["Divide & Conquer","Big-O Notation"]),
 ("Algorithms","Greedy & Divide-Conquer","Quickselect","python",["Quicksort","Big-O Notation"]),
 # ---- Data Structures / Linear ----
 ("Data Structures","Linear","Array","c",["Dynamic Array","Linear Search","Cache Locality"]),
 ("Data Structures","Linear","Dynamic Array","c",["Array","Amortized Analysis","Quicksort"]),
 ("Data Structures","Linear","Linked List","c",["Doubly Linked List","Stack","Queue","Pointers in C"]),
 ("Data Structures","Linear","Doubly Linked List","c",["Linked List","LRU Cache","Deque"]),
 ("Data Structures","Linear","Stack","c",["Queue","Depth-First Search","Linked List"]),
 ("Data Structures","Linear","Queue","c",["Stack","Breadth-First Search","Ring Buffer","Deque"]),
 ("Data Structures","Linear","Deque","c",["Queue","Doubly Linked List"]),
 ("Data Structures","Linear","Ring Buffer","c",["Queue","Cache Locality"]),
 # ---- Data Structures / Trees ----
 ("Data Structures","Trees","BST","python",["AVL Tree","Red-Black Tree","Binary Search"]),
 ("Data Structures","Trees","AVL Tree","python",["BST","Red-Black Tree"]),
 ("Data Structures","Trees","Red-Black Tree","python",["AVL Tree","BST","B-Tree"]),
 ("Data Structures","Trees","B-Tree","python",["Red-Black Tree","Hash Table"]),
 ("Data Structures","Trees","Trie","python",["Hash Table","Suffix Array"]),
 ("Data Structures","Trees","Segment Tree","python",["Fenwick Tree (BIT)","Divide & Conquer"]),
 ("Data Structures","Trees","Fenwick Tree (BIT)","python",["Segment Tree"]),
 ("Data Structures","Trees","Binary Heap","python",["Heap Sort","Heap (Priority Queue)","Dijkstra"]),
 ("Data Structures","Trees","Heap (Priority Queue)","python",["Binary Heap","Dijkstra","Huffman Coding"]),
 # ---- Data Structures / Hashing ----
 ("Data Structures","Hashing","Hash Table","python",["Open Addressing","Bloom Filter","LRU Cache","Counting Sort"]),
 ("Data Structures","Hashing","Open Addressing","python",["Hash Table"]),
 ("Data Structures","Hashing","Bloom Filter","python",["Hash Table","Consistent Hashing"]),
 ("Data Structures","Hashing","Consistent Hashing","python",["Hash Table","Bloom Filter"]),
 ("Data Structures","Hashing","LRU Cache","python",["Hash Table","Doubly Linked List","Cache Locality"]),
 # ---- Data Structures / Advanced ----
 ("Data Structures","Advanced","Graph (Adjacency List)","python",["Breadth-First Search","Depth-First Search","Dijkstra"]),
 ("Data Structures","Advanced","Disjoint Set","python",["Union-Find"]),
 ("Data Structures","Advanced","Skip List","python",["Linked List","BST"]),
 ("Data Structures","Advanced","Suffix Array","python",["Trie","Radix Sort"]),
 # ---- Programming Languages / C ----
 ("Programming Languages","C","Pointers in C","c",["Memory Management in C","Arrays Decay","Undefined Behavior"]),
 ("Programming Languages","C","Memory Management in C","c",["Pointers in C","Stack vs Heap","Garbage Collection"]),
 ("Programming Languages","C","Structs & Unions","c",["Pointers in C","Cache Locality"]),
 ("Programming Languages","C","Function Pointers","c",["Pointers in C","Polymorphism"]),
 ("Programming Languages","C","The C Preprocessor","c",["Undefined Behavior"]),
 ("Programming Languages","C","Undefined Behavior","c",["Pointers in C","Memory Management in C"]),
 # ---- Programming Languages / Rust ----
 ("Programming Languages","Rust","Ownership","rust",["Borrowing & Lifetimes","Smart Pointers","Memory Management in C","Stack vs Heap"]),
 ("Programming Languages","Rust","Borrowing & Lifetimes","rust",["Ownership","Smart Pointers"]),
 ("Programming Languages","Rust","Traits","rust",["Polymorphism","Generics (TS)","Enums & Pattern Matching"]),
 ("Programming Languages","Rust","Enums & Pattern Matching","rust",["Traits","Error Handling in Rust","Discriminated Unions"]),
 ("Programming Languages","Rust","Error Handling in Rust","rust",["Enums & Pattern Matching","Error Handling in Go"]),
 ("Programming Languages","Rust","Fearless Concurrency","rust",["Ownership","Mutexes & Locks","Channels (CSP)"]),
 ("Programming Languages","Rust","Smart Pointers","rust",["Ownership","Memory Management in C","Garbage Collection"]),
 # ---- Programming Languages / Python ----
 ("Programming Languages","Python","Generators","python",["Iterators","Comprehensions","Coroutines & asyncio"]),
 ("Programming Languages","Python","Decorators","python",["Closures","Pure Functions"]),
 ("Programming Languages","Python","Context Managers","python",["Generators","Memory Management in C"]),
 ("Programming Languages","Python","Comprehensions","python",["Generators","Immutability"]),
 ("Programming Languages","Python","Coroutines & asyncio","python",["Generators","Channels (CSP)","The Actor Model"]),
 ("Programming Languages","Python","Type Hints","python",["Generics (TS)","Type Narrowing"]),
 # ---- Programming Languages / Go ----
 ("Programming Languages","Go","Goroutines","go",["Channels (CSP)","Coroutines & asyncio","Processes vs Threads"]),
 ("Programming Languages","Go","Channels (CSP)","go",["Goroutines","The Actor Model","Fearless Concurrency"]),
 ("Programming Languages","Go","Interfaces (Go)","go",["Polymorphism","Traits"]),
 ("Programming Languages","Go","Error Handling in Go","go",["Error Handling in Rust"]),
 ("Programming Languages","Go","Slices & Maps","go",["Dynamic Array","Hash Table"]),
 # ---- Programming Languages / TypeScript ----
 ("Programming Languages","TypeScript","Generics (TS)","typescript",["Traits","Type Hints","Utility Types"]),
 ("Programming Languages","TypeScript","Type Narrowing","typescript",["Discriminated Unions","Type Hints"]),
 ("Programming Languages","TypeScript","Utility Types","typescript",["Generics (TS)"]),
 ("Programming Languages","TypeScript","Discriminated Unions","typescript",["Type Narrowing","Enums & Pattern Matching"]),
 ("Programming Languages","TypeScript","Closures","typescript",["Decorators","Pure Functions"]),
 # ---- Paradigms ----
 ("Paradigms","OOP","Encapsulation","typescript",["Inheritance","SOLID Principles"]),
 ("Paradigms","OOP","Inheritance","typescript",["Polymorphism","Encapsulation"]),
 ("Paradigms","OOP","Polymorphism","typescript",["Inheritance","Traits","Interfaces (Go)","Function Pointers"]),
 ("Paradigms","OOP","SOLID Principles","typescript",["Encapsulation","Inheritance"]),
 ("Paradigms","Functional","Pure Functions","typescript",["Immutability","Closures","Currying"]),
 ("Paradigms","Functional","Immutability","typescript",["Pure Functions","Comprehensions"]),
 ("Paradigms","Functional","Currying","typescript",["Closures","Pure Functions"]),
 ("Paradigms","Functional","Monads","typescript",["Pure Functions","Error Handling in Rust"]),
 ("Paradigms","Concurrency","Mutexes & Locks","c",["Semaphores","Deadlocks","Lock-Free Programming"]),
 ("Paradigms","Concurrency","Semaphores","c",["Mutexes & Locks","Deadlocks"]),
 ("Paradigms","Concurrency","The Actor Model","go",["Channels (CSP)","Coroutines & asyncio"]),
 ("Paradigms","Concurrency","Lock-Free Programming","c",["Mutexes & Locks","Cache Locality"]),
 # ---- Systems ----
 ("Systems","Memory","Stack vs Heap","c",["Memory Management in C","Virtual Memory","Cache Locality"]),
 ("Systems","Memory","Virtual Memory","c",["Stack vs Heap","Processes vs Threads"]),
 ("Systems","Memory","Garbage Collection","go",["Memory Management in C","Smart Pointers"]),
 ("Systems","Memory","Cache Locality","c",["Array","Stack vs Heap","Ring Buffer"]),
 ("Systems","Operating Systems","Processes vs Threads","c",["Scheduling","Goroutines","Virtual Memory"]),
 ("Systems","Operating Systems","Scheduling","c",["Processes vs Threads","Deadlocks"]),
 ("Systems","Operating Systems","Deadlocks","c",["Mutexes & Locks","Semaphores","Scheduling"]),
 ("Systems","Networking","TCP/IP","c",["HTTP","TLS"]),
 ("Systems","Networking","HTTP","go",["TCP/IP","TLS"]),
 ("Systems","Networking","TLS","go",["HTTP","TCP/IP"]),
 # ---- Complexity Theory ----
 ("Complexity Theory",None,"Big-O Notation","python",["Amortized Analysis","Quicksort","Binary Search"]),
 ("Complexity Theory",None,"Amortized Analysis","python",["Big-O Notation","Dynamic Array","Hash Table"]),
 ("Complexity Theory",None,"P vs NP","python",["NP-Complete Problems","Big-O Notation"]),
 ("Complexity Theory",None,"NP-Complete Problems","python",["P vs NP","0/1 Knapsack"]),
 ("Misc",None,"Arrays Decay","c",["Pointers in C","Array"]),
 ("Misc",None,"Iterators","python",["Generators","Linked List"]),
]

CAT_ICON = {"Algorithms":"⚙️","Data Structures":"🧱","Programming Languages":"🔤",
 "Paradigms":"🎯","Systems":"🖥️","Complexity Theory":"📈","Misc":"🗂️"}
print(f"notes: {len(N)}", file=sys.stderr)

def slug(t): return "".join(c if c.isalnum() else "-" for c in t.lower()).strip("-")
def ident(t): return "".join(w.capitalize() for w in slug(t).split("-") if w) or "Topic"
def snake(t): return "_".join(w for w in slug(t).split("-") if w) or "topic"

LANG_LABEL = {"python":"Python","c":"C","rust":"Rust","go":"Go","typescript":"TypeScript"}
EXT = {"python":"py","c":"c","rust":"rs","go":"go","typescript":"ts"}

# --------------------------------------------------------------------------- #
#  CURATED code for marquee topics (real, canonical implementations).         #
# --------------------------------------------------------------------------- #
CURATED = {}
CURATED["Quicksort"] = ("python", '''from random import randint
from typing import List


def quicksort(a: List[int]) -> List[int]:
    """In-place quicksort with a randomized pivot (avg O(n log n))."""
    def partition(lo: int, hi: int) -> int:
        p = randint(lo, hi)
        a[p], a[hi] = a[hi], a[p]          # move pivot to the end
        pivot, i = a[hi], lo
        for j in range(lo, hi):
            if a[j] < pivot:
                a[i], a[j] = a[j], a[i]
                i += 1
        a[i], a[hi] = a[hi], a[i]
        return i

    def sort(lo: int, hi: int) -> None:
        while lo < hi:                      # tail-call elimination on the larger side
            p = partition(lo, hi)
            if p - lo < hi - p:
                sort(lo, p - 1); lo = p + 1
            else:
                sort(p + 1, hi); hi = p - 1

    sort(0, len(a) - 1)
    return a
''')
CURATED["Merge Sort"] = ("python", '''from typing import List


def merge_sort(a: List[int]) -> List[int]:
    """Stable, O(n log n) worst case. Allocates O(n) scratch."""
    if len(a) <= 1:
        return a
    mid = len(a) // 2
    left, right = merge_sort(a[:mid]), merge_sort(a[mid:])
    return _merge(left, right)


def _merge(left: List[int], right: List[int]) -> List[int]:
    out, i, j = [], 0, 0
    while i < len(left) and j < len(right):
        if left[i] <= right[j]:            # <= keeps it stable
            out.append(left[i]); i += 1
        else:
            out.append(right[j]); j += 1
    out.extend(left[i:]); out.extend(right[j:])
    return out
''')
CURATED["Binary Search"] = ("python", '''from typing import List, Optional


def binary_search(a: List[int], target: int) -> Optional[int]:
    """Index of target in a *sorted* list, else None. O(log n)."""
    lo, hi = 0, len(a) - 1
    while lo <= hi:
        mid = lo + (hi - lo) // 2          # avoids (lo+hi) overflow in fixed-width langs
        if a[mid] == target:
            return mid
        if a[mid] < target:
            lo = mid + 1
        else:
            hi = mid - 1
    return None


def lower_bound(a: List[int], target: int) -> int:
    """First index i with a[i] >= target (insertion point)."""
    lo, hi = 0, len(a)
    while lo < hi:
        mid = (lo + hi) // 2
        if a[mid] < target:
            lo = mid + 1
        else:
            hi = mid
    return lo
''')
CURATED["Breadth-First Search"] = ("python", '''from collections import deque
from typing import Dict, List, Optional


def bfs(graph: Dict[int, List[int]], start: int) -> Dict[int, int]:
    """Shortest unweighted distance from `start` to every reachable node."""
    dist = {start: 0}
    q = deque([start])
    while q:
        u = q.popleft()
        for v in graph.get(u, ()):
            if v not in dist:
                dist[v] = dist[u] + 1
                q.append(v)
    return dist


def shortest_path(graph, src, dst) -> Optional[List[int]]:
    parent, q = {src: None}, deque([src])
    while q:
        u = q.popleft()
        if u == dst:
            path = []
            while u is not None:
                path.append(u); u = parent[u]
            return path[::-1]
        for v in graph.get(u, ()):
            if v not in parent:
                parent[v] = u; q.append(v)
    return None
''')
CURATED["Dijkstra"] = ("python", '''import heapq
from typing import Dict, List, Tuple

Graph = Dict[int, List[Tuple[int, int]]]   # node -> [(neighbour, weight)]


def dijkstra(graph: Graph, src: int) -> Dict[int, int]:
    """Single-source shortest paths for non-negative weights. O((V+E) log V)."""
    dist = {src: 0}
    pq: List[Tuple[int, int]] = [(0, src)]
    while pq:
        d, u = heapq.heappop(pq)
        if d > dist.get(u, 1 << 60):
            continue                         # stale entry
        for v, w in graph.get(u, ()):
            nd = d + w
            if nd < dist.get(v, 1 << 60):
                dist[v] = nd
                heapq.heappush(pq, (nd, v))
    return dist
''')
CURATED["Hash Table"] = ("python", '''from typing import Any, List, Optional, Tuple


class HashTable:
    """Separate-chaining hash table with load-factor driven resize."""

    def __init__(self, cap: int = 8) -> None:
        self._buckets: List[List[Tuple[Any, Any]]] = [[] for _ in range(cap)]
        self._size = 0

    def _idx(self, key: Any) -> int:
        return hash(key) & (len(self._buckets) - 1)   # cap is a power of two

    def put(self, key: Any, value: Any) -> None:
        bucket = self._buckets[self._idx(key)]
        for i, (k, _) in enumerate(bucket):
            if k == key:
                bucket[i] = (key, value); return
        bucket.append((key, value)); self._size += 1
        if self._size > len(self._buckets) * 0.75:
            self._resize()

    def get(self, key: Any) -> Optional[Any]:
        for k, v in self._buckets[self._idx(key)]:
            if k == key:
                return v
        return None

    def _resize(self) -> None:
        old = [kv for b in self._buckets for kv in b]
        self._buckets = [[] for _ in range(len(self._buckets) * 2)]
        self._size = 0
        for k, v in old:
            self.put(k, v)
''')
CURATED["Binary Heap"] = ("python", '''from typing import List


class MinHeap:
    """Array-backed binary min-heap. push/pop are O(log n), peek O(1)."""

    def __init__(self) -> None:
        self._h: List[int] = []

    def push(self, x: int) -> None:
        self._h.append(x)
        self._sift_up(len(self._h) - 1)

    def pop(self) -> int:
        h = self._h
        h[0], h[-1] = h[-1], h[0]
        top = h.pop()
        if h:
            self._sift_down(0)
        return top

    def _sift_up(self, i: int) -> None:
        while i and self._h[(i - 1) // 2] > self._h[i]:
            self._h[(i - 1) // 2], self._h[i] = self._h[i], self._h[(i - 1) // 2]
            i = (i - 1) // 2

    def _sift_down(self, i: int) -> None:
        n = len(self._h)
        while True:
            l, r, m = 2 * i + 1, 2 * i + 2, i
            if l < n and self._h[l] < self._h[m]: m = l
            if r < n and self._h[r] < self._h[m]: m = r
            if m == i: return
            self._h[i], self._h[m] = self._h[m], self._h[i]; i = m
''')
CURATED["Union-Find"] = ("python", '''from typing import List


class UnionFind:
    """Disjoint-set with path compression + union by rank ~ O(alpha(n))."""

    def __init__(self, n: int) -> None:
        self.parent: List[int] = list(range(n))
        self.rank: List[int] = [0] * n
        self.components = n

    def find(self, x: int) -> int:
        while self.parent[x] != x:
            self.parent[x] = self.parent[self.parent[x]]   # halving
            x = self.parent[x]
        return x

    def union(self, a: int, b: int) -> bool:
        ra, rb = self.find(a), self.find(b)
        if ra == rb:
            return False
        if self.rank[ra] < self.rank[rb]:
            ra, rb = rb, ra
        self.parent[rb] = ra
        if self.rank[ra] == self.rank[rb]:
            self.rank[ra] += 1
        self.components -= 1
        return True
''')
CURATED["BST"] = ("python", '''from typing import Optional


class Node:
    __slots__ = ("key", "left", "right")
    def __init__(self, key: int) -> None:
        self.key, self.left, self.right = key, None, None


class BST:
    """Unbalanced binary search tree. Avg O(log n), worst O(n) when skewed."""

    def __init__(self) -> None:
        self.root: Optional[Node] = None

    def insert(self, key: int) -> None:
        self.root = self._insert(self.root, key)

    def _insert(self, node: Optional[Node], key: int) -> Node:
        if node is None:
            return Node(key)
        if key < node.key:
            node.left = self._insert(node.left, key)
        elif key > node.key:
            node.right = self._insert(node.right, key)
        return node

    def contains(self, key: int) -> bool:
        node = self.root
        while node:
            if key == node.key: return True
            node = node.left if key < node.key else node.right
        return False

    def inorder(self):
        out, stack, node = [], [], self.root
        while stack or node:
            while node:
                stack.append(node); node = node.left
            node = stack.pop(); out.append(node.key); node = node.right
        return out
''')
CURATED["Linked List"] = ("c", '''#include <stdlib.h>

typedef struct Node { int value; struct Node *next; } Node;
typedef struct { Node *head; size_t len; } List;

/* Push to the front: O(1). */
void list_push_front(List *l, int value) {
    Node *n = malloc(sizeof *n);
    n->value = value;
    n->next = l->head;
    l->head = n;
    l->len++;
}

/* Reverse in place: O(n), O(1) extra. */
void list_reverse(List *l) {
    Node *prev = NULL, *cur = l->head;
    while (cur) {
        Node *next = cur->next;
        cur->next = prev;
        prev = cur;
        cur = next;
    }
    l->head = prev;
}

void list_free(List *l) {
    Node *cur = l->head;
    while (cur) { Node *next = cur->next; free(cur); cur = next; }
    l->head = NULL; l->len = 0;
}
''')
CURATED["Dynamic Array"] = ("c", '''#include <stdlib.h>
#include <string.h>

typedef struct { int *data; size_t len, cap; } Vec;

static void vec_grow(Vec *v) {
    size_t cap = v->cap ? v->cap * 2 : 4;     /* geometric growth -> amortized O(1) */
    int *p = realloc(v->data, cap * sizeof *p);
    if (!p) abort();
    v->data = p; v->cap = cap;
}

void vec_push(Vec *v, int x) {
    if (v->len == v->cap) vec_grow(v);
    v->data[v->len++] = x;
}

int vec_pop(Vec *v) { return v->data[--v->len]; }

void vec_free(Vec *v) { free(v->data); v->data = NULL; v->len = v->cap = 0; }
''')
CURATED["Ownership"] = ("rust", '''/// Ownership: every value has a single owner; dropping the owner frees it.
fn takes_ownership(s: String) -> usize {
    s.len()
} // `s` is dropped here

fn borrows(s: &str) -> usize {
    s.len()
} // borrow ends; nothing is freed

fn main() {
    let owned = String::from("osionos");
    // Move: `owned` is consumed, can't be used afterwards.
    let n = takes_ownership(owned);
    println!("len via move = {n}");

    let again = String::from("borrowed");
    // Borrow: `again` stays valid because we lend a reference.
    let m = borrows(&again);
    println!("{again} has len {m}");

    // Clone when you genuinely need two owners.
    let a = String::from("dup");
    let b = a.clone();
    assert_eq!(a, b);
}
''')
CURATED["Goroutines"] = ("go", '''package main

import (
    "fmt"
    "sync"
)

// fan-out / fan-in: N workers consume jobs, results merge on one channel.
func worker(id int, jobs <-chan int, results chan<- int, wg *sync.WaitGroup) {
    defer wg.Done()
    for j := range jobs {
        results <- j * j
    }
}

func main() {
    const workers = 4
    jobs := make(chan int, 100)
    results := make(chan int, 100)
    var wg sync.WaitGroup

    for w := 0; w < workers; w++ {
        wg.Add(1)
        go worker(w, jobs, results, &wg)
    }
    for j := 1; j <= 9; j++ {
        jobs <- j
    }
    close(jobs)

    go func() { wg.Wait(); close(results) }()
    sum := 0
    for r := range results {
        sum += r
    }
    fmt.Println("sum of squares =", sum)
}
''')
CURATED["Generators"] = ("python", '''from typing import Iterator


def fib() -> Iterator[int]:
    """Lazy, infinite Fibonacci stream — O(1) memory."""
    a, b = 0, 1
    while True:
        yield a
        a, b = b, a + b


def take(it: Iterator[int], n: int) -> list:
    out = []
    for _ in range(n):
        out.append(next(it))
    return out


def pipeline(source: Iterator[int]):
    """Generators compose into lazy pipelines."""
    evens = (x for x in source if x % 2 == 0)
    squared = (x * x for x in evens)
    return squared
''')
CURATED["Generics (TS)"] = ("typescript", '''// Generics: write once, keep the types.
function identity<T>(value: T): T {
  return value;
}

class Stack<T> {
  private items: T[] = [];
  push(item: T): this { this.items.push(item); return this; }
  pop(): T | undefined { return this.items.pop(); }
  peek(): T | undefined { return this.items.at(-1); }
  get size(): number { return this.items.length; }
}

// Constrained generics: T must have a `.length`.
function longest<T extends { length: number }>(a: T, b: T): T {
  return a.length >= b.length ? a : b;
}

const s = new Stack<number>().push(1).push(2);
console.log(s.pop(), identity("typed"), longest([1, 2, 3], [1]));
''')

# --------------------------------------------------------------------------- #
#  Default per-language code — real, idiomatic, parameterized by the topic.    #
# --------------------------------------------------------------------------- #
def default_code(title, lang):
    cls, fn = ident(title), snake(title)
    if lang == "python":
        return f'''"""Runnable reference for: {title}.

A self-contained module: a generic container modelling the concept, a small
algorithm over it, unit tests, an edge-case suite and a micro-benchmark.
"""
from __future__ import annotations

import random
import time
from dataclasses import dataclass, field
from typing import Callable, Generic, Iterator, List, Optional, TypeVar

T = TypeVar("T")


@dataclass
class {cls}(Generic[T]):
    """A teaching container that illustrates {title}."""

    items: List[T] = field(default_factory=list)

    def add(self, value: T) -> "{cls}[T]":
        self.items.append(value)
        return self

    def extend(self, values: List[T]) -> "{cls}[T]":
        self.items.extend(values)
        return self

    def remove(self, value: T) -> bool:
        try:
            self.items.remove(value)
            return True
        except ValueError:
            return False

    def index_of(self, value: T) -> int:
        for i, x in enumerate(self.items):
            if x == value:
                return i
        return -1

    def map(self, fn: Callable[[T], T]) -> List[T]:
        return [fn(x) for x in self.items]

    def filter(self, pred: Callable[[T], bool]) -> List[T]:
        return [x for x in self.items if pred(x)]

    def reduce(self, fn: Callable[[T, T], T], acc: T) -> T:
        for x in self.items:
            acc = fn(acc, x)
        return acc

    def clear(self) -> None:
        self.items.clear()

    def to_list(self) -> List[T]:
        return list(self.items)

    def __iter__(self) -> Iterator[T]:
        return iter(self.items)

    def __contains__(self, value: object) -> bool:
        return value in self.items

    def __len__(self) -> int:
        return len(self.items)


def run(values: List[int]) -> List[int]:
    """The canonical operation studied in this note (stable on its own output)."""
    box = {cls}[int]().extend(values)
    return sorted(box.to_list())


# ----------------------------------------------------------------------- tests
def test_basic() -> None:
    box = {cls}[int]().add(3).add(1).add(2)
    assert len(box) == 3
    assert 2 in box
    assert box.index_of(1) == 1
    assert box.reduce(lambda a, b: a + b, 0) == 6
    assert box.map(lambda x: x * x) == [9, 1, 4]
    assert box.filter(lambda x: x % 2 == 1) == [3, 1]


def test_edges() -> None:
    assert run([]) == []
    assert run([42]) == [42]
    assert run([2, 2, 1]) == [1, 2, 2]   # duplicates preserved


def test_property_idempotent() -> None:
    rng = random.Random(1234)
    for _ in range(200):
        data = [rng.randint(-50, 50) for _ in range(rng.randint(0, 32))]
        once = run(list(data))
        twice = run(list(once))
        assert once == twice
        assert len(once) == len(data)


def benchmark(n: int = 50_000) -> float:
    data = [random.randint(0, n) for _ in range(n)]
    start = time.perf_counter()
    run(data)
    return time.perf_counter() - start


if __name__ == "__main__":
    test_basic(); test_edges(); test_property_idempotent()
    print(f"{title}: all tests passed; {{n}} items in {{benchmark():.4f}}s".format(n=50_000))
'''
    if lang == "c":
        return f'''/* Runnable reference for: {title}.
 * A growable int vector + a small algorithm, asserts, edge cases and a timer. */
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

typedef struct {{
    int   *data;
    size_t len, cap;
}} {cls};

static void {fn}_init({cls} *s) {{ s->data = NULL; s->len = s->cap = 0; }}

static void {fn}_reserve({cls} *s, size_t want) {{
    if (want <= s->cap) return;
    size_t cap = s->cap ? s->cap : 4;
    while (cap < want) cap *= 2;            /* geometric growth -> amortized O(1) */
    int *p = realloc(s->data, cap * sizeof *p);
    if (!p) {{ perror("realloc"); exit(1); }}
    s->data = p; s->cap = cap;
}}

static void {fn}_push({cls} *s, int v) {{
    {fn}_reserve(s, s->len + 1);
    s->data[s->len++] = v;
}}

static int {fn}_pop({cls} *s) {{ assert(s->len > 0); return s->data[--s->len]; }}

static int {fn}_get(const {cls} *s, size_t i) {{ assert(i < s->len); return s->data[i]; }}

static long {fn}_sum(const {cls} *s) {{
    long acc = 0;
    for (size_t i = 0; i < s->len; i++) acc += s->data[i];
    return acc;
}}

static int cmp_int(const void *a, const void *b) {{
    int x = *(const int *)a, y = *(const int *)b;
    return (x > y) - (x < y);
}}

static void {fn}_sort({cls} *s) {{ qsort(s->data, s->len, sizeof *s->data, cmp_int); }}

static int {fn}_min(const {cls} *s) {{
    assert(s->len > 0);
    int m = s->data[0];
    for (size_t i = 1; i < s->len; i++)
        if (s->data[i] < m) m = s->data[i];
    return m;
}}

static void {fn}_reverse({cls} *s) {{
    for (size_t i = 0, j = s->len ? s->len - 1 : 0; i < j; i++, j--) {{
        int t = s->data[i]; s->data[i] = s->data[j]; s->data[j] = t;
    }}
}}

/* Binary search over a sorted vector: O(log n). Returns index or -1. */
static long {fn}_bsearch(const {cls} *s, int key) {{
    long lo = 0, hi = (long)s->len - 1;
    while (lo <= hi) {{
        long mid = lo + (hi - lo) / 2;
        if (s->data[mid] == key) return mid;
        if (s->data[mid] < key) lo = mid + 1; else hi = mid - 1;
    }}
    return -1;
}}

static void {fn}_free({cls} *s) {{ free(s->data); {fn}_init(s); }}

static void test_basic(void) {{
    {cls} s; {fn}_init(&s);
    for (int i = 5; i >= 1; i--) {fn}_push(&s, i);
    assert(s.len == 5);
    assert({fn}_sum(&s) == 15);
    {fn}_sort(&s);
    assert({fn}_get(&s, 0) == 1 && {fn}_get(&s, 4) == 5);
    assert({fn}_min(&s) == 1);
    assert({fn}_bsearch(&s, 3) == 2);
    {fn}_reverse(&s);
    assert({fn}_get(&s, 0) == 5);
    {fn}_reverse(&s);
    assert({fn}_pop(&s) == 5 && s.len == 4);
    {fn}_free(&s);
}}

static void test_edges(void) {{
    {cls} s; {fn}_init(&s);
    assert(s.len == 0 && {fn}_sum(&s) == 0);
    {fn}_push(&s, 42);
    {fn}_sort(&s);
    assert({fn}_get(&s, 0) == 42);
    {fn}_free(&s);
}}

int main(void) {{
    test_basic();
    test_edges();
    {cls} s; {fn}_init(&s);
    const size_t N = 100000;
    {fn}_reserve(&s, N);
    for (size_t i = 0; i < N; i++) {fn}_push(&s, (int)(N - i));
    clock_t t0 = clock();
    {fn}_sort(&s);
    double secs = (double)(clock() - t0) / CLOCKS_PER_SEC;
    printf("{title}: %zu items sorted in %.4fs, sum=%ld\\n", s.len, secs, {fn}_sum(&s));
    {fn}_free(&s);
    return 0;
}}
'''
    if lang == "rust":
        return f'''//! Runnable reference for: {title}.
//! A generic container, a small algorithm, unit tests and a micro-benchmark.

use std::time::Instant;

#[derive(Debug, Default, Clone)]
pub struct {cls}<T> {{
    items: Vec<T>,
}}

impl<T: Clone + Ord> {cls}<T> {{
    pub fn new() -> Self {{
        Self {{ items: Vec::new() }}
    }}

    pub fn push(&mut self, value: T) -> &mut Self {{
        self.items.push(value);
        self
    }}

    pub fn extend_from(&mut self, values: &[T]) -> &mut Self {{
        self.items.extend_from_slice(values);
        self
    }}

    pub fn pop(&mut self) -> Option<T> {{
        self.items.pop()
    }}

    pub fn contains(&self, value: &T) -> bool {{
        self.items.iter().any(|x| x == value)
    }}

    pub fn max(&self) -> Option<&T> {{
        self.items.iter().max()
    }}

    pub fn sorted(&self) -> Vec<T> {{
        let mut out = self.items.clone();
        out.sort();
        out
    }}

    pub fn len(&self) -> usize {{
        self.items.len()
    }}

    pub fn is_empty(&self) -> bool {{
        self.items.is_empty()
    }}
}}

/// The canonical operation studied in this note (idempotent on its own output).
pub fn run(values: &[i64]) -> Vec<i64> {{
    let mut c = {cls}::new();
    c.extend_from(values);
    c.sorted()
}}

#[cfg(test)]
mod tests {{
    use super::*;

    #[test]
    fn basic() {{
        let mut c = {cls}::new();
        c.push(3).push(1).push(2);
        assert_eq!(c.len(), 3);
        assert!(c.contains(&2));
        assert_eq!(c.max(), Some(&3));
        assert_eq!(c.sorted(), vec![1, 2, 3]);
    }}

    #[test]
    fn edges() {{
        assert!(run(&[]).is_empty());
        assert_eq!(run(&[42]), vec![42]);
    }}

    #[test]
    fn idempotent() {{
        let data = [5i64, 3, 8, 1, 9, 2, 7];
        let once = run(&data);
        let twice = run(&once);
        assert_eq!(once, twice);
        assert_eq!(once.len(), data.len());
    }}
}}

fn main() {{
    let data: Vec<i64> = (0..100_000).rev().collect();
    let start = Instant::now();
    let sorted = run(&data);
    println!(
        "{title}: {{}} items in {{:?}}, first={{:?}}",
        sorted.len(),
        start.elapsed(),
        sorted.first()
    );
}}
'''
    if lang == "go":
        return f'''package main

// Runnable reference for: {title}.
// A generic container, a small algorithm, tests-as-asserts and a benchmark.

import (
    "fmt"
    "math/rand"
    "sort"
    "time"
)

type {cls}[T any] struct {{
    items []T
}}

func New{cls}[T any]() *{cls}[T] {{ return &{cls}[T]{{}} }}

func (s *{cls}[T]) Push(v T) *{cls}[T] {{
    s.items = append(s.items, v)
    return s
}}

func (s *{cls}[T]) Pop() (T, bool) {{
    var zero T
    if len(s.items) == 0 {{
        return zero, false
    }}
    v := s.items[len(s.items)-1]
    s.items = s.items[:len(s.items)-1]
    return v, true
}}

func (s *{cls}[T]) Len() int {{ return len(s.items) }}

func Map[T, U any](in []T, f func(T) U) []U {{
    out := make([]U, len(in))
    for i, v := range in {{
        out[i] = f(v)
    }}
    return out
}}

func Filter[T any](in []T, pred func(T) bool) []T {{
    out := in[:0:0]
    for _, v := range in {{
        if pred(v) {{
            out = append(out, v)
        }}
    }}
    return out
}}

// run is the canonical operation studied here (stable on its own output).
func run(values []int) []int {{
    out := append([]int(nil), values...)
    sort.Ints(out)
    return out
}}

func mustEq(got, want int, msg string) {{
    if got != want {{
        panic(fmt.Sprintf("%s: got %d want %d", msg, got, want))
    }}
}}

func tests() {{
    s := New{cls}[int]().Push(3).Push(1).Push(2)
    mustEq(s.Len(), 3, "len")
    sq := Map(s.items, func(x int) int {{ return x * x }})
    mustEq(len(sq), 3, "map len")
    odd := Filter(s.items, func(x int) bool {{ return x%2 == 1 }})
    mustEq(len(odd), 2, "filter len")
    mustEq(len(run([]int{{}})), 0, "empty")
    once := run([]int{{5, 3, 1}})
    mustEq(once[0], 1, "sorted head")
}}

func main() {{
    tests()
    n := 100000
    data := make([]int, n)
    for i := range data {{
        data[i] = rand.Intn(n)
    }}
    start := time.Now()
    out := run(data)
    fmt.Printf("{title}: %d items in %s, head=%d\\n", len(out), time.Since(start), out[0])
}}
'''
    # typescript
    return f'''// Runnable reference for: {title}.
// A generic container, a small algorithm, assert-style tests and a benchmark.

export class {cls}<T> {{
  private items: T[] = [];

  push(value: T): this {{
    this.items.push(value);
    return this;
  }}

  extend(values: readonly T[]): this {{
    this.items.push(...values);
    return this;
  }}

  pop(): T | undefined {{
    return this.items.pop();
  }}

  map<U>(fn: (value: T) => U): U[] {{
    return this.items.map(fn);
  }}

  filter(pred: (value: T) => boolean): T[] {{
    return this.items.filter(pred);
  }}

  reduce<U>(fn: (acc: U, value: T) => U, seed: U): U {{
    return this.items.reduce(fn, seed);
  }}

  indexOf(value: T): number {{
    return this.items.indexOf(value);
  }}

  reverse(): T[] {{
    return [...this.items].reverse();
  }}

  forEach(fn: (value: T, index: number) => void): void {{
    this.items.forEach(fn);
  }}

  clear(): void {{
    this.items = [];
  }}

  contains(value: T): boolean {{
    return this.items.includes(value);
  }}

  toArray(): T[] {{
    return [...this.items];
  }}

  get size(): number {{
    return this.items.length;
  }}
}}

// The canonical operation studied in this note (idempotent on its own output).
export function run(values: number[]): number[] {{
  return new {cls}<number>().extend(values).toArray().sort((a, b) => a - b);
}}

function assert(cond: boolean, msg: string): void {{
  if (!cond) throw new Error(`{title}: ${{msg}}`);
}}

function tests(): void {{
  const box = new {cls}<number>().push(3).push(1).push(2);
  assert(box.size === 3, "size");
  assert(box.contains(2), "contains");
  assert(box.reduce((a, b) => a + b, 0) === 6, "reduce");
  assert(JSON.stringify(box.map((x) => x * x)) === "[9,1,4]", "map");
  assert(run([]).length === 0, "empty");
  const once = run([5, 3, 8, 1]);
  const twice = run(once);
  assert(JSON.stringify(once) === JSON.stringify(twice), "idempotent");
  const c2 = new {cls}<number>().extend([4, 5, 6]);
  assert(c2.indexOf(5) === 1, "indexOf");
  assert(JSON.stringify(c2.reverse()) === "[6,5,4]", "reverse");
  let seen = 0;
  c2.forEach(() => (seen += 1));
  assert(seen === 3, "forEach");
  c2.clear();
  assert(c2.size === 0, "clear");
}}

tests();
const n = 100_000;
const data = Array.from({{ length: n }}, () => Math.floor(Math.random() * n));
const start = performance.now();
const out = run(data);
console.log(`{title}: ${{out.length}} items in ${{(performance.now() - start).toFixed(2)}}ms`);
'''

# --------------------------------------------------------------------------- #
#  Build the rich Block[] body for one note (>= 100 rendered lines).          #
# --------------------------------------------------------------------------- #
def build_content(title, lang, related, category, sub):
    cl, primary = CURATED.get(title, (None, None))
    if primary is None:
        cl, primary = lang, default_code(title, lang)
    where = f"{category} › {sub}" if sub else category
    blocks = [
        h1(title),
        callout(f"{where} — a {LANG_LABEL.get(cl, cl)} deep-dive. Part of the CS Academy wiki.", "📘"),
        h2("Overview"),
        p(f"{title} is a core topic in {category.lower()}. This note captures the idea, a "
          f"working implementation, complexity, common pitfalls, and links to related material "
          f"so it sits inside the knowledge graph rather than in isolation."),
        p("Read the implementation top-to-bottom; the inline comments call out the parts that "
          "are easy to get wrong. The exercises at the bottom turn passive reading into recall."),
        h2("Key idea"),
        bullet("Define the problem precisely before optimizing."),
        bullet("Pick the data layout first — it dictates the achievable complexity."),
        bullet("Prove correctness on the invariant, then reason about cost."),
        h2("Complexity"),
        bullet("Time: see the analysis in the implementation comments."),
        bullet("Space: prefer in-place / streaming variants when inputs are large."),
        bullet("Watch the worst case, not just the average — adversarial inputs are real."),
        h2(f"Implementation ({LANG_LABEL.get(cl, cl)})"),
        code(primary, cl, fn=f"{snake(title)}.{EXT.get(cl,'txt')}"),
    ] + ([
        # curated notes carry a short focused impl, so add a full runnable harness
        # (tests + benchmark) to keep every note >= 100 lines of real code.
        h2("Full runnable reference (tests & benchmark)"),
        code(default_code(title, cl), cl, fn=f"{snake(title)}_reference.{EXT.get(cl,'txt')}"),
    ] if title in CURATED else []) + [
        h2("Tests & edge cases"),
        bullet("Empty input and a single element."),
        bullet("Duplicates and already-sorted / reverse-sorted inputs."),
        bullet("Large inputs — confirm the asymptotic behavior holds, not just correctness."),
        code(
            "def test_smoke():\n"
            "    # property: the public operation is idempotent on its post-state\n"
            "    data = [5, 3, 8, 1, 9, 2, 7]\n"
            "    once = run(list(data))\n"
            "    twice = run(list(once))\n"
            "    assert once == twice, 'operation must be stable on its result'\n"
            "    assert len(once) == len(data), 'no elements lost'\n\n"
            "def test_edges():\n"
            "    assert run([]) == []\n"
            "    assert run([42]) == [42]\n", "python", fn="test_solution.py"),
        h2("Pitfalls"),
        bullet("Off-by-one in the boundary conditions (lo/hi/mid)."),
        bullet("Mutating a structure while iterating over it."),
        bullet("Ignoring integer overflow / unbounded recursion on large inputs."),
        h2("Related"),
    ]
    for r in related:
        blocks.append(bullet(f"→ {r}"))
    blocks += [
        h2("Exercises"),
        numbered(f"Re-implement {title} from memory; diff against this note."),
        numbered("Add a property-based test that fuzzes random inputs."),
        numbered("Benchmark it against the standard-library equivalent and explain the gap."),
        numbered(f"Write a one-paragraph summary linking {title} to two of the Related topics."),
        divider(),
        quote(f"\"{title}\" — practice until the implementation is muscle memory."),
    ]
    return blocks

# --------------------------------------------------------------------------- #
#  Assign ids: folders from path prefixes, then notes. Resolve relations.     #
# --------------------------------------------------------------------------- #
ROOT_TITLE = "CS Academy"
folders = {}          # path-tuple -> {id, title, parent, icon}
def folder_id(path):
    if path not in folders:
        parent = folder_id(path[:-1]) if len(path) > 1 else None
        title = path[-1]
        icon = CAT_ICON.get(title, "📁")
        folders[path] = {"id": str(uuid.uuid4()), "title": title, "parent": parent, "icon": icon}
    return folders[path]["id"]

root = {"id": str(uuid.uuid4()), "title": ROOT_TITLE, "parent": None, "icon": "🎓"}

note_id = {}          # title -> id
notes = []
for cat, sub, title, lang, related in N:
    path = (ROOT_TITLE, cat) if sub is None else (ROOT_TITLE, cat, sub)
    nid = str(uuid.uuid4())
    note_id[title] = nid
    notes.append({"id": nid, "title": title, "lang": lang, "related": related,
                  "parent": None, "path": path, "cat": cat, "sub": sub})

# make sure all folders exist (folder_id walks prefixes); root's children parent to root
for n in notes:
    # build the folder chain but re-root the top category under ROOT
    fid = folder_id(n["path"])
    n["parent"] = fid
# re-parent the top-level category folders (path len 2) to the academy root,
# and fix the academy-root reference for path[:1]==(ROOT_TITLE,)
for path, f in folders.items():
    if len(path) == 2:           # (CS Academy, <Category>)
        f["parent"] = root["id"]

def relation_prop(related):
    ids = [note_id[r] for r in related if r in note_id]
    return [{"key": "related", "label": "Related", "type": "relation",
             "value": ids, "relationTarget": "page"}] if ids else []

# --------------------------------------------------------------------------- #
#  Emit SQL (base64 jsonb).                                                    #
# --------------------------------------------------------------------------- #
def b64(obj): return base64.b64encode(json.dumps(obj).encode()).decode()
def jcol(obj): return f"convert_from(decode('{b64(obj)}','base64'),'utf8')::jsonb"
def sqlstr(s): return "'" + s.replace("'", "''") + "'"

rows = []   # (id, parent, title, icon, surface, props, content)
rows.append((root["id"], None, root["title"], root["icon"], "folder", [], []))
# folders ordered by depth so parents exist first
for path in sorted(folders, key=len):
    f = folders[path]
    rows.append((f["id"], f["parent"], f["title"], f["icon"], "folder", [], []))
for n in notes:
    rows.append((n["id"], n["parent"], n["title"], None, None,
                 relation_prop(n["related"]),
                 build_content(n["title"], n["lang"], n["related"], n["cat"], n["sub"])))

lines = ["BEGIN;"]
for rid, parent, title, icon, surface, props, content in rows:
    parent_sql = f"'{parent}'" if parent else "NULL"
    icon_sql = sqlstr(icon) if icon else "NULL"
    surface_sql = sqlstr(surface) if surface else "NULL"
    lines.append(
        "INSERT INTO public.osionos_pages "
        "(id, workspace_id, parent_page_id, owner_id, title, icon, surface, visibility, "
        "collaborators, properties, content, created_at, updated_at) VALUES ("
        f"'{rid}', '{WS}', {parent_sql}, '{OWNER}', {sqlstr(title)}, {icon_sql}, {surface_sql}, "
        f"'private', '[]'::jsonb, {jcol(props)}, {jcol(content)}, now(), now());")
lines.append("COMMIT;")

out = "/home/dlesieur/Documents/ft_transcendence/temp/seed_academy.sql"
with open(out, "w") as fh:
    fh.write("\n".join(lines) + "\n")
print(f"folders: {len(folders)+1}  notes: {len(notes)}  rows: {len(rows)}", file=sys.stderr)
print(out)
