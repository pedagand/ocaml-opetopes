(*
 *  tree.ml - infinite dim'l trees in ocaml
 *)

open Applicative
open Traverse
open Monad

type ('a, 'b) gtree = Lf of 'b | Nd of 'a * ('a, 'b) gtree tree
and 'a tree = ('a, unit) gtree

type ('a, 'b) gtree_shell = ('a, 'b) gtree tree
type 'a tree_shell = ('a, unit) gtree_shell

let is_leaf t =
  match t with
    Lf _ -> true
  | Nd (_, _) -> false 

let is_node t =
  match t with
    Lf _ -> false
  | Nd (_, _) -> true 

let rec gtree_map : 'a 'b 'c 'd. ('a -> 'b) -> ('c -> 'd) -> ('a, 'c) gtree -> ('b, 'd) gtree =
  fun f g t -> match t with
               Lf x -> Lf (g x)
             | Nd (a, sh) -> Nd (f a, gtree_map (gtree_map f g) (fun _ -> ()) sh) 

let rec tree_map : 'a 'b. ('a -> 'b) -> 'a tree -> 'b tree =
  fun f t -> gtree_map f (fun _ -> ()) t

let as_shell : 'a 'b. 'a tree -> 'b tree_shell =
  fun t -> tree_map (fun _ -> Lf ()) t

(* Derivatives, Contexts, and Zippers *)
type ('a, 'b) gtree_deriv = TrD of ('a, 'b) gtree_shell * ('a, 'b) gtree_ctxt
 and ('a, 'b) gtree_ctxt = TrG of ('a * (('a, 'b) gtree, unit) gtree_deriv) list

type ('a, 'b) glazy_deriv = ('a, 'b) gtree_deriv Lazy.t
type ('a, 'b) gtree_zipper = ('a, 'b) gtree * ('a, 'b) gtree_ctxt

type 'a tree_deriv = ('a, unit) gtree_deriv
type 'a tree_ctxt = ('a, unit) gtree_ctxt
type 'a lazy_deriv = ('a, unit) glazy_deriv
type 'a tree_zipper = ('a, unit) gtree_zipper

let rec plug_tree_deriv : 'a 'b. ('a, 'b) gtree_deriv -> 'a -> ('a, 'b) gtree =
  fun d a -> match d with
               TrD (sh,g) -> close_tree_ctxt g (Nd (a, sh))
and close_tree_ctxt : 'a 'b. ('a, 'b) gtree_ctxt -> ('a, 'b) gtree -> ('a, 'b) gtree =
  fun c t -> match c with
               TrG [] -> t
             | TrG ((a,d)::gs) -> close_tree_ctxt (TrG gs) (Nd (a, plug_tree_deriv d t))


let mk_deriv : 'a. 'a tree_shell -> 'a tree_deriv =
  fun sh -> TrD (sh, TrG [])

let sh_deriv : 'a 'b. 'a tree -> 'b tree_deriv =
  fun t -> mk_deriv (as_shell t)
         
                     
(* Tree Addresses *)
type dir = Dir of dir list
type addr = dir list

