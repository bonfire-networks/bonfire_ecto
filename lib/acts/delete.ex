defmodule Bonfire.Ecto.Acts.Delete do
  # @moduledoc """
  # An act that marks a changeset or struct for deletion
  # """

  # alias Bonfire.Epics.Act
  alias Bonfire.Epics.Epic

  alias Bonfire.Ecto.Acts.Work
  alias Ecto.Changeset
  import Bonfire.Epics
  use Arrows
  import Untangle
  import Ecto.Query

  @doc """
  Runs the delete act, marking the specified changeset or struct for deletion.

  This function marks an object for deletion based on the `:on` key in the act options.
  If associations are specified for deletion, they will be processed as well.

  ## Parameters

    - `epic` - The epic struct that contains the list of acts to be executed.
    - `act` - The current act being processed.

  ## Examples

      iex> epic = %Epic{assigns: %{some_key: %SomeStruct{}}, errors: []}
      iex> act = %{options: %{on: :some_key}}
      iex> Bonfire.Ecto.Acts.Delete.run(epic, act)
      %Epic{assigns: %{some_key: %SomeStruct{}}, errors: []}

      iex> epic = %Epic{assigns: %{some_key: %SomeStruct{}}, errors: ["error"]}
      iex> act = %{options: %{on: :some_key}}
      iex> Bonfire.Ecto.Acts.Delete.run(epic, act)
      %Epic{assigns: %{some_key: %SomeStruct{}}, errors: ["error"]}

  """
  def run(epic, act) do
    on = act.options[:on]
    object = epic.assigns[on]

    cond do
      epic.errors != [] ->
        maybe_debug(epic, act, "skipping because of epic errors")
        epic

      not is_atom(on) ->
        error(on, "Invalid `on` key provided")
        Epic.add_error(epic, act, {:invalid_on, on})

      # is_struct(object) and object.__struct__ == Changeset ->
      #   maybe_debug(epic, act, object, "Got changeset, marking for deletion")
      #   mark_for_deletion(object, delete_associations)
      #   |> Epic.assign(epic, on, ...)

      is_struct(object) ->
        maybe_debug(epic, act, object, "Got object, marking for deletion")

        repo = Application.get_env(:bonfire, :repo_module)

        delete_associations =
          (Keyword.get(epic.assigns[:options], :delete_associations, []) ++
             (act.options[:delete_extra_associations] || []))
          |> Enum.uniq()

        # try to preload each assocation that should potentially be deleted
        # object = Enum.reduce(delete_associations, object, &repo.maybe_preload(&2, &1, false))

        maybe_debug(
          epic,
          act,
          delete_associations,
          "Delete including these associations"
        )

        epic =
          Enum.reduce(delete_associations, epic, fn assoc, epic ->
            case repo.maybe_preload(object, assoc)
                 |> Map.get(assoc) do
              loaded when is_map(loaded) or (is_list(loaded) and loaded != []) ->
                maybe_debug(epic, act, loaded, "adding association")

                loaded
                |> mark_for_deletion()
                |> Epic.assign(epic, assoc, ...)
                |> Work.add(assoc)

              _ ->
                maybe_debug(epic, act, assoc, "skipping empty association")
                epic
            end
          end)
          |> debug("assoc objects")

        object
        |> mark_for_deletion()
        |> Epic.assign(epic, on, ...)
        |> Work.add(on)

      true ->
        warn(
          object,
          "Don't know how to delete this, expected an ecto struct at opts[:#{on}] but got"
        )

        epic
    end
  end

  defp mark_for_deletion(obj) do
    obj
    |> Changeset.cast(%{}, [])
    |> Map.put(:action, :delete)
    |> debug("deletion changeset")
  end

  # defp mark_for_deletion(changeset, delete_associations) do
  #   changeset
  #   # |> Enum.reduce(delete_associations, ..., &Ecto.build_assoc(&2, &1))
  #   |> mark_for_deletion()
  #   |> debug("changeset")
  # end

  # defp maybe_build_assoc(struct, assoc) do
  #   Ecto.build_assoc(struct, assoc)
  # rescue
  #   e in ArgumentError ->
  #     debug(e, "skip")
  #     struct
  # end

  # defp maybe_put_assoc(changeset, assoc, value \\ nil) do
  #   Changeset.put_assoc(changeset, assoc, value)
  # rescue
  #   e in ArgumentError ->
  #     debug(e, "skip")
  #     changeset
  # end

  @doc """
  Attempts to delete the given objects or struct from the repository.

  This function handles the deletion of objects, whether they are a list, a `Needle.Pointer`, or a regular struct. It returns the number of objects deleted.

  ## Parameters

    - `objects` - The object(s) to be deleted, can be a list or a single struct.
    - `repo` - The repository module to use for deletion.

  ## Examples

      iex> objects = [%SomeStruct{id: 1}, %SomeStruct{id: 2}]
      iex> repo = MyApp.Repo
      iex> Bonfire.Ecto.Acts.Delete.maybe_delete(objects, repo)
      {:ok, 2}

      iex> object = %SomeStruct{id: 1}
      iex> repo = MyApp.Repo
      iex> Bonfire.Ecto.Acts.Delete.maybe_delete(object, repo)
      {:ok, 1}

  """
  def maybe_delete(objects, repo) when is_list(objects) do
    debug(objects)
    # FIXME: optimise
    Enum.each(objects, &maybe_delete(&1, repo))
    # FIXME: returned number 
    {:ok, Enum.count(objects)}
    # objects |> repo.delete_all
  end

  def maybe_delete(%Needle.Pointer{id: id, table_id: table_id} = pointer, repo) do
    schema = Needle.Tables.schema!(table_id)
    debug(schema, id)

    with {num, nil} <-
           repo.delete_all(from p in schema, where: p.id == ^id)
           |> debug() do
      {:ok, num}
    end
  rescue
    e in Ecto.StaleEntryError ->
      warn(e, "already deleted")
      {:ok, 0}

    e in Ecto.MultiplePrimaryKeyError ->
      error(e)

      # FIXME: the above doesn't work for tables with multiple primary keys, just deleting the pointer instead for now
      repo.delete(pointer)
  end

  def maybe_delete(object, repo) do
    debug(object)
    repo.delete(object)
    {:ok, 1}
  rescue
    e in Ecto.StaleEntryError ->
      warn(e, "already deleted")
      {:ok, 0}
  end
end
