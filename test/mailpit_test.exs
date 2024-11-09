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
      How was your day? Long time no see!
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

  # https://github.com/swoosh/swoosh/issues/968
  test "period at start of line is escaped" do
    message_id = "#{System.system_time()}.#{System.unique_integer([:positive])}.mua@localhost"

    assert {:ok, _receipt} =
             Mua.easy_send(
               _host = "localhost",
               _from = "me@localhost",
               _rcpts = ["you@localhost"],
               """
               Message-ID: <#{message_id}>
               Date: Fri, 30 Sep 2016 12:02:00 +0200
               From: me@localhost
               To: you@localhost
               Subject: Test message

               This is a test message
               . with a dot
               in a line
               .. and now two dots
               in a line
               """,
               port: 1025
             )

    assert %{"messages" => [%{"ID" => id}]} =
             mailpit_search(%{"query" => "message-id:#{message_id}"})

    assert %{
             "Text" => """
             This is a test message
             . with a dot
             in a line
             .. and now two dots
             in a line
             \r
             """
           } = mailpit_summary(id)
  end

  # https://mailpit.axllent.org/docs/api-v1/view.html#get-/api/v1/search
  defp mailpit_search(params) do
    mailpit_get("/api/v1/search?" <> URI.encode_query(params))
  end

  # https://mailpit.axllent.org/docs/api-v1/view.html#get-/api/v1/message/-ID-
  defp mailpit_summary(id) do
    mailpit_get("/api/v1/message/#{id}")
  end

  defp mailpit_get(path) do
    url = String.to_charlist(Path.join("http://localhost:8025", path))

    http_opts = [
      timeout: :timer.seconds(15),
      connect_timeout: :timer.seconds(15)
    ]

    opts = [
      body_format: :binary
    ]

    case :httpc.request(:get, {url, _req_headers = []}, http_opts, opts) do
      {:ok, {{_, status, _}, _resp_headers, body} = response} ->
        unless status == 200 do
          raise "failed GET #{url} with #{inspect(response)}"
        end

        Jason.decode!(body)

      {:error, reason} ->
        raise "failed GET #{url} with #{inspect(reason)}"
    end
  end
end
