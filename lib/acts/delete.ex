defmodule Bonfire.Ecto.Acts.Delete do
  @moduledoc """
  An act that marks a changeset or struct for deletino
  """
  alias Bonfire.Epics.{Act, Epic}
  alias Ecto.Changeset
  import Bonfire.Epics
  use Arrows
  import Where

  def run(epic, act) do
    on = act.options[:on]
    subject = epic.assigns[on]
    cond do
      epic.errors != [] ->
        maybe_debug(epic, act, "skipping because of epic errors")
        epic
      not is_atom(on) ->
        error(on, "Invalid `on` key provided")
        Epic.add_error(epic, act, {:invalid_on, on})
      !is_struct(subject) || (subject.__struct__ != Changeset && !subject[:__meta__]) ->
        warn(subject, "don't know how to delete this, expected a changeset or ecto struct")
        epic
      subject.__struct__ == Changeset ->
        maybe_debug(epic, act, "Got changeset, marking for deletion")
        Epic.assign(epic, on, Map.put(subject, :action, :delete))
      true ->
        maybe_debug(epic, act, "Got object, marking for deletion")
        Changeset.cast(subject, %{}, [])
        |> Map.put(:action, :delete)
        |> Epic.assign(epic, on, ...)
    end
  end
end
