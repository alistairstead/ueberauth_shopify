defmodule Ueberauth.Strategy.Shopify do
  @moduledoc """
  Provides an Ueberauth strategy for authenticating with Shopify.

  ### Setup

  Create an application an embedded application in Shopify that your users will authenticate for use.

  Register a new application at: [your github developer page](https://github.com/settings/developers) and get the `client_id` and `client_secret`.

  Include the provider in your configuration for Ueberauth

      config :ueberauth, Ueberauth,
        providers: [
          github: { Ueberauth.Strategy.Shopify, [] }
        ]

  Then include the configuration for shopify.

      config :ueberauth, Ueberauth.Strategy.Shopify.OAuth,
        client_id: System.get_env("SHOPIFY_API_KEY"),
        client_secret: System.get_env("SHOPIFY_SECRET")

  If you haven't already, create a pipeline and setup routes for your callback handler

      pipeline :auth do
        Ueberauth.plug "/auth"
      end

      scope "/auth" do
        pipe_through [:browser, :auth]

        get "/:provider/callback", AuthController, :callback
      end


  Create an endpoint for the callback where you will handle the `Ueberauth.Auth` struct

      defmodule MyApp.AuthController do
        use MyApp.Web, :controller

        def callback_phase(%{ assigns: %{ ueberauth_failure: fails } } = conn, _params) do
          # do things with the failure
        end

        def callback_phase(%{ assigns: %{ ueberauth_auth: auth } } = conn, params) do
          # do things with the auth
        end
      end

  You can edit the behaviour of the Strategy by including some options when you register your provider.

  To set the `uid_field`

      config :ueberauth, Ueberauth,
        providers: [
          shopify: { Ueberauth.Strategy.Shopify, [uid_field: :email] }
        ]

  Default is `:login`

  To set the default 'scopes' (permissions):

      config :ueberauth, Ueberauth,
        providers: [
          shopify: { Ueberauth.Strategy.Shopify, [default_scope: "read_products,read_customers,read_orders"] }
        ]

  Deafult is "read_products,read_customers,read_orders"
  """
  use Ueberauth.Strategy, uid_field: :login,
                          default_scope: "read_products,read_customers,read_orders",
                          oauth2_module: Ueberauth.Strategy.Shopify.OAuth

  alias Ueberauth.Auth.Info
  alias Ueberauth.Auth.Credentials
  alias Ueberauth.Auth.Extra

  @doc """
  Handles the initial redirect to the Shopify authentication page.

  To customize the scope (permissions) that are requested by shopify include them as part of your url:

      "https://{shop_name}.myshopify.com/admin/oauth/authorize?scope=read_products,read_customers,read_orders"

  You can also include a `state` param that shopify will return to you.
  """
  def handle_request!(conn) do
    scopes = conn.params["scope"] || option(conn, :default_scope)
    opts = [ scope: scopes ]
    if conn.params["state"], do: opts = Keyword.put(opts, :state, conn.params["state"])
    opts = Keyword.put(opts, :redirect_uri, callback_url(conn))
    module = option(conn, :oauth2_module)

    redirect!(conn, apply(module, :authorize_url!, [opts]))
  end

  @doc """
  Handles the callback from Shopify. When there is a failure from Shopify the failure is included in the
  `ueberauth_failure` struct. Otherwise the information returned from Shopify is returned in the `Ueberauth.Auth` struct.
  """
  def handle_callback!(%Plug.Conn{ params: %{ "code" => code } } = conn) do
    module = option(conn, :oauth2_module)
    token = apply(module, :get_token!, [[code: code]])

    if token.access_token == nil do
      set_errors!(conn, [error(token.other_params["error"], token.other_params["error_description"])])
    else
      fetch_user(conn, token)
    end
  end

  @doc false
  def handle_callback!(conn) do
    set_errors!(conn, [error("missing_code", "No code received")])
  end

  @doc """
  Cleans up the private area of the connection used for passing the raw Shopify response around during the callback.
  """
  def handle_cleanup!(conn) do
    conn
    |> put_private(:github_user, nil)
    |> put_private(:github_token, nil)
  end

  @doc """
  Fetches the uid field from the Shopify response. This defaults to the option `uid_field` which in-turn defaults to `login`
  """
  def uid(conn) do
    conn.private.github_user[option(conn, :uid_field) |> to_string]
  end

  @doc """
  Includes the credentials from the Shopify response.
  """
  def credentials(conn) do
    token = conn.private.github_token
    scopes = (token.other_params["scope"] || "")
    |> String.split(",")

    %Credentials{
      token: token.access_token,
      refresh_token: token.refresh_token,
      expires_at: token.expires_at,
      token_type: token.token_type,
      expires: !!token.expires_at,
      scopes: scopes
    }
  end

  @doc """
  Fetches the fields to populate the info section of the `Ueberauth.Auth` struct.
  """
  def info(conn) do
    user = conn.private.github_user

    %Info{
      name: user["name"],
      nickname: user["login"],
      email: user["email"],
      location: user["location"],
      urls: %{
        followers_url: user["followers_url"],
        avatar_url: user["avatar_url"],
        events_url: user["events_url"],
        starred_url: user["starred_url"],
        blog: user["blog"],
        subscriptions_url: user["subscriptions_url"],
        organizations_url: user["organizations_url"],
        gists_url: user["gists_url"],
        following_url: user["following_url"],
        api_url: user["url"],
        html_url: user["html_url"],
        received_events_url: user["received_events_url"],
        repos_url: user["repos_url"]
      }
    }
  end

  @doc """
  Stores the raw information (including the token) obtained from the Shopify callback.
  """
  def extra(conn) do
    %Extra {
      raw_info: %{
        token: conn.private.github_token,
        user: conn.private.github_user
      }
    }
  end

  defp fetch_user(conn, token) do
    conn = put_private(conn, :github_token, token)
    case OAuth2.AccessToken.get(token, "/user") do
      { :ok, %OAuth2.Response{status_code: 401, body: _body}} ->
        set_errors!(conn, [error("token", "unauthorized")])
      { :ok, %OAuth2.Response{status_code: status_code, body: user} } when status_code in 200..399 ->
        put_private(conn, :github_user, user)
      { :error, %OAuth2.Error{reason: reason} } ->
        set_errors!(conn, [error("OAuth2", reason)])
    end
  end

  defp option(conn, key) do
    Dict.get(options(conn), key, Dict.get(default_options, key))
  end
end
