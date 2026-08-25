defmodule Mua.MailpitTest do
  use ExUnit.Case, async: true

  @moduletag :mailpit

  @plain_smtp_port 1025
  @plain_api_port 8025
  @starttls_smtp_port 1026
  @starttls_api_port 8026
  @starttls_no_auth_smtp_port 1027
  @starttls_no_auth_api_port 8027
  @timeout :timer.seconds(5)

  describe "easy_send/5" do
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
                 port: @plain_smtp_port,
                 timeout: @timeout
               )

      assert %{
               "messages" => [
                 %{
                   "From" => %{"Address" => "mua@localhost", "Name" => "Mua"},
                   "To" => [%{"Address" => "mailpit@localhost", "Name" => "Mailpit"}],
                   "Cc" => nil,
                   "Bcc" => nil
                 }
               ]
             } =
               mailpit_search(%{"query" => "message-id:" <> message.id}, @plain_api_port)
    end

    test "multiple recipients", %{message: message} do
      assert {:ok, _receipt} =
               Mua.easy_send(
                 _host = "localhost",
                 _from = "mua@localhost",
                 _rcpts = ["mailpit@localhost", _bcc = "bcc@localhost"],
                 message.body,
                 port: @plain_smtp_port,
                 timeout: @timeout
               )

      assert %{
               "messages" => [
                 %{
                   "From" => %{"Address" => "mua@localhost", "Name" => "Mua"},
                   "To" => [%{"Address" => "mailpit@localhost", "Name" => "Mailpit"}],
                   "Cc" => nil,
                   "Bcc" => [%{"Address" => "bcc@localhost"}]
                 }
               ]
             } =
               mailpit_search(%{"query" => "message-id:" <> message.id}, @plain_api_port)
    end

    test "explicit plaintext authentication", %{message: message} do
      assert {:ok, _receipt} =
               Mua.easy_send(
                 _host = "localhost",
                 _from = "mua@localhost",
                 _rcpts = ["mailpit@localhost"],
                 message.body,
                 port: @plain_smtp_port,
                 timeout: @timeout,
                 starttls: :never,
                 auth: [username: "username", password: "password"]
               )

      assert %{
               "messages" => [
                 %{
                   "ID" => id,
                   "From" => %{"Address" => "mua@localhost", "Name" => "Mua"},
                   "To" => [%{"Address" => "mailpit@localhost", "Name" => "Mailpit"}]
                 }
               ]
             } =
               mailpit_search(%{"query" => "message-id:" <> message.id}, @plain_api_port)

      assert %{"Username" => "username"} = mailpit_summary(id, @plain_api_port)
    end

    test "explicit opportunistic authentication", %{message: message} do
      assert {:ok, _receipt} =
               Mua.easy_send(
                 "localhost",
                 "mua@localhost",
                 ["mailpit@localhost"],
                 message.body,
                 port: @plain_smtp_port,
                 timeout: @timeout,
                 starttls: :if_available,
                 auth: [username: "username", password: "password"]
               )

      assert %{"messages" => [%{"ID" => id}]} =
               mailpit_search(%{"query" => "message-id:" <> message.id}, @plain_api_port)

      assert %{"Username" => "username"} = mailpit_summary(id, @plain_api_port)
    end

    test "requires STARTTLS by default for authentication", %{message: message} do
      assert {:error, %Mua.TransportError{reason: :starttls_required}} =
               Mua.easy_send(
                 "localhost",
                 "mua@localhost",
                 ["mailpit@localhost"],
                 message.body,
                 port: @plain_smtp_port,
                 timeout: @timeout,
                 auth: [username: "username", password: "password"]
               )

      assert %{"messages" => []} =
               mailpit_search(%{"query" => "message-id:" <> message.id}, @plain_api_port)
    end

    test "authenticates over required STARTTLS", %{message: message} do
      assert {:ok, _receipt} =
               Mua.easy_send(
                 "localhost",
                 "mua@localhost",
                 ["mailpit@localhost"],
                 message.body,
                 port: @starttls_smtp_port,
                 timeout: @timeout,
                 ssl: [verify: :verify_none],
                 auth: [username: "username", password: "password"]
               )

      assert %{"messages" => [%{"ID" => id}]} =
               mailpit_search(%{"query" => "message-id:" <> message.id}, @starttls_api_port)

      assert %{"Username" => "username"} = mailpit_summary(id, @starttls_api_port)
    end

    test "starttls: :never skips advertised STARTTLS", %{message: message} do
      assert {:error, %Mua.SMTPError{code: 530}} =
               Mua.easy_send(
                 "localhost",
                 "mua@localhost",
                 ["mailpit@localhost"],
                 message.body,
                 port: @starttls_smtp_port,
                 timeout: @timeout,
                 starttls: :never,
                 auth: [username: "username", password: "password"]
               )

      assert %{"messages" => []} =
               mailpit_search(%{"query" => "message-id:" <> message.id}, @starttls_api_port)
    end

    test "does not invent an authentication mechanism after STARTTLS", %{message: message} do
      assert {:error, %Mua.TransportError{reason: :auth_not_supported}} =
               Mua.easy_send(
                 "localhost",
                 "mua@localhost",
                 ["mailpit@localhost"],
                 message.body,
                 port: @starttls_no_auth_smtp_port,
                 timeout: @timeout,
                 ssl: [verify: :verify_none],
                 auth: [username: "username", password: "password"]
               )

      assert %{"messages" => []} =
               mailpit_search(
                 %{"query" => "message-id:" <> message.id},
                 @starttls_no_auth_api_port
               )
    end

    test "does not downgrade after a TLS handshake failure", %{message: message} do
      assert {:error, %Mua.TransportError{reason: {:tls_alert, _alert}}} =
               Mua.easy_send(
                 "localhost",
                 "mua@localhost",
                 ["mailpit@localhost"],
                 message.body,
                 port: @starttls_smtp_port,
                 timeout: @timeout,
                 auth: [username: "username", password: "password"]
               )

      assert %{"messages" => []} =
               mailpit_search(%{"query" => "message-id:" <> message.id}, @starttls_api_port)
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
               port: @plain_smtp_port,
               timeout: @timeout
             )

    assert %{"messages" => [%{"ID" => id}]} =
             mailpit_search(%{"query" => "message-id:#{message_id}"}, @plain_api_port)

    assert %{
             "Text" => """
             This is a test message
             . with a dot
             in a line
             .. and now two dots
             in a line
             \r
             """
           } = mailpit_summary(id, @plain_api_port)
  end

  # https://mailpit.axllent.org/docs/api-v1/view.html#get-/api/v1/search
  defp mailpit_search(params, api_port) do
    mailpit_get("/api/v1/search?" <> URI.encode_query(params), api_port)
  end

  # https://mailpit.axllent.org/docs/api-v1/view.html#get-/api/v1/message/-ID-
  defp mailpit_summary(id, api_port) do
    mailpit_get("/api/v1/message/#{id}", api_port)
  end

  defp mailpit_get(path, api_port) do
    url = String.to_charlist("http://localhost:#{api_port}" <> path)

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
