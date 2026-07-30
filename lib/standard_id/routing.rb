require "action_dispatch/routing/mapper"

module StandardId
  # Route-mapper extensions, available inside `Rails.application.routes.draw`.
  module Routing
    # Documents this helper can draw, mapped to their path and controller.
    WELL_KNOWN_DOCUMENTS = {
      oauth_authorization_server: {
        path: "oauth-authorization-server",
        to: "standard_id/api/well_known/oauth_authorization_server#show"
      },
      openid_configuration: {
        path: "openid-configuration",
        to: "standard_id/api/well_known/openid_configuration#show"
      },
      jwks: {
        path: "jwks.json",
        to: "standard_id/api/well_known/jwks#show"
      }
    }.freeze

    # Draw StandardId's discovery documents at the ORIGIN ROOT.
    #
    #   # config/routes.rb
    #   Rails.application.routes.draw do
    #     standard_id_well_known_routes at: "/api/v1"
    #     namespace :api do
    #       mount StandardId::ApiEngine, at: "/", as: :standard_id_api
    #     end
    #   end
    #
    # ## Why the gem cannot just route these itself
    #
    # The engine's own `.well-known` routes live INSIDE its mount, so an app
    # mounting ApiEngine at `/api/v1` serves them at
    # `/api/v1/.well-known/openid-configuration`. But RFC 8615 clients probe the
    # **origin root**, which is outside any engine mount — a mapper helper in the
    # host's routes file is the only place these can be drawn.
    #
    # ## The path-inserted form, and why it is not optional
    #
    # For each document this draws BOTH:
    #
    #   /.well-known/oauth-authorization-server
    #   /.well-known/oauth-authorization-server/api/v1     <- RFC 8414 §3.1
    #
    # The second is the spec's form for an issuer that carries a path: the
    # well-known segment is INSERTED BEFORE the issuer's path rather than appended
    # to it. It looks redundant and it is not. It is the URL Claude Code actually
    # requests in production against a path-carrying issuer; without it the client
    # 404s, falls back to issuer-relative defaults (hitting the engine's real
    # `/authorize` instead of a host audience shim), and every subsequent
    # authenticated request 401s. That failure is remote from its cause and hard
    # to diagnose, which is why the route is drawn for you rather than documented
    # as an extra step.
    #
    # Both forms serve the same document. The mount path is stamped into the
    # route defaults so DiscoveryResolver can build endpoint URLs off it — a root
    # route has no SCRIPT_NAME to read it from.
    #
    # @param at [String] the path ApiEngine is mounted at ("/" or "" for root).
    #   Used both to build the path-inserted routes and to resolve endpoint URLs.
    # @param only [Array<Symbol>, Symbol, nil] restrict to these documents.
    #   Keys: :oauth_authorization_server, :openid_configuration, :jwks. Apps
    #   that keep a host-owned metadata controller but want the gem's JWKS at the
    #   root pass `only: :jwks`.
    # @param except [Array<Symbol>, Symbol, nil] the inverse of `only`.
    # @param extra_paths [Array<String>] additional path-inserted suffixes beyond
    #   `at:`. For serving the same document under a second issuer path (e.g. a
    #   protected resource at `/mcp`) without a second route block.
    # @param path_inserted [Boolean] set false to draw only the bare root forms.
    #   Defaults to true; turning it off is what reintroduces the Claude Code
    #   failure above, so it exists only for apps that route those themselves.
    def standard_id_well_known_routes(at:, only: nil, except: nil, extra_paths: [], path_inserted: true)
      mount_path = StandardId::Oauth::DiscoveryResolver.normalize_path(at)
      documents = StandardId::Routing.selected_documents(only: only, except: except)

      suffixes = path_inserted ? ([mount_path] + Array(extra_paths)).map { |p| StandardId::Oauth::DiscoveryResolver.normalize_path(p) } : []
      suffixes = suffixes.reject(&:empty?).uniq

      defaults = { StandardId::Oauth::DiscoveryResolver::MOUNT_PATH_PARAM => mount_path }

      scope ".well-known" do
        documents.each do |name, config|
          get config[:path], to: config[:to], as: :"standard_id_root_#{name}", defaults: defaults

          # jwks.json is a concrete file path, not a metadata document whose
          # location RFC 8414 §3.1 relocates — a path-inserted variant of it
          # would advertise a URL no spec describes.
          next if name == :jwks

          suffixes.each_with_index do |suffix, index|
            get "#{config[:path]}#{suffix}",
              to: config[:to],
              as: :"standard_id_root_#{name}_at_#{index}",
              defaults: defaults
          end
        end
      end
    end

    # @return [Hash] the WELL_KNOWN_DOCUMENTS entries `only:`/`except:` select
    def self.selected_documents(only: nil, except: nil)
      if only.present? && except.present?
        raise ArgumentError, "standard_id_well_known_routes accepts `only:` or `except:`, not both"
      end

      keys = WELL_KNOWN_DOCUMENTS.keys
      requested = Array(only).map(&:to_sym) + Array(except).map(&:to_sym)
      unknown = requested - keys
      if unknown.any?
        raise ArgumentError,
          "Unknown StandardId well-known document(s): #{unknown.join(', ')}. Valid: #{keys.join(', ')}"
      end

      selected = if only.present?
        Array(only).map(&:to_sym)
      elsif except.present?
        keys - Array(except).map(&:to_sym)
      else
        keys
      end

      WELL_KNOWN_DOCUMENTS.slice(*selected)
    end
  end
end

# Included directly rather than through a load hook: ActionDispatch has no
# `:action_dispatch_routing_mapper` hook, and this file is required from
# lib/standard_id.rb during Bundler.require — long before any routes file is
# evaluated — so the mapper method is defined by the time a host calls it.
ActionDispatch::Routing::Mapper.include(StandardId::Routing)
