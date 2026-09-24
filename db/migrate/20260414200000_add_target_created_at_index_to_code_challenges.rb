# Superseded by 20260416180511's partial index_code_challenges_on_active_target_created_at; hosts that installed that may skip this one (StandardId::MigrationCheck::SUPERSEDED_BY).
class AddTargetCreatedAtIndexToCodeChallenges < ActiveRecord::Migration[8.0]
  def change
    add_index :standard_id_code_challenges,
      [:realm, :channel, :target, :created_at],
      name: "index_code_challenges_on_target_created_at"
  end
end
