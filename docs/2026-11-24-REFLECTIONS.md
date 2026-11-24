# FP-RISC & QOS: Reflections Leading to 1.0

A retrospective and working reference organized around six questions. The recurring lesson is to define something useful, observe its behavior, and refine the places where stronger structure or guarantees are needed. The emerging 1.0 goal is a small, dependable foundation with explicit limits, rather than completion of every possible feature.

This summary distinguishes reported experience from interpretations and proposed investigations. It is not a release specification or an independent assessment of the current implementation. Some earlier experiences appear only through the conversation’s retrospective commentary; unresolved choices remain questions here.

## 1. What constitutes the minimal language foundation?

### Reflections and surprises

The discussion describes a shift from a broad range of possible language mechanisms toward the abstractions that actual applications repeatedly use: immutable values, algebraic data types, records, pattern matching, `Option`, `Result`, `List`, `String`, ordinary numeric types, and user-defined application types. Linear resources, actors, and structured concurrency address more specific ownership and execution needs.

The surprise is how much can be expressed with this relatively small foundation. Advanced polymorphism, borrowing, session types, or other mechanisms should earn their place through concrete problems. Their theoretical usefulness alone does not establish that they belong in the 1.0 Core.

The Builtin → Base → ExtBase hierarchy may express a progression of execution capabilities as well as library organization. One interpretation proposed in the discussion was:

- **Builtin:** computation without an assumed runtime environment.
- **Base:** managed execution and external interaction.
- **ExtBase:** composition of application services.

That interpretation is a useful organizing hypothesis, not a settled definition. It could help locate an abstraction according to what it requires, even when its implementation changes.

### Challenges and open questions

- What remains if every feature that has not been essential to real applications is removed?
- What is the smallest useful program that is still awkward to express? Does the difficulty require language support, a library, or a narrower foreign interface?
- Which types need privileged compiler knowledge, and which can remain ordinary definitions?
- Does the hierarchy describe dependencies, capabilities, initialization requirements, or some combination?
- What would make the Core comfortable to leave unchanged for five years?

QOS supplies demanding workloads for the language, while tools, games, and simulators help test whether the resulting foundation is useful beyond QOS. The challenge is to retain that feedback without allowing either system to conceal weaknesses in the other.

## 2. What representation, ownership, and memory model should 1.0 guarantee?

### Reflections and surprises

Value semantics and narrow, opaque C interfaces appear to have supported substantial application development without exposing general pointer manipulation throughout the language. Stateful implementation machinery can stay behind a small interface instead of making every caller understand its layout and ownership rules.

Regions have been useful in the retrospective account. The user also explicitly reports working without GC or thunks and finding list behavior predictable. This is valuable experience, but the absence of tracing collection and deferred evaluation does not by itself establish bounded memory use or bounded cleanup time.

The central question is compositional lifetime behavior: how allocation, sharing, transfer, cancellation, and reclamation fit together. Regions, reference counting, borrowing, and linearity address different parts of that problem. The conversation does not settle a universal choice among them.

### Challenges and open questions

- When an immutable list is extended, is its tail shared or copied? What keeps shared tails valid, and what eventually reclaims them?
- Can values escape a region, and how are lifetimes enforced across actor boundaries?
- What happens to queued messages and owned resources when a sender, receiver, or supervising scope is cancelled?
- Can long-lived actors retain otherwise dead allocations indefinitely?
- Can cycles arise through language values or foreign resources, and who breaks or reclaims them?
- Which foreign handles need linear ownership, and what happens if their owner fails during transfer?

The emerging principle is to specify observable ownership and lifetime guarantees while leaving room to improve representation. That freedom ends wherever representation affects public layout, ABI, failure behavior, or promised resource bounds.

## 3. What have collections, strings, and numbers taught us through practical use?

### Reflections and surprises

