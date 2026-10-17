# Value semantics all the way through: there is no borrowing

Date: 2026-10-17. Kind: design decision (a living position: later pages
cite it, and a change to it is recorded here with its date). Applies from
revision `ee84d90`. Said here because
[2026-10-17-LINEAR-OWNERSHIP-GAPS.md](2026-10-17-LINEAR-OWNERSHIP-GAPS.md)
lists "constrained borrowing" among the ways to let a function read an
owned record, and
[2026-10-17-OWNERSHIP-POLYMORPHISM.md](2026-10-17-OWNERSHIP-POLYMORPHISM.md)
called the absence of a borrow form a limit. It is neither: it is the
design.

## The decision

FP-RISC has **value semantics end to end**. Binding a value, passing it,
returning it, putting it in a list, record or constructor, and sending it
to another actor all mean the same thing: *this value*. Never "a reference
to that one". A program cannot tell whether two bindings share memory,
because nothing in the language lets it: there is no mutation through a
name, no identity comparison, no address.

There will be **no borrowing scheme**: no borrowed references, no
lifetimes, no regions, no "read-only view of an owner" in the type system,
no observer or uniqueness-with-borrow discipline. Not a simple one either.
The complexity such schemes pay for (reading something without owning it)
is bought here by the two rules below, which are already the language.

## The two rules that replace borrowing

1. **An owned value is a value that cannot be copied.** The linear types
   (`Vector`, `Handle`, `SString`, a user `T 1 = Type (...)`) are not
   references to resources; they are the resource, held as a value exactly
   once. Reading one *hands it back*: `Vec.len : Vector a -> (Int, Vector a)`,
   and the same for `SStr.len`/`at`/`toStr` since
   [VEC.md](2026-08-25-VEC.md) section 7, which also records why a read
   exemption would be unsound (a function that folds and frees would type
   like a read). A function that wants only part of what an owned value
   knows takes that part as a value: an `Int` length, a copied field, a
   disposable snapshot. "Copy on retain" and "never send live state" in
   [MEMORY.md](2026-08-25-MEMORY.md) are the same rule at actor boundaries.

2. **A service owns its linear resource.** (MEMORY.md, the laws.) A
   resource that many places need to ask about lives in one actor, and the
   places hold its address, which is an ordinary unrestricted value. The
   mailbox is the serialization; the questions are messages; the answers
   are values. Nothing is lent.

## What sharing and Rc are, then

Implementation. Under the hood a value may be:

- **structurally shared**: an immutable list, tree, record or constructor
  that two bindings "have" is one allocation with two users, and nothing
  can observe that because nothing can mutate it in place;
- **reference-counted** inside an actor (regime 2 of MEMORY.md), so the
  allocation is freed when its last user is done;
- **promoted and shared across actors** only by the explicit `sendArc`
  (regime 3), frozen at promotion;
- **mutated in place** when it is uniquely owned (regime 1: a Vector
  threaded through its handle), which is the compiler's business, not the
  program's;
- **deep-copied** on `keep`, on a plain `send`, and wherever a value
  must outlive the root it was found in.

None of these appears in a type or changes what a program means. They
change what it costs, and cost is what the `work`/`alloc`/`live` bounds,
the cost pass and the memory register are for. A new mechanism of this
kind is welcome if it keeps that property; one that leaks into the
semantics (a type that says "shared", a value whose identity can be
observed) is not.

## What follows for the ownership checker

- The refusals that look like "no borrowing" are correct and stay:
  `List.length [owner]` is refused because `length` does not give the
  owners back; a function reading `model.running` while `model.proc` is
  an owner is refused because the record is a value that cannot be copied
  and is being used twice. The answer in each case is the shape of the API
  or the data, never a borrow:
  - thread the value back out, `(n, xs)`, as the reads of `Vector` do;
  - keep the resource out of the structure that is read for other reasons:
    the editor's model should hold the address of a process actor, not the
    process (rule 2), and then `model.running` is a plain read of a plain
    value;
  - destructure once, consume every owned field, rebuild what goes on.
- "Constrained borrowing" in the audit page's item 4 is declined.
  Complete destructuring and explicit moves are the whole answer; the
  checker's work is to see through generics, records and closures so that
  those moves are checked, which is what the two batches of 2026-10-17 do.
- `keep` is a deep copy, by name, and not a loophole: it produces a second
  value. Its only special standing is that the copy of a resource handle is
  a second handle to the same resource, which is why it is an escape and is
  audited as one.

## What this rules out, by name

A Rust-style borrow checker with lifetimes; `&`/`&mut` or any reference
type; regions; Clean-style observer types; copy-on-write as a *semantic*
(a program that could ask "was this copied?"); and any proposal whose
motivation is "so that a function can look at an owned value without
taking it". The motivation is granted; the mechanism is rules 1 and 2.
