Rails.application.routes.draw do
  mount MissionControl::Jobs::Engine, at: "/jobs"

  namespace :admin do
    resources :users
    resources :roles
    resources :api_keys
    resources :mcp_server_types
    resources :mcp_servers
    resources :plan_types
    resources :plans
    resources :invitations do
      member do
        put "/event/:event", to: "invitations#event", as: :event
      end
    end
    root to: "users#index"
  end
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check
  get "healthz", to: "health#show"

  resources :mcp_servers, path: "servers", only: %i[index new create show edit update destroy] do
    collection do
      get :tags
    end
    member do
      get "tools", to: "mcp_servers/tools#index", as: :tools

      get "auth", to: "mcp_servers/auth#show", as: :auth
      get "auth/status", to: "mcp_servers/auth#status", as: :auth_status
      post "auth/credentials", to: "mcp_servers/auth#credentials", as: :auth_credentials
      post "auth/continue", to: "mcp_servers/auth#continue", as: :auth_continue
      match "auth/logout", to: "mcp_servers/auth#logout", via: %i[get post], as: :auth_logout
      post "auth/clear_service", to: "mcp_servers/auth#clear_service", as: :auth_clear_service

      post "oauth", to: "mcp_servers/provider_oauth#create", as: :provider_oauth
      post "auth/save_oauth_token", to: "mcp_servers/provider_oauth#save_token", as: :save_oauth_token
    end
  end

  # MCP host URLs stay unlocalized for connector compatibility.
  scope "/servers/:type_code/:id", as: :instance do
    post "mcp", to: "mcp_servers/mcp#create", as: :mcp
    match "mcp", to: "mcp_servers/mcp#options", via: :options
    get "mcp", to: "mcp_servers/mcp#method_not_allowed"
    delete "mcp", to: "mcp_servers/mcp#method_not_allowed"

    post "tools/:tool", to: "mcp_servers/tools#create", as: :tool

    get "auth/authorize", to: "mcp_servers/oauth#authorize"
    post "auth/register", to: "mcp_servers/oauth#register"
    post "auth/token", to: "mcp_servers/oauth#token"
    post "auth/revoke", to: "mcp_servers/oauth#revoke"
    match "auth/register", to: "mcp_servers/oauth#options", via: :options
    match "auth/token", to: "mcp_servers/oauth#options", via: :options
    match "auth/revoke", to: "mcp_servers/oauth#options", via: :options

    get "oauth_callback", to: "mcp_servers/provider_oauth#callback", as: :oauth_callback

    get ".well-known/oauth-authorization-server", to: "mcp_servers/oauth#authorization_server"
    match ".well-known/oauth-authorization-server", to: "mcp_servers/oauth#options", via: :options
    get ".well-known/openid-configuration", to: "mcp_servers/oauth#authorization_server"
    match ".well-known/openid-configuration", to: "mcp_servers/oauth#options", via: :options
  end

  get "/.well-known/oauth-protected-resource/servers/:type_code/:id/mcp",
      to: "mcp_servers/oauth#protected_resource"
  match "/.well-known/oauth-protected-resource/servers/:type_code/:id/mcp",
        to: "mcp_servers/oauth#options", via: :options
  get "/.well-known/oauth-authorization-server/servers/:type_code/:id",
      to: "mcp_servers/oauth#authorization_server"
  match "/.well-known/oauth-authorization-server/servers/:type_code/:id",
        to: "mcp_servers/oauth#options", via: :options
  get "/.well-known/oauth-authorization-server/servers/:type_code/:id/mcp",
      to: "mcp_servers/oauth#authorization_server"
  match "/.well-known/oauth-authorization-server/servers/:type_code/:id/mcp",
        to: "mcp_servers/oauth#options", via: :options
  get "/.well-known/openid-configuration/servers/:type_code/:id",
      to: "mcp_servers/oauth#authorization_server"
  match "/.well-known/openid-configuration/servers/:type_code/:id",
        to: "mcp_servers/oauth#options", via: :options
  get "/.well-known/openid-configuration/servers/:type_code/:id/mcp",
      to: "mcp_servers/oauth#authorization_server"
  match "/.well-known/openid-configuration/servers/:type_code/:id/mcp",
        to: "mcp_servers/oauth#options", via: :options
  get "/.well-known/openid-configuration",
      to: "mcp_servers/oauth#missing_openid_configuration"
  match "/.well-known/openid-configuration",
        to: "mcp_servers/oauth#options", via: :options

  concern :apiable do
    get "test", to: "test#index"
  end

  # Auth (outside locale scope — session drives I18n, like mydepot)
  get "sign_in", to: "sessions#new", as: :sign_in
  post "sign_in", to: "sessions#create"
  delete "sign_out", to: "sessions#destroy", as: :sign_out
  get "auth/failure", to: "sessions#failure", as: :auth_failure
  get "auth/:provider/callback", to: "sessions#create"

  get "sign_up", to: "registrations#new", as: :sign_up
  post "sign_up", to: "registrations#create"

  get "invitations/consume", to: "invitations#consume", as: :invitation_consume
  get "invitations/consume/:code", to: "invitations#consume", as: :invitation_consume_with_code
  post "invitations/consume", to: "invitations#consume"

  resources :users, only: [ :index, :show, :edit, :update ]

  namespace :api do
    concerns :apiable
    namespace :v1 do
      concerns :apiable
    end
  end

  get "set_session_locale/:locale", to: "locale#set_session_locale", as: :set_session_locale

  legal_slug = /privacy-policy|terms-and-conditions|cookie-policy/
  get "/:slug", to: "static_pages#show", as: :view_static_page,
      constraints: { slug: legal_slug }
  scope "(:locale)", constraints: { locale: /#{Regexp.union(I18n.available_locales.map(&:to_s))}/ } do
    get "/:slug", to: "static_pages#show",
        constraints: { slug: legal_slug }
  end

  root "home#index"
end
