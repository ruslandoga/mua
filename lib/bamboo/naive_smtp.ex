defmodule Bamboo.NaiveSMTP do
  @moduledoc """
  TODO
  """

  @behaviour Bamboo.Adapter

  @impl true
  def deliver(email, config) do
    email = %{
      sender: email.from,
      recipients: [email.to],
      headers: [],
      subject: email.subject,
      message: email.text_body
    }

    # TODO
    [result] = NaiveSMTP.send(email, config)
    result
  end

  @impl true
  def handle_config(config), do: config

  @impl true
  def supports_attachments?, do: false

  # @doc false
  # def get_sender(%Bamboo.Email{from: from}) do
  #   from
  # end

  # @doc false
  # def get_recipients(%Bamboo.Email{to: to, cc: cc, bcc: bcc}) do
  #   [to] ++ cc ++ bcc
  # end

  # def get_message(%Bamboo.Email{}) do
  # end
end