module TreeZipperOps (M: MonadError with type e = string) = struct

  open M

  let focus_of : 'a 'b. ('a, 'b) gtree_zipper -> ('a, 'b) gtree =
    function (fcs, _) -> fcs

  let ctxt_of : 'a 'b. ('a, 'b) gtree_zipper -> ('a * (('a, 'b) gtree, unit) gtree_deriv) list =
    function (_, TrG g) -> g
                
  let mk_zipper : 'a 'b. ('a, 'b) gtree -> ('a, 'b) gtree_zipper =
    fun t -> (t, TrG [])
    
  let close : 'a 'b. ('a, 'b) gtree_zipper -> ('a, 'b) gtree =
    function (fcs, ctxt) -> close_tree_ctxt ctxt fcs

  let close_with : 'a 'b. ('a, 'b) gtree -> ('a, 'b) gtree_zipper -> ('a, 'b) gtree =
    fun t z ->
    match z with
      (_, ctxt) -> close_tree_ctxt ctxt t

  let predecessor : 'a 'b. ('a, 'b) gtree_zipper -> ('a, 'b) gtree_zipper m =
    function
      (fcs, TrG []) -> throw "Zipper has no predecessor"
    | (fcs, TrG ((a, TrD(ts,g))::gs)) ->
       return (Nd (a, close_tree_ctxt g (Nd (fcs, ts))), TrG gs)
                                    
  let rec predecessor_which : 'a 'b. ('a -> bool) -> ('a, 'b) gtree_zipper -> ('a, 'b) gtree_zipper m =
    fun p z ->
    match z with
      (fcs, TrG []) -> throw "Zipper has no predecessor"
    | (fcs, TrG ((a, TrD(ts,g))::gs)) ->
       let pz = (Nd (a, close_tree_ctxt g (Nd (fcs, ts))), TrG gs)
       in if (p a) then return pz else predecessor_which p pz

  let rec visit : 'a 'b. dir -> ('a, 'b) gtree_zipper -> ('a, 'b) gtree_zipper m =
    fun d z ->
    match (focus_of z, d) with
      (Lf _, _) -> throw "Cannot visit a leaf"
    | (Nd (a, sh), Dir ds) ->
       seek ds (mk_zipper sh) >>= function
         (Lf (), _) -> throw "Leaf during visit"
       | (Nd (t, ts), g) ->
          return (t, TrG ((a, TrD(ts, g)) :: ctxt_of z))

  and seek : 'a 'b. addr -> ('a, 'b) gtree_zipper -> ('a, 'b) gtree_zipper m =
    fun a z ->
    match a with
      [] -> return z
    | d :: ds ->
       seek ds z >>= fun zz ->
       visit d zz

  let sibling : dir -> ('a, 'b) gtree_zipper -> ('a, 'b) gtree_zipper m =
    fun d z ->
    match (d, z) with
      (_, (_, TrG [])) -> throw "No sibling in empty context"
    | (Dir dir, (fcs, TrG ((a, TrD (vs, TrG hcn)) :: cs))) ->
       seek dir (mk_zipper vs) >>= fun vzip ->
       match vzip with
         (Lf (), _) -> throw "Leaf in sibling"
       | (Nd (Lf (), _), _) -> throw "Leaf in sibling"
       | (Nd (Nd (nfcs, vrem), hmask), ctxt) ->
          let drv = TrD (vrem, TrG ((fcs, TrD (hmask, ctxt)) :: hcn))
          in return (nfcs, TrG ((a, drv) :: cs))

  let parent : ('a, 'b) gtree_zipper -> ('a, 'b) gtree_zipper m =
    function
      (fcs, TrG []) -> throw "No parent in empty context"
    | (fcs, TrG ((a, d) :: cs)) -> return (Nd (a, plug_tree_deriv d fcs), TrG cs)
       
end

module TraverseImpl (A : Applicative) : LocalBase
       with type 'a t = 'a tree
       with type 'a m = 'a A.m
       with type ta = addr
       with type 'a td = 'a tree_deriv = 
struct

  (* XXX: after generalizing [LocalBase], one could write a generic
  traverse for [gtree] and, therefore [tree] and [nesting] *)

  open A

  type 'a t = 'a tree
  type 'a m = 'a A.m
  type ta = addr
  type 'a td = 'a tree_deriv
             
  type la = addr Lazy.t
  type 'a ld = 'a tree_deriv Lazy.t

  let mkNd a sh = Nd (a, sh)

  (* This traverse version evalutes the address and derivative
       lazily so that we can reuse the same definition and specialize
       to the less-informed traverses
   *)
  let rec lazy_traverse_impl : 'a 'b 'c. la -> ('a -> la -> 'b ld -> 'c m) -> 'a t -> 'c t m =
    fun bs f t ->
    match t with
      Lf () -> return (Lf ())
    | Nd (a, sh) -> let d = lazy (sh_deriv sh)
                    and bt br ldir _ = let laddr = lazy ((Dir (Lazy.force ldir)) :: (Lazy.force bs))
                                       in lazy_traverse_impl laddr f br
                    in mkNd <$> (f a bs d) <*> (lazy_traverse_impl (lazy []) bt sh)

  let lazy_traverse : 'a 'b 'c. ('a -> la -> 'b ld -> 'c m) -> 'a t -> 'c t m =
    fun f t -> lazy_traverse_impl (lazy []) f t
                                  
