'use strict';
// Behavioral summaries for primitives without useful per-name source comments.
// Names and types still come from the compiler, never from this supplement.
// Contracts: compiler/Infer.hs, compiler/Sol/{Infer,VM}.hs, core/prelude.fpr,
// runtime/{actors,runtime,vec,sstr,mod}.c and docs/{2026-10-18-I32,
// 2026-10-05-I64,2026-10-12-INT-OVERFLOW,2026-10-01-TYPED-VECTORS}.md.
const docs = {
  'NativeGit.headLater': 'Plan a read of the repository HEAD commit id (output limit, repository path) to run at commit; return it as a Deferred String. sol/lib/git.sol trims it as Git.headLater.',
  'NativeGit.tagAt': 'Queue creating a tag (output limit, repository path, tag name) at a deferred commit id; the tag is made at commit, after the step that produces the id.',
  'NativeGit.pushLater': 'Queue a push (output limit, repository path, remote, branch) as the terminal publication at commit. Another queued world effect after it is refused.',
  'NativeGit.commitNow': 'Commit already staged changes now (output limit, repository path, author name, email, message) and return Ok commit id or Err. Needs an attached branch and no earlier queued effects; one per attempt, undone on retry by a journaled reference compare-and-swap.',
  'Deferred.out': 'Project the captured stdout of a deferred process result. Resolved at commit; a missing value fails the consuming step.',
  'Deferred.trim': 'Trim surrounding whitespace from a deferred string when it is resolved at commit.',
  'Deferred.line': 'Select a one-based line of a deferred string at commit. A missing line fails the consuming step and fences later external effects.',
  'Deferred.field': 'Split a deferred string on a nonempty separator and select a one-based field at commit. A missing field fails the consuming step.',
  logTo: 'Append the rendered value as a line to a file path after a successful commit. The path joins the transaction lock set; failed or retried attempts write nothing, and symbolic links are refused.',
  'Proc.queryReplayable': 'Run a process now, like Proc.query, and declare that repeating it on a transaction retry is acceptable. It does not check that the command is read-only.',
  BITMASK: 'Build a mask from a bit width and bit offset, in that order.',
  open: 'Open a path as a linear transactional file handle. Thread the handle through reads/writes and close it exactly once.',
  readAll: 'Read all text from a transactional handle and return both the text and successor handle.',
  writeAll: 'Write text through a transactional handle and return its successor.',
  close: 'Consume and close a linear transactional handle.',
  args: 'Return the script command-line arguments; takes Unit.',
  use: 'Load a module by path for use in this program.',
  run: 'Run a loaded Sol module with an argument and return its captured text output.',
  'BStr.new': 'Create an empty linear byte buffer.',
  'BStr.fromStr': 'Copy a String into a new linear byte buffer.',
  'BStr.toStr': 'Consume a linear byte buffer and return its String contents.',
  'BStr.append': 'Append a String to a linear byte buffer and return the successor buffer.',
  'BStr.cat': 'Concatenate string/buffer values, consuming linear buffer inputs.',
  'BStr.len': 'Return byte length and the successor buffer owner.',
  'BStr.at': 'Read a byte at a zero-based index and return its code and the successor buffer owner.',
  'BStr.sub': 'Extract a slice by offset and length, returning the slice buffer and successor original buffer.',
  'BStr.free': 'Consume and release a linear byte buffer.',
  'NativeGit.afterCommit': 'Schedule a typed Git operation to run after the transaction commits, using the supplied admission budget and context.',
  'NativeGit.query': 'Perform a typed Git query under the caller’s budget; return output text or an error.',
  'NativeGit.push': 'Push through the native Git capability under the supplied budget; return output text or an error.',
  'NativeArchive.afterCommit': 'Schedule archive creation after the transaction commits, with explicit caller-supplied limits.',
  'Host.snapshot': 'Read a bounded host snapshot, returning host identity, system, filesystem and process information or an error.',
  heapUsed: 'Return bytes currently used in the actor allocation pool.',
  device: 'Resolve a named device through the selected host/device interface.',
  strCmp: 'Compare byte strings lexicographically, returning a negative, zero or positive integer.',
  'Sys.loop': 'Run step on the current value state until it returns (False, next); return that final state. In AOT, each step uses scratch storage and only the next state survives. Mutable vector ownership belongs in Sys.loopWith.',
  'Sys.loopWith': 'Run a state loop with an explicitly owned linear vector. Each step returns (continue, nextState, nextVector); False ends the loop and returns (state, vector). AOT scratch allocations are reclaimed between steps.',
  'Sys.memInfo': 'Return [arenaKiB, freeKiB, requests, waits, direct, frees, denied, inline] from the runtime memory ledger. Arena/free are zero when no buddy allocator is owned by this process.',
  'Sys.actInfo': 'Return the indexed live actor as [id, status, parent, code], newest first. Status 0 is ready and 1 blocked; out-of-range indexes return an empty list.',
  'Sys.irqBind': 'Bind a device interrupt source to an actor through the interrupt router; inspect the Result for refusal.',
  'Sys.irqUnbind': 'Unbind an interrupt source through the router, preserving its ownership checks.',
  'Sys.logAt': 'Write a log line at the supplied severity through the log service.',
  'Sys.logSeq': 'Read the log service sequence number.',
  'Sys.logSnap': 'Read retained log lines for the requested severity.',
  'Sys.logKeep': 'Change the log service’s retained-line limit.',
  str: 'Render a value as a string. Also used by string interpolation.',
  strcat: 'Concatenate two byte strings, in argument order.',
  strlen: 'Return the length of a string in bytes, not Unicode code points.',
  'String.len': 'Return the length of a string in bytes, not Unicode code points.',
  charAt: 'Read the byte code at a zero-based string offset.',
  chr: 'Construct a single-byte string from a character code.',
  substr: 'Take a substring: string, zero-based byte offset, byte length.',
  strIndexOf: 'Find a needle in a string. Return its zero-based byte offset, or -1 if absent.',
  strIndexFrom: 'Find a needle in a string starting at a zero-based byte offset; return -1 if absent.',
  strReplace: 'Replace occurrences of the first string with the second string in the third string.',
  strUpper: 'Convert ASCII lowercase letters to uppercase; other bytes are preserved.',
  strLower: 'Convert ASCII uppercase letters to lowercase; other bytes are preserved.',
  strTrim: 'Remove whitespace from both ends of a string.',
  strCodes: 'Return the byte codes of a string in order.',
  strJoin: 'Join a list of strings with the separator supplied as the first argument.',
  intMax: 'Return the largest tagged Int on this target. Use Unit as the argument. Int arithmetic traps on overflow; use I32/I64 for explicit wrapping arithmetic in AOT programs.',
  intMin: 'Return the smallest tagged Int on this target. Use Unit as the argument. This value has no positive Int counterpart: negating it overflows.',
  fileRead: 'Read a file into a string through the selected host machine implementation.',
  fileWrite: 'Replace the contents of a file. Return Ok Unit or Err with the host error.',
  fileAppend: 'Append text to a file. Return Ok Unit or Err with the host error.',
  fileExists: 'Test whether a path exists through the host file interface.',
  print: 'Render a value to the program output.',
  error: 'Fail the current computation with the supplied message; never returns a value normally.',
  send: 'Queue a message to an actor. Ok Unit means queued; Err reports refusal such as a full mailbox or dead actor. Check the result before waiting for a reply.',
  sendLinear: 'Send a linear message, transferring its ownership to the receiving actor. Check the Result for enqueue failure.',
  sendArc: 'Send a message through the reference-counted actor transport. Return the enqueue Result.',
  receive: 'Wait for a message in the receiving actor mailbox. In AOT, the returned message is borrowed: keep values that must survive dropping the message.',
  receiveRes: 'Receive a message through the Result-returning mailbox interface. Inspect Ok/Err rather than assuming receipt succeeded.',
  receiveNow: 'Poll the mailbox without blocking. Return Ok message or Err "empty" when no message is queued.',
  receiveFrom: 'Wait for a message from the specified sender, leaving other senders queued. Prefer receiveFromRes when the sender may die.',
  receiveFromRes: 'Wait for a message from the specified sender. Return Ok message, or Err when the sender has died and its queued messages are drained. Other senders remain queued.',
  receiveFromNow: 'Poll for a message from the specified sender without blocking. Return Ok message, Err "empty" while it is alive with no message, or a dead-sender error after its queue drains.',
  spawn: 'Start an actor with an entry function that receives its own actor ID; return the new actor ID.',
  spawnOn: 'Start an actor on the requested hart, passing its actor ID to the entry function.',
  spawnCap: 'Start an actor with mailbox mode and capacity, then its entry function. Mode 0 is a fixed ring; mode 1 allows growth.',
  spawnCapOn: 'Start an actor with hart, mailbox mode, capacity and entry function. Mode 0 is fixed; mode 1 allows growth.',
  spawnHeap: 'Start an actor with an explicit heap grant in bytes and an entry function. Return Ok actor ID or Err if admission fails.',
  myself: 'Return the current actor ID; conventionally called with 0.',
  myPid: 'Return the current process ID; conventionally called with 0.',
  yield: 'Yield execution so another ready actor can run.',
  kill: 'Stop the actor with the supplied actor ID.',
  drop: 'Release a received/owned value when it is no longer needed. Do not reuse a linear value after dropping it.',
  keep: 'Retain a value beyond its current borrowed lifetime, for example before dropping a received message.',
  hartId: 'Return the current hardware worker (hart) index.',
  harts: 'Return the runtime worker count.',
  schedTau: 'Read the scheduler time-slice setting.',
  schedSetTau: 'Set the scheduler time-slice setting.',
  schedMaxWait: 'Read the scheduler maximum-wait statistic.',
  schedSteals: 'Read the scheduler work-stealing statistic.',
  fuelPreempts: 'Read the count of scheduler preemptions caused by exhausted execution fuel.',
  fuelQuantum: 'Read the execution-fuel quantum used by the scheduler.',
  reg8: 'Select an 8-bit device register by device and byte offset for the read/write interface.',
  reg32: 'Select a 32-bit device register by device and byte offset for the read/write interface.',
  f32frombits: 'Construct an F32 from its raw IEEE-754 bit representation. Used by float-literal lowering.',
  f64frombits: 'Construct an F64 from two 32-bit halves of its IEEE-754 bit representation, high half first.',
  'Sys.actLive': 'Return the number of live actors in the runtime.',
  'Sys.stkStats': 'Return runtime stack-usage statistics for inspection.',
  'Sys.harts': 'Return the runtime worker count; takes Unit.',
  'Mod.rows': 'Return the number of exported rows in a module table. Table -1 denotes the current image.',
  'Mod.rowHash': 'Read the identity hash of a module export row, given table and row indexes.',
  'Mod.rowName': 'Read the name of a module export row, given table and row indexes.',
  'Mod.rowIface': 'Read the interface description of a module export row, given table and row indexes.',
  'Mod.rowFn': 'Read the callable value of a module export row. Its use must agree with that row’s interface.',
  'Mod.rowArity': 'Read the argument count of a module export row, given table and row indexes.',
  map: 'Apply a function to every list element, preserving order.',
  filter: 'Keep list elements for which the predicate returns True.',
  foldl: 'Fold a list from left to right with an accumulator function and initial value.',
  'Try.readPath': 'Read a path within the Sol transaction. Return Ok text or Err with the failure, without panicking.',
  timeNow: 'Return the current time through the Sol host clock interface.',
  'Num.sqrt': 'Compute the square root using Sol’s Numeric arithmetic.',
  Unit: 'The sole value of the Unit type, used when no payload is needed.',
  True: 'The true Boolean value.', False: 'The false Boolean value.',
  Nil: 'The empty list. Its element type is inferred from context.',
  Cons: 'Construct a list from its head element and tail list; also written head :: tail.',
  Ok: 'The successful case of Result, containing the result value.',
  Err: 'The failure case of Result, containing the error value.',
};
const bits = { and: 'Bitwise AND', or: 'Bitwise OR', xor: 'Bitwise exclusive OR', not: 'Bitwise complement', neg: 'Wrapping negation', shl: 'Left shift', shr: 'Logical right shift (zero fill)', sar: 'Arithmetic right shift (sign extension)', rotl: 'Rotate left', rotr: 'Rotate right', clz: 'Count leading zero bits', ctz: 'Count trailing zero bits', popcnt: 'Count set bits' };
const integer = {
  '+': 'Add, wrapping on overflow.', '-': 'Subtract, wrapping on overflow.', '*': 'Multiply, wrapping on overflow.',
  '/': 'Signed division, truncating toward zero. Zero divisor and minimum value divided by -1 trap.',
  '<': 'Signed less-than comparison.', '>': 'Signed greater-than comparison.', '<=': 'Signed less-than-or-equal comparison.', '>=': 'Signed greater-than-or-equal comparison.', '==': 'Compare for equality.', '!=': 'Compare for inequality.',
  rem: 'Signed remainder with the dividend’s sign. Zero divisor traps; minimum value remainder -1 is zero.',
  divU: 'Unsigned division of the bit patterns. Zero divisor traps.', remU: 'Unsigned remainder of the bit patterns. Zero divisor traps.',
  ltU: 'Unsigned less-than comparison.', gtU: 'Unsigned greater-than comparison.', leU: 'Unsigned less-than-or-equal comparison.', geU: 'Unsigned greater-than-or-equal comparison.',
  BITMASK: 'Build a mask from a bit width and bit offset, in that order.',
  open: 'Open a path as a linear transactional file handle. Thread the handle through reads/writes and close it exactly once.',
  readAll: 'Read all text from a transactional handle and return both the text and successor handle.',
  writeAll: 'Write text through a transactional handle and return its successor.',
  close: 'Consume and close a linear transactional handle.',
  args: 'Return the script command-line arguments; takes Unit.',
  use: 'Load a module by path for use in this program.',
  run: 'Run a loaded Sol module with an argument and return its captured text output.',
  'BStr.new': 'Create an empty linear byte buffer.',
  'BStr.fromStr': 'Copy a String into a new linear byte buffer.',
  'BStr.toStr': 'Consume a linear byte buffer and return its String contents.',
  'BStr.append': 'Append a String to a linear byte buffer and return the successor buffer.',
  'BStr.cat': 'Concatenate string/buffer values, consuming linear buffer inputs.',
  'BStr.len': 'Return byte length and the successor buffer owner.',
  'BStr.at': 'Read a byte at a zero-based index and return its code and the successor buffer owner.',
  'BStr.sub': 'Extract a slice by offset and length, returning the slice buffer and successor original buffer.',
  'BStr.free': 'Consume and release a linear byte buffer.',
  'NativeGit.afterCommit': 'Schedule a typed Git operation to run after the transaction commits, using the supplied admission budget and context.',
  'NativeGit.query': 'Perform a typed Git query under the caller’s budget; return output text or an error.',
  'NativeGit.push': 'Push through the native Git capability under the supplied budget; return output text or an error.',
  'NativeArchive.afterCommit': 'Schedule archive creation after the transaction commits, with explicit caller-supplied limits.',
  'Host.snapshot': 'Read a bounded host snapshot, returning host identity, system, filesystem and process information or an error.',
  heapUsed: 'Return bytes currently used in the actor allocation pool.',
  device: 'Resolve a named device through the selected host/device interface.',
  strCmp: 'Compare byte strings lexicographically, returning a negative, zero or positive integer.',
  'Sys.loop': 'Run step on the current value state until it returns (False, next); return that final state. In AOT, each step uses scratch storage and only the next state survives. Mutable vector ownership belongs in Sys.loopWith.',
  'Sys.loopWith': 'Run a state loop with an explicitly owned linear vector. Each step returns (continue, nextState, nextVector); False ends the loop and returns (state, vector). AOT scratch allocations are reclaimed between steps.',
  'Sys.memInfo': 'Return [arenaKiB, freeKiB, requests, waits, direct, frees, denied, inline] from the runtime memory ledger. Arena/free are zero when no buddy allocator is owned by this process.',
  'Sys.actInfo': 'Return the indexed live actor as [id, status, parent, code], newest first. Status 0 is ready and 1 blocked; out-of-range indexes return an empty list.',
  'Sys.irqBind': 'Bind a device interrupt source to an actor through the interrupt router; inspect the Result for refusal.',
  'Sys.irqUnbind': 'Unbind an interrupt source through the router, preserving its ownership checks.',
  'Sys.logAt': 'Write a log line at the supplied severity through the log service.',
  'Sys.logSeq': 'Read the log service sequence number.',
  'Sys.logSnap': 'Read retained log lines for the requested severity.',
  'Sys.logKeep': 'Change the log service’s retained-line limit.',
  str: 'Render as signed decimal.', strU: 'Render the bit pattern as unsigned decimal.', hex: 'Render as lowercase hexadecimal without a prefix or padding.',
  parse: 'Parse a bit pattern with optional sign, decimal or 0x hex digits, and underscores between digits. Return Err for malformed or out-of-width values.',
  toInt: 'Convert the signed value to tagged Int; return Err if it does not fit the target’s Int range.',
  toIntU: 'Convert the unsigned bit pattern to tagged Int; return Err if it does not fit the target’s Int range.',
  ofI64: 'Take the low 32 bits of an I64.', toI64: 'Sign-extend the 32-bit value to I64.', toI64U: 'Zero-extend the 32-bit pattern to I64.',
  fromParts: 'Combine high and low unsigned 32-bit Int halves into an I64.', hi: 'Extract the high unsigned 32-bit half as Int.', lo: 'Extract the low unsigned 32-bit half as Int.',
  fromWords: 'Combine high and low 32-bit Word halves into an I64.', hiWord: 'Extract the high 32-bit half as Word.', loWord: 'Extract the low 32-bit half as Word.',
};
const vectors = {
  new: 'Create an empty vector; its element type is inferred from use.',
  newAs: 'Create an empty vector with an explicit runtime layout descriptor.',
  push: 'Append an element and return the successor vector.',
  len: 'Return the element count and the successor vector owner.',
  get: 'Read the element at a zero-based index, returning it with the successor vector owner.',
  at: 'Read the element at a zero-based index, returning it with the successor vector owner.',
  set: 'Replace an element at a zero-based index and return the successor vector.',
  put: 'Replace an element at a zero-based index and return the successor vector.',
  map: 'Apply a function to every element, allowing its type to change. Return the resulting vector.',
  mapSame: 'Apply a same-element-type function to every vector element. This is the native frontend same-type mapping helper.',
  filter: 'Retain elements that satisfy the predicate and return the successor vector.',
  fold: 'Fold elements with an accumulator function and initial value; return the result and the successor vector owner.',
  fromList: 'Construct a vector from list elements in order.',
  toList: 'Consume a vector and return its elements as a list.',
  free: 'Consume and release a vector.',
  dup: 'Create an independent copy and return both linear owners.',
  iota: 'Construct the integer vector 0 through n-1.',
  axpb: 'Transform every integer lane x to a*x+b, with a and b supplied before the vector.',

  range: 'Construct an integer range vector from start (inclusive) to end (inclusive).',
  split: 'Split a vector at the supplied index, returning the two linear vector owners.',
  sar: 'Apply an arithmetic right shift by the supplied count to each integer lane.',
  minS: 'Take the minimum of the scalar and each integer lane.', maxS: 'Take the maximum of the scalar and each integer lane.',
  ges: 'Compare each integer lane against the scalar with greater-than-or-equal, producing mask lanes.',
  zipAdd: 'Add corresponding integer lanes of two vectors.', zipSub: 'Subtract corresponding integer lanes of two vectors.',
  zipMul: 'Multiply corresponding integer lanes of two vectors.', zipDiv: 'Divide corresponding integer lanes of two vectors.',
  zipMin: 'Take the pairwise minimum of two integer vectors.', zipMax: 'Take the pairwise maximum of two integer vectors.',
  zipLt: 'Compare corresponding integer lanes with less-than, producing mask lanes.', zipEq: 'Compare corresponding integer lanes for equality, producing mask lanes.',
  dot: 'Multiply corresponding integer lanes and sum the products.', scale: 'Multiply every integer lane by the supplied scalar.',
  gather: 'Gather lanes by an index vector; return the gathered vector and the retained source owner.',
  blend: 'Select lanes from two integer vectors using a mask vector.', slice: 'Extract a slice by offset and length, returning its vector and the retained source owner.',
  burst: 'Copy a source vector into a destination vector at the supplied offset.', absv: 'Take the absolute value of every integer lane.', eqS: 'Compare each integer lane with the scalar for equality, producing mask lanes.',
};
const sstrings = {
  sstrNew: 'Create an empty fixed-capacity inline string.', sstrLen: 'Return the byte length together with the successor string owner.',
  sstrAt: 'Read a byte at the supplied index, returning its code and the successor string owner.',
  sstrPut: 'Replace the byte at the supplied index and return the successor string owner.',
  sstrPush: 'Append a byte code and return the successor string owner.', sstrFromStr: 'Copy a heap string into the fixed-capacity inline string representation.',
  sstrToStr: 'Return a heap String copy together with the successor inline-string owner.', sstrClear: 'Clear an inline string and return its successor owner.',
};
module.exports = function describe(name, profile) {
  if (profile === 'sol') {
    if (/^spawn(Cap(On)?|On)$/.test(name)) return 'Start a Sol actor using the supplied entry function. The VM accepts but ignores hart placement and mailbox capacity/mode; its actor queues are unbounded.';
    if (name === 'spawnHeap') return 'Start a Sol actor. The heap grant is accepted but not enforced by the VM; admission returns Ok actor ID.';
    if (name === 'Sys.memInfo') return 'Return eight zeros in the Sol compatibility shim; AOT buddy-memory accounting is not implemented by the VM.';
    if (name === 'Sys.loop') return 'Call step with the current state until it returns (False, next); return that final state. Sol uses garbage collection rather than AOT scratch arenas.';
    if (name === 'heapUsed') return 'Return zero in Sol: the VM uses garbage collection rather than an AOT actor pool.';
    if (name === 'f32frombits' || name === 'f64frombits') return 'Decode IEEE float-literal bits into Sol’s Numeric representation.';
    if (name === 'receive') return 'Wait for the next message in the Sol actor mailbox.';
    if (name === 'drop') return 'Compatibility release operation for Sol’s garbage-collected runtime.';
    if (name === 'keep') return 'Preserve the value; Sol’s garbage-collected runtime does not need an AOT borrowed-message copy.';
  }
  if (docs[name]) return docs[name];
  if (sstrings[name]) return sstrings[name] + ' SString is linear and has a fixed 128-byte capacity.';
  if (/^Tup[2-8]$/.test(name)) return `Construct a ${name.slice(3)}-element tuple; ordinary tuple syntax is (a, b, …).`;
  const [family, member] = name.split('.');
  if (family === 'I32' || family === 'I64') {
    const width = family.slice(1);
    if (integer[member]) return integer[member] + ` Uses the distinct ${width}-bit ${family} type; no implicit mixing with Int.`;
    if (member === 'ofInt') return family === 'I32' ? 'Convert Int to I32 by taking its low 32 bits, wrapping.' : 'Convert Int to I64; every tagged Int fits.';
    if (bits[member]) return `${bits[member]} on ${width}-bit values.` + (/^(shl|shr|sar|rotl|rotr)$/.test(member) ? ` The Int count is taken modulo ${width}, including negative counts.` : /^(clz|ctz)$/.test(member) ? ` Zero returns ${width}.` : '');
    if (/^(of|to)F(32|64)Bits$/.test(member)) return 'Reinterpret the IEEE-754 bit pattern without numeric conversion, preserving signed zero and NaN payload bits.';
    if (/^toF(32|64)U?$/.test(member)) return `Convert the ${member.endsWith('U') ? 'unsigned bit pattern' : 'signed integer'} numerically to ${member.slice(2,5)}, with floating-point rounding.`;
    if (/^ofF(32|64)U?$/.test(member)) return `Truncate the float toward zero and check the ${member.endsWith('U') ? 'unsigned' : 'signed'} ${width}-bit range. Return Err for NaN, infinity or out-of-range values.`;
  }
  if (family === 'F32' || family === 'F64') {
    const maths = { sqrt: 'Square root', log: 'Natural logarithm', log2: 'Base-two logarithm', exp: 'Exponential (e raised to the argument)', sin: 'Sine of an angle in radians', cos: 'Cosine of an angle in radians', pow: 'Raise the first argument to the second power', ofInt: 'Convert tagged Int to floating point', toInt: 'Convert floating point to tagged Int', ofF32: 'Widen an F32 to F64', ofF64: 'Round an F64 to F32' };
    if (maths[member]) return `${maths[member]}. Operates in ${family} precision.`;
  }
  if (family === 'Vec' && vectors[member]) return vectors[member] + ' Preserve linear ownership using the returned vector(s); inputs are consumed as shown by the signature.';
  if (family === 'Word' && bits[member]) return `${bits[member]} on an unsigned machine Word.`;
  if (name === 'Word.sub') return 'Subtract unsigned machine words, wrapping at the target word width.';
  if (/^Mem\.(read|write)(16|Word)$/.test(name)) return `${member.startsWith('read') ? 'Read' : 'Write'} ${member.endsWith('16') ? '16 bits' : 'one machine word'} at an Addr. The caller is responsible for valid address, alignment and access permissions.`;
  const bitAliases = { band: 'and', bor: 'or', bxor: 'xor', BITSHIFTL: 'shl', BITSHIFTR: 'shr' };
  if (bitAliases[name]) return bits[bitAliases[name]] + ' on Int bit patterns.';
  const bitFields = { BITSET: 'Set a bit', BITCLEAR: 'Clear a bit', BITTEST: 'Test a bit', BITMASK: 'Build a bit mask' };
  if (bitFields[name]) return bitFields[name] + ' using the supplied Int value and bit position/range.';
  return '';
};
