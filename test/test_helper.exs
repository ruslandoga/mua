exclude = []
shell = Mix.shell()

exclude =
  case Mua.mxlookup("gmail.com") do
    [_ | _] ->
      exclude

    [] ->
      shell.error("To enable online tests, please ensure you are connected to the internet.")
      [:online | exclude]
  end

exclude =
  case :httpc.request(:get, {~c"http://localhost:8025/api/v1/info", []}, [], []) do
    {:ok, {{_version, _status = 200, _reason}, _headers, _body}} ->
      exclude

    {:error, {:failed_connect, [_to_address, {:inet, [:inet], :econnrefused}]}} ->
      shell.error("""
      To enable Mailpit tests, start the local container with the following command:

          docker run -d --rm -p 1025:1025 -p 8025:8025 -e "MP_SMTP_AUTH_ACCEPT_ANY=1" -e "MP_SMTP_AUTH_ALLOW_INSECURE=1" --name mailpit axllent/mailpit
      """)

      [:mailpit | exclude]
  end

ExUnit.start(exclude: exclude)