end

module TreeTraverse (A : Applicative) : LocalTraverse
       with type 'a t = 'a tree
       with type 'a m = 'a A.m
       with type ta = addr
       with type 'a td = 'a tree_deriv
                         = MakeLocal
                             (struct
                               type 'a s = 'a tree
                               type sa = addr
                               type 'a sd = 'a tree_deriv
                             end)(TraverseImpl)(A)

module TreeMatchImpl (M : MonadError with type e = string)
       : MatchBase with type 'a t = 'a tree
       with type 'a m = 'a M.m
       with type ta = addr
       with type 'a td = 'a tree_deriv = struct

  (* XXX: after generalizing [MatchBase], one could write a generic
  traverse for [gtree] and, therefore [tree] and [nesting] *)

  open M
                                  
  type 'a t = 'a tree
  type 'a m = 'a M.m
  type ta = addr
  type 'a td = 'a tree_deriv

  type la = addr Lazy.t
  type 'a ld = 'a tree_deriv Lazy.t
             
  let rec lazy_match_impl : 'a 'b 'c 'd. la -> ('a -> 'b -> la -> 'c ld -> 'd m) -> 'a t -> 'b t -> 'd t m =
    fun la f s t ->
    match (s, t) with
      (Lf (), Lf ()) -> return (Lf ())
    | (Nd (a, ash), Nd (b, bsh)) ->
       let f' sb tb dir drv = let lla = lazy ((Dir (Lazy.force dir)) :: (Lazy.force la))
                              in lazy_match_impl lla f sb tb
       in lazy_match_impl (lazy []) f' ash bsh >>= fun ds ->
          f a b la (lazy (sh_deriv ash)) >>= fun d ->
          return (Nd (d, ds))
    | (_, _) -> throw "Match error"

  let lazy_match : ('a -> 'b -> ta Lazy.t -> 'c td Lazy.t -> 'd m) -> 'a t -> 'b t -> 'd t m =
    fun f s t -> lazy_match_impl (lazy []) f s t

end

module TreeMatch (M : MonadError with type e = string) 
       : MatchTraverse with type 'a t = 'a tree
       with type 'a m = 'a M.m
       with type ta = addr
       with type 'a td = 'a tree_deriv = MakeMatch(M)(TreeMatchImpl(M))