**Lists have become a default starting point.** The user’s explanation is that they are simple, align with functional idioms, and support familiar operations such as `map`, `fold`, and `find` without forcing an early commitment to a specialized collection. They still represent an ordered sequence with possible duplicates; using one as a set does not automatically give set semantics.

Lists also support incremental specialization: a list of optimized chunks, a list plus an index, or a list paired with a map. Each change can address a demonstrated workload without replacing the whole programming model. The additional structure introduces real obligations, especially keeping an index consistent with the underlying values.

Predictability is part of the appeal. Strict evaluation avoids thunk retention, and no tracing GC means no tracing-collector pauses. However, repeated end-appends can become quadratic, recursive traversals can consume stack, and allocation or region retention can still grow with workload. Predictable local operations and bounded total memory are different claims.

**String versus Vector challenged the value of generality.** The retrospective describes greater practical value from a well-optimized `String` than from making applications choose among specialized storage representations. `Vector` can still serve contiguous storage, indexed access, and bulk processing, while `List` serves structural composition and `String` serves text.

**Numeric semantics deserve foundational attention.** The discussion identifies uncertainty around `Int` as consequential for portability, overflow, optimization, ABI, and WCET. A small, explicit numeric model may be more valuable for 1.0 than another sophisticated type-system feature.

### Challenges and open questions

- Which workloads actually require a list to become chunked or indexed, and what measurements identify that point?
- What are the allocation, sharing, and failure contracts of ordinary collection operations?
- Should fixed-size strings be public types, bounded interfaces, or internal optimizations? What concrete requirement justifies exposing them?
- Which string operations dominate real applications, and can representation changes remain invisible to callers?
- What exactly does default `Int` mean across targets? How do overflow, conversions, and exceptional arithmetic behave?
- Which numeric guarantees must remain stable across compiler and backend changes?

The lesson is to begin with a representation that is easy to understand, then specialize where evidence makes the extra invariants worthwhile.

## 4. How much incremental verification is useful, and what must it promise?

### Reflections and surprises

The user reports that deliberately limited preconditions and termination measures delivered more value than expected. A comprehensive prover was unnecessary. A restricted predicate vocabulary could reuse facts already available from guards, pattern matching, and conditional branches.

Programmer guidance also reduced the problem: identifying a measure gives the compiler something to check instead of requiring it to invent a termination argument. For preconditions that could not be established statically, the reported fallback was a dynamic guard that faults on violation.

This supports a collaborative model: the programmer supplies intent and structure, the compiler proves the supported cases, and runtime checks enforce permitted residual obligations. The important requirement is sound, consistent behavior within a limited scope.

### Challenges and open questions

- What precise predicate fragment is supported, and can developers predict when a runtime check will remain?
- Can diagnostics distinguish obligations that are proved, dynamically guarded, and unresolved?
- What happens on guard failure, including resource cleanup and transaction state?
- Which execution profiles may accept runtime guards, and which must reject unresolved static obligations?
- How are verified contracts distinguished from unchecked assertions when reasoning across modules?
- How is guard elimination validated against compiler mistakes, perhaps through a reference evaluator, IR checker, or differential testing?

Preconditions and termination measures need distinct contracts. Checking a precondition tests one invocation. A termination argument requires a well-founded measure and appropriate decrease across recursive transitions. Even a valid termination argument does not establish a useful WCET bound if the work performed per step is unbounded.

Measures and preconditions often became clearer after implementation. The define → observe → refine cycle is therefore part of discovering useful contracts, with each version’s actual guarantees kept explicit.

## 5. What must the runtime, WCET model, and ABI reliably guarantee?

### Reflections and surprises

FP-RISC and QOS reinforce each other through actors, linear resources, scheduling, filesystem services, driver interfaces, and transactions. Their hardest contracts concern the intermediate states between a request and its completion.

The discussion proposes three distinct reliability dimensions: **safety**, meaning valid state and ownership; **liveness**, meaning defined progress, completion, cancellation, or waiting behavior; and **boundedness**, meaning explicit limits on resource use and cleanup. Successful ordinary execution does not settle all three.

