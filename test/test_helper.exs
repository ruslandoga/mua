shell = Mix.shell()
include = ExUnit.configuration()[:include]

if :online in include do
  with [] <- Mua.mxlookup("gmail.com") do
    shell.error("To enable online tests, please ensure you are connected to the internet.")
  end
end

if :gmail in include do
  has_gmail_creds? = System.get_env("GMAIL_USERNAME") && System.get_env("GMAIL_APP_PASSWORD")

  unless has_gmail_creds? do
    shell.error(
      "To enable Gmail tests, please set the GMAIL_USERNAME and GMAIL_APP_PASSWORD environment variables."
    )
  end
end

if :mailpit in include do
  case :httpc.request(:get, {~c"http://localhost:8025/api/v1/info", []}, [], []) do
    {:ok, {{_version, _status = 200, _reason}, _headers, _body}} ->
      :ok

    {:error, {:failed_connect, [_to_address, {:inet, [:inet], :econnrefused}]}} ->
      shell.error("""
      To enable Mailpit tests, start the local container with the following command:

          docker run -d --rm -p 1025:1025 -p 8025:8025 -e "MP_SMTP_AUTH_ACCEPT_ANY=1" -e "MP_SMTP_AUTH_ALLOW_INSECURE=1" --name mailpit axllent/mailpit
      """)
  end
end

ExUnit.start(exclude: [:online, :gmail, :mailpit])
