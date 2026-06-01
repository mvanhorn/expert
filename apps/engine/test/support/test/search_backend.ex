defmodule Engine.Test.SearchBackend do
  @behaviour Engine.Search.Store.Backend

  alias Forge.Search.Indexer.Entry

  def new(_project), do: {:ok, :new}

  def prepare(_backend_result) do
    if entries() == [] do
      {:ok, :empty}
    else
      {:ok, :stale}
    end
  end

  def set_entries(entries) when is_list(entries) do
    :persistent_term.put({__MODULE__, :entries}, entries)
  end

  def entries do
    :persistent_term.get({__MODULE__, :entries}, [])
  end

  def replace_all(new_entries) when is_list(new_entries) do
    set_entries(new_entries)
    :ok
  end

  def delete_by_path(path) do
    {deleted_entries, kept_entries} =
      entries()
      |> Enum.split_with(&(&1.path == path))

    set_entries(kept_entries)

    {:ok, Enum.flat_map(deleted_entries, &List.wrap(&1.id))}
  end

  def insert(new_entries) when is_list(new_entries) do
    set_entries(entries() ++ new_entries)
    :ok
  end

  def reduce(accumulator, reducer_fun) do
    Enum.reduce(entries(), accumulator, fn
      %Entry{} = entry, acc -> reducer_fun.(entry, acc)
      _entry, acc -> acc
    end)
  end

  def find_by_subject(_subject, _type, _subtype), do: []
  def find_by_prefix(_prefix, _type, _subtype), do: []
  def find_by_ids(_ids, _type, _subtype), do: []
  def siblings(_entry), do: []
  def parent(_entry), do: nil
  def structure_for_path(_path), do: :error
  def drop, do: set_entries([])
  def destroy(_project), do: :ok
end
