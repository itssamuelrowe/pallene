package = "titan-v0"
version = "scm-1"
source = {
   url = "git+https://github.com/titan-lang/titan-v0"
}
description = {
   summary = "Initial prototype of the Titan compiler",
   detailed = [[
      Initial prototype of the Titan compiler.
      This is a proof-of-concept, implementing a subset of
      the Titan language.
   ]],
   homepage = "http://github.com/titan-lang/titan-v0",
   license = "MIT"
}
dependencies = {
   "lua ~> 5.3",
   "lpeglabel >= 1.0.0",
   "inspect >= 3.1.0",
   "argparse >= 0.5.0",
}
build = {
   type = "builtin",
   modules = {
      ["titan-compiler.ast"] = "titan-compiler/ast.lua",
      ["titan-compiler.checker"] = "titan-compiler/checker.lua",
      ["titan-compiler.lexer"] = "titan-compiler/lexer.lua",
      ["titan-compiler.parser"] = "titan-compiler/parser.lua"
      ["titan-compiler.symtab"] = "titan-compiler/symtab.lua"
      ["titan-compiler.syntax_errors"] = "titan-compiler/syntax_errors.lua"
      ["titan-compiler.util"] = "titan-compiler/util.lua"
   },
   install = {
      bin = {
         "titanc"
      }
   }
}
