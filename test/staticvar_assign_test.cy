-- Copyright (c) 2023 Cyber (See LICENSE)

import t 'test'

var a: 123

-- Assignment to a static variable.
a = 234
f = func():
    t.eq(a, 234)
try f()

-- Assignment with same name in nested block does not write to static var.
a = 123
f = func():
    a = 234
    t.eq(a, 234)
try f()
t.eq(a, 123)

-- Assignment to static variable inside nested block.
a = 123
f = func():
    static a = 234
    t.eq(a, 234)
try f()
t.eq(a, 234)

-- Subsequent assignment to static variable inside nested block.
a = 123
f = func():
    static a = 234
    a = 345
    t.eq(a, 345)
try f()
t.eq(a, 345)

-- Subsequent assignment to after declared as a static var.
a = 123
f = func ():
    static a
    a = 345
    t.eq(a, 345)
try f()
t.eq(a, 345)

-- Assignment to a static variable before it is declared.
f = func():
    static b = 234
    t.eq(b, 234)
try f()
t.eq(b, 234)
var b: 123

-- Operator assignment to a static variable.
a = 123
a += 321
t.eq(a, 444)