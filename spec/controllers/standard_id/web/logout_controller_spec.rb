require "rails_helper"

RSpec.describe StandardId::Web::LogoutController, type: :controller do
  routes { StandardId::WebEngine.routes }

  describe "POST #create" do
    context "when authenticated" do
      before do
        allow(controller).to receive(:authenticated?).and_return(true)
      end

      it "revokes current session and redirects to provided redirect_uri with notice" do
        expect(controller).to receive(:revoke_current_session!).once

        post :create, params: { redirect_uri: "/goodbye" }

        expect(response).to have_http_status(:found)
        expect(response).to redirect_to("/goodbye")
        expect(flash[:notice]).to eq("Successfully signed out")
      end

      it "revokes current session and redirects to root_path with notice when no redirect_uri" do
        expect(controller).to receive(:revoke_current_session!).once

        post :create

        expect(response).to have_http_status(:found)
        expect(response).to redirect_to("/")
        expect(flash[:notice]).to eq("Successfully signed out")
      end
    end

    context "when not authenticated" do
      before do
        allow(controller).to receive(:authenticated?).and_return(false)
      end

      it "redirects to provided redirect_uri and does not revoke session" do
        expect(controller).not_to receive(:revoke_current_session!)

        post :create, params: { redirect_uri: "/landing" }

        expect(response).to have_http_status(:found)
        expect(response).to redirect_to("/landing")
        expect(flash[:notice]).to be_nil
      end

      it "redirects to root_path and does not revoke session when no redirect_uri" do
        expect(controller).not_to receive(:revoke_current_session!)

        post :create

        expect(response).to have_http_status(:found)
        expect(response).to redirect_to("/")
        expect(flash[:notice]).to be_nil
      end
    end
  end
end
