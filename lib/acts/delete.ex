defmodule Bonfire.Ecto.Acts.Delete do
  @moduledoc """
  An act that marks a changeset or struct for deletion
  """
  alias Bonfire.Epics.{Act, Epic}
  alias Bonfire.Ecto.Acts.Work
  alias Ecto.Changeset
  import Bonfire.Epics
  use Arrows
  import Where

  def run(epic, act) do
    on = act.options[:on]
    subject = epic.assigns[on]

    delete_associations = (
      Keyword.get(epic.assigns[:options], :delete_associations, [])
      ++ (act.options[:delete_extra_associations] || [])
    ) |> Enum.uniq()

    maybe_debug(epic, act, delete_associations, "Delete including associations")

    cond do
      epic.errors != [] ->
        maybe_debug(epic, act, "skipping because of epic errors")
        epic
      not is_atom(on) ->
        error(on, "Invalid `on` key provided")
        Epic.add_error(epic, act, {:invalid_on, on})
      # is_struct(subject) and subject.__struct__ == Changeset ->
      #   maybe_debug(epic, act, subject, "Got changeset, marking for deletion")
      #   mark_for_deletion(subject, delete_associations)
      #   |> Epic.assign(epic, on, ...)

      is_struct(subject) ->
        maybe_debug(epic, act, subject, "Got object, marking for deletion")

        # try to preload each assocation that should potentially be deleted
        # subject = Enum.reduce(delete_associations, subject, &Bonfire.Common.Repo.maybe_preload(&2, &1, false))

        epic = Enum.reduce(delete_associations, epic, fn assoc, epic ->
          case Bonfire.Common.Repo.maybe_preload(subject, assoc)
              |> Map.get(assoc) do
                %{} = loaded -> loaded
                                # |> mark_for_deletion()
                                |> Epic.assign(epic, assoc, ...)
                                |> Work.add(assoc)
                _ -> epic
              end
        end)
        # |> debug("assoc objects")

        subject
        # |> mark_for_deletion()
        |> Epic.assign(epic, on, ...)
        |> Work.add(on)

      true ->
        warn(subject, "Don't know how to delete this, expected an ecto struct")
        epic
    end
  end

  defp mark_for_deletion(obj) do
    obj
    |> Changeset.cast(%{}, [])
    |> Map.put(:action, :delete)
    |> debug("changeset")
  end

  defp mark_for_deletion(changeset, delete_associations) do
    changeset
    # |> Enum.reduce(delete_associations, ..., &Ecto.build_assoc(&2, &1))
    |> mark_for_deletion()
    |> debug("changeset")
  end

  defp maybe_build_assoc(struct, assoc) do
    Ecto.build_assoc(struct, assoc)
  rescue
    e in ArgumentError ->
      debug(e, "skip")
      struct
  end

  defp maybe_put_assoc(changeset, assoc, value \\ nil) do
    Changeset.put_assoc(changeset, assoc, value)
  rescue
    e in ArgumentError ->
      debug(e, "skip")
      changeset
  end
end