The retrospective also raises abstraction costs, including expensive actor round trips in portable QOS. Such observations can influence where boundaries belong, rather than being treated only as opportunities for later optimization.

WCET needs a clearly delimited initial scope. The discussion mentions an approximately 5% accuracy ambition, but not a demonstrated universal guarantee. Accurate prediction and a conservative upper bound are different objectives. Target hardware, allocation, interference, scheduling, and external I/O can materially change what is defensible.

### Challenges and open questions

- What happens if a filesystem client disappears after sending a request, or a transaction commits but its acknowledgement is lost?
- What happens if a driver completes after its client dies, or a receiver fails immediately after resource transfer?
- Can cancellation be exercised at every relevant state transition, with ownership and cleanup checked?
- Which operations have bounded allocation, queue growth, blocking, and reclamation?
- Which target and runtime assumptions support each timing claim? What invalidates an existing bound?
- What does the ABI freeze: layouts, calling conventions, ownership transfer, errors, or module metadata?
- What are the measured costs of messaging, blocked actors, MVU updates, string operations, and reload boundaries?

The proposed 1.0 direction is a narrow contractual backbone with explicit failure semantics. Evidence should distinguish what is specified, tested, modelled, and proven rather than treating these as interchangeable levels of confidence.

## 6. How should programs evolve through live reload while preserving compatibility?

### Reflections and surprises

The user reports implementing LiveReload but not yet using it extensively. The next investigation is whether it can support a practical feedback-oriented development workflow: deploy a program with defined interfaces, observe it, and replace behavior while retaining established guarantees.

The central tension is independent replacement versus cross-module optimization. If one module’s function is inlined into another, replacing the original does not update the copied implementation. Proposed approaches include explicit reload boundaries, dependency tracking and recompilation, or coordinated replacement of optimization units.

The conversation distinguishes compatible implementation replacement, explicit state migration, and protocol evolution. Starting with the first is a proposed scope reduction; the more advanced mechanisms are not established requirements or demonstrated capabilities.

### Challenges and open questions

- Where is the safe replacement point, and what happens to suspended frames, queued messages, and in-flight commands?
- How are old code generations retained and eventually reclaimed?
- Which optimized dependants must be rebuilt or switched together?
- Does a failed replacement leave the old implementation active? What can still be rolled back after external effects occur?
- What compatibility is promised separately for source, behavior, ABI, service protocols, persisted data, and timing evidence?
- Can a refinement strengthen guarantees without rejecting inputs that existing callers were entitled to supply?

A proposed first experiment is a running MVU application with a reloadable `update` function, unchanged `Model` and `Msg` types, and replacement only between invocations. Measure latency, dispatch overhead, recompilation, retained generations, repeated reloads, and messages arriving during replacement.

Identical signatures alone do not prove semantic compatibility. For substitutable contracts, the replacement must continue accepting the inputs promised by the old contract and satisfying its output guarantees. More demanding preconditions can break callers even when the type signature stays unchanged.

## The emerging 1.0 position

Separate what must be **stable** from what must be **complete**. A small library, restricted prover, narrow filesystem interface, or limited reload mechanism can be useful if its supported behavior and boundaries are precise.

The most revealing next evidence will come from awkward programs, real failures, resource measurements, and cancellation at difficult moments. Those examples can determine which complexity belongs in the language, libraries, runtime, or foreign implementation, and which complexity is not yet justified.

The working release principle is a conservative foundation with stable semantics, explicit failure behavior, and clearly identified implementation evidence. Further refinement should strengthen that foundation without silently changing the promises on which existing programs rely.

## Source

[Define 1.0 Guarantees](chatgpt-conversation://6afd3301-5330-83ec-b85b-345cac79d2c4). The six organizing questions follow the conversation’s requested consolidation; follow-up questions and proposed experiments retain their exploratory status.
