require "securerandom"

module Admin
  class ClientsController < ApplicationController
    before_action :set_client, only: [:show, :edit, :update, :destroy, :rotate_secret]

    def index
      @clients = current_account.client_applications.includes(:client_secret_credentials)
    end

    def show
      @client_secrets = @client.client_secret_credentials.active
    end

    def new
      @client = current_account.client_applications.build
    end

    def create
      @client = current_account.client_applications.build(client_params)

      # Build initial client secret via nested attributes to ensure atomic save
      if @client.confidential? && @client.client_secret_credentials.empty?
        @client.client_secret_credentials.build(
          name: "Initial Secret"
        )
      end

      if @client.save
        redirect_to client_path(@client), notice: "Client application created successfully."
      else
        render :new, status: :unprocessable_content
      end
    end

    def edit
    end

    def update
      if @client.update(client_params)
        redirect_to client_path(@client), notice: "Client application updated successfully."
      else
        render :edit, status: :unprocessable_content
      end
    end

    def destroy
      @client.destroy!
      redirect_to clients_path, notice: "Client application deleted successfully."
    end

    def rotate_secret
      if @client.confidential?
        new_secret = @client.rotate_client_secret!
        flash[:notice] = "Client secret rotated successfully."
        flash[:secret_value] = new_secret.client_secret # Show once for copying
      else
        flash[:alert] = "Cannot rotate secret for public clients."
      end

      redirect_to client_path(@client)
    end

    private

    def set_client
      @client = current_account.client_applications.find(params[:id])
    end

    def client_params
      params.require(:client_application).permit(
        :name, :description, :redirect_uris, :scopes, :grant_types,
        :response_types, :client_type, :require_pkce, :code_challenge_methods,
        :access_token_lifetime, :authorization_code_lifetime,
        :require_consent, :metadata,
        client_secret_credentials_attributes: [:name]
      )
    end
  end
end
