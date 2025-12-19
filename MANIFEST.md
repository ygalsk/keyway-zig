Below is a **single-page architecture manifesto** intended to be read, remembered, and enforced.
It is written for **contributors, reviewers, and agents**.
Every sentence is deliberate. Nothing here is accidental.

---

# Keystone Architecture Manifesto

**(One Page · Non-Negotiable Design Contract)**

## Purpose

Keystone is a **high-performance HTTP engine** built on:

**Zig · LuaJIT · io_uring · libxev · picohttpparser · eBPF**

Its goal is not to expose APIs, but to **establish a correct execution and memory model** that scales predictably, remains observable, and avoids accidental complexity.

This document defines the **rules**.
All code, agents, and contributions must align with them.

---

## 1. Execution Model: Proactor First

Keystone is a **proactor-based system**.

* I/O is **submitted**, not performed inline
* The kernel completes work asynchronously
* User code **describes intent**, it does not “do” I/O

### Consequences

* Lua **never performs syscalls**
* Lua **never decides when to write**
* Zig submits all I/O via **io_uring**
* libxev orchestrates structured async execution

If code violates this, it is architecturally incorrect.

---

## 2. One Core, One Thread, One Lua State

Keystone runs:

* **1 worker thread per CPU core**
* **1 Lua state per worker**
* **No Lua state is shared**
* **No cross-thread Lua access**

### Connection Affinity Is Mandatory

* `SO_REUSEPORT` is enabled
* eBPF is used as a **kernel-level load balancer**
* Connections are consistently routed to the **same worker**
* Requests from the same connection **always hit the same Lua state**

This guarantees:

* No data leakage
* No locking
* No synchronization overhead
* Perfect cache locality

---

## 3. Memory Ownership Is Singular and Explicit

### Zig Owns All Memory

* Request bytes live in a **RingBuffer**
* Headers, params, body slices are **offsets**
* Lua receives **views**, never ownership

### There Is One Shared Contract

`HttpExchange` is:

* The **only object Lua touches**
* A **stable ABI**
* A memory view, not a data structure
* Valid for exactly one request

There are no hidden lifetimes.

---

## 4. Layered Responsibility (No Exceptions)

Each layer has **one job**:

| Layer            | Responsibility       |
| ---------------- | -------------------- |
| RingBuffer       | Own bytes            |
| picohttpparser   | Mark structure       |
| Radix router     | Assign meaning       |
| HttpExchange     | Bind memory contract |
| Lua              | Express policy       |
| Response Builder | Commit I/O           |
| Kernel           | Execute              |

No layer leaks upward.
No layer compensates for another.

---

## 5. Lua Is a Policy Language, Not a Runtime

Lua code:

* Mutates state
* Assigns intent
* Looks declarative

Lua **never**:

* Calls I/O
* Manages lifetimes
* Owns file descriptors
* Implements backpressure
* Coordinates concurrency

If Lua code looks imperative, the design is wrong.

---

## 6. Organic Interface Rule (No Verbs)

Lua interacts with `ctx` as if it were a table:

```lua
ctx.status = 200
ctx.headers["Content-Type"] = "application/json"
ctx.body = "ok"
```

There are:

* No `send()`
* No `write()`
* No `set_header()`
* No lifecycle calls

Only **state**.

---

## 7. Zero-Copy Is the Default

* Request data is never copied
* Headers and params are slices
* Response bodies:

  * Inline → direct write
  * File → `sendfile`
  * Stream → generator pulled by Zig

Copying is a **failure mode**, not a feature.

---

## 8. Streaming Is Kernel-Driven

Streaming obeys proactor semantics:

* Lua provides a **pure generator**
* Zig pulls when the kernel is ready
* Backpressure is handled by io_uring
* Lua never blocks

This preserves correctness and performance.

---

## 9. libxev Rules

libxev is used for:

* Structured async submission
* Explicit lifetimes
* Minimal callbacks

libxev callbacks:

* Do not contain logic
* Do not capture state
* Do not inspect Lua

All state lives in `HttpExchange`.

---

## 10. io_uring Rules

io_uring is used because:

* It rewards fixed memory
* It rewards batch submission
* It rewards zero-copy design

Any design that:

* Allocates per request
* Copies unnecessarily
* Crosses language boundaries mid-flight

Is invalid.

---

## 11. eBPF Is for Observability and Routing

eBPF is used to:

* Implement `SO_REUSEPORT` load balancing
* Preserve connection affinity
* Observe syscall behavior
* Measure latency without instrumentation

eBPF never replaces logic.
It observes and routes — nothing more.

---

## 12. LuaRocks Policy

Keystone **uses LuaRocks for functionality**, not as a package manager.

* We do not care how users install LuaRocks
* We do not manage LuaRocks environments
* We only rely on **LuaRocks module resolution semantics**

Lua modules must:

* Load via LuaRocks
* Work without Keystone-specific installers
* Remain sandboxable

---

## 13. What This System Is Not

Keystone is not:

* An event-driven callback soup
* A framework that hides control flow
* A Lua server pretending to be C
* A general-purpose runtime

It is a **memory-accurate, proactor-aligned execution engine**.

---

## 14. Canonical Mental Model (Final)

> RingBuffer holds reality
> picohttpparser marks structure
> Radix assigns meaning
> HttpExchange binds memory
> Lua expresses intent
> libxev schedules work
> io_uring executes
> Response Builder commits truth
> eBPF observes silently

If a contribution does not fit this model,
it does not belong in Keystone.

---

**This manifesto is the contract.**
Agents enforce it.
Reviewers defend it.
Contributors follow it.
