defmodule Bonfire.Ecto.Acts.Delete do
  @moduledoc """
  An act that marks a changeset or struct for deletion
  """
  # alias Bonfire.Epics.Act
  alias Bonfire.Epics.Epic

  alias Bonfire.Ecto.Acts.Work
  # alias Ecto.Changeset
  import Bonfire.Epics
  use Arrows
  import Untangle
  # import Ecto.Query, only: [from: 2]

  def run(epic, act) do
    on = act.options[:on]
    object = epic.assigns[on]

    delete_associations =
      (Keyword.get(epic.assigns[:options], :delete_associations, []) ++
         (act.options[:delete_extra_associations] || []))
      |> Enum.uniq()

    maybe_debug(
      epic,
      act,
      delete_associations,
      "Delete including these associations"
    )

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

        # try to preload each assocation that should potentially be deleted
        # object = Enum.reduce(delete_associations, object, &repo.maybe_preload(&2, &1, false))

        epic =
          Enum.reduce(delete_associations, epic, fn assoc, epic ->
            case repo.maybe_preload(object, assoc)
                 |> Map.get(assoc) do
              loaded when is_map(loaded) or is_list(loaded) ->
                maybe_debug(epic, act, loaded, "adding association")

                loaded
                # |> mark_for_deletion()
                |> Epic.assign(epic, assoc, ...)
                |> Work.add(assoc)

              _ ->
                maybe_debug(epic, act, assoc, "skipping empty association")
                epic
            end
          end)

        # |> debug("assoc objects")

        object
        # |> mark_for_deletion()
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

  # defp mark_for_deletion(obj) do
  #   obj
  #   |> Changeset.cast(%{}, [])
  #   |> Map.put(:action, :delete)
  #   |> debug("changeset")
  # end

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

  def maybe_delete(objects, repo) when is_list(objects) do
    # FIXME: optimise
    Enum.each(objects, &maybe_delete(&1, repo))
    {:ok, nil}
  end

  # def maybe_delete(%Pointers.Pointer{id: id}, repo) do
  #   id
  #   |> debug()
  #   # TODO: not sure if this right
  #   repo.delete_all(from p in Pointers.Pointer, where: p.id == ^id)
  #   |> debug()
  # rescue
  #   e in Ecto.StaleEntryError ->
  #     warn(e, "already deleted")
  #     {:ok, nil}
  # end

  def maybe_delete(object, repo) do
    debug(object)
    repo.delete(object)
  rescue
    e in Ecto.StaleEntryError ->
      warn(e, "already deleted")
      {:ok, nil}
  end
end
