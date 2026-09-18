# operators.sol — `+ - * /` on YOUR OWN types, with no compiler changes
# and no bespoke helper names.
#
# An operator site resolves by the type of its operands. Int/F64 hit the
# primitives, String and List have their prelude structs, a sig carrier
# projects through the dictionary — and any OTHER concrete type is
# implemented by a global named `<Struct>.<op>` whose first parameter is
# that type. The operator's own signature IS the instance declaration, so
# there is no table to register with and nothing to import: define the
# struct and `a * b` works.

V2 = Type (V2 Int Int).

v2add a b = V2 ax ay = a; V2 bx by = b; V2 (ax + bx) (ay + by).
v2sub a b = V2 ax ay = a; V2 bx by = b; V2 (ax - bx) (ay - by).
v2mul a b = V2 ax ay = a; V2 bx by = b; V2 (ax * bx) (ay * by).
v2show v = V2 x y = v; "({x}, {y})".

# the struct is the surface; the field names ARE the operators
Vec2 = Struct {
  (+) = fn a b -> v2add a b,
  (-) = fn a b -> v2sub a b,
  (*) = fn a b -> v2mul a b
}.

> p = V2 1 2;
  q = V2 10 20;
  u1 = print "p + q     = {v2show (p + q)}";
  u2 = print "q - p     = {v2show (q - p)}";
  u3 = print "p * q     = {v2show (p * q)}";
  print "(p + q) * p = {v2show ((p + q) * p)}".

# the same site machinery still resolves the builtin cases, unchanged
> joined = "rail" + "way";
  ints = 2 + 3 * 4;
  lists = [1, 2] + [3];
  u1 = print "ints:   {ints}";
  u2 = print "string: {joined}";
  print "list:   {lists}".
