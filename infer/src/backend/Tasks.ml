(*
 * Copyright (c) 2017-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd
module L = Logging

type 'a doer = 'a -> unit

type 'a task_generator = 'a ProcessPool.task_generator

let run_sequentially ~(f : 'a doer) (tasks : 'a list) : unit =
  let task_bar = TaskBar.create ~jobs:1 in
  (ProcessPoolState.update_status :=
     fun t status ->
       TaskBar.update_status task_bar ~slot:0 t status ;
       TaskBar.refresh task_bar) ;
  TaskBar.set_tasks_total task_bar (List.length tasks) ;
  TaskBar.tasks_done_reset task_bar ;
  List.iter
    ~f:(fun task -> f task ; TaskBar.tasks_done_add task_bar 1 ; TaskBar.refresh task_bar)
    tasks ;
  TaskBar.finish task_bar


let fork_protect ~f x =
  (* this is needed whenever a new process is started *)
  Epilogues.reset () ;
  EventLogger.prepare () ;
  L.reset_formatters () ;
  ResultsDatabase.new_database_connection () ;
  (* get different streams of random numbers in each fork, in particular to lessen contention in
     `Filename.mk_temp` *)
  Random.self_init () ;
  f x


module Runner = struct
  type 'a t = 'a ProcessPool.t

  let create ~jobs ~f ~tasks =
    PerfEvent.(
      log (fun logger -> log_begin_event logger ~categories:["sys"] ~name:"fork prepare" ())) ;
    ResultsDatabase.db_close () ;
    let pool =
      ProcessPool.create ~jobs ~f ~tasks
        ~child_prelude:
          ((* hack: run post-fork bookkeeping stuff by passing a dummy function to [fork_protect] *)
           fork_protect ~f:(fun () -> ()))
    in
    ResultsDatabase.new_database_connection () ;
    PerfEvent.(log (fun logger -> log_end_event logger ())) ;
    pool


  let run runner ~n_tasks =
    (* Flush here all buffers to avoid passing unflushed data to forked processes, leading to duplication *)
    Pervasives.flush_all () ;
    (* Compact heap before forking *)
    Gc.compact () ;
    ProcessPool.run runner n_tasks
end

let gen_of_list (lst : 'a list) : 'a task_generator =
  let content = ref lst in
  let is_empty () = List.is_empty !content in
  let next _finished_item =
    match !content with
    | [] ->
        None
    | x :: xs ->
        content := xs ;
        Some x
  in
  {is_empty; next}
