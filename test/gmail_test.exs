defmodule Mua.GmailTest do
  use ExUnit.Case, async: true

  # these tests do not run by default
  # to run the, use:
  #     mix test --include gmail

  @moduletag :gmail

  test "&amp; is unescaped" do
    username = System.fetch_env!("GMAIL_USERNAME")
    password = System.fetch_env!("GMAIL_APP_PASSWORD")

    message_id = "#{System.system_time()}.#{System.unique_integer([:positive])}." <> username

    text = """
    How was your day? Long time no see!

    Visit: https://example.com/?c=d&a=b
    """

    html = """
    <p>How was your day? Long time no see!</p>

    <p>Visit <a href="https://example.com/?c=d&amp;a=b">this place!</a></p>
    """

    message =
      Mail.build_multipart()
      |> Mail.Message.put_header("Date", DateTime.utc_now())
      |> Mail.Message.put_header("Message-ID", message_id)
      |> Mail.put_from({"Mua", username})
      |> Mail.put_to({"Myself", username})
      |> Mail.put_subject("Hey!")
      |> Mail.put_text(text)
      |> Mail.put_html(html)
      |> Mail.render()

    assert {:ok, _} =
             Mua.easy_send("smtp.gmail.com", username, [username], message,
               port: 587,
               auth: [username: username, password: password]
             )
  end
end
