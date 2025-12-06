require "rails_helper"

RSpec.describe StandardId::Providers::Base do
  describe "interface contract" do
    let(:base_class) { described_class }

    describe ".provider_name" do
      it "raises NotImplementedError" do
        expect {
          base_class.provider_name
        }.to raise_error(NotImplementedError, /must implement .provider_name/)
      end
    end

    describe ".authorization_url" do
      it "raises NotImplementedError" do
        expect {
          base_class.authorization_url(state: "test", redirect_uri: "http://example.com")
        }.to raise_error(NotImplementedError, /must implement .authorization_url/)
      end
    end

    describe ".get_user_info" do
      it "raises NotImplementedError" do
        expect {
          base_class.get_user_info(code: "test")
        }.to raise_error(NotImplementedError, /must implement .get_user_info/)
      end
    end

    describe ".config_schema" do
      it "returns empty hash by default" do
        expect(base_class.config_schema).to eq({})
      end
    end

    describe ".resolve_params" do
      it "returns params unchanged by default" do
        params = { code: "abc", redirect_uri: "http://example.com" }
        result = base_class.resolve_params(params, context: { flow: :web })

        expect(result).to eq(params)
      end
    end

    describe ".callback_path" do
      it "raises NotImplementedError because provider_name is not implemented" do
        expect { base_class.callback_path }.to raise_error(NotImplementedError)
      end
    end

    describe ".default_scope" do
      it "returns nil by default" do
        expect(base_class.default_scope).to be_nil
      end
    end

    describe ".setup" do
      it "does nothing by default" do
        expect { base_class.setup }.not_to raise_error
      end
    end
  end

  describe "subclass implementation" do
    let(:custom_provider) do
      Class.new(described_class) do
        class << self
          def provider_name
            "custom"
          end

          def authorization_url(state:, redirect_uri:, **options)
            "https://custom.example.com/auth?state=#{state}"
          end

          def get_user_info(code: nil, id_token: nil, access_token: nil, redirect_uri: nil, **options)
            build_response(
              { "sub" => "user_123", "email" => "user@example.com" },
              tokens: { access_token: "token_123" }
            )
          end

          def config_schema
            { custom_client_id: { type: :string, default: nil } }
          end
        end
      end
    end

    it "allows implementing provider_name" do
      expect(custom_provider.provider_name).to eq("custom")
    end

    it "allows implementing authorization_url" do
      url = custom_provider.authorization_url(state: "abc", redirect_uri: "http://example.com")

      expect(url).to eq("https://custom.example.com/auth?state=abc")
    end

    it "allows implementing get_user_info" do
      result = custom_provider.get_user_info(code: "auth_code")

      expect(result[:user_info]["sub"]).to eq("user_123")
      expect(result[:user_info]["email"]).to eq("user@example.com")
      expect(result[:tokens][:access_token]).to eq("token_123")
    end

    it "allows implementing config_schema" do
      expect(custom_provider.config_schema).to eq(
        { custom_client_id: { type: :string, default: nil } }
      )
    end

    describe ".callback_path" do
      it "returns default callback path based on provider_name" do
        expect(custom_provider.callback_path).to eq("/auth/callback/custom")
      end
    end

    describe ".default_scope" do
      it "can be overridden" do
        provider_with_scope = Class.new(described_class) do
          define_singleton_method(:provider_name) { "scoped" }
          define_singleton_method(:authorization_url) { |**| "url" }
          define_singleton_method(:get_user_info) { |**| {} }
          define_singleton_method(:default_scope) { "read write" }
        end

        expect(provider_with_scope.default_scope).to eq("read write")
      end
    end

    describe ".build_response helper" do
      it "builds standardized response format" do
        result = custom_provider.get_user_info(code: "test")

        expect(result).to be_a(HashWithIndifferentAccess)
        expect(result).to have_key(:user_info)
        expect(result).to have_key(:tokens)
      end

      it "compacts nil tokens" do
        provider_with_nil_tokens = Class.new(described_class) do
          class << self
            def provider_name
              "nil_tokens_test"
            end

            def authorization_url(**); end

            def get_user_info(**options)
              build_response(
                { "sub" => "123" },
                tokens: { access_token: "token", refresh_token: nil, id_token: nil }
              )
            end
          end
        end

        result = provider_with_nil_tokens.get_user_info(code: "test")

        expect(result[:tokens]["access_token"]).to eq("token")
        expect(result[:tokens]).not_to have_key(:refresh_token)
        expect(result[:tokens]).not_to have_key("refresh_token")
        expect(result[:tokens]).not_to have_key(:id_token)
        expect(result[:tokens]).not_to have_key("id_token")
      end
    end
  end
end
