if true: foo = 123: foo = 234

--cytest: error
--ParseError: Expected end of line or file. Got colon.
--
--main:1:19:
--if true: foo = 123: foo = 234
--                  ^
--