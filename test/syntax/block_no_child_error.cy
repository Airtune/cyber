if true:
return 123

--cytest: error
--ParseError: Block requires an indented child statement. Use the `pass` statement as a placeholder.
--
--main:2:1:
--return 123
--^
--