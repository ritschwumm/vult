(*
The MIT License (MIT)

Copyright (c) 2014 Leonardo Laguna Ruiz

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

(** Template for the Teensy Audio library *)

open Config

let modelicaOutputType m =
   match m with
   | OReal -> "double"
   | OInt -> "int"
   | OBool -> "int"

let modelicaInputType m =
   match m with
   | IReal _ -> "double"
   | IInt _ -> "int"
   | IBool _  -> "int"
   | IContext -> "void *object"

let rec removeContext inputs =
   match inputs with
   | IContext :: t -> removeContext t
   | _ -> inputs

let processArgs (config:config) =
   let return_type, outputs =
      match config.process_outputs with
      | [] -> Pla.string "void", []
      | [typ] -> Pla.string (modelicaOutputType typ), []
      | _ ->
         let outputs =
            config.process_outputs
            |> List.map modelicaOutputType
            |> List.mapi (fun i typ -> {pla|<#typ#s> &out_<#i#i>|pla})
         in
         Pla.string "void", outputs
   in
   let inputs =
      removeContext config.process_inputs
      |> List.map modelicaInputType
      |> List.mapi (fun i typ -> {pla|<#typ#s> in_<#i#i>|pla})
   in
   let args = {pla|void *object|pla}:: inputs @ outputs |> Pla.join_sep Pla.commaspace in
   return_type, args


(** Header function *)
let header (params:params) (code:Pla.t) : Pla.t =
   let file = String.uppercase params.output in
   let output = params.output in
   let ret, args = processArgs params.config in
   {pla|
/* Code automatically generated by Vult https://github.com/modlfo/vult */
#ifndef <#file#s>_H
#define <#file#s>_H

#include <stdint.h>
#include <math.h>
#include "vultin.h"

<#code#>

#if defined(_MSC_VER)
    //  Microsoft VC++
    #define EXPORT __declspec(dllexport)
#else
    //  GCC
    #define EXPORT __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

#include <stdlib.h>

EXPORT void *<#output#s>__constructor();

EXPORT void <#output#s>__destructor(void *object);

EXPORT <#ret#> <#output#s>__process(<#args#>);

EXPORT void <#output#s>__noteOn(void *object, int note, int vel, int channel);

EXPORT void <#output#s>__noteOff(void *object, int note, int channel);

EXPORT void <#output#s>__controlChange(void *object, int control, int value, int channel);

#ifdef __cplusplus
}
#endif

#endif // <#file#s>_H
|pla}


let castType (cast:string) (value:Pla.t) : Pla.t =
   match cast with
   | "float" -> {pla|(float) <#value#>|pla}
   | "int" -> {pla|(int) <#value#>|pla}
   | "bool" -> {pla|(bool) <#value#>|pla}
   | _ ->{pla|<#cast#s>(<#value#>)|pla}

let castInput (params:params) (typ:input) (value:Pla.t) : Pla.t =
   let current_typ = Replacements.getType params.repl (Config.inputTypeString typ) in
   let cast = Replacements.getCast params.repl "float" current_typ in
   castType cast value

let castOutput (params:params) (typ:output) (value:Pla.t) : Pla.t =
   let current_typ = Replacements.getType params.repl (Config.outputTypeString typ) in
   let cast = Replacements.getCast params.repl current_typ "float" in
   castType cast value

let inputName params (i, acc) s =
   match s with
   | IContext -> i, (Pla.string "*data" :: acc)
   | _ -> i + 1, (castInput params s {pla|in_<#i#i>|pla} :: acc)

let processFunctionCall module_name (params:params) (config:config) =
   (* generates the aguments for the process call *)
   let args =
      List.fold_left (inputName params) (0, []) config.process_inputs
      |> snd |> List.rev
      |> (fun a -> if List.length config.process_outputs > 1 then a @ [Pla.string "ret"] else a)
      |> Pla.join_sep Pla.comma
   in
   (* declares the return variable and copies the values to the output buffers *)
   let ret, copy =
      let output_pla a = Pla.string (Config.outputTypeString a) in
      let underscore = Pla.string "_" in
      match config.process_outputs with
      | []  -> Pla.unit, Pla.unit
      | [o] ->
         let current_typ = Replacements.getType params.repl (Config.outputTypeString o) in
         let decl = {pla|<#current_typ#s> ret = |pla} in
         let value = castOutput params o (Pla.string "ret") in
         let copy = {pla|return <#value#>; |pla} in
         decl, copy
      | o ->
         let decl = Pla.(string "_tuple___" ++ map_sep underscore output_pla o ++ string "__ ret; ") in
         let copy =
            List.mapi
               (fun i o ->
                   let value = castOutput params o {pla|ret.field_<#i#i>|pla} in
                   {pla|out_<#i#i> = <#value#>; |pla}) o
            |> Pla.join_sep_all Pla.newline
         in
         decl, copy
   in
   {pla|<#ret#> <#module_name#s>_process(<#args#>); <#><#copy#>|pla}

let getInitDefaultCalls module_name params =
   if  List.exists (fun s -> s = IContext) params.config.process_inputs then
      {pla|<#module_name#s>_process_type|pla},
      {pla|<#module_name#s>_process_init(*data);|pla},
      {pla|<#module_name#s>_default(*data);|pla}
   else
      Pla.string "float", Pla.unit, Pla.unit

let functionInput i =
   match i with
   | IContext -> Pla.string "*data"
   | IReal name | IInt name | IBool name -> {pla|(int)<#name#s>|pla}

let functionInputDecls i =
   match i with
   | IContext -> failwith ""
   | IReal name | IInt name | IBool name -> {pla|int <#name#s>|pla}

let noteFunctions (params:params) main_type =
   let output = params.output in
   let module_name = params.module_name in
   let on_args = Pla.map_sep Pla.comma functionInputDecls (removeContext params.config.noteon_inputs) in
   let off_args = Pla.map_sep Pla.comma functionInputDecls (removeContext params.config.noteoff_inputs) in
   let on_call_args = Pla.map_sep Pla.comma functionInput params.config.noteon_inputs in
   let off_call_args = Pla.map_sep Pla.comma functionInput params.config.noteoff_inputs in
   {pla|
EXPORT void <#output#s>__noteOn(void *object, <#on_args#>){
   <#main_type#> *data = (<#main_type#> *)object;
   if(vel) <#module_name#s>_noteOn(<#on_call_args#>);
   else <#module_name#s>_noteOff(<#off_call_args#>);
}
|pla},
   {pla|
EXPORT void <#output#s>__noteOff(void *object, <#off_args#>) {
   <#main_type#> *data = (<#main_type#> *)object;
   <#module_name#s>_noteOff(<#off_call_args#>);
}
|pla}

let controlChangeFunction (params:params) main_type =
   let output = params.output in
   let module_name = params.module_name in
   let ctrl_args = Pla.map_sep Pla.comma functionInputDecls (removeContext params.config.controlchange_inputs) in
   let ctrl_call_args = Pla.map_sep Pla.comma functionInput params.config.controlchange_inputs in
   {pla|
EXPORT void <#output#s>__controlChange(void *object, <#ctrl_args#>) {
   <#main_type#> *data = (<#main_type#> *)object;
   <#module_name#s>_controlChange(<#ctrl_call_args#>);
}
|pla}

(** Implementation function *)
let implementation (params:params) (code:Pla.t) : Pla.t =
   let output = params.output in
   let module_name = params.module_name in

   let process_call = processFunctionCall module_name params params.config in
   let main_type, init_call, default_call = getInitDefaultCalls module_name params in
   let note_on, note_off = noteFunctions params main_type in
   let ctr_change = controlChangeFunction params main_type in
   let ret, args = processArgs params.config in
   {pla|
/* Code automatically generated by Vult https://github.com/modlfo/vult */
#include "<#output#s>.h"

<#code#>

extern "C" {

EXPORT void *<#output#s>__constructor()
{
   <#main_type#> *data = (<#main_type#> *)malloc(sizeof(<#main_type#>));
   <#init_call#>
   <#default_call#>
   return (void *)data;
}

EXPORT void <#output#s>__destructor(void *object)
{
   <#main_type#> *data = (<#main_type#> *)object;
   free(data);
}

EXPORT <#ret#> <#output#s>__process(<#args#>)
{
   <#main_type#> *data = (<#main_type#> *)object;
   <#process_call#>
}

<#note_on#>

<#note_off#>

<#ctr_change#>

} // extern "C"
|pla}

let cmakeFile (params:params) : Pla.t * FileKind.t =
   let output = params.output in
   {pla|
cmake_minimum_required(VERSION 2.8)
set(CMAKE_BUILD_TYPE Release)

set(CMAKE_INSTALL_PREFIX ${CMAKE_CURRENT_LIST_DIR}/Resources CACHE PATH "Install" FORCE)

set(SRC <#output#s>.cpp <#output#s>.h vultin.c vultin.h)

add_library(<#output#s> SHARED ${SRC})

install(TARGETS <#output#s> DESTINATION Library)
install(FILES vultin.h <#output#s>.h DESTINATION Include)
|pla},
   FileKind.FullName("CMakeLists.txt")

let process_input_output_decl (f:'a -> string) (kind:string) (names:string list) (types:'a list) =
   List.map2
      (fun name typ ->
          let motype = f typ in
          {pla|<#kind#s> <#motype#s> <#name#s>;|pla})
      names types
   |> Pla.join_sep Pla.newline

let getModelica (params:params) : Pla.t * FileKind.t =
   let output = params.output in
   let input_names = List.mapi (fun i _ -> "in" ^ (string_of_int i)) params.config.process_inputs in
   let output_names = List.mapi (fun i _ -> "out" ^ (string_of_int i)) params.config.process_outputs in
   let input_array_names = List.mapi (fun i _ -> "u[" ^ (string_of_int (i+1)) ^ "]") params.config.process_inputs in
   let output_array_names = List.mapi (fun i _ -> "y[" ^ (string_of_int (i+1)) ^ "]") params.config.process_outputs in
   let nin = List.length params.config.process_inputs in
   let nout = List.length params.config.process_outputs in

   let process_ext_call_inputs = "obj" :: input_names |> Pla.map_sep Pla.commaspace Pla.string in

   let process_input_decl = process_input_output_decl modelicaInputType "input" input_names params.config.process_inputs in
   let process_output_decl = process_input_output_decl modelicaOutputType "output" output_names params.config.process_outputs in

   let process_call_inputs = "obj" :: input_array_names |> Pla.map_sep Pla.commaspace Pla.string in
   let process_call_outputs = output_array_names |> Pla.map_sep Pla.commaspace Pla.string |> Pla.parenthesize in

   let ext_calls =
      match nout with
      | 0 -> {pla|<#output#s>__process(<#process_ext_call_inputs#>)|pla}
      | 1 -> {pla|out0 = <#output#s>__process(<#process_ext_call_inputs#>)|pla}
      | _ ->
         let args = "obj" :: input_names@output_names |> Pla.map_sep Pla.commaspace Pla.string in
         {pla|<#output#s>__process(<#args#>)|pla}
   in
   {pla|
package <#output#s>
   model Processor
      parameter Real sampleRate = 44100.0;
      extends Modelica.Blocks.Interfaces.DiscreteMIMO(samplePeriod = 1.0/sampleRate, nin=<#nin#i>, nout=<#nout#i>);
      Internal.<#output#s>Object obj = Internal.<#output#s>Object.constructor();
   equation
      when sampleTrigger then
        <#process_call_outputs#> = Internal.process(<#process_call_inputs#>);
      end when;
   end Processor;

   package Internal
   class <#output#s>Object
      extends ExternalObject;

      function constructor
         output <#output#s>Object obj;
         external "C" obj = <#output#s>__constructor() annotation(Include = "#include \"<#output#s>.h\"", Library = "<#output#s>", IncludeDirectory = "modelica://<#output#s>/Resources/Include", LibraryDirectory = "modelica://<#output#s>/Resources/Library");
      end constructor;

      function destructor
         input <#output#s>Object obj;
         external "C" <#output#s>__destructor(obj) annotation(Include = "#include \"<#output#s>.h\"", Library = "<#output#s>", IncludeDirectory = "modelica://<#output#s>/Resources/Include", LibraryDirectory = "modelica://<#output#s>/Resources/Library");
         end destructor;
   end <#output#s>Object;

   function process
      input <#output#s>Object obj;
<#process_input_decl#>
<#process_output_decl#>
      external "C" <#ext_calls#> annotation(Include = "#include \"<#output#s>.h\"", Library = "<#output#s>", IncludeDirectory = "modelica://<#output#s>/Resources/Include", LibraryDirectory = "modelica://<#output#s>/Resources/Library");
   end process;
   end Internal;
end <#output#s>;
|pla},
   FileKind.FullName(params.output ^ ".mo")


let get (params:params) (header_code:Pla.t) (impl_code:Pla.t) : (Pla.t * FileKind.t) list =
   [
      header params header_code, FileKind.ExtOnly("h");
      implementation params impl_code, FileKind.ExtOnly("cpp");
      cmakeFile params;
      getModelica params;
   ]
