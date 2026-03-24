class AddNullifyToRefreshTokenPreviousTokenFk < ActiveRecord::Migration[8.0]
  def change
    remove_foreign_key :standard_id_refresh_tokens, column: :previous_token_id
    add_foreign_key :standard_id_refresh_tokens, :standard_id_refresh_tokens,
      column: :previous_token_id, on_delete: :nullify
  end
end
