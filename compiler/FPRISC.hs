-- Compatibility facade. New compiler code imports the owning modules directly.
-- Syntax, parsing, lowering, ownership and diagnostics have separate owners.
module FPRISC
  (module Core.Syntax,
   module Frontend.Syntax,
   module Frontend.Lexer,
   module Frontend.Parser,
   module Frontend.Normalize,
   module Frontend.MemoryLayout,
   module Frontend.Paths,
   module Frontend.Desugar,
   module Core.Pretty,
   module Frontend.Traverse,
   module Frontend.Diagnostics,
   module Ownership.Shape,
   module Frontend.Linearity) where
import Core.Syntax
import Frontend.Syntax
import Frontend.Lexer
import Frontend.Parser
import Frontend.Normalize
import Frontend.MemoryLayout
import Frontend.Paths
import Frontend.Desugar
import Core.Pretty
import Frontend.Traverse
import Frontend.Diagnostics
import Ownership.Shape
import Frontend.Linearity