module TreeOps (M: MonadError with type e = string) = struct
  open M
     
  module Z = TreeZipperOps(M)
  open Z
           
  module T = TreeTraverse(M)
  open T

  module TM = TreeMatch(M)
     
  let as_leaf : 'a 'b. ('a, 'b) gtree -> 'b m =
    function
      Lf a -> return a
    | Nd (_, _) -> throw "Leaf force failed"

  let as_node : 'a 'b. ('a, 'b) gtree -> ('a * ('a, 'b) gtree_shell) m =
    function
      Lf _ -> throw "Node force failed"
    | Nd (a, sh) -> return (a, sh)

  let root_value : 'a tree -> 'a m =
    function
      Lf () -> throw "No root value"
    | Nd (a, sh) -> return a

  let seek_to : addr -> 'a tree -> 'a tree_zipper m =
    fun a t -> seek a (mk_zipper t)
             
  let element_at : addr -> 'a tree -> 'a m =
    fun a t -> seek_to a t >>= fun z ->
               root_value (focus_of z)

  let rec split_with : 'a 'b 'c. ('a -> ('b * 'c)) -> 'a tree -> ('b tree * 'c tree) =
    fun f t ->
    match t with
      Lf () -> (Lf (), Lf ())
    | Nd (a, sh) -> let (b , c) = f a in
                    let (bsh, csh) = split_with (split_with f) sh in
                    (Nd (b, bsh) , Nd (c, csh))

  let tree_unzip : 'a 'b. ('a * 'b) tree -> ('a tree * 'b tree) =
    fun t -> split_with (fun p -> p) t
                  
  let rec tree_fold : 'a 'b. (addr -> 'b m) -> ('a -> 'b tree -> 'b m) -> 'a tree -> 'b m =
    fun lr nr t ->
    match t with
      Lf () -> lr []
    | Nd (a, Lf ()) -> nr a (Lf ())
    | Nd (a, Nd (v, hs)) ->

       let unzip_and_join = (* 'a 'b. ('b tree * addr tree) tree -> ('b tree_shell * addr tree) m *)
         fun t -> let (bs, adJn) = tree_unzip t
                  in tree_join adJn >>= fun at -> return (bs, at) in

       let unzip_join_append = (* 'a 'b. ('b tree * addr tree) tree -> 'b m -> ('b tree * addr tree) m *)
         fun t mb -> unzip_and_join t >>= function
                       (bs, at) -> mb >>= fun b -> return (Nd (b, bs), at) in

       let rec fold_pass = (* 'a 'b. 'a tree_shell -> addr -> addr tree_deriv -> ('b tree * addr tree) m *)
         fun h addr d ->
         match h with
           Lf () -> return (Lf (), plug_tree_deriv d addr)
         | Nd (Lf (), hs) -> let f = fun hbr dir deriv -> fold_pass hbr ((Dir dir) :: addr) deriv
                          in  traverse_with_local f hs >>= fun hr ->
                              unzip_join_append hr (lr addr)
         | Nd (Nd (a, vs), hs) -> fold_pass vs addr d >>= function
                                    (bs, at) -> TM.match_with_deriv fold_pass hs at >>= fun mr ->
                                                unzip_join_append mr (nr a bs) in

       let init_horizontal = (* 'a 'b. 'a -> 'a tree_shell tree -> ('b * addr tree) m -> ('b * addr tree) m *)
         fun a h m -> m >>= function (c, at) -> TM.match_with_deriv fold_pass h at >>=
                                                  unzip_and_join >>= function
                                                  (cs, atr) -> nr a (Nd (c, cs)) >>= fun b ->
                                                               return (b , at) in
       
       let rec init_vertical = (* 'a 'b. 'a -> 'a tree -> 'a tree_shell tree -> ('b * addr tree) m *)
         fun a v h ->
         match v with
           Lf () -> let h' = map_with_addr (fun _ dir -> ((Dir dir) :: [])) h
                 in init_horizontal a h (lr [] >>= fun b -> return (b, h'))
         | Nd (aa, Lf ()) -> init_horizontal a h (nr aa (Lf ()) >>= fun b -> return (b, map (fun _ -> []) h))
         | Nd (aa, Nd (vv, hh)) -> init_horizontal a h (init_vertical aa vv hh)

       in init_vertical a v hs >>= function (r, _) -> return r

  and tree_graft : 'a. 'a tree -> 'a tree_shell -> 'a tree m =
    fun t sh -> tree_fold (fun a -> element_at a sh) (fun a ash -> return (Nd (a, ash))) t

  and tree_join : 'a. 'a tree_shell -> 'a tree m =
    function
      Lf () -> return (Lf ())
    | Nd (a, ash) -> traverse tree_join ash >>= fun r ->
                     tree_graft a r
                          
end
