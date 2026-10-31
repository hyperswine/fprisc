'use strict';
const assert = require('assert/strict');
const { caseBindings } = require('../server/case-bindings');
function check(source, specs) {
  const lookup = caseBindings(source);
  for (const [word, expected] of Object.entries(specs)) {
    const hits = [...source.matchAll(new RegExp(`\\b${word}\\b`, 'g'))];
    assert.equal(hits.length, expected.length, word + ' fixture count');
    hits.forEach((m, i) => assert.equal(lookup(word, m.index)?.declaration ?? null, expected[i], `${word} occurrence ${i}: ${source}`));
  }
}
check('f x = case x of Ok value -> value | Err problem -> problem.\ng y = value.', {value:[true,false,null],problem:[true,false],Ok:[null],Err:[null]});
check('f x = case x of (head :: tail, [one, two], {field}, (Ok inner)) -> (head, tail, one, two, field, inner) | _ -> head.', {head:[true,false,null],tail:[true,false],one:[true,false],two:[true,false],field:[true,false],inner:[true,false],_:[null],Ok:[null]});
check('f x = case x of Ok outer -> (case outer of Some inner -> inner | None -> outer) | Err err -> outer.', {outer:[true,false,false,null],inner:[true,false],err:[true]});
check('f x = result = case x of Ok item -> item | Err err -> 0; item.', {item:[true,false,null],err:[true]});
check('f x = case x of Ok item -> local = item; local + item | Err err -> item.', {item:[true,false,false,null],err:[true]});
check('f x = case x of Ok str -> str | Err err -> str err.', {str:[true,false,null],err:[true,false]});
check('f x = if x then case x of Ok item -> item else item.', {item:[true,false,null]});
check('f x = "case x of Ok fake -> fake". # case x of Ok fake -> fake\ng x = fake.', {fake:[null,null,null,null,null]});
check('f x = (case x of Ok item -> item, item).', {item:[true,false,null]});
check('f x = case (case x of Ok inner -> inner) of Ok outer -> outer.', {inner:[true,false],outer:[true,false]});
check('f x = case x of Ok (bound : Shape) -> bound.', {bound:[true,false],Shape:[null]});
check('f x = case x of Ok value -> value |> fn n -> n | Err err -> err.', {value:[true,false],err:[true,false]});
console.log('case-bindings: scope regression checks passed');
