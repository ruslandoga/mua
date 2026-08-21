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
  mailpit_api_ports = [8025, 8026, 8027]

  unavailable_ports =
    Enum.reject(mailpit_api_ports, fn port ->
      url = String.to_charlist("http://localhost:#{port}/api/v1/info")

      match?(
        {:ok, {{_version, _status = 200, _reason}, _headers, _body}},
        :httpc.request(:get, {url, []}, [], [])
      )
    end)

  if unavailable_ports != [] do
    shell.error("""
    To enable Mailpit tests, start all three local containers:

        docker run -d --rm -p 1025:1025 -p 8025:8025 -e "MP_SMTP_AUTH_ACCEPT_ANY=1" -e "MP_SMTP_AUTH_ALLOW_INSECURE=1" -e "MP_SMTP_DISABLE_RDNS=1" --name mua-mailpit axllent/mailpit:v1.30.7
        docker run -d --rm -p 1026:1025 -p 8026:8025 -e "MP_SMTP_AUTH_ACCEPT_ANY=1" -e "MP_SMTP_DISABLE_RDNS=1" -e "MP_SMTP_REQUIRE_STARTTLS=1" -e "MP_SMTP_TLS_CERT=sans:localhost" -e "MP_SMTP_TLS_KEY=sans:localhost" --name mua-mailpit-starttls axllent/mailpit:v1.30.7
        docker run -d --rm -p 1027:1025 -p 8027:8025 -e "MP_SMTP_DISABLE_RDNS=1" -e "MP_SMTP_REQUIRE_STARTTLS=1" -e "MP_SMTP_TLS_CERT=sans:localhost" -e "MP_SMTP_TLS_KEY=sans:localhost" --name mua-mailpit-starttls-no-auth axllent/mailpit:v1.30.7

    Unavailable Mailpit API ports: #{Enum.join(unavailable_ports, ", ")}
    """)
  end
end

ExUnit.start(exclude: [:online, :gmail, :mailpit])
