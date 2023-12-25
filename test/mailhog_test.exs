defmodule Mua.MailHogTest do
  use ExUnit.Case, async: true

  @moduletag :mailhog

  # uses https://github.com/mailhog/MailHog
  # docker run -d --rm -p 1025:1025 -p 8025:8025 --name mailhog mailhog/mailhog

  describe "easy_send/4" do
    setup do
      now = DateTime.utc_now()
      message_id = "#{System.system_time()}.#{System.unique_integer([:positive])}.mua@localhost"

      message_body = """
      Date: #{Calendar.strftime(now, "%a, %d %b %Y %H:%M:%S %z")}\r
      Message-ID: #{message_id}\r
      From: Mua <mua@localhost>\r
      Subject: Hey!\r
      To: MailHog <mailhog@@localhost>\r
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
                 _from = "from@mua.example",
                 _rcpts = ["rcpt@mailhog.example"],
                 message.body,
                 port: 1025,
                 timeout: :timer.seconds(1)
               )

      assert %{
               "items" => [
                 %{
                   "Raw" => %{
                     "From" => "from@mua.example",
                     "Helo" => "mua.example",
                     "To" => ["rcpt@mailhog.example"]
                   }
                 }
               ]
             } =
               mailhog_search(%{"kind" => "containing", "query" => message.id})
    end

    test "multiple recipients", %{message: message} do
      assert {:ok, _receipt} =
               Mua.easy_send(
                 _host = "localhost",
                 _from = "from@mua.example",
                 _rcpts = ["to@mailhog.example", _bcc = "bcc@mailhog.example"],
                 message.body,
                 port: 1025,
                 timeout: :timer.seconds(1)
               )

      assert %{
               "items" => [
                 %{
                   "Raw" => %{
                     "From" => "from@mua.example",
                     "Helo" => "mua.example",
                     "To" => ["to@mailhog.example", "bcc@mailhog.example"]
                   }
                 }
               ]
             } = mailhog_search(%{"kind" => "containing", "query" => message.id})
    end

    test "auth", %{message: message} do
      assert {:ok, _receipt} =
               Mua.easy_send(
                 _host = "localhost",
                 _from = "from@mua.example",
                 _rcpts = ["to@mailhog.example", _bcc = "bcc@mailhog.example"],
                 message.body,
                 port: 1025,
                 timeout: :timer.seconds(1),
                 auth: [username: "username", password: "password"]
               )

      assert %{
               "items" => [
                 %{
                   "Raw" => %{
                     "From" => "from@mua.example",
                     "Helo" => "mua.example",
                     "To" => ["to@mailhog.example", "bcc@mailhog.example"]
                   }
                 }
               ]
             } = mailhog_search(%{"kind" => "containing", "query" => message.id})
    end

    test "invalid host (mailhog http api)", %{message: message} do
      assert {:error, %Mua.TransportError{reason: :timeout}} =
               Mua.easy_send(
                 _host = "localhost",
                 _from = "from@mua.example",
                 _rcpts = ["to@mailhog.example", _bcc = "bcc@mailhog.example"],
                 message.body,
                 port: 8025,
                 timeout: :timer.seconds(1)
               )
    end
  end

  defp mailhog_search(params) do
    Req.get!("http://localhost:8025/api/v2/search?" <> URI.encode_query(params)).body
  end
end
