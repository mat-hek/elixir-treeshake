defmodule Treeshake.Utils.BeamReader do
  @moduledoc """
  Reads abstract code from a BEAM file and extracts metadata about its functions.
  """

  defmodule FunctionInfo do
    @moduledoc false
    defstruct [:name, :arity, :public, :calls, :potential_modules, matching_terms: []]

    # Enumerating a FunctionInfo iterates over its matching_terms, so callers
    # can write `Enum.find(function_info, fn {M, f, a} -> ... end)`.
    defimpl Enumerable do
      def count(%{matching_terms: terms}), do: {:ok, length(terms)}
      def member?(%{matching_terms: terms}, el), do: {:ok, el in terms}

      def reduce(%{matching_terms: terms}, acc, fun),
        do: Enumerable.List.reduce(terms, acc, fun)

      def slice(%{matching_terms: terms}) do
        size = length(terms)
        {:ok, size, fn i, n -> Enum.slice(terms, i, n) end}
      end
    end
  end

  @type name_arity :: {atom(), non_neg_integer()}
  @type local_call :: {nil, atom(), non_neg_integer()}
  @type remote_call :: {atom(), atom(), non_neg_integer()}

  @type module_info :: %{
          module: atom(),
          functions: [FunctionInfo.t()],
          is_protocol: boolean(),
          behaviour_callbacks: [name_arity()],
          behaviour_impls: [atom()],
          protocol_impls: [{atom(), atom()}],
          protocol_callbacks: [name_arity()]
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

  All result maps always contain `:callbacks`, `:behaviours`,
  `:implemented_protocols`, and `:protocol_callbacks` — each is an empty list
  when not applicable. `:protocol_callbacks` is non-empty only for `defprotocol`
  modules; `:implemented_protocols` is non-empty only for `defimpl` modules.

  Returns `{:ok, module_info()}` or `:error`.
  """
  @spec read(Path.t(), (term() -> {:match, term()} | term())) :: {:ok, module_info()} | :error
  def read(beam_path, filter \\ nil) do
    case get_forms(beam_path) do
      {:ok, module, forms} ->
        exports = collect_exports(forms)
        callbacks = collect_callbacks(forms)
        behaviours = collect_behaviours(forms)
        protocol_impls = collect_protocol_impls(forms)
        is_protocol = protocol_definition?(forms)
        functions = collect_functions(forms, exports, filter)

        {:ok,
         %{
           module: module,
           functions: functions,
           is_protocol: is_protocol,
           behaviour_callbacks: if(is_protocol, do: [], else: callbacks),
           behaviour_impls: behaviours,
           protocol_impls: protocol_impls,
           protocol_callbacks: if(is_protocol, do: callbacks, else: [])
         }}

      :error ->
        :error
    end
  end

  def read!(beam_path, filter \\ nil) do
    case read(beam_path, filter) do
      {:ok, info} -> info
      :error -> raise "Couldn't read abstract code of #{beam_path}"
    end
  end

  # ---- private helpers ----

  def get_forms(beam_path) do
    case :beam_lib.chunks(String.to_charlist(beam_path), [:abstract_code]) do
      {:ok, {module, [{:abstract_code, {:raw_abstract_v1, forms}}]}} ->
        {:ok, module, forms}

      _ ->
        :error
    end
  end

  defp collect_exports(forms) do
    Enum.reduce(forms, MapSet.new(), fn
      {:attribute, _, :export, exports}, acc -> MapSet.union(acc, MapSet.new(exports))
      _, acc -> acc
    end)
  end

  defp collect_callbacks(forms) do
    Enum.flat_map(forms, fn
      {:attribute, _, :callback, {{name, arity}, _}} -> [{name, arity}]
      _ -> []
    end)
  end

  defp collect_behaviours(forms) do
    Enum.flat_map(forms, fn
      {:attribute, _, :behaviour, beh} -> [beh]
      _ -> []
    end)
  end

  # Elixir protocol implementations do not use a :protocol_impl attribute.
  # Instead, the compiler generates a __impl__/1 function with two clauses:
  #   def __impl__(:for),      do: ForType
  #   def __impl__(:protocol), do: ProtocolModule
  defp protocol_definition?(forms) do
    Enum.any?(forms, &match?({:function, _, :__protocol__, 1, _}, &1))
  end

  defp collect_protocol_impls(forms) do
    case Enum.find(forms, &match?({:function, _, :__impl__, 1, _}, &1)) do
      {:function, _, :__impl__, 1, clauses} ->
        protocol = extract_impl_clause(clauses, :protocol)
        for_type = extract_impl_clause(clauses, :for)
        if protocol && for_type, do: [{protocol, for_type}], else: []

      nil ->
        []
    end
  end

  defp extract_impl_clause(clauses, key) do
    Enum.find_value(clauses, fn
      {:clause, _, [{:atom, _, ^key}], [], [{:atom, _, value}]} -> value
      _ -> nil
    end)
  end

  defp collect_functions(forms, exports, filter) do
    Enum.flat_map(forms, fn
      {:function, _, name, arity, clauses} ->
        {calls, potential_modules} =
          clauses
          |> collect_calls()
          |> Enum.uniq()
          |> Enum.split_with(&is_tuple/1)

        [
          %FunctionInfo{
            name: name,
            arity: arity,
            public: MapSet.member?(exports, {name, arity}),
            calls: calls,
            potential_modules: potential_modules,
            matching_terms: collect_matching_terms(clauses, filter) |> Enum.uniq()
          }
        ]

      _ ->
        []
    end)
  end

  # ---- call collection ----

  defp collect_calls(forms) when is_list(forms) do
    Enum.flat_map(forms, &collect_calls/1)
  end

  # Remote call: Mod.fun(args)
  defp collect_calls({:call, _, {:remote, _, {:atom, _, mod}, {:atom, _, fun}}, args}) do
    [{mod, fun, length(args)}] ++ collect_calls(args)
  end

  # Local call: fun(args)
  defp collect_calls({:call, _, {:atom, _, name}, args}) do
    [{nil, name, length(args)}] ++ collect_calls(args)
  end

  # &Mod.fun/arity
  defp collect_calls({:fun, _, {:function, mod, fun, arity}})
       when is_atom(mod) and is_atom(fun) and is_integer(arity) do
    [{mod, fun, arity}]
  end

  # &fun/arity (local capture)
  defp collect_calls({:fun, _, {:function, name, arity}}) do
    [{nil, name, arity}]
  end

  # Call through a variable or complex expression — recurse into args only
  defp collect_calls({:call, _, _fun_expr, args}) do
    collect_calls(args)
  end

  # Hardcoded MFA tuple: {Mod, :fun, arity} or {Mod, :fun, [args]}
  # Only recurse into arity_form — m and f are consumed by the MFA tuple itself
  # and must not also appear as plain atom references.
  defp collect_calls({:tuple, _, [{:atom, _, m}, {:atom, _, f}, arity_form]})
       when is_atom(m) and is_atom(f) do
    own =
      case mfa_arity(arity_form) do
        {:ok, arity} -> [{m, f, arity}]
        :error -> []
      end

    own ++ collect_calls(arity_form)
  end

  # Hardcoded atom literal — may be a module reference used in dynamic dispatch.
  defp collect_calls({:atom, _, v}) when is_atom(v), do: [v]

  defp collect_calls(form) when is_tuple(form) do
    form |> Tuple.to_list() |> collect_calls()
  end

  defp collect_calls(_), do: []

  defp mfa_arity({:integer, _, a}) when is_integer(a) and a >= 0, do: {:ok, a}

  defp mfa_arity(list_form) do
    count_list(list_form)
  end

  defp count_list({nil, _}), do: {:ok, 0}

  defp count_list({:cons, _, _head, tail}) do
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

  defp collect_matching_terms(forms, filter) when is_list(forms) do
    Enum.flat_map(forms, &collect_matching_terms(&1, filter))
  end

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

  # Scalars resolve to their plain Elixir value.
  defp reconstruct_shape({:atom, _, v}), do: v
  defp reconstruct_shape({:integer, _, v}), do: v
  defp reconstruct_shape({:float, _, v}), do: v
  defp reconstruct_shape({:string, _, v}), do: v
  defp reconstruct_shape({:char, _, v}), do: v
  defp reconstruct_shape({nil, _}), do: []

  # Lists: each element is reconstructed; non-literal elements stay as raw AST.
  defp reconstruct_shape({:cons, _, head, tail}),
    do: [reconstruct_shape(head) | reconstruct_shape_tail(tail)]

  # Tuples: each child is reconstructed; non-literal children stay as raw AST.
  defp reconstruct_shape({:tuple, _, children}),
    do: children |> Enum.map(&reconstruct_shape/1) |> List.to_tuple()

  # Everything else (variables, calls, …) is kept as-is.
  defp reconstruct_shape(other), do: other

  defp reconstruct_shape_tail({nil, _}), do: []

  defp reconstruct_shape_tail({:cons, _, head, tail}),
    do: [reconstruct_shape(head) | reconstruct_shape_tail(tail)]

  # Improper list tail — wrap in a list so the result is always a proper list.
  defp reconstruct_shape_tail(other), do: [reconstruct_shape(other)]
end
