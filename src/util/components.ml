(*
   The MIT License (MIT)

   Copyright (c) 2016 Leonardo Laguna Ruiz

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

(* This is a naive implementation of the Kosaraju's algorithm to get the strong connected components.
   This module exists in order to not drag a new dependency to OCamlgraph.
*)

(* Graph module *)
module G = struct
   (* main type of a graph *)
   type 'a g =
      { forward : ('a, 'a list) Hashtbl.t
      ; (* forward representation of the graph *)
        backward : ('a, 'a list) Hashtbl.t
      ; (* reversed repesentation of directed graph *)
        vertex : ('a, unit) Hashtbl.t (* set with all the vertex in the graph *)
      }

   (* returns an empty graph *)
   let empty () : 'a g = { forward = Hashtbl.create 8; backward = Hashtbl.create 8; vertex = Hashtbl.create 8 }

   (* adds a graph edge *)
   let addEdge (g : 'a g) (from_v : 'a) (to_v : 'a) : unit =
      let () =
         (* inserts edge from_v to to_v *)
         match Hashtbl.find g.forward from_v with
         | deps -> Hashtbl.replace g.forward from_v (to_v :: deps)
         | exception Not_found -> Hashtbl.add g.forward from_v [ to_v ]
      in
      let () =
         (* inserts edge to_v to from_v *)
         match Hashtbl.find g.backward to_v with
         | deps -> Hashtbl.replace g.backward to_v (from_v :: deps)
         | exception Not_found -> Hashtbl.add g.backward to_v [ from_v ]
      in
      (* adds both vertex to the set *)
      let () = Hashtbl.replace g.vertex from_v () in
      let () = Hashtbl.replace g.vertex to_v () in
      ()


   let addVertex (g : 'a g) (v : 'a) : unit = Hashtbl.replace g.vertex v ()

   (* gets the all vertices pointed by a given vertex *)
   let getDependencies (g : 'a g) (v : 'a) : 'a list =
      match Hashtbl.find g.forward v with
      | deps -> deps
      | exception Not_found -> []


   (* gets the all vertices that point to a given vertex *)
   let getRevDependencies (g : 'a g) (v : 'a) : 'a list =
      match Hashtbl.find g.backward v with
      | deps -> deps
      | exception Not_found -> []


   (* returns a list with all vertices of the graph *)
   let getVertices (g : 'a g) : 'a list = Hashtbl.fold (fun v _ acc -> v :: acc) g.vertex []

   (* makes a graph given a list of the vertices and it's dependencies *)
   let make (e : ('a * 'a list) list) : 'a g =
      let g = empty () in
      let () =
         List.iter
            (fun (v, deps) ->
                addVertex g v ;
                List.iter (addEdge g v) deps )
            e
      in
      g
end

(* imperative stack implementation *)
module S = struct
   (* the stack is represented as a list ref *)
   type 'a t = 'a list ref

   (* creates a new empty stack *)
   let empty () : 'a t = ref []

   (* returns true if the stack is empty *)
   let isEmpty (s : 'a t) : bool = !s = []

   (* inserts an element to the stack *)
   let push (s : 'a t) (e : 'a) : unit = s := e :: !s

   (* returns the first element of the stack *)
   let pop (s : 'a t) : 'a =
      match !s with
      | [] -> failwith "Stack is empty"
      | h :: t ->
         s := t ;
         h


   (* returns a list representation of the stack *)
   let toList (s : 'a t) : 'a list = !s
end

(* trivial implementation of an imperative set *)
module V = struct
   (* the set is represented with a hastable *)
   type 'a t = ('a, unit) Hashtbl.t

   (* returns an empty set *)
   let empty () : 'a t = Hashtbl.create 8

   (* adds an element to the set*)
   let add (t : 'a t) (v : 'a) : unit = Hashtbl.replace t v ()

   (* returns true if the set contains the give element *)
   let contains (t : 'a t) (v : 'a) : bool = Hashtbl.mem t v
end

(* pass one of the Kosaraju's algorithm *)
let rec pass1 g stack visited v =
   if not (V.contains visited v) then
      let () = V.add visited v in
      let children = G.getDependencies g v in
      let () = List.iter (pass1 g stack visited) children in
      S.push stack v


let rec pass2_part g visited comp v =
   if not (V.contains visited v) then
      let deps = G.getRevDependencies g v in
      let () = V.add visited v in
      let () = S.push comp v in
      List.iter (pass2_part g visited comp) deps


let rec pass2 g comps stack visited =
   if not (S.isEmpty stack) then (
      let v = S.pop stack in
      if V.contains visited v then
         pass2 g comps stack visited
      else
         let comp = S.empty () in
         let () = S.push comps comp in
         pass2_part g visited comp v ;
         pass2 g comps stack visited )


(* calculates the strong components of a graph *)
let components (graph : ('a * 'a list) list) : 'a list list =
   let g = G.make graph in
   let stack = S.empty () in
   (* creates a set of visited vertex *)
   let visited = V.empty () in
   (* performs the first pass *)
   let () = List.iter (fun v -> pass1 g stack visited v) (G.getVertices g) in
   (* creates a stack to hold the components *)
   let comps = S.empty () in
   (* creates a new set of visited vertex *)
   let visited = V.empty () in
   (* performs the second pass *)
   pass2 g comps stack visited ;

   (* returns the components as a list of lists *)
   comps |> S.toList |> List.map S.toList
