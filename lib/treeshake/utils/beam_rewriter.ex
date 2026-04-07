defmodule Treeshake.Utils.BeamRewriter do
  @moduledoc """
  Low-level utility for rewriting compiled BEAM files by keeping only specific functions.

  Reads the abstract code chunk, strips all functions not in the keep list (along
  with their export entries and typespecs), recompiles, and returns the resulting binary.

  Raises if the BEAM cannot be read, has no `debug_info`, or fails to recompile.
  """

  @doc """
  Keep only `functions` in the BEAM file at `beam_path` and return the new binary.

  `functions` is a list of `{name, arity}` tuples identifying the functions to
  retain. All other functions, their export entries, typespecs, and inline hints
  are removed.

  Raises on any failure (missing file, no debug_info, compile error, etc.).
  """
  @spec keep_funs(Path.t(), [{atom(), non_neg_integer()}]) :: {binary(), [{atom(), non_neg_integer()}]}
  def keep_funs(beam_path, functions) do
    to_keep = MapSet.new(functions)

    {module, forms} = read_abstract_code!(beam_path)

    {new_forms, removed} =
      Enum.flat_map_reduce(forms, [], fn
        {:function, _line, name, arity, _clauses} = form, removed ->
          if MapSet.member?(to_keep, {name, arity}),
            do: {[form], removed},
            else: {[], [{name, arity} | removed]}

        {:attribute, line, :export, exports}, removed ->
          filtered = Enum.filter(exports, fn {f, a} -> MapSet.member?(to_keep, {f, a}) end)
          {[{:attribute, line, :export, filtered}], removed}

        {:attribute, _line, :spec, {{name, arity}, _}} = form, removed ->
          if MapSet.member?(to_keep, {name, arity}), do: {[form], removed}, else: {[], removed}

        {:attribute, line, :compile, value}, removed ->
          {[{:attribute, line, :compile, filter_inline(value, to_keep)}], removed}

        form, removed ->
          {[form], removed}
      end)

    {compile!(module, new_forms, beam_path), removed}
  end

  defp read_abstract_code!(beam_path) do
    case beam_path |> String.to_charlist() |> :beam_lib.chunks([:abstract_code]) do
      {:ok, {module, [abstract_code: {:raw_abstract_v1, forms}]}} ->
        {module, forms}

      {:ok, {_module, [abstract_code: :no_abstract_code]}} ->
        raise "no abstract code (debug_info) in #{beam_path}"

      {:error, :beam_lib, reason} ->
        raise "failed to read BEAM #{beam_path}: #{inspect(reason)}"

      error ->
        raise "unexpected error reading #{beam_path}: #{inspect(error)}"
    end
  end

  defp compile!(module, forms, beam_path) do
    case :compile.forms(forms, [:return_errors, :return_warnings, :debug_info]) do
      {:ok, ^module, binary, _warnings} ->
        binary

      {:ok, other_module, _binary, _warnings} ->
        raise "module name mismatch after recompile: expected #{inspect(module)}, got #{inspect(other_module)} (#{beam_path})"

      {:error, errors, _warnings} ->
        raise "recompile failed for #{beam_path}:\n#{format_errors(errors)}"
    end
  end

  defp filter_inline({:inline, inlines}, to_keep) when is_list(inlines) do
    {:inline, Enum.filter(inlines, fn {f, a} -> MapSet.member?(to_keep, {f, a}) end)}
  end

  defp filter_inline(opts, to_keep) when is_list(opts) do
    Enum.map(opts, fn
      {:inline, inlines} ->
        {:inline, Enum.filter(inlines, fn {f, a} -> MapSet.member?(to_keep, {f, a}) end)}

      other ->
        other
    end)
  end

  defp filter_inline(other, _to_keep), do: other

  defp format_errors(errors) do
    Enum.map_join(errors, "\n", fn {file, file_errors} ->
      Enum.map_join(file_errors, "\n", fn {line, mod, desc} ->
        "#{file}:#{line}: #{mod.format_error(desc)}"
      end)
    end)
  end
end
