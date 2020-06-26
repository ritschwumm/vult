(*
   The MIT License (MIT)

   Copyright (c) 2020 Leonardo Laguna Ruiz

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

open Prog
open Util.Maps

type state =
  { repeat : bool
  ; ticks : (string, int) Hashtbl.t
  ; stmt_acc : stmt list
  ; function_deps : Set.t Map.t
  ; type_deps : Set.t Map.t
  }

type env =
  { in_if_exp : bool
  ; bound_if : bool
  ; bound_call : bool
  ; current_function : function_def option
  ; current_type : struct_descr option
  ; args : Util.Args.args
  }

let default_state : state =
  { repeat = false; ticks = Hashtbl.create 16; stmt_acc = []; function_deps = Map.empty; type_deps = Map.empty }


let default_env args : env =
  { args; in_if_exp = false; bound_if = false; current_function = None; bound_call = false; current_type = None }


let reapply state = { state with repeat = true }

let setStmts (state : state) stmts = { state with stmt_acc = stmts @ state.stmt_acc }

let getStmts (state : state) = { state with stmt_acc = [] }, state.stmt_acc

let currentFunction env =
  match env.current_function with
  | None -> failwith "not in a function"
  | Some { name; args = (ctx, t, _) :: _; _ } -> name, ctx, t
  | Some _ -> failwith "function has no context"


let getTick (env : env) (state : state) =
  let name =
    match env.current_function with
    | None -> ""
    | Some def -> def.name
  in
  match Hashtbl.find_opt state.ticks name with
  | None ->
      Hashtbl.add state.ticks name 1 ;
      0
  | Some n ->
      Hashtbl.replace state.ticks name (n + 1) ;
      n


module SimpleReplacements = struct
  let exp =
    Mapper.make
    @@ fun env state (e : exp) ->
    match e with
    | { e = ECall { path; args }; t; _ } ->
        let args_t = List.map (fun (e : exp) -> e.t) args in
        begin
          match (Replacements.getFunToFun env.args.code) path args_t t with
          | None -> state, e
          | Some path -> state, { e with e = ECall { path; args } }
        end
    | _ -> state, e


  let mapper = { Mapper.identity with exp }
end

module CollectDependencies = struct
  let initializeDeps map name =
    let set =
      match Map.find_opt name map with
      | None -> Set.empty
      | Some set -> set
    in
    Map.add name set map


  let addFunctionDep (state : state) name dep =
    let set =
      match Map.find_opt name state.function_deps with
      | None -> Set.empty
      | Some set -> set
    in
    let set = Set.add dep set in
    let function_deps = Map.add name set state.function_deps in
    { state with function_deps }


  let addTypeDep (state : state) name dep =
    let set =
      match Map.find_opt name state.type_deps with
      | None -> Set.empty
      | Some set -> set
    in
    let set = Set.add dep set in
    let type_deps = Map.add name set state.type_deps in
    { state with type_deps }


  let exp =
    Mapper.make
    @@ fun env state (e : exp) ->
    match e with
    | { e = ECall { path; _ }; _ } ->
        begin
          match env.current_function with
          | None -> state, e
          | Some def ->
              let state = addFunctionDep state def.name path in
              state, e
        end
    | _ -> state, e


  let type_ =
    Mapper.make
    @@ fun env state (p : type_) ->
    match p with
    | { t = TStruct { path; _ }; _ } ->
        begin
          match env.current_type with
          | None -> state, p
          | Some { path = name; _ } ->
              let state = addTypeDep state name path in
              state, p
        end
    | _ -> state, p


  let top_stmt =
    Mapper.makeExpander
    @@ fun _env state (top : top_stmt) ->
    match top with
    | { top = TopType { path; _ }; _ } ->
        let type_deps = initializeDeps state.type_deps path in
        { state with type_deps }, [ top ]
    | { top = TopFunction ({ name; _ }, _); _ } ->
        let function_deps = initializeDeps state.function_deps name in
        { state with function_deps }, [ top ]
    | _ -> state, [ top ]


  let mapper = { Mapper.identity with exp; type_; top_stmt }
end

module GetVariables = struct
  let exp =
    Mapper.make
    @@ fun _env (state : Set.t) (e : exp) ->
    match e with
    | { e = EId name; _ } -> Set.add name state, e
    | _ -> state, e


  let lexp =
    Mapper.make
    @@ fun _env (state : Set.t) (e : lexp) ->
    match e with
    | { l = LId name; _ } -> Set.add name state, e
    | _ -> state, e


  let mapper = { Mapper.identity with exp; lexp }

  let in_exp (e : exp) =
    let state, _ = Mapper.exp mapper () Set.empty e in
    state


  let in_lexp (e : lexp) =
    let state, _ = Mapper.lexp mapper () Set.empty e in
    state
end

module Location = struct
  let top_stmt_env =
    Mapper.makeEnv
    @@ fun env (s : top_stmt) ->
    match s with
    | { top = TopFunction (def, _); _ } -> { env with current_function = Some def }
    | { top = TopType def; _ } -> { env with current_type = Some def }
    | _ -> env


  let exp_env =
    Mapper.makeEnv
    @@ fun env (e : exp) ->
    match e with
    | { e = EIf _; _ } -> { env with in_if_exp = true }
    | _ -> env


  let mapper = { Mapper.identity with top_stmt_env; exp_env }
end

module IfExpressions = struct
  let stmt_env =
    Mapper.makeEnv
    @@ fun env (s : stmt) ->
    match s with
    | { s = StmtBind (_, { e = EIf _; _ }); _ } -> { env with bound_if = true }
    | { s = StmtReturn { e = EIf _; _ }; _ } -> { env with bound_if = true }
    | _ -> env


  let stmt =
    Mapper.makeExpander
    @@ fun _env state (s : stmt) ->
    match s with
    | { s = StmtBind (lhs, { e = EIf { cond; then_; else_ }; _ }); loc } ->
        let then_ = { s = StmtBind (lhs, then_); loc } in
        let else_ = { s = StmtBind (lhs, else_); loc } in
        reapply state, [ { s = StmtIf (cond, then_, Some else_); loc } ]
    | { s = StmtReturn { e = EIf { cond; then_; else_ }; _ }; loc } ->
        let then_ = { s = StmtReturn then_; loc } in
        let else_ = { s = StmtReturn else_; loc } in
        reapply state, [ { s = StmtIf (cond, then_, Some else_); loc } ]
    | _ -> state, [ s ]


  let exp =
    Mapper.make
    @@ fun env state (e : exp) ->
    match e with
    (* Bind if-expressions to a variable *)
    | { e = EIf _; t; loc } when (not env.in_if_exp) && not env.bound_if ->
        let tick = getTick env state in
        let temp = "_if_temp_" ^ string_of_int tick in
        let temp_e = { e = EId temp; t; loc } in
        let decl_stmt = { s = StmtDecl { d = DId (temp, None); t; loc }; loc } in
        let bind_stmt = { s = StmtBind ({ l = LId temp; t; loc }, e); loc } in
        let state = setStmts state [ decl_stmt; bind_stmt ] in
        reapply state, temp_e
    | _ -> state, e


  let mapper = { Mapper.identity with stmt; exp; stmt_env }
end

module Tuples = struct
  let stmt_env =
    Mapper.makeEnv
    @@ fun env (s : stmt) ->
    match s with
    (* Mark bound multi-return functions as bound *)
    | { s = StmtBind (_, { e = ECall _; t = { t = TTuple _; _ }; _ }); _ } -> { env with bound_call = true }
    | _ -> env


  let exp =
    Mapper.make
    @@ fun env state (e : exp) ->
    match e with
    (* bind multi-return function calls *)
    | { e = ECall _; t = { t = TTuple elems; _ } as t; loc } when (not env.bound_call) && not env.in_if_exp ->
        let temp =
          List.map
            (fun (t : type_) ->
              let tick = getTick env state in
              "_call_temp_" ^ string_of_int tick, t)
            elems
        in
        let decl_stmt = List.map (fun (name, t) -> { s = StmtDecl { d = DId (name, None); t; loc }; loc }) temp in
        let temp_l = List.map (fun (name, t) -> { l = LId name; t; loc }) temp in
        let bind_stmt = { s = StmtBind ({ l = LTuple temp_l; t; loc }, e); loc } in
        let state = setStmts state (decl_stmt @ [ bind_stmt ]) in
        let temp_e = List.map (fun (name, t) -> { e = EId name; t; loc }) temp in
        reapply state, { e = ETuple temp_e; t; loc }
    | _ -> state, e


  let stmt =
    Mapper.makeExpander
    @@ fun env state (s : stmt) ->
    match s with
    (* split multiple declarations *)
    | { s = StmtDecl { d = DTuple elems; _ }; loc } ->
        let stmts = List.map (fun d -> { s = StmtDecl d; loc }) elems in
        reapply state, stmts
    (* remove wild declarations *)
    | { s = StmtDecl { d = DWild; _ }; _ } -> reapply state, []
    (* split tuple assings *)
    | { s = StmtBind (({ l = LTuple l_elems; _ } as lhs), ({ e = ETuple r_elems; _ } as rhs)); loc } ->
        let l = GetVariables.in_lexp lhs in
        let r = GetVariables.in_exp rhs in
        let d = Set.inter l r in
        if Set.is_empty d then
          let bindings = List.map2 (fun l r -> { s = StmtBind (l, r); loc }) l_elems r_elems in
          reapply state, bindings
        else
          let temp_list = List.map (fun (l : lexp) -> "_t_temp_" ^ string_of_int (getTick env state), l.t) l_elems in
          let decl = List.map (fun (n, t) -> { s = StmtDecl { d = DId (n, None); loc; t }; loc }) temp_list in
          let bindings1 =
            List.map2
              (fun (l, _) (r : exp) -> { s = StmtBind ({ l = LId l; t = r.t; loc = r.loc }, r); loc })
              temp_list
              r_elems
          in
          let bindings2 =
            List.map2
              (fun (l : lexp) (r, _) -> { s = StmtBind (l, { e = EId r; t = l.t; loc = l.loc }); loc })
              l_elems
              temp_list
          in
          reapply state, decl @ bindings1 @ bindings2
    (* bind multi return calls to the context *)
    | { s = StmtBind (({ l = LTuple elems; _ } as lhs), ({ e = ECall { path; args = ctx :: _ }; loc = rloc; _ } as rhs))
      ; loc
      } ->
        let bindings =
          List.mapi
            (fun i (l : lexp) ->
              let r = { e = EMember (ctx, path ^ "_ret_" ^ string_of_int i); t = l.t; loc = l.loc } in
              { s = StmtBind (l, r); loc })
            elems
        in
        let s = { s = StmtBind ({ lhs with l = LWild }, { rhs with t = { t = TVoid; loc = rloc } }); loc } in
        reapply state, s :: bindings
    | { s = StmtReturn { e = ETuple elems; loc = eloc; _ }; loc } ->
        let name, ctx_name, ctx_t = currentFunction env in
        let ctx = { l = LId ctx_name; t = ctx_t; loc } in
        let bindings =
          List.mapi
            (fun i (r : exp) ->
              let l = { l = LMember (ctx, name ^ "_ret_" ^ string_of_int i); t = r.t; loc = r.loc } in
              { s = StmtBind (l, r); loc })
            elems
        in
        let s = { s = StmtReturn { e = EUnit; t = { t = TVoid; loc }; loc = eloc }; loc } in
        reapply state, bindings @ [ s ]
    | _ -> state, [ s ]


  let top_stmt =
    Mapper.makeExpander
    @@ fun _env state (top : top_stmt) ->
    match top with
    | { top = TopFunction (({ t = args_t, { t = TTuple _; loc = tloc }; _ } as def), body); loc } ->
        let def = { def with t = args_t, { t = TVoid; loc = tloc } } in
        state, [ { top = TopFunction (def, body); loc } ]
    | _ -> state, [ top ]


  let mapper = { Mapper.identity with stmt; stmt_env; exp; top_stmt }
end

module Builtin = struct
  let exp =
    Mapper.make
    @@ fun _env state (e : exp) ->
    match e with
    | { e = ECall { path = "not"; args = [ e1 ] }; loc; _ } ->
        reapply state, { e with e = EOp (OpEq, e1, { e = EBool false; t = { t = TBool; loc }; loc }) }
    | { e = ECall { path = "size"; args = [ { t = { t = TArray (size, _); _ }; _ } ] }; loc; _ } ->
        reapply state, { e with e = EInt size; loc }
    | _ -> state, e


  let mapper = { Mapper.identity with exp }
end

module Simplify = struct
  let exp =
    Mapper.make
    @@ fun _env state e ->
    match e with
    | _ -> state, e


  let mapper = { Mapper.identity with exp }
end

module PrependStmts = struct
  let stmt =
    Mapper.makeExpander
    @@ fun _env state (s : stmt) ->
    match s with
    | _ ->
        let state, pre = getStmts state in
        state, pre @ [ s ]


  let mapper = { Mapper.identity with stmt }
end

module Sort = struct
  let dependencies = Location.mapper |> Mapper.seq CollectDependencies.mapper

  let rec split types functions externals stmts =
    match stmts with
    | [] -> List.rev types, List.rev functions, List.rev externals
    | ({ top = TopType { path; _ }; _ } as h) :: t -> split ((path, h) :: types) functions externals t
    | ({ top = TopFunction ({ name; _ }, _); _ } as h) :: t -> split types ((name, h) :: functions) externals t
    | ({ top = TopExternal _; _ } as h) :: t -> split types functions (h :: externals) t


  let rec sort deps table visited sorted stmts =
    match stmts with
    | [] -> List.rev sorted
    | { top = TopType { path = name; _ }; _ } :: t
     |{ top = TopFunction ({ name; _ }, _); _ } :: t
     |{ top = TopExternal ({ name; _ }, _); _ } :: t ->
        let visited, sorted = pullIn deps table visited sorted name in
        sort deps table visited sorted t


  and pullIn deps table visited sorted name =
    if Set.mem name visited then
      visited, sorted
    else
      match Map.find_opt name deps with
      | None ->
          let visited = Set.add name visited in
          visited, sorted
      | Some dep_set ->
          let visited = Set.add name visited in
          let missing = Set.filter (fun name -> not (Set.mem name visited)) dep_set in
          let visited, sorted =
            Set.fold (fun name (visited, sorted) -> pullIn deps table visited sorted name) missing (visited, sorted)
          in
          let stmt = Map.find name table in
          visited, stmt :: sorted


  let getDependencies args prog =
    let state, _ = Mapper.prog dependencies (default_env args) default_state prog in
    state.type_deps, state.function_deps


  let run args prog =
    let type_deps, function_deps = getDependencies args prog in
    let types, functions, externals = split [] [] [] prog in
    let type_table = Map.of_list types in
    let functions_table = Map.of_list functions in
    let types = sort type_deps type_table Set.empty [] (List.map snd types) in
    let functions = sort function_deps functions_table Set.empty [] (List.map snd functions) in
    types @ externals @ functions
end

let passes =
  Location.mapper
  |> Mapper.seq Builtin.mapper
  |> Mapper.seq IfExpressions.mapper
  |> Mapper.seq Tuples.mapper
  |> Mapper.seq Simplify.mapper
  |> Mapper.seq PrependStmts.mapper
  |> Mapper.seq SimpleReplacements.mapper


let apply env state prog =
  let rec loop state prog n =
    if n > 20 then
      prog
    else
      let state, prog = Mapper.prog passes env state prog in
      if state.repeat then
        loop { state with repeat = false } prog (n + 1)
      else
        prog
  in
  loop state prog 0


let run args (prog : prog) : prog =
  let prog = apply (default_env args) default_state prog in
  let prog = Sort.run args prog in
  prog