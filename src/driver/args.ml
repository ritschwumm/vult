(*
   The MIT License (MIT)

   Copyright (c) 2017 Leonardo Laguna Ruiz

   Permission is hereby granted, free of charge, to any person obtaining a copy
   of this software and associated documentation files (the "Software"), to deal
   in the Software without restriction, including without limitation the rights
   to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
   copies of the Software, and to permit persons to whom the Software is
   furnished to do so, subject to the following conditions:

   The above copyright notice and this permission notice shall be included in
   all copies or substantial portions of the Software.

   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
   IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
   FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
   AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
   LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
   OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
   THE SOFTWARE.
*)

open Util

type file_path =
  | ExtOnly  of string
  | FullName of string

type input =
  | File of string
  | Code of string * string
[@@deriving show, eq, ord]

type output =
  | Version       of string
  | Message       of string
  | Dependencies  of string list
  | ParsedCode    of string
  | GeneratedCode of (Pla.t * file_path) list
  | Interpret     of string
  | CheckOk
  | Errors        of Error.t list

type code =
  | NoCode
  | CCode
  | JSCode
  | LuaCode
  | JavaCode
[@@deriving show, eq, ord]

(** Stores the options passed to the command line *)
type args =
  { mutable files : input list
  ; mutable dparse : bool
  ; mutable eval : bool
  ; mutable check : bool
  ; mutable code : code
  ; mutable output : string
  ; mutable real : string
  ; mutable template : string
  ; mutable show_version : bool
  ; mutable includes : string list
  ; mutable deps : bool
  ; mutable fs : float option
  ; mutable tables : bool
  ; mutable roots : string list
  ; mutable shorten : bool
  ; mutable mac : bool
  ; mutable force_write : bool
  ; mutable prefix : string
  }
[@@deriving show, eq, ord]

let default_arguments : args =
  { files = []
  ; dparse = false
  ; code = NoCode
  ; eval = false
  ; check = false
  ; output = ""
  ; real = "float"
  ; template = "default"
  ; show_version = false
  ; includes = []
  ; deps = false
  ; fs = None
  ; tables = true
  ; roots = []
  ; shorten = false
  ; mac = false
  ; force_write = false
  ; prefix = ""
  }


type flags =
  { flag : string
  ; action : Arg.spec
  ; comment : string
  }

let flags result =
  [ { flag = "-ccode"
    ; action = Arg.Unit (fun () -> result.code <- CCode)
    ; comment = " Converts the code to c (default: off)"
    }
  ; { flag = "-javacode"
    ; action =
        Arg.String
          (fun prefix ->
            result.code <- JavaCode ;
            result.prefix <- prefix)
    ; comment =
        "prefix Converts the code to java (default: off). Requires prefix to name the package. e.g. 'com.company'"
    }
  ; { flag = "-jscode"
    ; action = Arg.Unit (fun () -> result.code <- JSCode)
    ; comment = " Converts the code to javascript (default: off)"
    }
  ; { flag = "-luacode"
    ; action = Arg.Unit (fun () -> result.code <- LuaCode)
    ; comment = " Converts the code to lua (default: off)"
    }
  ; { flag = "-check"
    ; action = Arg.Unit (fun () -> result.check <- true)
    ; comment = " Checks the code without generating any code (default: off)"
    }
  ; { flag = "-o"
    ; action = Arg.String (fun output -> result.output <- output)
    ; comment = "output Defines the prefix of the output files"
    }
  ; { flag = "-force-write"
    ; action = Arg.Unit (fun () -> result.force_write <- true)
    ; comment = " Writes the generated files even if they are the same (default: off)"
    }
  ; { flag = "-real"
    ; action = Arg.String (fun real -> result.real <- real)
    ; comment = " Defines the numeric type for the generated code: double, fixed"
    }
  ; { flag = "-samplerate"
    ; action = Arg.Float (fun fs -> result.fs <- Some fs)
    ; comment = "number When set, the function samplerate() is evaluated"
    }
  ; { flag = "-template"
    ; action = Arg.String (fun temp -> result.template <- temp)
    ; comment = "name Defines the template used to generate code (ccode only): pd, teensy"
    }
  ; { flag = "-eval"; action = Arg.Unit (fun () -> result.eval <- true); comment = " Runs the code (default: off)" }
  ; { flag = "-tables"
    ; action = Arg.Bool (fun b -> result.tables <- b)
    ; comment = " Create lookup tables (default: on)"
    }
  ; { flag = "-shorten"
    ; action = Arg.Unit (fun () -> result.shorten <- true)
    ; comment = " Creates short function names (default: off)"
    }
  ; { flag = "-mac"
    ; action = Arg.Unit (fun () -> result.mac <- true)
    ; comment = " Generates mac() function calls (default: off)"
    }
  ; { flag = "-i"
    ; action = Arg.String (fun path -> result.includes <- path :: result.includes)
    ; comment = "path Adds the given path to the list of places to look for modules"
    }
  ; { flag = "-root"
    ; action = Arg.String (fun id -> result.roots <- id :: result.roots)
    ; comment = "id Performs code cleanup keeping as roots the specified functions"
    }
  ; { flag = "-test"
    ; action = Arg.Unit (fun () -> Float.reduce_precision := true)
    ; comment = " Enters a special mode useful only for testing (default: off)"
    }
  ; { flag = "-dparse"
    ; action = Arg.Unit (fun () -> result.dparse <- true)
    ; comment = " Dumps the parse tree (default: off)"
    }
  ; { flag = "-deps"; action = Arg.Unit (fun () -> result.deps <- true); comment = " Prints all file dependencies" }
  ; { flag = "-version"
    ; action = Arg.Unit (fun () -> result.show_version <- true)
    ; comment = " Show the version of vult"
    }
  ]


(** Returns a 'arguments' type containing the options passed in the command line *)
let processArguments () : args =
  let result = { default_arguments with files = [] } in
  let opts = List.map (fun f -> f.flag, f.action, f.comment) (flags result) |> Arg.align in
  let _ =
    Arg.parse opts (fun a -> result.files <- File a :: result.files) "Usage: vultc file.vult [options]\noptions:"
  in
  let () = result.files <- List.rev result.files in
  result