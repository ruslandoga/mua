defmodule Bamboo.Mua do
  @moduledoc """
  TODO
  """

  @behaviour Bamboo.Adapter

  @impl true
  def deliver(email, config) do
  end

  @impl true
  def handle_config(config), do: config

  @impl true
  def supports_attachments?, do: false
end
