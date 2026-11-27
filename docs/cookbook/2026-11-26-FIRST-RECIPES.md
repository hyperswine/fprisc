# First FP-RISC recipes

Kind: cookbook. Based on the FP-RISC examples at revision `7ed74a6a`.
Save each block as its own `.fpr` file and run it from the FP-RISC checkout.

## Count words in files

Save as `words.fpr`. This is the word-count part of
[examples/wc.fpr](../../examples/wc.fpr). `File.readText` returns a
`Result`, so each path produces a count or a diagnostic. `List.each`
applies the same function to every command-line argument.

```fpr
profile base.
File = use "std/file".
List = use "std/list".
String = use "std/string".
Program = use "std/program".

count path = case File.readText path of
    Ok text -> print "{List.length (String.words text)} {path}"
  | Err why -> Program.writeError "words: {path}: {why}".

main = List.each count (Program.args Unit).
```

```sh
printf 'red green blue\n' > colors.txt
./fpr run words.fpr colors.txt
```

Expected output is `3 colors.txt`. To exercise the error branch, pass a
path that does not exist.

## Match a base case in a function equation

Save as `factorial.fpr`. The definition comes from
[examples/tangnano20k_hello.fpr](../../examples/tangnano20k_hello.fpr).
The first equation matches zero. The second handles other inputs and
recurses with `n - 1`. This example calls it with a small nonnegative
integer. That input restriction is important because a negative value
would move away from the base case.

```fpr
profile base.
fact : unsafe Int -> Int .
fact 0 = 1.
fact n = n * fact (n - 1).

main : unsafe Unit .
main = print "factorial(6)={fact 6}".
```

Run `./fpr run factorial.fpr` for `factorial(6)=720`.

## Update one field in a record

Save as `toggle.fpr`. This extracts the record update from the Tab
handler in [examples/todo.fpr](../../examples/todo.fpr).
`{item | done = not item.done}` constructs an updated record, keeping
its `text` field. The original value is still available.

```fpr
profile base.
Todo = {text : String, done : Bool}.

toggle : Todo -> Todo .
toggle item = {item | done = not item.done}.

main =
  before = {text = "Read the cookbook", done = False};
  after = toggle before;
  print "{after.text}: before={before.done}, after={after.done}".
```

Run `./fpr run toggle.fpr` for
`Read the cookbook: before=False, after=True`.
