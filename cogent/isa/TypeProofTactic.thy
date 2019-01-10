theory TypeProofTactic
  imports TypeTrackingSemantics CogentHelper TermPatternAntiquote
begin

declare [[ML_debugger = true]]

ML {*
datatype goal_type = Simp of thm list | Resolve of thm list | Force of thm list

(* TODO the fact we need to specify all the possible misc goal patterns is a bit of a mess.
  Maybe just default to force with an expanded simpset + timeout when we don't know what to do?
  (and log it?)
  ~ v.jackson / 2018.12.04 *)
fun goal_type_of_term @{term_pat "TypeTrackingSemantics.ttyping _ _ _ _ _"} =
  SOME (Resolve @{thms ttyping.intros(2-) ttyping.intros(1)})
  (* try the default case second, as it resolves with every ttyping (but won't complete most of the time) *)
| goal_type_of_term @{term_pat "Cogent.typing _ _ _ _ _"}               = SOME (Resolve @{thms typing_typing_all.intros})
| goal_type_of_term @{term_pat "ttsplit _ _ _ _ _ _ _"}                 = SOME (Resolve @{thms ttsplitI})
| goal_type_of_term @{term_pat "ttsplit_inner _ _ _ _ _"}               = SOME (Resolve @{thms ttsplit_innerI})
| goal_type_of_term @{term_pat "Cogent.kinding _ _ _"}                  = SOME (Simp @{thms kinding_defs})
| goal_type_of_term @{term_pat "ttsplit_triv _ _ _ _ _"}                = SOME (Simp @{thms ttsplit_triv_def})
| goal_type_of_term @{term_pat "\<not> composite_anormal_expr _"}            = SOME (Simp @{thms composite_anormal_expr_def})
| goal_type_of_term @{term_pat "weakening _ _ _"}                       = SOME (Force @{thms kinding_def weakening_Cons weakening_nil weakening_comp.simps Cogent.empty_def})
| goal_type_of_term @{term_pat "is_consumed _ _"}                       = SOME (Force @{thms kinding_def weakening_Cons weakening_nil weakening_comp.simps Cogent.empty_def})
| goal_type_of_term @{term_pat "tsk_split_comp _ _ _ _ _"}              = SOME (Force @{thms tsk_split_comp.simps})
| goal_type_of_term @{term_pat "type_wellformed_pretty _ _"}            = SOME (Simp [])

| goal_type_of_term @{term_pat "HOL.Ex _"}                              = SOME (Force [])
| goal_type_of_term @{term_pat "_ \<and> _"}                                 = SOME (Force [])
| goal_type_of_term @{term_pat "_ = _"}                                 = SOME (Force [])
| goal_type_of_term @{term_pat "_ < _"}                                 = SOME (Force [])
| goal_type_of_term @{term_pat "_ \<in> _"}                                 = SOME (Force [])
| goal_type_of_term @{term_pat "distinct _"}                            = SOME (Force [])
| goal_type_of_term @{term_pat "list_all _ _"}                          = SOME (Force [])
| goal_type_of_term @{term_pat "list_all2 _ _ _"}                       = SOME (Force [])
| goal_type_of_term _                                                   = NONE


fun tactic_of_goal_type ctxt (Resolve thms) = resolve_tac ctxt thms 1 
| tactic_of_goal_type ctxt (Simp thms) =
  CHANGED (Simplifier.asm_full_simp_tac (fold Simplifier.add_simp thms ctxt) 1)
| tactic_of_goal_type ctxt (Force thms) = (force_tac (fold Simplifier.add_simp thms ctxt)) 1


(* TODO n.b. this approach only works because we never encounter a proof like
  \<open>False \<Longrightarrow> False\<close> where we can't show the premise is true (and thus vacuous + removable).
  I don't think we should encounter this, but make certain we don't.
  ~ v.jackson / 2018.12.04 *)

datatype proof_status =
  ProofDone of thm
(*
need this eventually for branching
(* a subgoal is a goal which we apply to the main goal after it gets solved, to eliminate schemantic
  variables in the goal for future subgoals *)
| ProofSubgoal of thm
*)
| ProofFailed of {
  goal : thm, (* the overall goal of the current proof *)
  failed : proof_status tree (* the subgoal which failed *)
}
| ProofUnexpectedTerm of thm

fun strip_trueprop @{term_pat "HOL.Trueprop ?t"} = t
| strip_trueprop _ = raise ERROR "strip_trueprop passed something which wasn't a Trueprop"

(* take a goal, and try to solve the first hypothesis using simp *)
fun quicksolve_goal ctxt goal =
  if Thm.nprems_of goal = 0
  then NONE
  else (case Seq.pull (Simplifier.simp_tac ctxt 1 goal) of
    SOME (goal, _) => SOME goal
  | NONE => NONE)

(* solve_typeproof takes a proposition term and solves it by recursively solving the term tree *)
fun solve_typeproof ctxt (Const ("HOL.Trueprop", @{typ "bool \<Rightarrow> prop"}) $ t_rest) : proof_status tree =
  let
    val t_start = (Const ("HOL.Trueprop", @{typ "bool \<Rightarrow> prop"}) $ t_rest);
    val goal =
         Thm.cterm_of ctxt t_start
      |> Goal.init
      |> Simplifier.simp_tac ctxt 1
      |> Seq.pull
      |> (the #> fst);
  in
    case goal_type_of_term t_rest of
      SOME goal_type =>
        let
          val results = goal |> tactic_of_goal_type ctxt goal_type
          (* TODO more principled handling of tactic results *)
          val goal' = (case Seq.pull results of
              SOME (goal, _) => goal
            | NONE => raise ERROR ("solve_typing_goal: failed on " ^ (@{make_string} (Thm.cterm_of ctxt t_start))))
          in
            solve_typeproof_subgoals ctxt goal' []
          end
      | NONE =>
        (* we don't know what this is. Try to simplify it *)
        (case Seq.pull (Simplifier.simp_tac ctxt 1 goal) of
          SOME (goal, _) => Tree { value = ProofDone goal, branches = [] }
        | NONE => Tree { value = ProofUnexpectedTerm goal, branches = [] })
  end
| solve_typeproof _ _ = raise ERROR "solve_typeproof was not passed a Trueprop!"
(* iteratively solve the subgoals, unifying as we go *)
and solve_typeproof_subgoals ctxt goal (solved_subgoals_rev : proof_status tree list) : proof_status tree = 
  case Thm.prems_of goal of
    (t_subgoal :: _) =>
      (case goal_type_of_term (strip_trueprop t_subgoal) of
        SOME (Simp thms) =>
        let
          val simp_solns =
             goal
            |> SOLVED' (Simplifier.asm_full_simp_tac (fold Simplifier.add_simp thms ctxt)) 1
          val goal' =
            (case Seq.pull simp_solns of
              SOME (goal', _) => goal'
            | NONE => raise ERROR ("(solve_typeproof) failed to simplify subgoal: " ^ @{make_string} (Thm.cprem_of goal 1)))
        in
          solve_typeproof_subgoals ctxt goal' solved_subgoals_rev
        end
      | SOME (Resolve _) =>
        (* TODO duplicates some of the work of solve_typeproof. Deduplicate *)
        let
          (* solve the subgoal *)
          val solved_subgoal = solve_typeproof ctxt t_subgoal
        in
          (case tree_value solved_subgoal of
            ProofDone thm_subgoal =>
              (* solved the subgoal, resolve it with the goal to make the goal smaller *)
              let
                (* resolve solution of the subgoal with the goal to make the goal smaller *)
                val goal' =
                  case Seq.pull (resolve_tac ctxt [thm_subgoal] 1 goal) of
                    SOME (thm_soln, _) => thm_soln
                  | NONE => (* this shouldn't happen! *)
                    raise ERROR ("failed to unify subgoal (" ^ @{make_string} goal ^ ") with solved subgoal: " ^ (@{make_string} thm_subgoal))
              in
                solve_typeproof_subgoals ctxt goal' (solved_subgoal :: solved_subgoals_rev)
              end
          | _ =>
            (* if the subgoal fails, the goal fails too *)
            Tree { value = ProofFailed { goal = goal, failed = solved_subgoal }, branches = rev solved_subgoals_rev })
        end
      | SOME (Force thms) =>
        let
          val force_solns =
            goal
            |> SOLVED' (force_tac (fold Simplifier.add_simp thms ctxt)) 1
          val goal' =
            (case Seq.pull force_solns of
              SOME (goal', _) => goal'
            | NONE => raise ERROR ("(solve_typeproof) failed to force subgoal: " ^ @{make_string} (Thm.cprem_of goal 1)))
        in
          solve_typeproof_subgoals ctxt goal' solved_subgoals_rev
        end
      | NONE => if strip_trueprop t_subgoal = @{term "HOL.False"} then raise ERROR ("Encountered unprovable goal: " ^ @{make_string} goal)
                else raise ERROR ("Don't know what to do with: " ^ @{make_string} (Thm.cprem_of goal 1)))
  (* no more subgoals, we've solved the goal *)
  | [] => Tree { value = ProofDone (Goal.finish ctxt goal), branches = rev solved_subgoals_rev }

(* trace the last unsolved subgoal *)
fun trace_typeproof (Tree { value = ProofFailed { goal = _, failed = failed_subgoal }, branches = _ }) =
  trace_typeproof failed_subgoal
| trace_typeproof (Tree { value = ProofUnexpectedTerm goal, branches = _ } : proof_status tree) =
  (@{print tracing} goal ; ())
| trace_typeproof (Tree { value = _, branches = _ } : proof_status tree) = ()



fun get_typing_tree2 ctxt f : thm tree =
  let val abbrev_defs = Proof_Context.get_thms ctxt "abbreviated_type_defs"
                        handle ERROR _ => [];
      (* generate a simpset of all the definitions of the `f` function, type, and typetree *)
      val defs = maps (Proof_Context.get_thms ctxt)
                   (map (prefix f) ["_def", "_type_def", "_typetree_def"] @ ["replicate_unfold"])
                 @ abbrev_defs;
      val main_goal = (Syntax.read_term ctxt
         ("Trueprop (\<Xi>, fst " ^ f ^ "_type, (" ^ f ^ "_typetree, [Some (fst (snd " ^ f ^ "_type))])" ^
          "            T\<turnstile> " ^ f ^ " : snd (snd " ^ f ^ "_type))"));
  in
    solve_typeproof (fold Simplifier.add_simp defs ctxt) main_goal
    |> tree_map (fn v =>
      case v of
        ProofDone tr => tr
      | _ => error ("(get_typing_tree2) failed for function " ^ f))
  end
*}

end