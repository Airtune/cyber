func foo(a pointer):
    pass
foo(123)

--cytest: error
--CompileError: Can not find compatible function for call: `foo(int)`.
--Functions named `foo` in `main`:
--    func foo(pointer) dynamic
--
--main:3:5:
--foo(123)
--    ^
--