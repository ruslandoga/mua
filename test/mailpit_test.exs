defmodule Mua.MailpitTest do
  use ExUnit.Case, async: true

  @moduletag :mailpit

  describe "easy_send/4" do
    setup do
      now = DateTime.utc_now()
      message_id = "#{System.system_time()}.#{System.unique_integer([:positive])}.mua@localhost"

      message_body = """
      Date: #{Calendar.strftime(now, "%a, %d %b %Y %H:%M:%S %z")}\r
      Message-ID: #{message_id}\r
      From: Mua <mua@localhost>\r
      Subject: Hey!\r
      To: Mailpit <mailpit@localhost>\r
      \r
      How was your day? Long time no see!\r
      .\r
      """

      {:ok, message: %{id: message_id, body: message_body}}
    end

    test "one recipient", %{message: message} do
      assert {:ok, _receipt} =
               Mua.easy_send(
                 _host = "localhost",
                 _from = "mua@localhost",
                 _rcpts = ["mailpit@localhost"],
                 message.body,
                 port: 1025,
                 timeout: :timer.seconds(1)
               )

      assert %{
               "messages" => [
                 %{
                   "From" => %{"Address" => "mua@localhost", "Name" => "Mua"},
                   "To" => [%{"Address" => "mailpit@localhost", "Name" => "Mailpit"}],
                   "Cc" => [],
                   "Bcc" => []
                 }
               ]
             } =
               mailpit_search(%{"query" => "message-id:" <> message.id})
    end

    test "multiple recipients", %{message: message} do
      assert {:ok, _receipt} =
               Mua.easy_send(
                 _host = "localhost",
                 _from = "mua@localhost",
                 _rcpts = ["mailpit@localhost", _bcc = "bcc@localhost"],
                 message.body,
                 port: 1025,
                 timeout: :timer.seconds(1)
               )

      assert %{
               "messages" => [
                 %{
                   "From" => %{"Address" => "mua@localhost", "Name" => "Mua"},
                   "To" => [%{"Address" => "mailpit@localhost", "Name" => "Mailpit"}],
                   "Cc" => [],
                   "Bcc" => [%{"Address" => "bcc@localhost"}]
                 }
               ]
             } = mailpit_search(%{"query" => "message-id:" <> message.id})
    end

    test "auth", %{message: message} do
      assert {:ok, _receipt} =
               Mua.easy_send(
                 _host = "localhost",
                 _from = "mua@localhost",
                 _rcpts = ["mailpit@localhost"],
                 message.body,
                 port: 1025,
                 timeout: :timer.seconds(1),
                 auth: [username: "username", password: "password"]
               )

      assert %{
               "messages" => [
                 %{
                   "From" => %{"Address" => "mua@localhost", "Name" => "Mua"},
                   "To" => [%{"Address" => "mailpit@localhost", "Name" => "Mailpit"}]
                 }
               ]
             } = mailpit_search(%{"query" => "message-id:" <> message.id})
    end
  end

  defp mailpit_search(params) do
    url = String.to_charlist("http://localhost:8025/api/v1/search?" <> URI.encode_query(params))

    http_opts = [
      timeout: :timer.seconds(15),
      connect_timeout: :timer.seconds(15)
    ]

    opts = [
      body_format: :binary
    ]

    case :httpc.request(:get, {url, _headers = []}, http_opts, opts) do
      {:ok, {{_, status, _}, headers, body} = response} ->
        unless status == 200 do
          raise "failed GET #{url} with #{inspect(response)}"
        end

        Jason.decode!(body)

      {:error, reason} ->
        raise "failed GET #{url} with #{inspect(reason)}"
    end
  end
end
