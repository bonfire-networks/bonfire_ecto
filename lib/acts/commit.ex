defmodule Bonfire.Ecto.Acts.Commit do
  @moduledoc """
  A placeholder marker used by `Bonfire.Ecto.Acts.Begin` to identify when to commit the transaction.
  """

  def run(epic, act) do
    raise RuntimeError,
      message: """
      Bonfire.Ecto: Attempted to Commit without a Begin first!

      epic: #{inspect(epic)}

      act: #{inspect(act)}
      """
  end
end
