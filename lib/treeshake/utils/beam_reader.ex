defmodule Treeshake.Utils.BeamReader do
  @moduledoc """
  Reads core erlang from a BEAM file and extracts metadata about its functions.
  """

  defmodule FunctionInfo do
    @moduledoc false
    defstruct [:name, :arity, :public, :calls, :potential_modules, matching_terms: []]
  end

  @type name_arity :: {atom(), non_neg_integer()}
  @type local_call :: {nil, atom(), non_neg_integer()}
  @type remote_call :: {atom(), atom(), non_neg_integer()}

  @type module_info :: %{
          module: atom(),
          functions: [FunctionInfo.t()],
          abstraction: {:behaviour | :protocol, [name_arity()]} | nil,
          behaviour_impls: [atom()],
          protocol_impl: [{atom(), atom()}]
        }

  @doc """
  Reads a BEAM file and returns metadata about its functions.

  For each function the returned `FunctionInfo` struct contains:
    * `:name` / `:arity` — identity
    * `:public` — `true` when exported
    * `:calls` — list of `{module, fun, arity}` tuples for all statically
      visible call sites (local calls have `module == nil`) and hardcoded
      MFA tuples
    * `:potential_modules` — hardcoded atom literals that may be module
      references (atoms not already consumed as the `m` or `f` part of a
      call or MFA tuple)
    * `:matching_terms` — values collected by `filter`

  The filter receives **reconstructed shapes**: tuple and list literals are
  structurally reconstructed into Elixir values; non-literal sub-expressions
  (variables, calls, …) are kept as raw AST nodes within them. Scalar literals
  are passed as their plain Elixir value (`:ok`, `1`, …). The filter should
  return `{:match, value}` to collect `value`, or anything else to skip.

  Enumerating a `FunctionInfo` iterates over its `matching_terms`.

  `:abstraction` is `{:protocol, callbacks}` for `defprotocol` modules,
  `{:behaviour, callbacks}` for behaviour definitions, and `nil` otherwise.
  `:protocol_impl` is non-empty only for `defimpl` modules.

  Returns `{:ok, module_info()}` or `:error`.
  """
  @spec read(Path.t(), (term() -> {:match, term()} | term())) :: {:ok, module_info()} | :error
  def read(beam_path, filter \\ nil) do
    if File.exists?(beam_path <> ".core") do
      core = (beam_path <> ".core") |> File.read!() |> :erlang.binary_to_term()
      module = beam_path |> Path.basename(".beam") |> String.to_atom()
      do_read(module, core, filter)
    else
      case get_forms(beam_path) do
        {:ok, module, core} ->
          do_read(module, core, filter)

        :error ->
          :error
      end
    end
  end

  def read!(beam_path, filter \\ nil) do
    case read(beam_path, filter) do
      {:ok, info} -> info
      :error -> raise "Couldn't read abstract code of #{beam_path}"
    end
  end

  defp do_read(module, core, filter) do
    exports = collect_exports(core)
    callbacks = collect_callbacks(core)
    protocol_impl = collect_protocol_impl(core)
    behaviours = collect_behaviours(core)

    # Protocol implementations have a :behaviour attr pointing to the protocol,
    # but that is already captured in protocol_impl — exclude it from behaviour_impls.
    behaviours =
      case protocol_impl do
        {protocol, _type} -> List.delete(behaviours, protocol)
        nil -> behaviours
      end

    is_protocol = protocol_definition?(core)
    functions = collect_functions(core, exports, filter)

    abstraction =
      cond do
        is_protocol -> {:protocol, callbacks}
        callbacks != [] -> {:behaviour, callbacks}
        true -> nil
      end

    {:ok,
     %{
       module: module,
       functions: functions,
       abstraction: abstraction,
       behaviour_impls: behaviours,
       protocol_impl: protocol_impl
     }}
  end

  # ---- private helpers ----

  def get_forms(beam_path) do
    case :beam_lib.chunks(String.to_charlist(beam_path), [:abstract_code]) do
      {:ok, {module, [{:abstract_code, {:raw_abstract_v1, abstract_forms}}]}} ->
        case :compile.noenv_forms(abstract_forms, [:to_core]) do
          {:ok, ^module, core} -> {:ok, module, core}
          {:ok, ^module, core, _warnings} -> {:ok, module, core}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp collect_exports({:c_module, _, _, exports, _, _}) do
    exports
    |> Enum.map(fn {:c_var, _, {name, arity}} -> {name, arity} end)
    |> MapSet.new()
  end

  defp collect_callbacks({:c_module, _, _, _, attrs, _}) do
    # Core Erlang groups all attrs with the same key; callbacks value is a list.
    Enum.flat_map(attrs, fn
      {{:c_literal, _, :callback}, {:c_literal, _, cbs}} when is_list(cbs) ->
        for {{name, arity}, _} <- cbs, do: {name, arity}

      _ ->
        []
    end)
  end

  defp collect_behaviours({:c_module, _, _, _, attrs, _}) do
    # Core Erlang groups all behaviour attrs into a single list value.
    Enum.flat_map(attrs, fn
      {{:c_literal, _, :behaviour}, {:c_literal, _, behs}} when is_list(behs) ->
        Enum.filter(behs, &is_atom/1)

      _ ->
        []
    end)
  end

  # Elixir protocol implementations do not use a :protocol_impl attribute.
  # Instead, the compiler generates a __impl__/1 function with two clauses:
  #   def __impl__(:for),      do: ForType
  #   def __impl__(:protocol), do: ProtocolModule
  defp protocol_definition?({:c_module, _, _, _, _, defs}) do
    Enum.any?(defs, fn
      {{:c_var, _, {:__protocol__, 1}}, _} -> true
      _ -> false
    end)
  end

  defp collect_protocol_impl({:c_module, _, _, _, _, defs}) do
    protocol_impl =
      Enum.find(defs, fn
        {{:c_var, _, {:__impl__, 1}}, _} -> true
        _ -> false
      end)

    with {_, {:c_fun, _, _, body}} <- protocol_impl do
      protocol = find_impl_value(body, :protocol)
      for_type = find_impl_value(body, :for)
      if protocol && for_type, do: {protocol, for_type}, else: nil
    end
  end

  defp find_impl_value({:c_case, _, _, clauses}, key) do
    Enum.find_value(clauses, fn
      {:c_clause, _, [{:c_literal, _, ^key}], _, {:c_literal, _, val}} when is_atom(val) -> val
      _ -> nil
    end)
  end

  defp find_impl_value(_, _), do: nil

  defp collect_functions({:c_module, _, _, _, _, defs}, exports, filter) do
    defs
    |> Enum.reject(fn {{:c_var, _, {name, arity}}, _} ->
      name == :module_info and arity in [0, 1]
    end)
    |> Enum.map(fn {{:c_var, _, {name, arity}}, fun_body} ->
      # Letrec-defined helper functions (e.g. "lc$^0") are local to this function
      # body; calls to them should not appear in the call graph (they're not
      # module-level private functions and don't exist as separate graph nodes).
      letrec_names = collect_letrec_names(fun_body)

      {calls, potential_modules} =
        fun_body
        |> collect_calls()
        |> Enum.reject(fn
          {nil, fname, farity} -> MapSet.member?(letrec_names, {fname, farity})
          _ -> false
        end)
        |> Enum.uniq()
        |> Enum.split_with(&is_tuple/1)

      %FunctionInfo{
        name: name,
        arity: arity,
        public: MapSet.member?(exports, {name, arity}),
        calls: calls,
        potential_modules: potential_modules,
        matching_terms: collect_matching_terms(fun_body, filter) |> Enum.uniq()
      }
    end)
  end

  # Collects the names of all functions defined by c_letrec nodes within a body.
  defp collect_letrec_names({:c_letrec, _, defs, body}) do
    local =
      Enum.map(defs, fn {{:c_var, _, {name, arity}}, _} -> {name, arity} end)
      |> MapSet.new()

    nested =
      Enum.reduce(defs, MapSet.new(), fn {_, fun_body}, acc ->
        MapSet.union(acc, collect_letrec_names(fun_body))
      end)

    MapSet.union(MapSet.union(local, nested), collect_letrec_names(body))
  end

  defp collect_letrec_names(form) when is_tuple(form) do
    form
    |> Tuple.to_list()
    |> Enum.reduce(MapSet.new(), fn elem, acc -> MapSet.union(acc, collect_letrec_names(elem)) end)
  end

  defp collect_letrec_names([head | tail]) do
    MapSet.union(collect_letrec_names(head), collect_letrec_names(tail))
  end

  defp collect_letrec_names(_), do: MapSet.new()

  # ---- call collection ----

  defp collect_calls([head | tail]), do: collect_calls(head) ++ collect_calls(tail)
  defp collect_calls([]), do: []

  # Functions of the form remote_mod:fun(M, F, Args, ...) where M and F are atom
  # literals and Args is the argument list — extract as a static call to M:F/arity.
  # Covers erlang:spawn/3, erlang:spawn_link/3, erlang:apply/3,
  # erlang:spawn_opt/4, proc_lib:start*/3-5, proc_lib:spawn*/3-5, etc.
  @mfa_callers %{
    erlang: [:spawn, :spawn_link, :apply],
    proc_lib: [:start, :start_link, :start_monitor, :spawn, :spawn_link, :spawn_opt, :spawn_mon]
  }

  defp collect_calls(
         {:c_call, _, {:c_literal, _, mod}, {:c_literal, _, fun},
          [{:c_literal, _, m}, {:c_literal, _, f}, args_expr | rest] = all_args}
       )
       when is_atom(m) and is_atom(f) and is_map_key(@mfa_callers, mod) do
    funs = Map.fetch!(@mfa_callers, mod)

    if fun in funs do
      own =
        case count_list(args_expr) do
          {:ok, arity} -> [{m, f, arity}]
          :error -> []
        end

      [{mod, fun, length(all_args)}] ++ own ++ collect_calls(args_expr) ++ collect_calls(rest)
    else
      [{mod, fun, length(all_args)}] ++ collect_calls(all_args)
    end
  end

  # Remote call: Mod.fun(args)
  defp collect_calls({:c_call, _, {:c_literal, _, mod}, {:c_literal, _, fun}, args})
       when is_atom(mod) and is_atom(fun) do
    [{mod, fun, length(args)}] ++ collect_calls(args)
  end

  # Remote call through variable/expression
  defp collect_calls({:c_call, _, mod_expr, fun_expr, args}) do
    collect_calls(mod_expr) ++ collect_calls(fun_expr) ++ collect_calls(args)
  end

  # Local apply to a known function variable
  defp collect_calls({:c_apply, _, {:c_var, _, {name, arity}}, args})
       when is_atom(name) and is_integer(arity) do
    [{nil, name, arity}] ++ collect_calls(args)
  end

  # Local apply through a variable or expression
  defp collect_calls({:c_apply, _, fun_expr, args}) do
    collect_calls(fun_expr) ++ collect_calls(args)
  end

  # Local function variable reference (higher-order / capture)
  defp collect_calls({:c_var, _, {name, arity}})
       when is_atom(name) and is_integer(arity) do
    [{nil, name, arity}]
  end

  # Hardcoded MFA tuple as a Core Erlang tuple node:
  # {:c_tuple, _, [c_literal(m), c_literal(f), arity_expr]}
  defp collect_calls({:c_tuple, _, [{:c_literal, _, m}, {:c_literal, _, f}, arity_expr]})
       when is_atom(m) and is_atom(f) do
    own =
      case mfa_arity(arity_expr) do
        {:ok, arity} -> [{m, f, arity}]
        :error -> []
      end

    own ++ collect_calls(arity_expr)
  end

  # Hardcoded MFA tuple folded into a c_literal by the compiler:
  # {:c_literal, _, {m, f, arity}} — arity may be an integer or an argument list
  defp collect_calls({:c_literal, _, {m, f, arity}})
       when is_atom(m) and is_atom(f) and is_integer(arity) and arity >= 0 do
    [{m, f, arity}]
  end

  # MFA with argument list rather than integer arity: {m, f, [arg1, ...]}
  defp collect_calls({:c_literal, _, {m, f, args}})
       when is_atom(m) and is_atom(f) and is_list(args) do
    [{m, f, length(args)}]
  end

  # Atom literal — may be a module reference used in dynamic dispatch.
  defp collect_calls({:c_literal, _, v}) when is_atom(v), do: [v]

  # Literal list/map/tuple — collect any atoms nested inside (e.g. supervisor
  # child-spec maps or [HelloPopcorn] passed to Supervisor.start_link/2 get
  # folded into a single c_literal by the compiler, making individual atom
  # nodes invisible to the generic traversal).
  defp collect_calls({:c_literal, _, v}) do
    collect_literal_atoms(v)
  end

  # Case/function clause: only collect from the body, not from patterns or guard.
  # Atoms used as pattern match literals or guard values are not module
  # references and must not pollute potential_modules.
  defp collect_calls({:c_clause, _, _patterns, _guard, body}) do
    collect_calls(body)
  end

  # c_letrec: skip the function variable names in the definitions — they are
  # local definitions, not call sites. Process only the function bodies and the
  # outer continuation body.
  defp collect_calls({:c_letrec, _, defs, body}) do
    Enum.flat_map(defs, fn {_fun_var, fun_body} -> collect_calls(fun_body) end) ++
      collect_calls(body)
  end

  defp collect_calls(form) when is_tuple(form) do
    form |> Tuple.to_list() |> collect_calls()
  end

  defp collect_calls(_), do: []

  defp collect_literal_atoms(atom) when is_atom(atom), do: [atom]

  defp collect_literal_atoms([head | tail]),
    do: collect_literal_atoms(head) ++ collect_literal_atoms(tail)

  defp collect_literal_atoms([]), do: []

  defp collect_literal_atoms(map) when is_map(map) do
    map
    |> Map.to_list()
    |> Enum.flat_map(fn {k, v} -> collect_literal_atoms(k) ++ collect_literal_atoms(v) end)
  end

  # Detect MFA tuples nested inside complex literals (e.g. supervisor child specs
  # folded into a single c_literal by the compiler).
  defp collect_literal_atoms({m, f, arity})
       when is_atom(m) and is_atom(f) and is_integer(arity) and arity >= 0,
       do: [{m, f, arity}]

  defp collect_literal_atoms({m, f, args})
       when is_atom(m) and is_atom(f) and is_list(args),
       do: [{m, f, length(args)}]

  defp collect_literal_atoms(tuple) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.flat_map(&collect_literal_atoms/1)
  end

  defp collect_literal_atoms(_), do: []

  defp mfa_arity({:c_literal, _, a}) when is_integer(a) and a >= 0, do: {:ok, a}

  defp mfa_arity(list_expr) do
    count_list(list_expr)
  end

  defp count_list({:c_literal, _, []}), do: {:ok, 0}
  defp count_list({:c_literal, _, list}) when is_list(list), do: {:ok, length(list)}

  defp count_list({:c_cons, _, _head, tail}) do
    case count_list(tail) do
      {:ok, n} -> {:ok, n + 1}
      :error -> :error
    end
  end

  defp count_list(_), do: :error

  # ---- term collection ----

  # Each AST node is reconstructed into its "shape" (tuples and lists are
  # structurally built; non-literal leaves stay as raw AST nodes), then passed
  # to the filter.  Traversal always continues into children so every sub-term
  # is checked independently.

  defp collect_matching_terms(_forms, nil) do
    []
  end

  defp collect_matching_terms([head | tail], filter),
    do: collect_matching_terms(head, filter) ++ collect_matching_terms(tail, filter)

  defp collect_matching_terms([], _filter), do: []

  defp collect_matching_terms(form, filter) when is_tuple(form) do
    own =
      case filter.(reconstruct_shape(form)) do
        {:match, value} -> [value]
        _ -> []
      end

    own ++ (form |> Tuple.to_list() |> collect_matching_terms(filter))
  end

  defp collect_matching_terms(_, _), do: []

  # ---- shape reconstruction ----

  # Literals resolve to their plain Elixir value.
  defp reconstruct_shape({:c_literal, _, v}), do: v

  # Lists: each element is reconstructed; non-literal elements stay as raw AST.
  defp reconstruct_shape({:c_cons, _, head, tail}),
    do: [reconstruct_shape(head) | reconstruct_shape_tail(tail)]

  # Tuples: each child is reconstructed; non-literal children stay as raw AST.
  defp reconstruct_shape({:c_tuple, _, children}),
    do: children |> Enum.map(&reconstruct_shape/1) |> List.to_tuple()

  # Everything else (variables, calls, …) is kept as-is.
  defp reconstruct_shape(other), do: other

  defp reconstruct_shape_tail({:c_literal, _, []}), do: []

  defp reconstruct_shape_tail({:c_cons, _, head, tail}),
    do: [reconstruct_shape(head) | reconstruct_shape_tail(tail)]

  # Improper list tail — wrap in a list so the result is always a proper list.
  defp reconstruct_shape_tail(other), do: [reconstruct_shape(other)]
end
