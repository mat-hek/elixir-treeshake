defmodule Treeshake.Utils.BeamRewriter do
  @moduledoc """
  Low-level utility for rewriting compiled BEAM files by keeping only specific functions.

  Reads the abstract code chunk, converts to core erlang, strips all functions not in the
  keep list (along with their export entries and typespecs), recompiles from core erlang,
  and returns the resulting binary.

  Raises if the BEAM cannot be read, has no `debug_info`, or fails to recompile.
  """

  @doc """
  Keep only `functions` in the BEAM file at `beam_path` and return the new binary.

  `functions` is a list of `{name, arity}` tuples identifying the functions to
  retain. All other functions, their export entries, typespecs, and inline hints
  are removed.

  Raises on any failure (missing file, no debug_info, compile error, etc.).
  """
  @spec keep_funs(Path.t(), [{atom(), non_neg_integer()}]) ::
          {binary(), [{atom(), non_neg_integer()}]}
  def keep_funs(beam_path, functions) do
    to_keep = MapSet.new(functions)

    {module, core} = read_core!(beam_path)

    {:c_module, anno, name, exports, attrs, defs} = core

    {new_defs, removed} =
      Enum.flat_map_reduce(defs, [], fn
        {{:c_var, _, {fname, farity}}, _} = def, acc ->
          if MapSet.member?(to_keep, {fname, farity}),
            do: {[def], acc},
            else: {[], [{fname, farity} | acc]}
      end)

    new_exports =
      Enum.filter(exports, fn {:c_var, _, {fname, farity}} ->
        MapSet.member?(to_keep, {fname, farity})
      end)

    new_attrs = filter_attrs(attrs, to_keep)

    new_core = {:c_module, anno, name, new_exports, new_attrs, new_defs}

    {compile!(module, new_core, beam_path), removed}
  end

  defp read_core!(beam_path) do
    if File.exists?(beam_path <> ".core") do
      core = (beam_path <> ".core") |> File.read!() |> :erlang.binary_to_term()
      module = beam_path |> Path.basename(".beam") |> String.to_atom()
      {module, core}
    else
      case beam_path |> String.to_charlist() |> :beam_lib.chunks([:abstract_code]) do
        {:ok, {module, [abstract_code: {:raw_abstract_v1, abstract_forms}]}} ->
          case :compile.noenv_forms(abstract_forms, [:to_core]) do
            {:ok, ^module, core} ->
              {module, core}

            {:ok, ^module, core, _warnings} ->
              {module, core}

            error ->
              raise "failed to convert #{beam_path} to core erlang: #{inspect(error)}"
          end

        {:ok, {_module, [abstract_code: :no_abstract_code]}} ->
          raise "no abstract code (debug_info) in #{beam_path}"

        {:error, :beam_lib, reason} ->
          raise "failed to read BEAM #{beam_path}: #{inspect(reason)}"

        error ->
          raise "unexpected error reading #{beam_path}: #{inspect(error)}"
      end
    end
  end

  defp compile!(module, core, beam_path) do
    case :compile.noenv_forms(core, [:from_core, :return_errors, :return_warnings, :debug_info]) do
      {:ok, ^module, binary, _warnings} ->
        binary

      {:ok, other_module, _binary, _warnings} ->
        raise "module name mismatch after recompile: expected #{inspect(module)}, got #{inspect(other_module)} (#{beam_path})"

      {:error, errors, _warnings} ->
        raise "recompile failed for #{beam_path}:\n#{format_errors(errors)}"
    end
  end

  defp filter_attrs(attrs, to_keep) do
    Enum.flat_map(attrs, fn
      {{:c_literal, anno_k, :spec}, {:c_literal, anno_v, specs}} when is_list(specs) ->
        # Core Erlang groups all specs into a single list value.
        filtered =
          Enum.filter(specs, fn
            {{fname, farity}, _} -> MapSet.member?(to_keep, {fname, farity})
            _ -> true
          end)

        case filtered do
          [] -> []
          _ -> [{{:c_literal, anno_k, :spec}, {:c_literal, anno_v, filtered}}]
        end

      {{:c_literal, anno_k, :compile}, {:c_literal, anno_v, value}} ->
        [{{:c_literal, anno_k, :compile}, {:c_literal, anno_v, filter_inline(value, to_keep)}}]

      {{:c_literal, anno_k, :dialyzer}, {:c_literal, anno_v, value}} ->
        case filter_dialyzer(value, to_keep) do
          nil -> []
          filtered -> [{{:c_literal, anno_k, :dialyzer}, {:c_literal, anno_v, filtered}}]
        end

      {{:c_literal, anno_k, :deprecated}, {:c_literal, anno_v, entries}} when is_list(entries) ->
        filtered =
          Enum.filter(entries, fn
            {f, a, _reason} -> MapSet.member?(to_keep, {f, a})
            {f, a} -> MapSet.member?(to_keep, {f, a})
            _ -> true
          end)

        [{{:c_literal, anno_k, :deprecated}, {:c_literal, anno_v, filtered}}]

      attr ->
        [attr]
    end)
  end

  # Returns nil to signal "drop the attribute entirely".
  defp filter_dialyzer(atom, _to_keep) when is_atom(atom), do: atom

  defp filter_dialyzer({type, {f, a}}, to_keep) do
    if MapSet.member?(to_keep, {f, a}), do: {type, {f, a}}, else: nil
  end

  defp filter_dialyzer({type, funs}, to_keep) when is_list(funs) do
    case Enum.filter(funs, fn
           {f, a} -> MapSet.member?(to_keep, {f, a})
           _ -> true
         end) do
      [] -> nil
      filtered -> {type, filtered}
    end
  end

  defp filter_dialyzer(entries, to_keep) when is_list(entries) do
    case Enum.flat_map(entries, fn entry ->
           case filter_dialyzer(entry, to_keep) do
             nil -> []
             v -> [v]
           end
         end) do
      [] -> nil
      filtered -> filtered
    end
  end

  defp filter_dialyzer(other, _to_keep), do: other

  defp filter_inline({:inline, inlines}, to_keep) when is_list(inlines) do
    {:inline, Enum.filter(inlines, fn {f, a} -> MapSet.member?(to_keep, {f, a}) end)}
  end

  defp filter_inline({:inline, {f, a}}, to_keep) do
    if MapSet.member?(to_keep, {f, a}), do: {:inline, {f, a}}, else: {:inline, []}
  end

  defp filter_inline(opts, to_keep) when is_list(opts) do
    Enum.map(opts, fn
      {:inline, inlines} when is_list(inlines) ->
        {:inline, Enum.filter(inlines, fn {f, a} -> MapSet.member?(to_keep, {f, a}) end)}

      {:inline, {f, a}} ->
        if MapSet.member?(to_keep, {f, a}), do: {:inline, {f, a}}, else: {:inline, []}

      other ->
        other
    end)
  end

  defp filter_inline(other, _to_keep), do: other

  defp format_errors(errors) do
    inspect(errors)
  end
end
